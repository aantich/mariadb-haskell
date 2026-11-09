"""Preserve the approved contract correction and real external-auth evidence."""
import copy
from contextlib import contextmanager
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import check
import feature_benchmarks as features
import publish_results as live
import stage1_gates
import stage7_benchmarks as auth
import auth_fixture


class ExternalAuthenticationPolicyTests(unittest.TestCase):
    def test_partial_setup_failures_never_publish_full_status(self):
        variants = [['--only=protocol.length-0'], ['--only', 'stage7.live.'],
                    ['--repetitions', '1'], ['--repetitions=6'],
                    ['--no-upstream'], ['--no-benchmarks']]
        for arguments in variants:
            for error in [RuntimeError('fixture failed'), KeyboardInterrupt()]:
                with self.subTest(arguments=arguments, error=type(error).__name__), \
                     patch('sys.argv', ['check.py', *arguments]), \
                     patch.object(check, '_main_with_authentication', side_effect=error), \
                     patch.object(check.live, 'publish') as publish:
                    self.assertEqual(130 if isinstance(error, KeyboardInterrupt) else 1,
                                     check.main_with_authentication())
                    publish.assert_not_called()

    def test_full_fixture_interruption_is_published(self):
        with patch('sys.argv', ['check.py', '--working-tree']), \
             patch.object(check, '_main_with_authentication', side_effect=KeyboardInterrupt()), \
             patch.object(check.live, 'input_snapshot', return_value={'files': {}}), \
             patch.object(check.live, 'publish') as publish:
            self.assertEqual(130, check.main_with_authentication())
        attempt = publish.call_args.args[0]
        self.assertEqual('FAILED', attempt['state'])
        self.assertEqual(130, attempt['exit_code'])

    def test_non_live_filters_do_not_provision_services(self):
        for selected in ['protocol.length-0', 'stage7.dialog.', 'stage7.wire.',
                         'stage7.clear-password.', 'stage7.gssapi.wrong-principal']:
            with self.subTest(selected=selected), \
                 patch('sys.argv', ['check.py', '--only='+selected]), \
                 patch.object(check, 'main', return_value=0), \
                 patch.object(check.run, 'sql_client') as preflight, \
                 patch.object(auth_fixture, 'environment') as fixture:
                self.assertEqual(0, check.main_with_authentication())
                fixture.assert_not_called()
                preflight.assert_not_called()

    def test_live_and_complete_selections_require_fixtures(self):
        for arguments in [[], ['--no-benchmarks'], ['--only', 'stage7'],
                          ['--only', 'gssapi'], ['--only', 'auth.pam-environment'],
                          ['--only', 'stage7.live.pam-wrong-password']]:
            with self.subTest(arguments=arguments):
                self.assertTrue(check.needs_authentication_fixture(check.parse_arguments(arguments)))
        source = (live.ROOT/'validation/hs/Validation/Stage7.hs').read_text()
        required = {'stage7.'+name for name in re.findall(r'case7\s+"(live\.[^"]+)"', source)}
        self.assertTrue(required)
        self.assertTrue(required.issubset(check.AUTHENTICATION_FIXTURE_CASES))

    def test_private_fixture_config_preserves_argv_and_caller_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root/'.local').mkdir()
            config = root/'config.json'
            config.write_text(json.dumps({'MB_USER': 'caller', 'MB_PASSWORD': 'private'}))
            arguments = ['check.py', '--config', str(config), '--only=stage7.live.', '--unknown-option']
            @contextmanager
            def fixture():
                yield {'MB_AUTH_HOST': 'fixture', 'KRB5CCNAME': 'private-cache'}
            def run(args):
                settings = json.loads(args.config.read_text())
                self.assertEqual('caller', settings['MB_USER'])
                self.assertEqual('private', settings['MB_PASSWORD'])
                self.assertEqual('fixture', settings['MB_AUTH_HOST'])
                self.assertEqual(arguments, sys.argv)
                return 0
            with patch('sys.argv', arguments), patch.dict('os.environ', {}, clear=True), \
                 patch.object(check.run, 'HERE', root), \
                 patch.object(check.run, 'sql_client', return_value='MariaDB'), \
                 patch.object(auth_fixture, 'environment', side_effect=fixture), \
                 patch.object(check, 'main', side_effect=run):
                self.assertEqual(0, check.main_with_authentication())
            self.assertEqual([], list((root/'.local').iterdir()))

    def test_created_container_is_cleaned_after_creation_error_or_interrupt(self):
        for error in [RuntimeError('created but start failed'), KeyboardInterrupt()]:
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as folder:
                owner = []
                def command(args, **_):
                    if args[:2] == ['docker', 'run']:
                        owner.append(args[args.index('--name')+1])
                        self.assertIn('mariadb-haskell.fixture-owner='+owner[0], args)
                        raise error
                def run(args, **_):
                    return subprocess.CompletedProcess(args, 0, owner[0]+'\n', '')
                with patch.object(auth_fixture, 'HERE', Path(folder)), \
                     patch.object(auth_fixture, 'command', side_effect=command), \
                     patch.object(auth_fixture.subprocess, 'run', side_effect=run) as cleanup:
                    with self.assertRaises(type(error)):
                        with auth_fixture.environment():
                            self.fail('failed fixture yielded an environment')
                removals = [c.args[0] for c in cleanup.call_args_list if c.args[0][:3] == ['docker', 'rm', '-f']]
                self.assertEqual([['docker', 'rm', '-f', owner[0]]], removals)

    def test_fixture_log_failure_cannot_skip_removal(self):
        def run(args, **_):
            if args[:2] == ['docker', 'logs']:
                raise OSError('diagnostics failed')
            return subprocess.CompletedProcess(args, 0, 'owned\n', '')
        with patch.object(auth_fixture.subprocess, 'run', side_effect=run) as cleanup:
            auth_fixture.cleanup_container('owned')
        self.assertEqual(['docker', 'rm', '-f', 'owned'], cleanup.call_args_list[-1].args[0])

    def test_name_collision_or_absent_container_is_not_removed(self):
        for result in [subprocess.CompletedProcess([], 0, 'another-owner\n', ''),
                       subprocess.CompletedProcess([], 1, '', 'absent')]:
            with self.subTest(result=result), patch.object(auth_fixture.subprocess, 'run', return_value=result) as cleanup:
                auth_fixture.cleanup_container('owned')
                self.assertEqual(1, cleanup.call_count)

    def test_runtime_identity_ignores_provenance_indexes(self):
        image = {'Id': 'old-index', 'RepoDigests': ['old-attestation'],
                 'Architecture': 'arm64', 'Os': 'linux',
                 'RootFS': {'Type': 'layers', 'Layers': ['content']},
                 'Config': {'Env': ['SETTING=1'], 'Entrypoint': ['server']}}
        later = {**image, 'Id': 'new-index', 'RepoDigests': ['new-attestation']}
        self.assertEqual(auth_fixture.runtime_identity(image), auth_fixture.runtime_identity(later))

    def test_runtime_identity_detects_files_and_configuration_changes(self):
        image = {'RootFS': {'Layers': ['old']}, 'Config': {'Env': ['SETTING=1']}}
        for changed in [{**image, 'RootFS': {'Layers': ['new']}},
                        {**image, 'Config': {'Env': ['SETTING=2']}}]:
            self.assertNotEqual(auth_fixture.runtime_identity(image), auth_fixture.runtime_identity(changed))

    def test_exact_initial_runtime_alias_is_verified(self):
        aliases = auth.legacy_runtime_aliases()['MB_AUTH_FIXTURE_IMAGE_ID']
        self.assertEqual(1, len(aliases))
        self.assertTrue(next(iter(aliases.values())).startswith('docker-runtime-sha256:'))

    def test_fixture_and_baseline_artifacts_are_fingerprinted(self):
        for name in ['validation/auth_fixture/Dockerfile', 'validation/auth_fixture/.dockerignore',
                     'cbits/gssapi.c', 'validation/results/stage7-reference.json',
                     'validation/results/references/stage6-publication-1.json']:
            self.assertTrue(live.is_input(name), name)
        for name in ['results.json', 'SUMMARY.md', 'SHA256SUMS']:
            self.assertTrue(live.is_input('validation/baselines/macos-arm64-external-authentication/'+name))

    def test_missing_authentication_measurements_block_publication(self):
        inputs = {'files': {}, 'sha256': 'source', 'dirty_inputs': [], 'commit': 'code'}
        attempt = {'state': 'COMPLETED', 'inputs': inputs}
        data = {'complete_suite': True, 'repetitions': 7, 'source_unchanged_during_run': True,
                'correctness': [{'id': 'stage7.required', 'status': 'PASS'}],
                'build': {'git_commit': 'code'}}
        with self.assertRaisesRegex(ValueError, 'External authentication'):
            live.verify({'latest_attempt': attempt,
                         'latest_completed_run': {'attempt': attempt, 'results': data}}, inputs)

    def test_fixture_image_changes_withhold_timing_deltas(self):
        spec = auth.specification()
        data = {'dependencies': [], 'server': {}, 'machine': {}, 'haskell_benchmark_rts': [],
                'build': {'ghc': 'compiler', 'cabal': 'tool'},
                'inputs': {'files': dict.fromkeys(spec.workload_paths, 'same')},
                'profiles': {}, 'environment_profile': {'MB_AUTH_FIXTURE_IMAGE_ID': 'new-image'}}
        baseline = copy.deepcopy(data)
        baseline['environment_profile']['MB_AUTH_FIXTURE_IMAGE_ID'] = 'old-image'
        with patch.object(features, 'load_baseline', return_value=(baseline, 'hash')):
            result = features.baseline_comparison(spec, data)
        self.assertFalse(result['comparable'])
        self.assertEqual({}, result['profiles'])

    def test_contract_correction_is_not_a_driver_improvement(self):
        baseline = json.loads(live.BASELINE.read_text())
        data = copy.deepcopy(baseline)
        for case in data['correctness']:
            if case['id'] in ['reliability.timeout-before-metadata', 'auth.pam-environment']:
                case['status'] = 'PASS'
        data['comparison'] = {'regressions': [], 'improved_cases':
            ['reliability.timeout-before-metadata', 'auth.pam-environment']}
        attempt = {'state': 'COMPLETED', 'exit_code': 0, 'started_at': 'start',
            'finished_at': 'finish', 'run_directory': 'logs', 'inputs': {
                'commit': data['build']['git_commit'], 'branch': 'main', 'sha256': 'source',
                'dirty_inputs': [], 'files': {'validation/hs/Validation/Stage7.hs': 'source'}}}
        text = live.render({'latest_attempt': attempt,
            'latest_completed_run': {'attempt': attempt, 'results': data}}, baseline)
        self.assertIn('Approved test-contract correction', text)
        self.assertNotIn('- `reliability.timeout-before-metadata`', text)
        self.assertIn('- `auth.pam-environment`', text)
        self.assertIn('1 newly passing check', text)
        self.assertEqual('FAIL', next(c['status'] for c in baseline['correctness']
            if c['id'] == 'reliability.timeout-before-metadata'))

    def candidate(self):
        prior, _ = stage1_gates.reference(live.ROOT/'validation/results/stage7-reference.json')
        candidate = copy.deepcopy(prior)
        for case in candidate['correctness']:
            if case['id'] in ['reliability.timeout-before-metadata', 'auth.pam-environment', 'auth.gssapi-environment']:
                case['status'] = 'PASS'
        candidate['correctness'].append({'id': 'stage7.required', 'status': 'PASS'})
        return prior, candidate

    def test_every_published_stage6_pass_is_required(self):
        prior, candidate = self.candidate()
        case = next(c for c in candidate['correctness'] if c['id'].startswith('stage6.'))
        case['status'] = 'FAIL'
        result = stage1_gates.compare(candidate, prior, prior, require_targets=False)
        self.assertIn('Stage 6: lost PASS '+case['id'], result['correctness_failures'])

    def test_external_authentication_cannot_stay_unavailable(self):
        for ident in ['auth.pam-environment', 'auth.gssapi-environment']:
            prior, candidate = self.candidate()
            next(c for c in candidate['correctness'] if c['id'] == ident)['status'] = 'ENVIRONMENT_UNAVAILABLE'
            result = stage1_gates.compare(candidate, prior, prior, require_targets=False)
            self.assertIn('required external-auth/timeout target not passing: '+ident,
                          result['correctness_failures'])

    def test_fixture_preflight_failure_remains_visible(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config.json'
            config.write_text('{}')
            with patch('sys.argv', ['check.py', '--config', str(config), '--working-tree']), \
                 patch.dict('os.environ', {}, clear=True), \
                 patch.object(check.run, 'sql_client', return_value='MariaDB'), \
                 patch('auth_fixture.environment', side_effect=RuntimeError('fixture startup failed')), \
                 patch.object(check.live, 'publish') as publish, \
                 patch.object(check.live, 'input_snapshot', return_value={'files': {}}):
                self.assertEqual(1, check.main_with_authentication())
            attempt = publish.call_args.args[0]
            self.assertEqual('FAILED', attempt['state'])
            self.assertIn('fixture startup failed', attempt['reason'])
            self.assertTrue(attempt['uncommitted_review'])


if __name__ == '__main__':
    unittest.main()
