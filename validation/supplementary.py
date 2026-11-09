#!/usr/bin/env python3
"""Separate Stage 1 experiments; never change frozen workload/recorder semantics.

Retention experiments collect current live heap after GC. Ordinary timing
profiles retain the original supplementary timing regions and high-water metric.
"""
import argparse
import json
import os
from pathlib import Path
import statistics

import publish_results as live
import release_recorder as run

PROFILES = {
    "connect.tcp": 30,
    "parameters.select": 500,
    "parameters.mixed": 500,
    "transaction.empty": 300,
    "batch.1000": 5,
    "stream.retention": 100000,
}
RETENTION = {
    "retention.10000": 10000,
    "retention.1000000": 1000000,
    "retention.tiny-slice": 16777216,
}


def read_sample(output, *, retention):
    """Parse the harness protocol, keeping live heap distinct from high-water."""
    marker = "RETENTION" if retention else "STAGE1"
    line = next(line for line in output.splitlines() if line.startswith(marker + "\t"))
    _, _, *values = line.split("\t")
    fields = (["units", "elapsed_ns", "current_live_bytes", "checksum"] if retention
              else ["units", "elapsed_ns", "allocated_bytes", "max_live_bytes", "checksum"])
    if len(fields) != len(values):
        raise ValueError("unexpected supplementary sample shape")
    sample = dict(zip(fields, map(int, values)))
    if retention:
        sample["live_heap_samples_bytes"] = [
            int(line.split("\t")[2]) for line in output.splitlines()
            if line.startswith("LIVE_HEAP\t")
        ]
    return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=7)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("repetitions must be positive")
    if args.output.exists():
        parser.error("output exists; preserve previous experiment")
    env = os.environ.copy()
    env.update(json.loads((run.HERE / ".local/environment.json").read_text()))
    env["TZ"] = "UTC"
    print("MariaDB:", run.sql_client(env, "SELECT VERSION()"), flush=True)
    inputs = live.input_snapshot()
    # A failed fresh build raises here: an older executable is never measured.
    run.command(["cabal", "build", "exe:mariadb-validation", "-O2", "--enable-tests"], timeout=300)
    if live.input_snapshot()["files"] != inputs["files"]:
        raise RuntimeError("inputs changed during supplementary build")
    binary = run.executable("exe:mariadb-validation")
    data = {"schema": 1, "recorded_at": live.now(), "inputs": inputs,
            "server": run.server_metadata(env), "profiles": {}}
    for ident, count in {**PROFILES, **RETENTION}.items():
        retention = ident in RETENTION
        samples = []
        for repetition in range(args.repetitions):
            output = run.command(
                [binary, "stage1-bench", ident, str(count), "+RTS", "-N4", "-T", "-RTS"],
                env=env, timeout=180,
            ).stdout
            samples.append(read_sample(output, retention=retention))
        if retention:
            # GC checkpoints belong only to these memory experiments. Their
            # elapsed time is not comparable with frozen throughput profiles.
            live_values = [sample["current_live_bytes"] for sample in samples]
            checkpoints = [value for sample in samples for value in sample["live_heap_samples_bytes"]]
            profile = {
                "samples": samples,
                "kind": "retention experiment; GC checkpoints are inside this experiment only",
                "median_current_live_bytes": statistics.median(live_values),
                "maximum_checkpoint_live_bytes": max(live_values + checkpoints),
            }
        else:
            profile = {
                "samples": samples,
                "median_ns_per_unit": statistics.median(
                    sample["elapsed_ns"] / sample["units"] for sample in samples
                ),
                "median_allocated_bytes_per_unit": statistics.median(
                    sample["allocated_bytes"] / sample["units"] for sample in samples
                ),
            }
        data["profiles"][ident] = profile
        print(ident, {key: value for key, value in profile.items() if key != "samples"}, flush=True)
    if live.input_snapshot()["files"] != inputs["files"]:
        raise RuntimeError("inputs changed during supplementary measurement")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
