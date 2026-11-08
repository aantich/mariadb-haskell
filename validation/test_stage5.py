"""CDC measurements require complete work, bounded heap and all new targets."""
import copy
import unittest

import feature_benchmarks as features
import publish_results as live
import stage5_benchmarks as cdc
import stage1_gates as gates


class CDCEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.spec = cdc.specification()
        self.heap = [[n,100000] for n in (1000,10000,100000,1000000)]*3

    def test_heap_complete(self):
        features.verify_heap(self.spec, 'cdc.retention', self.heap)

    def test_heap_missing_warmup(self):
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            features.verify_heap(self.spec, 'cdc.retention', self.heap[4:])

    def test_heap_wrong_count(self):
        self.heap = copy.deepcopy(self.heap)
        self.heap[-1][0] = 999999
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            features.verify_heap(self.spec, 'cdc.retention', self.heap)

    def test_heap_growth(self):
        self.heap = copy.deepcopy(self.heap)
        self.heap[-1][1] += 3*1024*1024
        with self.assertRaisesRegex(ValueError, 'grows'):
            features.verify_heap(self.spec, 'cdc.retention', self.heap)

    def test_crc_workload_uses_event_checksum(self):
        line='STAGE5\tcdc.framing.crc32\t20000\t100000\t200000\t100000\t1000\t20000'
        features.sample(self.spec, line, 'cdc.framing.crc32')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            features.sample(self.spec, line[:-5]+'10000', 'cdc.framing.crc32')

    def test_cdc_baselines_are_inputs(self):
        for name in ('results.json','SUMMARY.md','SHA256SUMS'):
            self.assertTrue(live.is_input('validation/baselines/macos-arm64-cdc/'+name))

    def test_required_cdc_targets(self):
        self.assertEqual(18, len(gates.CDC_TARGETS))
        self.assertIn('cdc.gtid-resume', gates.CDC_TARGETS)
        self.assertIn('cdc.durable-ack-control', gates.CDC_TARGETS)


class CDCPublicationTests(unittest.TestCase):
    def fixture(self):
        inputs={'sha256':'source','files':{},'commit':'code','dirty_inputs':[]}
        attempt={'state':'COMPLETED','inputs':inputs}
        data={'complete_suite':True,'repetitions':7,'source_unchanged_during_run':True,
              'correctness':[{'id':'stage5.fixture','status':'PASS'}], 'build':{'git_commit':'code'}}
        return {'latest_attempt':attempt,'latest_completed_run':{'attempt':attempt,'results':data}},inputs

    def test_missing_cdc_evidence_blocks_publication(self):
        document,inputs=self.fixture()
        with self.assertRaisesRegex(ValueError, 'CDC'):
            live.verify(document,inputs)

    def test_cdc_evidence_is_reverified(self):
        from unittest.mock import patch
        document,inputs=self.fixture()
        document['latest_attempt']['cdc']={'captured':'evidence'}
        with patch('stage5_benchmarks.verify_evidence') as verify:
            live.verify(document,inputs)
        verify.assert_called_once_with({'captured':'evidence'},inputs)

    def test_bad_heap_shape_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            features.verify_heap(cdc.specification(),'cdc.retention',[[1000,'unknown']]*12)


class CDCWrapperTests(unittest.TestCase):
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
            candidate={'complete_suite':True,'correctness':[{'id':'stage5.fixture','status':'PASS'}]}
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
                  patch.object(check,'cdc_benchmarks',return_value=measurements,side_effect=failure) as capture,
                  patch('stage5_benchmarks.verify_evidence'),
                  patch.object(check.live,'publish') as publish):
                build.return_value.returncode=0
                self.assertEqual(expected_status,check.main())
            capture.assert_called_once_with(output.resolve(),7,config)
            attempt,data=publish.call_args.args
            if failure is None:
                self.assertEqual('COMPLETED',attempt['state'])
                self.assertEqual(measurements,attempt['cdc'])
                self.assertEqual(candidate,data)
                if timing:
                    self.assertTrue(gate['performance_requires_confirmation'])
            else:
                self.assertEqual('FAILED',attempt['state'])
                self.assertEqual('CDC benchmarks',attempt['stage'])
                self.assertIsNone(data)

    def test_recorder_failure_is_visible(self):
        self.check_capture(RuntimeError('incomplete CDC capture'),1)

    def test_interruption_is_visible(self):
        self.check_capture(KeyboardInterrupt(),130)

    def test_small_timing_signal_stays_open(self):
        self.check_capture(None,0,[{'id':'cdc.live.rows','percent':6}])

    def test_large_timing_signal_fails_wrapper(self):
        self.check_capture(None,1,[{'id':'cdc.live.rows','percent':21}])
