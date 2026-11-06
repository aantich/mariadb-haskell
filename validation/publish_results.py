#!/usr/bin/env python3
"""Publish the live report, or check that it still covers the current source."""
from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HERE = ROOT / "validation"
BASELINE = HERE / "baselines/macos-arm64-mariadb-12.3.3/results.json"
CURRENT = HERE / "results/current.json"
REPORT = HERE / "RESULTS.md"


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root).decode()


def is_input(path):
    p = Path(path)
    return (p.suffix in {".hs", ".hsc", ".c", ".h", ".cabal", ".nix"}
            or path.startswith(("test/", "npins/"))
            or (path.startswith("validation/") and p.suffix == ".py")
            or p.name.startswith("cabal.project") or path == "mozillaCAStore.pem")


def input_snapshot(root=ROOT):
    """Hash build/test inputs, including additions/deletions, but not reports."""
    paths = set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0"))
    paths = sorted(p for p in paths if p and is_input(p))
    files = {p: hashlib.sha256((root / p).read_bytes()).hexdigest()
             if (root / p).is_file() else None for p in paths}
    changed = set(git(root, "diff", "--name-only", "-z", "HEAD").split("\0"))
    changed.update(git(root, "ls-files", "-z", "--others", "--exclude-standard").split("\0"))
    return {"commit": git(root, "rev-parse", "HEAD").strip(),
            "branch": git(root, "branch", "--show-current").strip(),
            "files": files, "dirty_inputs": sorted(set(paths) & changed),
            "sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}


def relative(path):
    try:
        return str(Path(path).resolve().relative_to(ROOT))
    except ValueError:
        return str(Path(path).resolve())


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        f.write(content)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def compatible(current, baseline):
    return (current.get("comparison", {}).get("same_workloads") is True
            and current["machine"] == baseline["machine"]
            and current["server"] == baseline["server"]
            and all(current["build"][k] == baseline["build"][k] for k in ("ghc", "cabal"))
            and current["dependency_plan_sha256"] == baseline["dependency_plan_sha256"])


def cell(value):
    return str(value).replace("|", "&#124;").replace("\n", " ").replace("\r", " ")


def render(document, baseline):
    attempt = document["latest_attempt"]
    lines = ["# Live MariaDB validation results", "",
             "**This is the current results document on `main`.** Every full `python3 validation/check.py` run refreshes it, including failed attempts. Commit this file and [the machine-readable results](results/current.json) with each tested change. Git history retains earlier results.", "",
             "The [original unchanged-driver baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md) remains the reference for measuring improvements.", "",
             "## Latest validation attempt", "",
             f"- State: **{attempt['state']}**; process exit code: **{attempt['exit_code']}**.",
             f"- Tested commit: [`{attempt['inputs']['commit']}`](https://github.com/aantich/mariadb-haskell/commit/{attempt['inputs']['commit']}) on `{attempt['inputs']['branch']}`.",
             f"- Started: {attempt['started_at']}; finished: {attempt['finished_at']}.",
             f"- Input fingerprint: `{attempt['inputs']['sha256']}`.",
             f"- Local raw logs and build plan: `{attempt['run_directory']}` (ignored by Git).", "",
             "The tested commit identifies the code used for execution. A following results-only commit publishes this document; it does not claim another test run. CI checks that the recorded inputs still match the current code.", ""]
    if attempt["inputs"]["dirty_inputs"]:
        lines += ["**Uncommitted test/build inputs:** the tested contents differ from the commit above: "
                  + ", ".join(f"`{p}`" for p in attempt["inputs"]["dirty_inputs"]) + ".", ""]
    if attempt["state"] != "COMPLETED":
        lines += [f"**Validation stopped at {attempt['stage']}:** {attempt['reason']}", ""]
    completed = document.get("latest_completed_run")
    if not completed:
        return "\n".join(lines + ["No complete suite has been published yet.", ""])
    data = completed["results"]
    if attempt["state"] != "COMPLETED":
        lines += ["## Last completed suite (older results)", "",
                  f"The results below are from `{data['build']['git_commit']}` at {data['recorded_at']}; they do **not** validate the failed attempt above.", ""]
    else:
        lines += ["## Current complete suite", ""]
    machine = data["machine"]
    lines += [f"Server: **{data['server']['identity'][0]}**. Machine: **{machine.get('cpu_model', machine['machine'])}**, macOS {machine.get('macos', '')}. GHC {data['build']['ghc']}; Cabal {data['build']['cabal']}; MariaDB Connector/C {data.get('connector_c_version', 'not recorded')}.", "",
              f"Full suite: **{data['complete_suite']}**. Benchmark repetitions: **{data['repetitions']}**. Driver/workloads unchanged during execution: **{data['source_unchanged_during_run']}**.", "",
              "### Correctness", "",
              "Counts include two aggregate records for the inherited unit/property and integration suites. Their individual cases are described in [coverage](COVERAGE.md). Unsupported APIs and unavailable environments are separate from passes.", "",
              "| Status | Current | Original baseline |", "| --- | ---: | ---: |"]
    counts = Counter(c["status"] for c in data["correctness"])
    old_counts = Counter(c["status"] for c in baseline["correctness"])
    for status in ("PASS", "FAIL", "TIMEOUT", "UNSUPPORTED", "ENVIRONMENT_UNAVAILABLE"):
        lines.append(f"| {status} | {counts[status]} | {old_counts[status]} |")
    comparison = data.get("comparison")
    if comparison:
        regressions = comparison["regressions"]
        improvements = comparison["improved_cases"]
        lines += ["", f"Regression comparison: **{'FAIL' if regressions else 'PASS'}**; **{len(regressions)}** regression signals; **{len(improvements)}** newly passing cases. This gate compares against the baseline; a passing gate does not mean all functionality passes.", ""]
        if regressions:
            lines += ["Regression signals:", ""] + ["- " + cell(p) for p in regressions] + [""]
        if improvements:
            lines += ["Newly passing cases:", ""] + ["- `" + cell(p) + "`" for p in improvements] + [""]
    else:
        lines += ["", "No regression comparison was requested for this run.", ""]
    lines += ["### Outstanding correctness findings", "",
              "| Test | Status | Detail |", "| --- | --- | --- |"]
    for case in data["correctness"]:
        if case["status"] != "PASS":
            detail = case.get("detail", "").strip().splitlines()
            lines.append(f"| {cell(case['id'])} | {case['status']} | {cell(detail[0] if detail else 'process deadline exceeded')} |")
    speed_comparable = compatible(data, baseline)
    lines += ["", "### Benchmarks", "",
              "Two warm-ups precede each measured process. ns/unit means rows, bytes or decoded rows according to [coverage](COVERAGE.md); p95 measures whole operations. All repetitions, allocations, GC statistics, checksums and latency samples are retained in [current.json](results/current.json).", "",
              ("Environment, compiler, dependencies and benchmark workloads match the original baseline. Deltas below compare medians; more than 20% slower triggers investigation."
               if speed_comparable else "Performance profiles differ or comparability was not established; speed deltas are withheld."), "",
              "| Workload | Status | Median ns/unit | Baseline ns/unit | Change | p95 operation ms |",
              "| --- | --- | ---: | ---: | ---: | ---: |"]
    for ident, bench in sorted(data["benchmarks"].items()):
        old = baseline["benchmarks"].get(ident, {})
        if bench["status"] != "PASS":
            lines.append(f"| {ident} | {bench['status']} | | | | |")
            continue
        before = f"{old['median_ns_per_unit']:.1f}" if speed_comparable and old.get("status") == "PASS" else "—"
        delta = f"{(bench['median_ns_per_unit']/old['median_ns_per_unit']-1)*100:+.1f}%" if before != "—" else "—"
        lines.append(f"| {ident} | PASS | {bench['median_ns_per_unit']:.1f} | {before} | {delta} | {bench['p95_operation_ns']/1e6:.3f} |")
    return "\n".join(lines) + "\n"


def publish(attempt, data=None, *, current=CURRENT, report=REPORT, baseline=BASELINE):
    document = json.loads(current.read_text()) if current.exists() else {"schema": 1}
    document["latest_attempt"] = attempt
    if data is not None:
        if not data["complete_suite"] or data["repetitions"] < 7:
            raise ValueError("partial/short runs cannot replace the live full-suite report")
        if data["build"]["git_commit"] != attempt["inputs"]["commit"]:
            raise ValueError("recorder commit differs from the tested commit")
        document["latest_completed_run"] = {"attempt": attempt, "results": data}
    text = render(document, json.loads(baseline.read_text()))
    atomic_write(current, json.dumps(document, indent=2) + "\n")
    atomic_write(report, text)


def verify(document, snapshot):
    attempt = document["latest_attempt"]
    if attempt["state"] != "COMPLETED":
        raise ValueError("latest full validation did not complete")
    completed = document["latest_completed_run"]
    if completed["attempt"] != attempt:
        raise ValueError("live results are from an older attempt")
    data = completed["results"]
    if not data["complete_suite"] or data["repetitions"] < 7 or not data["source_unchanged_during_run"]:
        raise ValueError("live results do not cover a stable complete suite with seven repetitions")
    if attempt["inputs"]["dirty_inputs"] or snapshot["dirty_inputs"]:
        raise ValueError("test/build inputs must be committed before the published run")
    if attempt["inputs"]["files"] != snapshot["files"]:
        raise ValueError("live results are stale; run python3 validation/check.py on the current code")
    if data["build"]["git_commit"] != attempt["inputs"]["commit"]:
        raise ValueError("recorder and report disagree about the tested commit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", required=True,
                        help="fail if the live report does not cover current committed inputs")
    parser.parse_args()
    try:
        document = json.loads(CURRENT.read_text())
        verify(document, input_snapshot())
        if REPORT.read_text() != render(document, json.loads(BASELINE.read_text())):
            raise ValueError("RESULTS.md does not match current.json")
    except (ValueError, KeyError, FileNotFoundError) as error:
        raise SystemExit(str(error))
    print("Live report covers current committed test/build inputs; results-only publication commits are allowed.")


if __name__ == "__main__":
    main()
