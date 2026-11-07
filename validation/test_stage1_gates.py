"""Keep every accepted improvement and reject incomparable measurements."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from stage1_gates import compare, reference

def data(status='PASS'):
    return {'correctness': [{'id': 'old.fixed', 'status': status}], 'benchmarks': {}, 'complete_suite': True, 'repetitions': 7, 'source_unchanged_during_run': True, 'machine': {}, 'server': {}, 'dependency_plan_sha256': 'same', 'connector_c_version': 'same', 'build': {'ghc': 'x', 'cabal': 'y', 'workload_files': {p: 'same' for p in ['Validation/Benchmark.hs', 'Validation/Common.hs', 'connector_c.c', 'run.py']}}}

class RatchetTests(unittest.TestCase):

    def test_reintroduced_original_failure_is_caught(self):
        r = compare(data('FAIL'), data('PASS'), data('FAIL'), require_targets=False)
        self.assertFalse(r['correctness_accepted'])
        self.assertIn('accepted: lost PASS', r['correctness_failures'][0])

    def test_missing_case_is_caught(self):
        r = compare({'correctness': []}, data(), data(), require_targets=False)
        self.assertFalse(r['correctness_accepted'])

    def test_failure_cannot_become_inventory(self):
        self.assertFalse(compare(data('UNSUPPORTED'), data('FAIL'), data('FAIL'), require_targets=False)['correctness_accepted'])

    def test_new_inventory_cannot_hide_new_failure(self):
        c = data()
        c['correctness'].append({'id': 'stage1.new', 'status': 'UNSUPPORTED'})
        self.assertFalse(compare(c, data(), data(), require_targets=False)['correctness_accepted'])

    def test_known_deferred_failure_remains_visible(self):
        self.assertTrue(compare(data('FAIL'), data('FAIL'), data('FAIL'), require_targets=False)['correctness_accepted'])

    def test_inventory_case_cannot_introduce_an_unapproved_failure(self):
        for original_status in ['UNSUPPORTED', 'ENVIRONMENT_UNAVAILABLE']:
            for failure_status in ['FAIL', 'TIMEOUT']:
                with self.subTest(original=original_status, current=failure_status):
                    report = compare(data(failure_status), data(original_status),
                                     data(original_status), require_targets=False)
                    self.assertFalse(report['correctness_accepted'])

    def test_unknown_case_status_is_rejected(self):
        report = compare(data('NOT_RUN'), data('FAIL'), data('FAIL'), require_targets=False)
        self.assertFalse(report['correctness_accepted'])

    def test_new_failed_benchmark_is_not_accepted(self):
        current = data()
        current['benchmarks']['haskell/new'] = {'status': 'FAIL'}
        self.assertFalse(compare(current, data(), data(), require_targets=False)['correctness_accepted'])

    def test_previously_unsupported_benchmark_cannot_become_a_deferred_failure(self):
        original = data()
        original['benchmarks']['haskell/bulk'] = {'status': 'UNSUPPORTED'}
        current = copy.deepcopy(original)
        current['benchmarks']['haskell/bulk']['status'] = 'FAIL'
        self.assertFalse(compare(current, original, original, require_targets=False)['correctness_accepted'])

    def test_unsupported_benchmark_inventory_cannot_disappear(self):
        original = data()
        original['benchmarks']['haskell/bulk'] = {'status': 'UNSUPPORTED'}
        self.assertFalse(compare(data(), original, original, require_targets=False)['correctness_accepted'])

    def test_new_pass_is_accepted(self):
        self.assertTrue(compare(data('PASS'), data('FAIL'), data('FAIL'), require_targets=False)['correctness_accepted'])

    def test_timing_and_allocation_five_percent_trigger(self):
        old = data()
        old['benchmarks'] = {'haskell/x': {'status': 'PASS', 'median_ns_per_unit': 100, 'samples': [{'units': 1, 'allocated_bytes': 100}]}}
        new = copy.deepcopy(old)
        new['benchmarks']['haskell/x'].update(median_ns_per_unit=106, samples=[{'units': 1, 'allocated_bytes': 106}])
        r = compare(new, old, old, require_targets=False)
        self.assertTrue(r['performance_requires_confirmation'])
        self.assertEqual(len(r['allocation_investigations']), 2)

    def test_required_targets_cannot_be_omitted(self):
        self.assertFalse(compare(data(), data(), data())['correctness_accepted'])

    def test_profile_change_withholds_comparison(self):
        old = data()
        old['benchmarks'] = {'haskell/x': {'status': 'PASS', 'median_ns_per_unit': 100}}
        new = copy.deepcopy(old)
        new['machine'] = {'cpu': 'other'}
        new['benchmarks']['haskell/x']['median_ns_per_unit'] = 1
        report = compare(new, old, old, require_targets=False)
        self.assertFalse(report['evidence_accepted'])
        self.assertEqual([], report['timing_investigations'])

    def test_connector_version_change_withholds_comparison(self):
        old = data()
        old['benchmarks'] = {'connector-c/x': {'status': 'PASS', 'median_ns_per_unit': 100}}
        new = copy.deepcopy(old)
        new['connector_c_version'] = 'other'
        self.assertFalse(compare(new, old, old, require_targets=False)['evidence_accepted'])

    def test_partial_or_unstable_evidence_is_rejected(self):
        for key, value in [('complete_suite', False), ('repetitions', 1), ('source_unchanged_during_run', False)]:
            current = data()
            current[key] = value
            self.assertFalse(compare(current, data(), data(), require_targets=False)['evidence_accepted'])

    def test_workload_hash_change_is_not_a_speedup(self):
        old = data()
        old['benchmarks'] = {'haskell/x': {'status': 'PASS', 'median_ns_per_unit': 100}}
        new = copy.deepcopy(old)
        new['build']['workload_files']['run.py'] = 'changed'
        self.assertFalse(compare(new, old, old, require_targets=False)['evidence_accepted'])
class AcceptedReferenceTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name) / "results"
        self.archive = self.root / "references/accepted.json"
        self.archive.parent.mkdir(parents=True)
        self.archive.write_text(json.dumps({"build": {"git_commit": "approved"}}))
        self.manifest = self.root / "accepted.json"

    def write_manifest(self, **changes):
        manifest = {"reference": "references/accepted.json", "tested_commit": "approved",
                    "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        manifest.update(changes)
        self.manifest.write_text(json.dumps(manifest))

    def test_approved_archive_is_loaded(self):
        self.write_manifest()
        accepted, manifest = reference(self.manifest)
        self.assertEqual("approved", accepted["build"]["git_commit"])
        self.assertEqual("approved", manifest["tested_commit"])

    def test_modified_reference_is_rejected(self):
        self.write_manifest(sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            reference(self.manifest)

    def test_manifest_commit_must_match_archive(self):
        self.write_manifest(tested_commit="different")
        with self.assertRaisesRegex(ValueError, "tested commit"):
            reference(self.manifest)

    def test_live_candidate_cannot_be_the_reference(self):
        (self.root / "current.json").write_bytes(self.archive.read_bytes())
        self.write_manifest(reference="current.json")
        with self.assertRaisesRegex(ValueError, "own accepted reference"):
            reference(self.manifest)

    def test_reference_cannot_escape_results_directory(self):
        self.write_manifest(reference="../outside.json")
        with self.assertRaisesRegex(ValueError, "escapes"):
            reference(self.manifest)


if __name__ == '__main__':
    unittest.main()
