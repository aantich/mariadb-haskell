#!/usr/bin/env python3
"""Regression-policy checks, independent of MariaDB and the driver."""
import copy
import unittest
import run


class ComparisonTests(unittest.TestCase):
    def example(self):
        return {"correctness":[{"id":"one","status":"PASS"},{"id":"known","status":"FAIL"}],
                "build":{"workload_files":{"validation/run.py":"a"},"ghc":"9.10.3","cabal":"3.16.1"},
                "machine":{"machine":"arm64"},"server":{"identity":["MariaDB"]},
                "dependency_plan_sha256":"same", "benchmarks":{"read":{"status":"PASS","median_ns_per_unit":100}}}

    def test_pass_becoming_unsupported_is_a_regression(self):
        before=self.example(); after=copy.deepcopy(before)
        after["correctness"][0]["status"]="UNSUPPORTED"
        self.assertTrue(run.compare(after,before,False)["regressions"])

    def test_removing_test_is_a_regression(self):
        before=self.example(); after=copy.deepcopy(before); after["correctness"].pop(0)
        self.assertTrue(run.compare(after,before,False)["regressions"])

    def test_improvement_is_reported(self):
        before=self.example(); after=copy.deepcopy(before); after["correctness"][1]["status"]="PASS"
        self.assertEqual(run.compare(after,before,False)["improved_cases"],["known"])

    def test_slowdown_is_a_regression(self):
        before=self.example(); after=copy.deepcopy(before); after["benchmarks"]["read"]["median_ns_per_unit"]=121
        self.assertTrue(run.compare(after,before,True)["regressions"])

    def test_changed_environment_refuses_speed_comparison(self):
        before=self.example(); after=copy.deepcopy(before); after["machine"]={"machine":"x86_64"}
        self.assertTrue(run.compare(after,before,True)["regressions"])

    def test_known_failure_cannot_be_hidden_as_unavailable(self):
        before=self.example(); after=copy.deepcopy(before); after["correctness"][1]["status"]="ENVIRONMENT_UNAVAILABLE"
        self.assertTrue(run.compare(after,before,False)["regressions"])

    def test_percentile_uses_all_operation_samples(self):
        self.assertEqual(run.percentile([1,2,3,4,5],.5),3)
        self.assertAlmostEqual(run.percentile([1,2,3,4,5],.95),4.8)

    def test_new_failing_test_requires_attention(self):
        before=self.example(); after=copy.deepcopy(before)
        after["correctness"].append({"id":"new","status":"FAIL"})
        self.assertTrue(run.compare(after,before,False)["regressions"])


if __name__ == "__main__": unittest.main()
