"""A broken acceptance reference must not leave an older run looking current."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check


class CheckFailureTests(unittest.TestCase):
    def test_build_launch_failure_is_recorded(self):
        self.check_process_failure("build", FileNotFoundError("cabal missing"), "build")

    def test_recorder_launch_failure_is_recorded(self):
        self.check_process_failure("recorder", OSError("cannot start recorder"), "suite")

    def test_unreadable_recorder_result_is_recorded(self):
        self.check_process_failure("json", None, "suite")

    def test_interruption_is_recorded(self):
        self.check_process_failure("build", KeyboardInterrupt(), "build", expected_status=130)

    def check_process_failure(self, failure_at, error, stage, *, expected_status=1):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "run"
            config = root / "config.json"
            config.write_text("{}")
            inputs = {"sha256": "candidate", "files": {}, "commit": "parent"}

            def recorder(*args, **kwargs):
                if failure_at == "recorder":
                    raise error
                output.mkdir()
                (output / "results.json").write_text("{")
                return 0

            with (patch("sys.argv", ["check.py", "--working-tree", "--output", str(output),
                                     "--config", str(config)]),
                  patch.object(check.live, "input_snapshot", return_value=inputs),
                  patch.object(check.run, "sql_client", return_value="12.3.3-MariaDB"),
                  patch.object(check.subprocess, "run") as build,
                  patch.object(check.subprocess, "call", side_effect=recorder),
                  patch.object(check, "install_runtime_data", return_value=0) as install,
                  patch.object(check.live, "publish") as publish):
                if failure_at == "install":
                    install.side_effect = error
                if failure_at == "build":
                    build.side_effect = error
                else:
                    build.return_value.returncode = 0
                self.assertEqual(expected_status, check.main())
            attempt, data = publish.call_args.args
            self.assertEqual("FAILED", attempt["state"])
            self.assertEqual(stage, attempt["stage"])
            self.assertIsNone(data)

    def test_runtime_data_installation_failure_is_recorded(self):
        self.check_process_failure("install", OSError("copy failed"), "runtime data installation")

    def test_runtime_data_installation_interruption_is_recorded(self):
        self.check_process_failure("install", KeyboardInterrupt(), "runtime data installation", expected_status=130)

    def test_install_selects_library_not_executable_setup(self):
        with tempfile.TemporaryDirectory() as folder:
            package = Path(folder)/"mysql-haskell-1.3.3"
            library = package/"opt"
            component = package/"x/mariadb-validation/opt"
            for build in [library, component]:
                build.mkdir(parents=True)
                (build/"setup-config").touch()
            module = library/"build/Database/MySQL/Connection.hi"
            module.parent.mkdir(parents=True)
            module.touch()
            binary = component/"build/mariadb-validation/mariadb-validation"
            with (patch.object(check.run, "executable", return_value=str(binary)),
                  patch.object(check.subprocess, "run") as copy):
                copy.return_value.returncode=0
                self.assertEqual(0, check.install_runtime_data())
                self.assertIn("--builddir="+str(library), copy.call_args.args[0])

    def test_missing_library_install_configuration_is_rejected(self):
        with patch.object(check.run, "executable", return_value="/no/library/executable"):
            with self.assertRaisesRegex(RuntimeError, "Setup configuration"):
                check.install_runtime_data()

    def test_bad_reference_publishes_failed_attempt_and_retains_raw_candidate(self):
        self.check_reference_failure(ValueError("hash mismatch"))

    def test_absent_manifest_cannot_disable_the_ratchet(self):
        self.check_reference_failure(FileNotFoundError("accepted.json absent"), missing=True)

    def check_reference_failure(self, error, *, missing=False):
        original_exists = Path.exists

        def exists(path):
            return False if missing and path.name == "accepted.json" else original_exists(path)

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = root / "run"
            config = root / "config.json"
            config.write_text("{}")
            inputs = {"sha256": "candidate", "files": {}, "commit": "parent"}

            def recorder(*args, **kwargs):
                output.mkdir()
                (output / "results.json").write_text(json.dumps({"complete_suite": True}))
                return 0

            with (patch("sys.argv", ["check.py", "--working-tree", "--output", str(output),
                                     "--config", str(config)]),
                  patch.object(check.live, "input_snapshot", return_value=inputs),
                  patch.object(check.run, "sql_client", return_value="12.3.3-MariaDB"),
                  patch.object(check.subprocess, "run") as build,
                  patch.object(check.subprocess, "call", side_effect=recorder),
                  patch.object(check.stage1_gates, "reference", side_effect=error) as reference,
                  patch.object(Path, "exists", exists),
                  patch.object(check, "install_runtime_data", return_value=0) as install,
                  patch.object(check.live, "publish") as publish):
                build.return_value.returncode = 0
                self.assertEqual(1, check.main())
            reference.assert_called_once()
            attempt, data = publish.call_args.args
            self.assertEqual("FAILED", attempt["state"])
            self.assertEqual("acceptance evidence", attempt["stage"])
            self.assertIn(str(error), attempt["reason"])
            self.assertIsNone(data)
            self.assertTrue((output / "results.json").exists())


if __name__ == "__main__":
    unittest.main()
