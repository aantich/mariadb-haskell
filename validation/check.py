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


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        status = subprocess.call([sys.executable,str(run.HERE/"run.py"),"--help"])
        print("\nFull runs also execute the native-feature benchmarks and update validation/RESULTS.md, results/overview.svg and results/current.json; the original baseline is compared by default. Partial runs do not replace the live report.")
        return status
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
    args,_=parser.parse_known_args()
    full = not (args.only or args.no_upstream or args.no_benchmarks) and args.repetitions >= 7
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
    attempt["stage"]="runtime data installation"
    try:
        installed = install_runtime_data()
    except (OSError, RuntimeError) as error:
        return finish(1, "Runtime data installation failed: " + str(error))
    except KeyboardInterrupt:
        return finish(130, "Validation interrupted during runtime data installation.")
    if installed:
        return finish(installed, "Runtime data installation failed; no suite results were produced.")
    attempt["stage"]="suite"
    options = [*[arg for arg in sys.argv[1:] if arg != "--working-tree"],"--output",str(output)]
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


if __name__=="__main__": raise SystemExit(main())
