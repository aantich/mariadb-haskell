"""Guard native-feature evidence units and identity, independently of Haskell."""
import unittest
import copy
import statistics
import json
import hashlib
from pathlib import Path
import tempfile
from unittest.mock import patch
import stage3_benchmarks as native
from stage3_benchmarks import sample, verify_evidence, PROFILES, PAIRS


class NativeSampleTests(unittest.TestCase):
    def record(self, ident='bulk.native', units=5000, checksum=3147500):
        return f'STAGE3\t{ident}\t{units}\t100\t200\t100\t10\t{checksum}\n'

    def test_valid_bulk_record(self):
        self.assertEqual(sample(self.record(), 'bulk.native')['units'], 5000)

    def test_missing_record(self):
        with self.assertRaises(ValueError):
            sample('', 'bulk.native')

    def test_duplicate_record(self):
        with self.assertRaises(ValueError):
            sample(self.record() * 2, 'bulk.native')

    def test_identity_mismatch(self):
        with self.assertRaises(ValueError):
            sample(self.record(), 'bulk.units')

    def test_checksum_mismatch(self):
        with self.assertRaises(ValueError):
            sample(self.record(checksum=1), 'bulk.native')

    def test_unit_mismatch(self):
        with self.assertRaises(ValueError):
            sample(self.record(units=1000), 'bulk.native')

    def test_zero_work(self):
        with self.assertRaises(ValueError):
            sample(self.record(units=0), 'bulk.native')

    def test_negative_counter(self):
        with self.assertRaises(ValueError):
            sample(self.record().replace('\t200\t', '\t-200\t'), 'bulk.native')

    def test_zero_allocation_cannot_be_a_comparison_denominator(self):
        with self.assertRaises(ValueError):
            sample(self.record().replace('\t200\t', '\t0\t'), 'bulk.native')

    def test_wide_query_checksum_and_units(self):
        result = sample(self.record('prepared.wide.cached', 500, 1923500), 'prepared.wide.cached')
        self.assertEqual(result['checksum'], 1923500)


class NativeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.inputs = {'sha256': 'current', 'files': {name: 'digest' for name in ['validation/hs/Validation/Stage3Bench.hs', 'validation/hs/Validation/Common.hs', 'validation/stage3_benchmarks.py']}}
        self.data = {'complete': True, 'repetitions': 7, 'inputs': self.inputs,
                     'profiles': {}, 'comparisons': {}}
        self.data.update(server={}, machine={}, dependencies=[], haskell_benchmark_rts=['-N4', '-T'], build={'ghc': 'compiler', 'cabal': 'tool'})
        for ident, iterations in PROFILES.items():
            units = iterations * (1000 if ident.startswith('bulk.') else 1)
            checksum = iterations * (629500 if ident.startswith('bulk.') else 3847 if '.wide.' in ident else 7)
            entry = {'units': units, 'elapsed_ns': 100, 'allocated_bytes': 200,
                     'cpu_ns': 80, 'gc_cpu_ns': 10, 'checksum': checksum}
            profile = {'samples': [copy.deepcopy(entry) for _ in range(7)]}
            for key in ('elapsed_ns', 'allocated_bytes', 'cpu_ns', 'gc_cpu_ns'):
                profile['median_' + key + '_per_unit'] = statistics.median([entry[key] / units] * 7)
            self.data['profiles'][ident] = profile
        for name, (candidate, reference) in PAIRS.items():
            self.data['comparisons'][name] = {'current': candidate, 'baseline': reference,
                'change_percent': {key: 100 * (self.data['profiles'][candidate]['median_' + key + '_per_unit'] /
                    self.data['profiles'][reference]['median_' + key + '_per_unit'] - 1)
                    for key in ('elapsed_ns', 'allocated_bytes')}}
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.directory = Path(folder.name) / native.BASELINE_DIRECTORY
        self.directory.mkdir(parents=True)
        self.write_baseline()
        location = patch.object(native.run, 'HERE', Path(folder.name))
        location.start()
        self.addCleanup(location.stop)
        native.compare_native_baseline(self.data)

    def write_baseline(self):
        artifacts = {'results.json': (json.dumps(self.data) + '\n').encode(),
                     'SUMMARY.md': b'Immutable native baseline fixture\n'}
        for name, raw in artifacts.items():
            (self.directory / name).write_bytes(raw)
        (self.directory / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256(raw).hexdigest() + '  ' + name + '\n'
            for name, raw in artifacts.items()))

    def test_complete_evidence(self):
        verify_evidence(self.data, self.inputs)

    def test_stale_evidence(self):
        with self.assertRaisesRegex(ValueError, 'stale'):
            verify_evidence(self.data, {'sha256': 'new'})

    def test_partial_evidence(self):
        self.data['complete'] = False
        with self.assertRaises(ValueError):
            verify_evidence(self.data, self.inputs)

    def test_missing_profile(self):
        del self.data['profiles']['bulk.units']
        with self.assertRaises(ValueError):
            verify_evidence(self.data, self.inputs)

    def test_missing_repetition(self):
        self.data['profiles']['bulk.native']['samples'].pop()
        with self.assertRaises(ValueError):
            verify_evidence(self.data, self.inputs)

    def test_changed_median(self):
        self.data['profiles']['bulk.native']['median_elapsed_ns_per_unit'] = 1
        with self.assertRaisesRegex(ValueError, 'summary'):
            verify_evidence(self.data, self.inputs)

    def test_changed_checksum(self):
        self.data['profiles']['bulk.native']['samples'][0]['checksum'] = 1
        with self.assertRaisesRegex(ValueError, 'checksum'):
            verify_evidence(self.data, self.inputs)

    def test_changed_comparison_reference(self):
        self.data['comparisons']['native_vs_sequential']['baseline'] = 'bulk.units'
        with self.assertRaisesRegex(ValueError, 'identity'):
            verify_evidence(self.data, self.inputs)

    def test_changed_comparison_percentage(self):
        self.data['comparisons']['native_vs_sequential']['change_percent']['elapsed_ns'] = 99
        with self.assertRaisesRegex(ValueError, 'comparison'):
            verify_evidence(self.data, self.inputs)

    def test_missing_baseline_comparison(self):
        del self.data['baseline_comparison']
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            verify_evidence(self.data, self.inputs)

    def test_publication_rejects_deleted_baseline(self):
        (self.directory / 'results.json').unlink()
        with self.assertRaisesRegex(ValueError, 'required native baseline'):
            verify_evidence(self.data, self.inputs)

    def test_publication_rejects_changed_baseline(self):
        (self.directory / 'results.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            verify_evidence(self.data, self.inputs)

    def test_publication_recalculates_baseline_deltas(self):
        self.data['baseline_comparison']['profiles']['bulk.native']['elapsed_ns'] = 99
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            verify_evidence(self.data, self.inputs)

    def test_publication_rejects_changed_baseline_alarms(self):
        self.data['baseline_comparison']['timing_investigations'] = [{'id': 'bulk.native', 'percent': 25}]
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            verify_evidence(self.data, self.inputs)

    def test_publication_rejects_false_profile_mismatch(self):
        self.data['baseline_comparison']['comparable'] = False
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            verify_evidence(self.data, self.inputs)


class NativeBaselineTests(unittest.TestCase):
    setUp = NativeEvidenceTests.setUp
    write_baseline = NativeEvidenceTests.write_baseline
    def compare(self, mutation=None, bad_hash=False):
        if mutation:
            mutation()
        if bad_hash:
            (self.directory / 'results.json').write_text('{}')
        native.compare_native_baseline(self.data)
        return self.data['baseline_comparison']

    def test_same_profile_uses_immutable_capture(self):
        comparison = self.compare()
        self.assertTrue(comparison['comparable'])
        self.assertEqual([], comparison['timing_investigations'])

    def test_changed_server_withholds_deltas(self):
        comparison = self.compare(lambda: self.data.update(server={'changed': True}))
        self.assertFalse(comparison['comparable'])
        self.assertEqual({}, comparison['profiles'])

    def test_timing_alarm_is_retained(self):
        def slow():
            self.data['profiles']['bulk.native']['median_elapsed_ns_per_unit'] *= 1.25
        comparison = self.compare(slow)
        self.assertAlmostEqual(25, comparison['timing_investigations'][0]['percent'])

    def test_baseline_tampering_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.compare(bad_hash=True)

    def test_missing_baseline_is_rejected(self):
        (self.directory / 'results.json').unlink()
        with self.assertRaisesRegex(ValueError, 'required native baseline'):
            self.compare()

    def test_missing_checksum_manifest_is_rejected(self):
        (self.directory / 'SHA256SUMS').unlink()
        with self.assertRaisesRegex(ValueError, 'required native baseline'):
            self.compare()

    def test_changed_summary_is_rejected(self):
        (self.directory / 'SUMMARY.md').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.compare()

    def test_dependency_tuples_match_their_json_representation(self):
        self.data['dependencies'] = [('example', '1.0')]
        self.write_baseline()
        self.assertTrue(self.compare()['comparable'])

    def test_policy_fix_preserves_identical_haskell_workload_comparison(self):
        self.inputs['files']['validation/stage3_benchmarks.py'] = 'policy fix'
        self.assertTrue(self.compare()['comparable'])

    def test_changed_workload_withholds_deltas(self):
        self.inputs['files'][native.WORKLOAD_PATHS[0]] = 'changed workload'
        self.assertFalse(self.compare()['comparable'])


if __name__ == '__main__':
    unittest.main()
