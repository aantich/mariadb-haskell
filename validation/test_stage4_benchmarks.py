"""Independently verify reuse work, immutable baselines and publication evidence."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import feature_benchmarks as features
import stage4_benchmarks as reuse


class ReuseEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.spec = reuse.specification()
        self.inputs = {'sha256': 'current', 'commit': 'code',
                       'files': {name: 'digest' for name in reuse.WORKLOAD_PATHS}}
        self.data = {'complete': True, 'repetitions': 7, 'inputs': copy.deepcopy(self.inputs),
                     'server': {}, 'machine': {}, 'dependencies': [],
                     'haskell_benchmark_rts': ['-N4', '-T'],
                     'build': {'ghc': 'compiler', 'cabal': 'tool', 'git_commit': 'code'},
                     'profiles': {}, 'comparisons': {}}
        for ident, count in reuse.PROFILES.items():
            sample = {'units': count, 'elapsed_ns': count * 100, 'allocated_bytes': count * 200,
                      'cpu_ns': count * 80, 'gc_cpu_ns': count * 10, 'checksum': count}
            profile = {'samples': [copy.deepcopy(sample) for _ in range(7)]}
            for key in ('elapsed_ns', 'allocated_bytes', 'cpu_ns', 'gc_cpu_ns'):
                profile['median_' + key + '_per_unit'] = sample[key] / count
            self.data['profiles'][ident] = profile
        for name, (current, baseline) in reuse.PAIRS.items():
            self.data['comparisons'][name] = {'current': current, 'baseline': baseline,
                'change_percent': {'elapsed_ns': 0.0, 'allocated_bytes': 0.0}}
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        self.directory = root / reuse.BASELINE_DIRECTORY
        self.directory.mkdir(parents=True)
        artifacts = {'results.json': json.dumps(self.data).encode(), 'SUMMARY.md': b'first reuse capture\n'}
        for name, raw in artifacts.items():
            (self.directory / name).write_bytes(raw)
        (self.directory / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256(raw).hexdigest() + '  ' + name + '\n' for name, raw in artifacts.items()))
        location = patch.object(features.run, 'HERE', root)
        location.start()
        self.addCleanup(location.stop)
        features.attach_baseline_comparison(self.spec, self.data)

    def verify(self):
        reuse.verify_evidence(self.data, self.inputs)

    def test_complete_data(self):
        self.verify()

    def test_wrong_units_for_same_checksum(self):
        self.data['profiles']['reuse.tcp.reset']['samples'][0]['units'] = 1
        with self.assertRaisesRegex(ValueError, 'unit count'):
            self.verify()

    def test_wrong_checksum(self):
        self.data['profiles']['reuse.tls.reset']['samples'][0]['checksum'] = 0
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.verify()

    def test_snapshot_has_its_own_unit_count(self):
        self.data['profiles']['session.snapshot']['samples'][0]['units'] = 30
        with self.assertRaisesRegex(ValueError, 'unit count'):
            self.verify()

    def test_missing_transport(self):
        del self.data['profiles']['reuse.socket.reconnect']
        with self.assertRaisesRegex(ValueError, 'profiles'):
            self.verify()

    def test_missing_repetition(self):
        self.data['profiles']['reuse.tcp.reset']['samples'].pop()
        with self.assertRaisesRegex(ValueError, 'repetitions'):
            self.verify()

    def test_edited_median(self):
        self.data['profiles']['reuse.tcp.reset']['median_elapsed_ns_per_unit'] = 1
        with self.assertRaisesRegex(ValueError, 'summary'):
            self.verify()

    def test_missing_comparison(self):
        del self.data['comparisons']['tls']
        with self.assertRaisesRegex(ValueError, 'comparison profiles'):
            self.verify()

    def test_reversed_comparison(self):
        self.data['comparisons']['tcp']['baseline'] = 'reuse.tcp.reset'
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.verify()

    def test_edited_change(self):
        self.data['comparisons']['tcp']['change_percent']['elapsed_ns'] = -50
        with self.assertRaisesRegex(ValueError, 'comparison'):
            self.verify()

    def test_old_input_fingerprint(self):
        self.data['inputs']['sha256'] = 'old'
        with self.assertRaisesRegex(ValueError, 'stale'):
            self.verify()

    def test_same_digest_cannot_hide_different_files(self):
        self.data['inputs']['files'][reuse.WORKLOAD_PATHS[0]] = 'fake mismatch'
        with self.assertRaisesRegex(ValueError, 'input file'):
            self.verify()

    def test_wrong_tested_commit(self):
        self.data['build']['git_commit'] = 'old'
        with self.assertRaisesRegex(ValueError, 'tested commit'):
            self.verify()

    def test_missing_baseline_is_rejected(self):
        (self.directory / 'results.json').unlink()
        with self.assertRaisesRegex(ValueError, 'required session reuse baseline'):
            self.verify()

    def test_changed_baseline_is_rejected(self):
        (self.directory / 'results.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.verify()

    def test_changed_summary_is_rejected(self):
        (self.directory / 'SUMMARY.md').write_text('different')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.verify()

    def test_omitted_baseline_comparison(self):
        del self.data['baseline_comparison']
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            self.verify()

    def test_cannot_hide_comparability(self):
        self.data['baseline_comparison']['comparable'] = False
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            self.verify()

    def test_cannot_hide_timing_alarm(self):
        self.data['baseline_comparison']['timing_investigations'] = [{'id': 'x', 'percent': 99}]
        with self.assertRaisesRegex(ValueError, 'baseline comparison'):
            self.verify()

    def test_environment_change_withholds_deltas(self):
        self.data['server'] = {'different': True}
        comparison = features.baseline_comparison(self.spec, self.data)
        self.assertFalse(comparison['comparable'])
        self.assertEqual({}, comparison['profiles'])

    def test_duplicate_and_wrong_markers(self):
        line = 'STAGE4\treuse.tcp.reset\t30\t100\t200\t80\t10\t30\n'
        for content in (line * 2, line.replace('STAGE4', 'STAGE3')):
            with self.assertRaises(ValueError):
                features.sample(self.spec, content, 'reuse.tcp.reset')


if __name__ == '__main__':
    unittest.main()
