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


def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        status = subprocess.call([sys.executable,str(run.HERE/"run.py"),"--help"])
        print("\nFull runs also update validation/RESULTS.md and results/current.json; the original baseline is compared by default. Partial runs do not replace the live report.")
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
    args,_=parser.parse_known_args()
    full = not (args.only or args.no_upstream or args.no_benchmarks) and args.repetitions >= 7
    inputs = live.input_snapshot()
    output = args.output.resolve() if args.output else run.HERE / "results/runs" / run.dt.datetime.now(run.dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    if output.exists():
        raise SystemExit("run output already exists; use a new directory")
    attempt = {"state":"FAILED", "stage":"server verification", "started_at":live.now(),
               "inputs":inputs, "run_directory":live.relative(output), "exit_code":1}

    def finish(status, reason="", data=None):
        if full:
            attempt.update(finished_at=live.now(),exit_code=status,reason=reason)
            if data is not None:
                attempt.update(state="COMPLETED",stage="complete")
            live.publish(attempt,data)
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
    build = subprocess.run(["cabal","build","exe:mariadb-validation","test:test","test:integration","--enable-tests","-O2"],cwd=run.ROOT)
    if build.returncode:
        return finish(build.returncode,"Current source did not build; no suite results were produced.")
    attempt["stage"]="suite"
    options = [*sys.argv[1:],"--output",str(output)]
    if full and not args.compare and not args.freeze:
        options += ["--compare",str(live.BASELINE)]
    status = subprocess.call([sys.executable,str(run.HERE/"run.py"),*options],cwd=run.ROOT)
    final = live.input_snapshot()
    if final["files"] != inputs["files"] or final["commit"] != inputs["commit"]:
        return finish(1,"Code or Git revision changed during build/execution; rerun on stable committed inputs.")
    results = output / "results.json"
    if not results.exists():
        return finish(status or 1,"The recorder stopped without a complete results file; see terminal output and run logs.")
    return finish(status,data=json.loads(results.read_text()) if full else None)


if __name__=="__main__": raise SystemExit(main())
