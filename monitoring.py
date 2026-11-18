"""Fail-open error reporting with a closed, application-owned event envelope."""
from functools import lru_cache
import os
from pathlib import Path
import re
import sys
import time
import traceback
from uuid import uuid4

from sentry_sdk import Client

APP = 'db-sync'
_JOBS = frozenset(['sync-abys-abone-sayac', 'sync-abys-yol-bilgileri', 'sync-sms-gis-building-door', 'sync-sms-gis-building', 'sync-abys-abone-adres-bilgileri', 'sync-abys-yol-bilgileri-2-emlak'])
_CODES = frozenset({"operation_failed", "upload_failed", "upload_audit_failed", "chart_failed", "export_failed", "job_failed", "monitoring_check"})
_TYPES = frozenset({"RuntimeError", "ValueError", "TypeError", "KeyError", "OSError", "PermissionError", "FileNotFoundError", "OperationalError", "DatabaseError", "IntegrityError", "TimeoutError", "ConnectionError"})
_FILES = frozenset({"app.py", "mdb_sync.py", "upload_audit.py", "monitoring.py"})
_ROOT = Path(__file__).resolve().parent


def _control(error):
    return not isinstance(error, Exception) or (
        type(error).__module__.startswith("streamlit.") and
        type(error).__name__ in {"RerunException", "StopException"}
    )


class Monitor:
    """Own an isolated SDK client; never attach business data or global scope."""
    def __init__(self, client=None):
        self.client = client

    @classmethod
    def from_env(cls, env=None, *, transport=None):
        values = os.environ if env is None else env
        dsn = values.get("SENTRY_DSN", "").strip()
        release = values.get("SENTRY_RELEASE", "")
        if not dsn or not re.fullmatch(re.escape(APP) + r"@[0-9a-f]{40}", release):
            return cls()
        if values.get("SENTRY_ENVIRONMENT", "production") != "production":
            return cls()
        try:
            from urllib.parse import urlsplit
            parsed = urlsplit(dsn)
            if parsed.scheme != "https" or not parsed.hostname or not parsed.username or parsed.password or parsed.query or parsed.fragment:
                return cls()
            def before_send(event, hint):
                # Rebuild after SDK processing: no enriched request, scope, SDK,
                # server, local variable, context, breadcrumb or raw exception.
                code = event.get("tags", {}).get("failure_code")
                if code not in _CODES:
                    code = "operation_failed"
                check = code == "monitoring_check"
                job = event.get("tags", {}).get("job")
                if job not in _JOBS:
                    job = "application"
                event_id = event.get("event_id", "")
                if not isinstance(event_id, str) or not re.fullmatch(r"[0-9a-f]{32}", event_id):
                    event_id = uuid4().hex
                safe = {
                    "event_id": event_id, "timestamp": time.time(),
                    "platform": "python", "level": "info" if check else "error",
                    "environment": "production", "release": release,
                    "message": "Synthetic monitoring check" if check else "Application operation failed",
                    "tags": {"app": APP, "component": 'scheduler', "failure_code": code,
                             "job": "monitoring-check" if check else job},
                    "fingerprint": [APP, job, code],
                }
                values = event.get("exception", {}).get("values", [])
                if values and not check:
                    item = values[-1]
                    kind = item.get("type")
                    if kind not in _TYPES:
                        kind = "ApplicationError"
                    frames = []
                    for frame in item.get("stacktrace", {}).get("frames", []):
                        filename, lineno = frame.get("filename"), frame.get("lineno")
                        if filename in _FILES and type(lineno) is int and 0 < lineno < 100000:
                            frames.append({"filename": filename, "lineno": lineno, "in_app": True})
                    safe["exception"] = {"values": [{"type": kind, "value": code, "stacktrace": {"frames": frames[-20:]}}]}
                return safe
            client = Client(
                dsn=dsn, release=release, environment="production", transport=transport,
                default_integrations=False, auto_enabling_integrations=False,
                data_collection={"user_info": False, "cookies": {"mode": "off"}, "http_headers": {"request": {"mode": "off"}}, "http_bodies": [], "url_query_params": {"mode": "off"}, "database_query_data": False, "queues": False, "stack_frame_variables": False, "frame_context_lines": 0},
                include_local_variables=False,
                include_source_context=False, max_breadcrumbs=0,
                max_request_body_size="never", traces_sample_rate=0.0,
                profiles_sample_rate=0.0, enable_logs=False, enable_metrics=False,
                auto_session_tracking=False, send_client_reports=False,
                transport_queue_size=20, shutdown_timeout=2.0,
                before_send=before_send,
            )
            return cls(client)
        except Exception:
            return cls()

    def _capture(self, event):
        if self.client is None:
            return None
        try:
            return self.client.capture_event(event, hint={}, scope=None)
        except Exception:
            return None

    def report(self, error, code="operation_failed", *, expected=()):
        if _control(error) or isinstance(error, expected) or getattr(error, "_monitoring_reported", False):
            return None
        try:
            error._monitoring_reported = True
            frames = []
            for frame, lineno in traceback.walk_tb(error.__traceback__):
                path = Path(frame.f_code.co_filename).resolve()
                if path.parent == _ROOT and path.name in _FILES:
                    frames.append({"filename": path.name, "lineno": lineno})
            return self._capture({"exception": {"values": [{"type": type(error).__name__, "stacktrace": {"frames": frames}}]}, "tags": {"failure_code": code}})
        except Exception:
            return None

    def failure(self, job):
        return self._capture({"tags": {"failure_code": "job_failed", "job": job}})

    def check(self):
        return self._capture({"tags": {"failure_code": "monitoring_check"}})

    def close(self):
        if self.client is not None:
            try:
                self.client.close(timeout=2.0)
            except Exception:
                pass


@lru_cache(maxsize=1)
def get_monitor():
    return Monitor.from_env()


def report(error, code="operation_failed", *, expected=()):
    """Report a caught failure once without changing its original outcome."""
    try:
        return get_monitor().report(error, code, expected=expected)
    except Exception:
        return None


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if args != ["monitoring-check"] and not (len(args) == 2 and args[0] == "job-failed" and args[1] in _JOBS):
        print("usage: monitoring.py monitoring-check")
        return 2
    monitor = Monitor.from_env()
    event_id = monitor.check() if args == ["monitoring-check"] else monitor.failure(args[1])
    monitor.close()
    print("monitoring_queued " + event_id if event_id else "monitoring_disabled_or_unavailable")
    return 0 if event_id else 2


if __name__ == "__main__":
    raise SystemExit(main())
