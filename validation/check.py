#!/usr/bin/env python3
"""Verify MariaDB, rebuild current source, then validate with run.py.

Rebuilding prevents a stale executable from being measured after a source edit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import run
import publish_results as live
import stage1_gates


def unchanged_inputs(expected):
    """Do not measure a binary built while source/test inputs were changing."""
    current = live.input_snapshot()
    return all(current.get(key) == expected.get(key) for key in ('files', 'commit', 'branch'))


def install_runtime_data():
    """Exercise Cabal installation, rather than making CA lookup depend on cwd.

    Reuse the successful v2 build's Setup configuration. Cabal copies the data
    declared by this package, including the CA snapshot, to its configured
    installation prefix; it does not register or resolve another library build.
    """
    binary = Path(run.executable("exe:mariadb-validation"))
    build = next((parent / "opt" for parent in binary.parents
                  if (parent / "opt/setup-config").is_file()
                  and (parent / "opt/build/Database/MySQL/Connection.hi").is_file()), None)
    if build is None:
        raise RuntimeError("library Setup configuration not found for runtime data installation")
    return subprocess.run(["cabal", "v1-copy", "lib:mysql-haskell", "--builddir=" + str(build)],
                          cwd=run.ROOT).returncode


def native_benchmarks(output, repetitions, config):
    """Keep additive native measurements in every complete validation run."""
    destination = output / "native"
    status = subprocess.call([sys.executable, str(run.HERE / "stage3_benchmarks.py"),
                              "--config", str(config), "--output", str(destination),
                              "--repetitions", str(repetitions)], cwd=run.ROOT)
    if status:
        raise RuntimeError("native benchmark recorder failed; its partial evidence is retained")
    data = json.loads((destination / "results.json").read_text())
    return data


def session_reuse_benchmarks(output, repetitions, config):
    """Require complete request-boundary measurements in every Stage 4 run."""
    destination = output / 'reuse'
    subprocess.run([sys.executable, str(run.HERE / 'stage4_benchmarks.py'),
                    '--config', str(config), '--output', str(destination),
                    '--repetitions', str(repetitions)], cwd=run.ROOT, check=True)
    return json.loads((destination / 'results.json').read_text())


def cdc_benchmarks(output, repetitions, config):
    """Preserve complete CDC measurements alongside every full Stage 5 run."""
    destination = output / 'cdc'
    subprocess.run([sys.executable, str(run.HERE / 'stage5_benchmarks.py'),
                    '--config', str(config), '--output', str(destination),
                    '--repetitions', str(repetitions)], cwd=run.ROOT, check=True)
    return json.loads((destination / 'results.json').read_text())


def wire_benchmarks(output, repetitions, config):
    """Keep all optional-wire alternatives in complete Stage 6 runs."""
    destination = output / 'wire'
    subprocess.run([sys.executable, str(run.HERE / 'stage6_benchmarks.py'),
                    '--config', str(config), '--output', str(destination),
                    '--repetitions', str(repetitions)], cwd=run.ROOT, check=True)
    return json.loads((destination / 'results.json').read_text())


def external_authentication_benchmarks(output, repetitions, config):
    path = output / 'external-authentication'
    subprocess.run([sys.executable, str(run.HERE / 'stage7_benchmarks.py'),
        '--output', str(path), '--repetitions', str(repetitions),
        '--config', str(config)], cwd=run.ROOT, check=True)
    return json.loads((path / 'results.json').read_text())


def parse_arguments(argv=None):
    """Share option parsing between execution and setup-failure publication."""
    parser=argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config",type=Path,default=run.HERE/".local/environment.json")
    parser.add_argument("--output",type=Path)
    parser.add_argument("--only")
    parser.add_argument("--no-upstream",action="store_true")
    parser.add_argument("--no-benchmarks",action="store_true")
    parser.add_argument("--repetitions",type=int,default=7)
    parser.add_argument("--compare",type=Path)
    parser.add_argument("--freeze",type=Path)
    parser.add_argument("--working-tree",action="store_true")
    args,_=parser.parse_known_args(argv)
    return args


def is_full_run(args):
    return not (args.only or args.no_upstream or args.no_benchmarks) and args.repetitions >= 7


# Keep fixture routing independent of non-live wire probes. Prefix/substring
# selections use the recorder's same substring semantics; complete selections
# always need the real services. Live Stage 7 cases follow this inventory.
AUTHENTICATION_FIXTURE_CASES = (
    'auth.pam-environment', 'auth.gssapi-environment',
    'stage7.live.gssapi-rejects-password-only-success',
    'stage7.live.pam-wrong-password', 'stage7.live.pam-multiple-questions',
    'stage7.live.pam-wrong-second-factor', 'stage7.live.pam-cancellation-and-reconnect',
    'stage7.live.gssapi-tls', 'stage7.live.gssapi-premature-ok-rejected',
    'stage7.live.gssapi-wrong-identity', 'stage7.live.gssapi-missing-cache',
    'stage7.live.gssapi-repeated-context-cleanup', 'stage7.live.gssapi-cancel-before-server-token',
)


def needs_authentication_fixture(args):
    return not args.only or any(args.only in ident for ident in AUTHENTICATION_FIXTURE_CASES)


def main(args=None):
    if "--help" in sys.argv or "-h" in sys.argv:
        status = subprocess.call([sys.executable,str(run.HERE/"run.py"),"--help"])
        print("\nFull runs execute native, reuse, CDC, wire and authentication benchmarks and update the live report. Partial runs do not replace it.")
        return status
    args = args if args is not None else parse_arguments()
    full = is_full_run(args)
    inputs = live.input_snapshot()
    output = args.output.resolve() if args.output else run.HERE / "results/runs" / run.dt.datetime.now(run.dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    if output.exists():
        raise SystemExit("run output already exists; use a new directory")
    attempt = {"state":"FAILED", "stage":"server verification", "started_at":live.now(),
               "inputs":inputs, "uncommitted_review":args.working_tree, "run_directory":live.relative(output), "exit_code":1}

    def finish(status, reason="", data=None):
        if full:
            attempt.update(finished_at=live.now(),exit_code=status,reason=reason)
            if data is not None:
                attempt.update(state="COMPLETED",stage="complete")
            gate = None
            # The initial immutable capture predates an accepted implementation.
            # Every normal candidate requires that reference; deleting its
            # manifest must not silently disable the acceptance ratchet.
            if data is not None and not args.freeze:
                try:
                    accepted,manifest = stage1_gates.reference()
                    original = json.loads(live.BASELINE.read_text())
                    previous_stage, stage_manifest = stage1_gates.reference(run.HERE / "results/previous-stage.json")
                    gate = stage1_gates.compare(data,accepted,original,previous_stage=previous_stage)
                    gate["previous_stage_reference"] = stage_manifest
                    gate.update(accepted_reference=manifest,tested_input_sha256=inputs['sha256'])
                    (run.HERE / "results/stage1-gates.json").write_text(json.dumps(gate,indent=2)+"\n")
                    if not gate['correctness_accepted'] or not gate['evidence_accepted']:
                        status = status or 1
                except (OSError, ValueError, KeyError) as error:
                    # A damaged/missing reference must leave a visible failed
                    # attempt, rather than crashing before the live publication.
                    # The candidate's raw results remain in its run directory.
                    attempt.update(state="FAILED", stage="acceptance evidence",
                                   reason="Acceptance evidence could not be verified: " + str(error))
                    data, gate, status = None, None, status or 1
            if data is not None and gate and gate['correctness_accepted'] and gate['evidence_accepted']:
                try:
                    native = native_benchmarks(output, args.repetitions, args.config)
                    from stage3_benchmarks import verify_evidence
                    verify_evidence(native, inputs)
                    attempt['native_features'] = native
                    comparison = native.get('baseline_comparison', {})
                    native_timing = comparison.get('timing_investigations', [])
                    native_allocation = comparison.get('allocation_investigations', [])
                    gate['native_timing_investigations'] = native_timing
                    gate['native_allocation_investigations'] = native_allocation
                    gate['performance_requires_confirmation'] = gate.get('performance_requires_confirmation', False) or bool(native_timing or native_allocation)
                    (run.HERE / 'results/stage1-gates.json').write_text(json.dumps(gate, indent=2) + '\n')
                    if any(item['percent'] > 20 for item in native_timing):
                        status = status or 1
                except (OSError, ValueError, KeyError, RuntimeError) as error:
                    attempt.update(state="FAILED", stage="native benchmarks",
                                   reason="Native benchmark evidence failed: " + str(error))
                    data, gate, status = None, None, status or 1
                except KeyboardInterrupt:
                    attempt.update(state="FAILED", stage="native benchmarks", reason="Native benchmarks interrupted.")
                    data, gate, status = None, None, 130
            if data is not None and any(case['id'].startswith('stage4.') for case in data.get('correctness', [])):
                try:
                    from stage4_benchmarks import verify_evidence as verify_reuse
                    reuse = session_reuse_benchmarks(output, args.repetitions, args.config)
                    verify_reuse(reuse, inputs)
                    attempt['session_reuse'] = reuse
                    comparison = reuse['baseline_comparison']
                    gate['reuse_timing_investigations'] = comparison['timing_investigations']
                    gate['reuse_allocation_investigations'] = comparison['allocation_investigations']
                    gate['performance_requires_confirmation'] = gate.get('performance_requires_confirmation', False) or bool(comparison['timing_investigations'] or comparison['allocation_investigations'])
                    (run.HERE / 'results/stage1-gates.json').write_text(json.dumps(gate, indent=2) + '\n')
                    if any(item['percent'] > 20 for item in comparison['timing_investigations']):
                        status = status or 1
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
                    attempt.update(state='FAILED', stage='session reuse benchmarks',
                                   reason='Session reuse evidence failed: ' + str(error))
                    data, gate, status = None, None, status or 1
                except KeyboardInterrupt:
                    attempt.update(state='FAILED', stage='session reuse benchmarks', reason='Session reuse benchmarks interrupted.')
                    data, gate, status = None, None, 130
            if data is not None and any(case['id'].startswith('stage5.') for case in data.get('correctness', [])):
                try:
                    from stage5_benchmarks import verify_evidence as verify_cdc
                    cdc = cdc_benchmarks(output, args.repetitions, args.config)
                    verify_cdc(cdc, inputs)
                    attempt['cdc'] = cdc
                    comparison = cdc['baseline_comparison']
                    gate['cdc_timing_investigations'] = comparison['timing_investigations']
                    gate['cdc_allocation_investigations'] = comparison['allocation_investigations']
                    gate['performance_requires_confirmation'] = gate.get('performance_requires_confirmation', False) or bool(comparison['timing_investigations'] or comparison['allocation_investigations'])
                    (run.HERE / 'results/stage1-gates.json').write_text(json.dumps(gate, indent=2) + '\n')
                    if any(item['percent'] > 20 for item in comparison['timing_investigations']):
                        status = status or 1
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
                    attempt.update(state='FAILED', stage='CDC benchmarks', reason='CDC evidence failed: '+str(error))
                    data, gate, status = None, None, status or 1
                except KeyboardInterrupt:
                    attempt.update(state='FAILED', stage='CDC benchmarks', reason='CDC benchmarks interrupted.')
                    data, gate, status = None, None, 130
            if data is not None and any(case['id'].startswith('stage6.') for case in data.get('correctness', [])):
                try:
                    from stage6_benchmarks import verify_evidence as verify_wire
                    wire = wire_benchmarks(output, args.repetitions, args.config)
                    verify_wire(wire, inputs)
                    attempt['wire_features'] = wire
                    comparison = wire['baseline_comparison']
                    for metric in ('timing_investigations', 'allocation_investigations'):
                        gate['wire_' + metric] = comparison[metric]
                    gate['performance_requires_confirmation'] = gate.get('performance_requires_confirmation', False) or bool(
                        comparison['timing_investigations'] or comparison['allocation_investigations'])
                    (run.HERE / 'results/stage1-gates.json').write_text(json.dumps(gate, indent=2) + '\n')
                    if any(item['percent'] > 20 for item in comparison['timing_investigations']):
                        status = status or 1
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
                    attempt.update(state='FAILED', stage='wire feature benchmarks', reason='Wire feature evidence failed: ' + str(error))
                    data, gate, status = None, None, status or 1
                except KeyboardInterrupt:
                    attempt.update(state='FAILED', stage='wire feature benchmarks', reason='Wire feature benchmarks interrupted.')
                    data, gate, status = None, None, 130
            if data is not None and any(case['id'].startswith('stage7.') for case in data.get('correctness', [])):
                try:
                    from stage7_benchmarks import verify_evidence as verify_auth
                    auth = external_authentication_benchmarks(output, args.repetitions, args.config)
                    verify_auth(auth, inputs)
                    attempt['external_authentication'] = auth
                    comparison = auth['baseline_comparison']
                    for metric in ('timing_investigations', 'allocation_investigations'):
                        gate['authentication_' + metric] = comparison[metric]
                    gate['performance_requires_confirmation'] = gate.get('performance_requires_confirmation', False) or bool(
                        comparison['timing_investigations'] or comparison['allocation_investigations'])
                    (run.HERE / 'results/stage1-gates.json').write_text(json.dumps(gate, indent=2) + '\n')
                    if any(item['percent'] > 20 for item in comparison['timing_investigations']):
                        status = status or 1
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
                    attempt.update(state='FAILED', stage='authentication benchmarks', reason='Authentication evidence failed: ' + str(error))
                    data, gate, status = None, None, status or 1
                except KeyboardInterrupt:
                    attempt.update(state='FAILED', stage='authentication benchmarks', reason='Authentication benchmarks interrupted.')
                    data, gate, status = None, None, 130
            attempt.update(exit_code=status, finished_at=live.now())
            live.publish(attempt,data,gate=gate)
            print("Live results updated:",live.REPORT,flush=True)
        else:
            print("Partial/short development run: live full-suite results were not replaced.",flush=True)
        return status

    try:
        env=os.environ.copy(); env.update(json.loads(args.config.read_text()))
        version=run.sql_client(env,"SELECT VERSION()")
        if "MariaDB" not in version: raise RuntimeError("expected MariaDB")
    except Exception as error:
        print("MariaDB must be installed, configured and running before validation. See validation/MACOS.md.\n"+str(error),file=sys.stderr)
        return finish(1,"MariaDB verification failed before build; see terminal output and MACOS.md.")
    print("Server verified before build:",version,flush=True)
    attempt["stage"]="build"
    try:
        build = subprocess.run(["cabal","build","exe:mariadb-validation","test:test","test:integration","--enable-tests","-O2"],cwd=run.ROOT)
    except OSError as error:
        return finish(1, "Build process could not start: " + str(error))
    except KeyboardInterrupt:
        return finish(130, "Validation interrupted during build.")
    if build.returncode:
        return finish(build.returncode,"Current source did not build; no suite results were produced.")
    if not unchanged_inputs(inputs):
        return finish(1, "Test/build inputs changed during build; no suite was measured.")
    attempt["stage"]="runtime data installation"
    try:
        installed = install_runtime_data()
    except (OSError, RuntimeError) as error:
        return finish(1, "Runtime data installation failed: " + str(error))
    except KeyboardInterrupt:
        return finish(130, "Validation interrupted during runtime data installation.")
    if installed:
        return finish(installed, "Runtime data installation failed; no suite results were produced.")
    if not unchanged_inputs(inputs):
        return finish(1, "Test/build inputs changed during runtime data installation; no suite was measured.")
    attempt["stage"]="suite"
    options = [*[arg for arg in sys.argv[1:] if arg != "--working-tree"],"--config",str(args.config),"--output",str(output)]
    if full and not args.compare and not args.freeze:
        options += ["--compare",str(live.BASELINE)]
    try:
        status = subprocess.call([sys.executable,str(run.HERE/"run.py"),*options],cwd=run.ROOT)
    except OSError as error:
        return finish(1, "Recorder process could not start: " + str(error))
    except KeyboardInterrupt:
        return finish(130, "Validation interrupted during suite execution.")
    final = live.input_snapshot()
    if final["files"] != inputs["files"] or final["commit"] != inputs["commit"]:
        return finish(1,"Code or Git revision changed during build/execution; rerun on stable committed inputs.")
    results = output / "results.json"
    if not results.exists():
        return finish(status or 1,"The recorder stopped without a complete results file; see terminal output and run logs.")
    try:
        data = json.loads(results.read_text()) if full else None
    except (OSError, ValueError) as error:
        return finish(status or 1, "Recorder results could not be read: " + str(error))
    return finish(status,data=data)


def main_with_authentication():
    """Publish setup failures only for the same full-run modes as execution."""
    if "--help" in sys.argv or "-h" in sys.argv:
        return main()
    args = parse_arguments()
    started = live.now()
    try:
        return _main_with_authentication(args)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        status = 130 if isinstance(error, KeyboardInterrupt) else 1
        reason = 'Authentication fixture setup interrupted.' if status == 130 else str(error)
        if is_full_run(args):
            snapshot = live.input_snapshot()
            live.publish({'state': 'FAILED', 'stage': 'external authentication fixture preflight',
                'started_at': started, 'finished_at': live.now(), 'exit_code': status,
                'inputs': snapshot, 'uncommitted_review': args.working_tree,
                'run_directory': 'validation/results/runs',
                'reason': 'External authentication fixture could not be prepared: ' + reason})
        print('External authentication fixture preflight failed: ' + reason, file=sys.stderr)
        return status


def _main_with_authentication(args=None):
    """Keep required services alive through correctness and feature benchmarks.

    Non-live filtered checks do not acquire Docker/Kerberos resources. A private
    config overrides only this invocation; original argv and caller settings are
    preserved, including unknown options forwarded to the frozen recorder.
    """
    args = args if args is not None else parse_arguments()
    if not needs_authentication_fixture(args):
        return main(args)
    settings = json.loads(args.config.read_text())
    env = {**os.environ, **settings}
    if env.get("MB_AUTH_HOST"):
        return main(args)
    # Verify the managed server before acquiring/building any test resources.
    if "MariaDB" not in run.sql_client(env, "SELECT VERSION()"):
        raise RuntimeError("expected a running MariaDB server before validation")
    import auth_fixture
    import tempfile
    with auth_fixture.environment() as fixture:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=run.HERE/".local") as config:
            json.dump({**settings, **fixture}, config)
            config.flush()
            configured = argparse.Namespace(**{**vars(args), 'config': Path(config.name)})
            return main(configured)


if __name__=="__main__": raise SystemExit(main_with_authentication())
