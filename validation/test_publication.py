#!/usr/bin/env python3
"""Protect live-report provenance and keep failed attempts visible."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import publish_results as live


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.current = self.root / "current.json"
        self.report = self.root / "RESULTS.md"
        self.data = json.loads(live.BASELINE.read_text())
        self.data["comparison"] = {"regressions": [], "improved_cases": [],
                                   "same_workloads": True, "performance_checked": True}
        self.inputs = {"commit": self.data["build"]["git_commit"], "branch": "main",
                       "files": {"src/Driver.hs": "abc"}, "dirty_inputs": [], "sha256": "digest"}
        self.attempt = {"state": "COMPLETED", "stage": "complete", "exit_code": 0,
                        "started_at": "start", "finished_at": "finish", "reason": "",
                        "inputs": self.inputs, "run_directory": "validation/results/runs/example"}

    def publish(self, attempt=None, data=None):
        live.publish(attempt or self.attempt, self.data if data is None else data,
                     current=self.current, report=self.report)
        return json.loads(self.current.read_text())

    def test_complete_run_includes_failures_and_performance_deltas(self):
        document = self.publish()
        live.verify(document, self.inputs)
        text = self.report.read_text()
        self.assertIn("56 failed or timed-out check records", text)
        self.assertIn("+0.0%", text)
        self.assertIn(self.inputs["commit"], text)
        self.assertIn("does not mean all functionality passes", text)

    def test_results_only_publication_commit_is_allowed(self):
        snapshot = {**self.inputs, "commit": "later-results-only-commit"}
        live.verify(self.publish(), snapshot)

    def test_changed_input_makes_report_stale(self):
        snapshot = {**self.inputs, "files": {"src/Driver.hs": "changed"}}
        with self.assertRaisesRegex(ValueError, "stale"):
            live.verify(self.publish(), snapshot)

    def test_dirty_source_cannot_claim_committed_results(self):
        snapshot = {**self.inputs, "dirty_inputs": ["src/Driver.hs"]}
        with self.assertRaisesRegex(ValueError, "committed"):
            live.verify(self.publish(), snapshot)

    def test_partial_or_short_runs_cannot_replace_current_results(self):
        self.publish()
        overview = self.current.parent / "overview.svg"
        before = self.current.read_bytes(), self.report.read_bytes(), overview.read_bytes()
        for key, value in [("complete_suite", False), ("repetitions", 1)]:
            data = {**self.data, key: value}
            with self.assertRaisesRegex(ValueError, "partial/short"):
                self.publish(data=data)
            self.assertEqual(before, (self.current.read_bytes(), self.report.read_bytes(), overview.read_bytes()))

    def test_failed_attempt_retains_but_labels_older_complete_results(self):
        before = self.publish()
        failed = {**self.attempt, "state": "FAILED", "stage": "build", "exit_code": 1,
                  "reason": "build failed", "inputs": {**self.inputs, "commit": "new-commit"}}
        live.publish(failed, current=self.current, report=self.report)
        after = json.loads(self.current.read_text())
        self.assertEqual(before["latest_completed_run"], after["latest_completed_run"])
        self.assertIn("Last completed suite (older results)", self.report.read_text())
        self.assertIn("PREVIOUS COMPLETE RUN", (self.current.parent / "overview.svg").read_text())
        with self.assertRaisesRegex(ValueError, "did not complete"):
            live.verify(after, self.inputs)

    def test_recorder_commit_mismatch_is_rejected(self):
        data = copy.deepcopy(self.data)
        data["build"]["git_commit"] = "different"
        with self.assertRaisesRegex(ValueError, "commit differs"):
            self.publish(data=data)

    def test_different_environment_withholds_speed_deltas(self):
        data = copy.deepcopy(self.data)
        data["machine"]["cpu_model"] = "different"
        self.publish(data=data)
        self.assertIn("speed deltas are withheld", self.report.read_text())
        self.assertNotIn("+0.0%", self.report.read_text())

    def test_snapshot_detects_added_changed_and_deleted_source_but_ignores_report(self):
        def git(*args):
            subprocess.run(["git", *args], cwd=self.root, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git("init")
        git("config", "user.name", "Test")
        git("config", "user.email", "test@example.invalid")
        (self.root / "src").mkdir()
        source = self.root / "src/Driver.hs"
        source.write_text("original")
        git("add", "src")
        git("commit", "-m", "test")
        initial = live.input_snapshot(self.root)
        self.report.write_text("report-only change")
        self.assertEqual(initial["files"], live.input_snapshot(self.root)["files"])
        source.write_text("changed")
        self.assertNotEqual(initial["files"], live.input_snapshot(self.root)["files"])
        self.assertEqual(live.input_snapshot(self.root)["dirty_inputs"], ["src/Driver.hs"])
        source.unlink()
        self.assertIsNone(live.input_snapshot(self.root)["files"]["src/Driver.hs"])
        (self.root / "src/New.hs").write_text("new")
        self.assertIn("src/New.hs", live.input_snapshot(self.root)["dirty_inputs"])


if __name__ == "__main__":
    unittest.main()
