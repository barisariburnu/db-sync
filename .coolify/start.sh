#!/bin/bash
set -euo pipefail
umask 077
python3 - <<'PYENV'
import os
import shlex
from pathlib import Path
keys = ['LOG_DIR', 'NLS_LANG', 'ORACLE_HOME', 'ORACLE_YONCA_DATABASE', 'ORACLE_YONCA_HOST', 'ORACLE_YONCA_PASSWORD', 'ORACLE_YONCA_PORT', 'ORACLE_YONCA_SCHEMA', 'ORACLE_YONCA_USER', 'PG_EMLAK_DATABASE', 'PG_EMLAK_HOST', 'PG_EMLAK_PASSWORD', 'PG_EMLAK_PORT', 'PG_EMLAK_USER', 'PG_YONCA_DATABASE', 'PG_YONCA_HOST', 'PG_YONCA_PASSWORD', 'PG_YONCA_PORT', 'PG_YONCA_USER', 'TZ']
Path('/app/.env').write_text(''.join(f'{key}={shlex.quote(os.environ[key])}\n' for key in keys if key in os.environ))
PYENV
crontab /app/scripts/crontab
cron -f &
cron_pid=$!
shutdown() {
    trap '' TERM INT
    # Freeze only the scheduler so it cannot launch a new job while its active children are collected.
    kill -STOP "$cron_pid" 2>/dev/null || true
    job_pids=$(python3 - "$cron_pid" <<'PYJOBS'
import pathlib
import sys
parent = int(sys.argv[1])
for stat in pathlib.Path('/proc').glob('[0-9]*/stat'):
    try:
        fields = stat.read_text().rsplit(')', 1)[1].split()
        if int(fields[1]) == parent:
            print(stat.parent.name)
    except (OSError, ValueError, IndexError):
        continue
PYJOBS
)
    kill -TERM "$cron_pid" 2>/dev/null || true
    kill -CONT "$cron_pid" 2>/dev/null || true
    wait "$cron_pid" 2>/dev/null || true
    # Existing jobs keep running; the init process reaps them after they finish.
    for pid in $job_pids; do
        while kill -0 "$pid" 2>/dev/null; do sleep 1; done
    done
    exit 0
}
trap shutdown TERM INT
wait "$cron_pid"
