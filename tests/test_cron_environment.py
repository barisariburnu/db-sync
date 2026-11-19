"""Exercise the real runtime environment writer under cron's clean PATH."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class CronEnvironmentTests(unittest.TestCase):
    def test_cron_job_can_resolve_oracle_client_from_runtime_path(self):
        # Dropping PATH from the startup writer must break this real child process.
        startup = (ROOT / ".coolify/start.sh").read_text()
        writer = startup.split("<<'PYENV'\n", 1)[1].split("\nPYENV", 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            oracle = root / "oracle client"
            oracle.mkdir()
            sqlplus = oracle / "sqlplus"
            sqlplus.write_text("#!/bin/sh\nprintf 'oracle-client-resolved\\n'\n")
            sqlplus.chmod(0o755)
            envfile = root / ".env"
            runtime = {"PATH": str(oracle) + ":/usr/bin:/bin"}
            # Redirect only the writer's absolute output path, retaining real I/O.
            with patch.dict(os.environ, runtime, clear=True), patch("pathlib.Path", return_value=envfile):
                exec(compile(writer, str(ROOT / ".coolify/start.sh"), "exec"), {})
            child = subprocess.run(
                ["/bin/bash", "-c", 'source "$1"; sqlplus -V', "cron-probe", str(envfile)],
                env={"HOME": str(root), "PATH": "/usr/bin:/bin"},
                capture_output=True, text=True,
            )
            self.assertEqual(child.returncode, 0, child.stderr)
            self.assertEqual(child.stdout.strip(), "oracle-client-resolved")


if __name__ == "__main__":
    unittest.main()
