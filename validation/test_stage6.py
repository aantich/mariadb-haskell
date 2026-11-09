"""Optional-wire evidence cannot disappear from a complete Stage 6 report."""
import unittest
from unittest.mock import patch

import feature_benchmarks as features
import publish_results as live
import stage6_benchmarks as wire


class WireEvidenceTests(unittest.TestCase):
    def test_expected_work_and_checksum(self):
        spec = wire.specification()
        self.assertEqual(13, len(spec.profiles))
        self.assertEqual(7, len(spec.pairs))
        for name in spec.profiles:
            line = 'STAGE6\t' + name + '\t' + '\t'.join(map(str,
                (spec.units[name], 1000, 2000, 100, 0, spec.checksums[name])))
            features.sample(spec, line, name)
            with self.assertRaisesRegex(ValueError, 'checksum'):
                features.sample(spec, line.rsplit('\t', 1)[0]+'\t0', name)

    def test_baseline_artifacts_are_inputs(self):
        for name in ('results.json', 'SUMMARY.md', 'SHA256SUMS'):
            self.assertTrue(live.is_input('validation/baselines/macos-arm64-wire-features/'+name))

    def test_retention_requires_all_upload_checkpoints(self):
        spec = wire.specification()
        checkpoints = (65536, 1048576, 16777216, 67108864)
        self.assertEqual(checkpoints, spec.heap_profiles['upload.retention'])
        entries = [[n, 100000] for n in checkpoints] * 3
        features.verify_heap(spec, 'upload.retention', entries)
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            features.verify_heap(spec, 'upload.retention', entries[4:])
        entries[-1][1] += 3 * 1024 * 1024
        with self.assertRaisesRegex(ValueError, 'grows'):
            features.verify_heap(spec, 'upload.retention', entries)

    def test_retention_rejects_growth_released_before_final_checkpoint(self):
        spec = wire.specification()
        entries = [[n, 100000] for n in spec.heap_profiles['upload.retention']] * 3
        # Fresh lists prevent changing another pass's shared test fixture.
        entries = [entry[:] for entry in entries]
        entries[2][1] += 3 * 1024 * 1024
        with self.assertRaisesRegex(ValueError, 'grows'):
            features.verify_heap(spec, 'upload.retention', entries)

    def test_buffering_control_must_fail_for_growth(self):
        import subprocess
        checkpoints = wire.specification().heap_profiles['upload.retention']
        small = ''.join(f'STAGE6_HEAP\t{n}\t100000\n' for n in checkpoints) * 3
        with patch.object(wire.run, 'command', return_value=subprocess.CompletedProcess([], 0, stdout=small)):
            with self.assertRaisesRegex(ValueError, 'escaped'):
                wire.verify_buffering_control('fixture')
        grown = ''.join(f'STAGE6_HEAP\t{n}\t{100000+n}\n' for n in checkpoints) * 3
        with patch.object(wire.run, 'command', return_value=subprocess.CompletedProcess([], 0, stdout=grown)), patch('builtins.print'):
            wire.verify_buffering_control('fixture')

    def fixture(self):
        inputs = {'sha256':'source', 'files':{}, 'commit':'code', 'dirty_inputs':[]}
        attempt = {'state':'COMPLETED', 'inputs':inputs}
        data = {'complete_suite':True, 'repetitions':7, 'source_unchanged_during_run':True,
                'correctness':[{'id':'stage6.fixture', 'status':'PASS'}], 'build':{'git_commit':'code'}}
        return {'latest_attempt':attempt, 'latest_completed_run':{'attempt':attempt, 'results':data}}, inputs

    def test_missing_wire_evidence_blocks_publication(self):
        document, inputs = self.fixture()
        with self.assertRaisesRegex(ValueError, 'Wire features'):
            live.verify(document, inputs)

    def test_wire_evidence_is_reverified(self):
        document, inputs = self.fixture()
        document['latest_attempt']['wire_features'] = {'captured':'evidence'}
        with patch('stage6_benchmarks.verify_evidence') as verify:
            live.verify(document, inputs)
        verify.assert_called_once_with({'captured':'evidence'}, inputs)


class WireWrapperTests(unittest.TestCase):
    def test_changed_build_inputs_are_rejected_before_recording(self):
        import check
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.json'
            config.write_text('{}')
            before = {'files':{'source.hs':'old'}, 'commit':'parent', 'branch':'main'}
            after = dict(before, files={'source.hs':'new'})
            with (patch('sys.argv', ['check.py','--working-tree','--config',str(config),'--output',str(Path(folder)/'run')]),
                  patch.object(check.live,'input_snapshot',side_effect=[before,after]),
                  patch.object(check.run,'sql_client',return_value='12.3.3-MariaDB'),
                  patch.object(check.subprocess,'run') as build,
                  patch.object(check.subprocess,'call') as recorder,
                  patch.object(check.live,'publish') as publish):
                build.return_value.returncode = 0
                self.assertEqual(1,check.main())
            recorder.assert_not_called()
            attempt,data = publish.call_args.args
            self.assertEqual('FAILED',attempt['state'])
            self.assertIn('changed during build',attempt['reason'])
            self.assertIsNone(data)

    def check_capture(self, failure, expected_status, timing=()):
        import json
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        import check
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            (root/'results').mkdir()
            output=root/'run'
            config=root/'config.json'
            config.write_text('{}')
            inputs={'sha256':'candidate','files':{},'commit':'parent'}
            candidate={'complete_suite':True,'correctness':[{'id':'stage6.fixture','status':'PASS'}]}
            gate={'correctness_accepted':True,'evidence_accepted':True}
            measurements={'baseline_comparison':{'timing_investigations':list(timing),'allocation_investigations':[]}}
            def recorder(*args,**kwargs):
                output.mkdir()
                (output/'results.json').write_text(json.dumps(candidate))
                return 0
            with (patch('sys.argv',['check.py','--working-tree','--config',str(config),'--output',str(output)]),
                  patch.object(check.live,'input_snapshot',return_value=inputs),
                  patch.object(check.run,'HERE',root),
                  patch.object(check.run,'sql_client',return_value='12.3.3-MariaDB'),
                  patch.object(check.subprocess,'run') as build,
                  patch.object(check.subprocess,'call',side_effect=recorder),
                  patch.object(check,'install_runtime_data',return_value=0),
                  patch.object(check.stage1_gates,'reference',return_value=({},{})),
                  patch.object(check.stage1_gates,'compare',return_value=gate),
                  patch.object(check,'native_benchmarks',return_value={}),
                  patch('stage3_benchmarks.verify_evidence'),
                  patch.object(check,'wire_benchmarks',return_value=measurements,side_effect=failure) as capture,
                  patch('stage6_benchmarks.verify_evidence'),
                  patch.object(check.live,'publish') as publish):
                build.return_value.returncode=0
                self.assertEqual(expected_status,check.main())
            capture.assert_called_once_with(output.resolve(),7,config)
            attempt,data=publish.call_args.args
            if failure is None:
                self.assertEqual('COMPLETED',attempt['state'])
                self.assertEqual(measurements,attempt['wire_features'])
                self.assertEqual(candidate,data)
                if timing:
                    self.assertTrue(gate['performance_requires_confirmation'])
            else:
                self.assertEqual('FAILED',attempt['state'])
                self.assertEqual('wire feature benchmarks',attempt['stage'])
                self.assertIsNone(data)

    def test_recorder_failure_is_visible(self):
        self.check_capture(RuntimeError('incomplete wire capture'),1)

    def test_interruption_is_visible(self):
        self.check_capture(KeyboardInterrupt(),130)

    def test_small_timing_signal_stays_open(self):
        self.check_capture(None,0,[{'id':'transport.wide.zlib','percent':6}])

    def test_large_timing_signal_fails_wrapper(self):
        self.check_capture(None,1,[{'id':'transport.wide.zlib','percent':21}])


if __name__ == '__main__':
    unittest.main()
