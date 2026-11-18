"""Synthetic SDK and build tests; no business service is contacted."""
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from sentry_sdk import isolation_scope
from sentry_sdk.transport import Transport

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
CANARY = "PRIVATE-canary-password-path-sql-body"

class RecordingTransport(Transport):
    def __init__(self, options):
        super().__init__(options)
        self.events = []
        self.envelopes = []
    def capture_envelope(self, envelope):
        self.envelopes.append(envelope)
        for item in envelope.items:
            if item.type == "event":
                self.events.append(item.payload.json)

class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("monitoring"), "monitoring integration is required")
        self.m = importlib.import_module("monitoring")
        self.env = {"SENTRY_DSN": "https://public@example.invalid/1", "SENTRY_ENVIRONMENT": "production", "SENTRY_RELEASE": self.m.APP + "@" + "a" * 40}
    def monitor(self, transport=RecordingTransport):
        value = self.m.Monitor.from_env(self.env, transport=transport)
        self.addCleanup(value.close)
        return value
    def test_sdk_final_envelope_removes_scope_nested_exception_and_frame_secrets(self):
        monitor = self.monitor()
        try:
            try: raise ValueError(CANARY)
            except ValueError as cause: raise RuntimeError(CANARY) from cause
        except RuntimeError as error:
            with isolation_scope() as scope:
                scope.set_client(monitor.client)
                scope.add_attachment(bytes=CANARY.encode(), filename=CANARY)
                scope.add_breadcrumb(message=CANARY, data={"secret": CANARY})
                scope.set_user({"id": CANARY})
                scope.set_context(CANARY, {"secret": CANARY})
                monitor.report(error, "operation_failed")
        events = monitor.client.transport.events
        self.assertEqual(len(events), 1)
        self.assertEqual([[item.type for item in envelope.items] for envelope in monitor.client.transport.envelopes], [["event"]])
        wire = b"".join(envelope.serialize() for envelope in monitor.client.transport.envelopes)
        self.assertNotIn(CANARY.encode(), wire)
        encoded = json.dumps(events)
        self.assertNotIn(CANARY, encoded)
        event = events[0]
        self.assertEqual(event["release"], self.env["SENTRY_RELEASE"])
        self.assertEqual(event["environment"], "production")
        self.assertEqual(set(event), {"event_id", "timestamp", "platform", "level", "environment", "release", "tags", "message", "fingerprint", "exception"})
        self.assertEqual(event["exception"]["values"][0]["type"], "RuntimeError")
    def test_final_whitelist_revalidates_untrusted_sdk_enrichment(self):
        monitor = self.monitor()
        result = monitor.client.options["before_send"]({"event_id": CANARY, "timestamp": CANARY, "release": CANARY, "environment": CANARY, "tags": {"failure_code": CANARY, "job": CANARY}, "request": {"data": CANARY}, "exception": {"values": [{"type": CANARY, "value": CANARY, "stacktrace": {"frames": [{"filename": CANARY, "vars": {"secret": CANARY}}]}}]}}, {})
        self.assertNotIn(CANARY, json.dumps(result))
    def test_disabled_invalid_release_and_failing_transport_are_fail_open(self):
        self.assertIsNone(self.m.Monitor.from_env({}).report(RuntimeError(CANARY)))
        self.assertIsNone(self.m.Monitor.from_env(dict(self.env, SENTRY_RELEASE=CANARY)).client)
        class Broken(Transport):
            def capture_envelope(self, envelope): raise RuntimeError(CANARY)
        self.assertIsNone(self.monitor(Broken).report(RuntimeError(CANARY)))
    def test_same_exception_and_streamlit_control_flow_are_not_reported_twice(self):
        monitor = self.monitor()
        error = RuntimeError(CANARY)
        monitor.report(error)
        monitor.report(error)
        for name in ["RerunException", "StopException"]:
            control = type(name, (BaseException,), {"__module__": "streamlit.runtime.scriptrunner_utils.exceptions"})
            monitor.report(control(CANARY))
        monitor.report(ValueError(CANARY), expected=(ValueError,))
        self.assertEqual(len(monitor.client.transport.events), 1)
    def test_check_is_synthetic_and_queued_does_not_claim_delivery(self):
        monitor = self.monitor()
        self.assertIsNotNone(monitor.check())
        event = monitor.client.transport.events[0]
        self.assertEqual(event["tags"]["job"], "monitoring-check")
        run = subprocess.run([sys.executable, str(ROOT / "monitoring.py"), "monitoring-check"], env=dict(os.environ, SENTRY_DSN=""), capture_output=True, text=True)
        self.assertEqual(run.returncode, 2)
        self.assertEqual(run.stdout.strip(), "monitoring_disabled_or_unavailable")
    def test_build_rejects_invalid_source_before_any_docker_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            script = tmp / "build.sh"
            script.write_text((ROOT / ".coolify/build.sh").read_text())
            docker = tmp / "docker"
            docker.write_text("#!/bin/sh\necho called >> \"$CALL_LOG\"\n")
            docker.chmod(0o755)
            for source in ["bad", "A" * 40, "a" * 39, "a" * 41]:
                run = subprocess.run(["sh", str(script)], cwd=tmp, env=dict(os.environ, SOURCE_COMMIT=source, PATH=str(tmp) + ":" + os.environ["PATH"], CALL_LOG=str(tmp / "calls")), capture_output=True)
                self.assertEqual(run.returncode, 35)
                self.assertFalse((tmp / "calls").exists())
    def test_actual_job_exit_hooks_report_only_failure_and_keep_exit_status(self):
        for job in (ROOT / "scripts").glob("*.sh"):
            text = job.read_text()
            self.assertIn("# END MONITORING EXIT HOOK", text, job.name)
            prefix = text.split("# END MONITORING EXIT HOOK", 1)[0]
            with tempfile.TemporaryDirectory() as tmp:
                tmp = Path(tmp)
                fake = tmp / "python3"
                fake.write_text('#!/bin/sh\necho called >> "$CALL_LOG"\nexit 2\n')
                fake.chmod(0o755)
                for status in [0, 7]:
                    calls = tmp / "calls"
                    calls.unlink(missing_ok=True)
                    script = tmp / "job.sh"
                    script.write_text(prefix + "\nexit " + str(status) + "\n")
                    run = subprocess.run(["bash", str(script)], env=dict(os.environ, PATH=str(tmp)+":"+os.environ["PATH"], CALL_LOG=str(calls)), capture_output=True)
                    self.assertEqual(run.returncode, status)
                    self.assertEqual(calls.exists(), status != 0)

    def test_build_reads_only_source_commit_without_evaluating_other_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            script = tmp / "build.sh"
            script.write_text((ROOT / ".coolify/build.sh").read_text())
            build_env = tmp / "build-time.env"
            build_env.write_text('SOURCE_COMMIT="' + 'b'*40 + '"\nSECRET=$(touch '+str(tmp / "executed")+')\n')
            docker = tmp / "docker"
            service = 'db-sync'
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALL_LOG"\ncase "$*" in *" config") printf "name: project\\n    container_name: '+service+'-project\\n";; inspect*) exit 1;; esac\n')
            docker.chmod(0o755)
            calls = tmp / "calls"
            run = subprocess.run(["sh", str(script), str(build_env)], cwd=tmp, env=dict(os.environ, SOURCE_COMMIT="", PATH=str(tmp)+":"+os.environ["PATH"], CALL_LOG=str(calls)), capture_output=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("--build-arg MONITORING_SOURCE_REVISION=" + "b"*40, calls.read_text())
            self.assertFalse((tmp / "executed").exists())
            calls.unlink()
            build_env.write_text("SOURCE_COMMIT=invalid\n")
            run = subprocess.run(["sh", str(script), str(build_env)], cwd=tmp, env=dict(os.environ, SOURCE_COMMIT="", PATH=str(tmp)+":"+os.environ["PATH"], CALL_LOG=str(calls)), capture_output=True)
            self.assertEqual(run.returncode, 35)
            self.assertFalse(calls.exists())

    def test_existing_graceful_drain_and_legacy_active_job_guard_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            script = tmp / "build.sh"
            script.write_text((ROOT / ".coolify/build.sh").read_text())
            docker = tmp / "docker"
            docker.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$CALL_LOG"\ncase "$*" in\n    *\' config\') printf \'name: project\\n    container_name: db-sync-project\\n\';;\n    *com.docker.compose.project*) echo project;;\n    *com.docker.compose.service*) echo db-sync;;\n    *Config.Entrypoint*) if [ "$LEGACY" = true ]; then echo legacy; else echo /app/.coolify/start.sh; fi;;\n    *State.Running*) echo true;;\n    *State.ExitCode*) echo 0;;\n    top*) printf \'PID COMMAND\\n42 active-job\\n\';;\nesac\n')
            docker.chmod(0o755)
            calls = tmp / "calls"
            for legacy in [True, False]:
                calls.unlink(missing_ok=True)
                run = subprocess.run(["sh", str(script)], cwd=tmp, env=dict(os.environ, SOURCE_COMMIT="c"*40, LEGACY=str(legacy).lower(), PATH=str(tmp)+":"+os.environ["PATH"], CALL_LOG=str(calls)), capture_output=True)
                self.assertEqual(run.returncode, 75 if legacy else 0, run.stderr)
                self.assertEqual("stop --time -1" in calls.read_text(), not legacy)

    def test_job_identifiers_are_closed_and_fingerprint_distinguishes_jobs(self):
        monitor = self.monitor()
        jobs = sorted(self.m._JOBS)
        monitor.failure(jobs[0])
        monitor.failure(jobs[1])
        events = monitor.client.transport.events
        self.assertEqual(events[0]["tags"]["job"], jobs[0])
        self.assertNotEqual(events[0]["fingerprint"], events[1]["fingerprint"])
        monitor.failure(CANARY)
        self.assertNotIn(CANARY, json.dumps(monitor.client.transport.events))

    def test_image_metadata_is_late_and_compose_does_not_override_release(self):
        docker = (ROOT / "Dockerfile").read_text()
        self.assertIn("ARG MONITORING_SOURCE_REVISION", docker)
        self.assertGreater(docker.index("ARG MONITORING_SOURCE_REVISION"), docker.rfind("RUN "))
        self.assertIn("SENTRY_RELEASE=" + self.m.APP + "@${MONITORING_SOURCE_REVISION}", docker)
        compose = (ROOT / ".coolify/compose.yaml").read_text()
        self.assertNotIn("${SOURCE_COMMIT", compose)
        self.assertIn("SENTRY_DSN: ${SENTRY_DSN:-}", compose)
        self.assertNotIn("SENTRY_RELEASE:", compose)

if __name__ == "__main__": unittest.main()
