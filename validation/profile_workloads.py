#!/usr/bin/env python3
"""Run focused experiments using the unchanged frozen workload functions.

These development measurements never replace the complete live report. A failed
build/workload or a source edit during measurement invalidates the experiment.
"""
import argparse
import json
import os
from pathlib import Path
import statistics

import publish_results as live
import release_recorder as run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profiles", nargs="+", required=True)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("repetitions must be positive")
    if args.output.exists():
        parser.error("experiment exists; preserve previous results")

    env = os.environ.copy()
    env.update(json.loads((run.HERE / ".local/environment.json").read_text()))
    env["TZ"] = "UTC"
    print("MariaDB:", run.sql_client(env, "SELECT VERSION()"), flush=True)
    inputs = live.input_snapshot()
    # run.command checks exit status: never measure a stale binary after a
    # failed build. Keep the build log beside the separate experiment output.
    build = run.command(
        ["cabal", "build", "exe:mariadb-validation", "-O2", "--enable-tests"],
        timeout=300,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".build.log").write_text(build.stdout + build.stderr)
    if live.input_snapshot()["files"] != inputs["files"]:
        raise RuntimeError("inputs changed during profile build")
    binary = run.executable("exe:mariadb-validation")
    manifest = dict(
        line.split("\t")
        for line in run.command([binary, "list-benchmarks"]).stdout.splitlines()
    )
    unknown = set(args.profiles) - manifest.keys()
    if unknown:
        parser.error("unknown frozen workloads: " + ", ".join(sorted(unknown)))
    data = {
        "schema": 1,
        "recorded_at": live.now(),
        "inputs": inputs,
        "successful_fresh_build": True,
        "server": run.server_metadata(env),
        "profiles": {},
    }
    logs = args.output.with_suffix("")
    logs.mkdir()
    for ident in args.profiles:
        samples = [
            run.benchmark_sample(
                binary, ident, int(manifest[ident]), env,
                logs / f"{ident}.{rep}.log",
            )
            for rep in range(args.repetitions)
        ]
        if any(sample["status"] != "PASS" for sample in samples):
            raise RuntimeError("workload failed: " + ident)
        profile = {
            "samples": samples,
            "median_ns_per_unit": statistics.median(
                sample["ns_per_unit"] for sample in samples
            ),
            "median_allocated_bytes_per_unit": statistics.median(
                sample["allocated_bytes"] / sample["units"] for sample in samples
            ),
        }
        data["profiles"][ident] = profile
        print(ident, profile["median_ns_per_unit"],
              profile["median_allocated_bytes_per_unit"], flush=True)
    if live.input_snapshot()["files"] != inputs["files"]:
        raise RuntimeError("inputs changed during profile experiment")
    args.output.write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
