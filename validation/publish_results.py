#!/usr/bin/env python3
"""Publish the live report, or check that it still covers the current source."""
from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
from html import escape
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
OVERVIEW = CURRENT.parent / "overview.svg"


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


def status_label(status):
    marker = {"PASS": "🟢", "FAIL": "🔴", "TIMEOUT": "🟠",
              "UNSUPPORTED": "🔵", "ENVIRONMENT_UNAVAILABLE": "🟡"}.get(status, "⚪")
    return f"{marker} {status}"


def render_overview(document):
    """A local, accessible SVG; no remote badge service or CSS dependency."""
    attempt = document["latest_attempt"]
    completed = document.get("latest_completed_run")
    lines = ['<svg xmlns="http://www.w3.org/2000/svg" width="1040" height="300" viewBox="0 0 1040 300" role="img" aria-labelledby="title description">',
             '<title id="title">MariaDB validation overview</title>',
             '<rect x="1" y="1" width="1038" height="298" rx="18" fill="#0f172a" stroke="#334155"/>',
             '<g font-family="-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif">',
             '<text x="30" y="35" font-size="12" font-weight="700" letter-spacing="2" fill="#94a3b8">MARIADB / VALIDATION</text>']
    if not completed:
        lines += ['<desc id="description">The latest validation attempt stopped. No complete results are available.</desc>',
                  '<text x="30" y="94" font-size="30" font-weight="700" fill="#fb7185">No completed suite</text>',
                  f'<text x="30" y="137" font-size="17" fill="#cbd5e1">Stopped at {escape(attempt["stage"])}</text>', '</g>', '</svg>']
        return "\n".join(lines) + "\n"
    data = completed["results"]
    counts = Counter(c["status"] for c in data["correctness"])
    regressions = data.get("comparison", {}).get("regressions", [])
    label = "CURRENT COMPLETE RUN" if attempt["state"] == "COMPLETED" else "PREVIOUS COMPLETE RUN"
    comparison = f"{len(regressions)} comparison {'alert' if len(regressions) == 1 else 'alerts'}" if regressions else "No comparison regressions"
    if not data.get("comparison"):
        comparison = "Comparison not requested"
    color = "#fbbf24" if regressions or not data.get("comparison") else "#34d399"
    description = (f"{counts['PASS']} passing records, {counts['FAIL']} failures, "
                   f"{counts['TIMEOUT']} timeouts, {counts['UNSUPPORTED']} unsupported APIs and "
                   f"{counts['ENVIRONMENT_UNAVAILABLE']} environment gaps. {comparison}.")
    lines += [f'<desc id="description">{escape(description)}</desc>',
              f'<text x="30" y="70" font-size="25" font-weight="700" fill="#f8fafc">{label}</text>',
              f'<text x="1008" y="68" text-anchor="end" font-size="15" font-weight="600" fill="{color}">{escape(comparison)}</text>']
    cards = [("PASSING RECORDS", counts["PASS"], "#34d399", "Including inherited suite summaries"),
             ("FAILURES / TIMEOUTS", counts["FAIL"] + counts["TIMEOUT"], "#fb7185", "Driver checks requiring attention"),
             ("UNSUPPORTED APIS", counts["UNSUPPORTED"], "#60a5fa", "Explicit gaps in the driver API"),
             ("ENVIRONMENT GAPS", counts["ENVIRONMENT_UNAVAILABLE"], "#fbbf24", "Fixtures not available on this host")]
    for index, (title, value, color, caption) in enumerate(cards):
        x = 30 + index * 248
        lines += [f'<rect x="{x}" y="94" width="234" height="128" rx="11" fill="#172338" stroke="#334155"/>',
                  f'<rect x="{x}" y="109" width="3" height="32" rx="1" fill="{color}"/>',
                  f'<text x="{x+16}" y="120" font-size="11" font-weight="700" letter-spacing="0.7" fill="#cbd5e1">{title}</text>',
                  f'<text x="{x+16}" y="171" font-size="43" font-weight="700" fill="{color}">{value}</text>',
                  f'<text x="{x+16}" y="201" font-size="10.5" fill="#94a3b8">{caption}</text>']
    footer = f"{data['server']['identity'][0]}  /  {data['repetitions']} benchmark repetitions  /  commit {data['build']['git_commit'][:12]}"
    lines += [f'<text x="30" y="258" font-size="13" fill="#cbd5e1">{escape(footer)}</text>',
              '<text x="30" y="281" font-size="11" fill="#94a3b8">Counts include two inherited suite summaries. Missing APIs and environment gaps are not passes.</text>',
              '</g>', '</svg>']
    return "\n".join(lines) + "\n"


def run_details(attempt, data):
    lines = ["## Run details", "", "<details>",
             "<summary>Revision, environment and reproducibility</summary>", "",
             "| Field | Latest attempt |", "| --- | --- |",
             f"| State / exit code | {attempt['state']} / {attempt['exit_code']} |",
             f"| Tested commit | [`{attempt['inputs']['commit']}`](https://github.com/aantich/mariadb-haskell/commit/{attempt['inputs']['commit']}) |",
             f"| Branch | `{attempt['inputs']['branch']}` |",
             f"| Started / finished (UTC) | {attempt['started_at']} / {attempt['finished_at']} |",
             f"| Input fingerprint | `{attempt['inputs']['sha256']}` |",
             f"| Local logs and build plan | `{attempt['run_directory']}` (ignored by Git) |"]
    if data:
        machine = data["machine"]
        lines += [f"| Server of completed run | {cell(data['server']['identity'][0])} |",
                  f"| Host | {cell(machine.get('cpu_model', machine['machine']))}; macOS {machine.get('macos', '')} |",
                  f"| Compiler / build tool | GHC {data['build']['ghc']}; Cabal {data['build']['cabal']} |",
                  f"| MariaDB Connector/C | {data.get('connector_c_version', 'not recorded')} |",
                  f"| Complete suite / repetitions | {data['complete_suite']} / {data['repetitions']} |",
                  f"| Driver/workloads stable during execution | {data['source_unchanged_during_run']} |"]
    lines += ["", "The tested commit identifies the code used for execution. A following results-only commit publishes this document; it does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.", "",
              "Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.", "", "</details>", ""]
    return lines


def render(document, baseline):
    attempt = document["latest_attempt"]
    lines = ["# Live MariaDB validation results", "",
             "Current measurements for `main`, compared with the original unchanged-driver baseline.", "",
             "![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)", "",
             "[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)", ""]
    if attempt["inputs"]["dirty_inputs"]:
        lines += ["**Uncommitted test/build inputs:** the tested contents differ from the recorded commit: "
                  + ", ".join(f"`{p}`" for p in attempt["inputs"]["dirty_inputs"]) + ".", ""]
    if attempt["state"] != "COMPLETED":
        lines += ["> [!CAUTION]", f"> **Latest attempt stopped at {attempt['stage']}.** {attempt['reason']}",
                  "> Retained results below are older and do not validate this attempt.", ""]
    completed = document.get("latest_completed_run")
    if not completed:
        return "\n".join(lines + ["No complete suite has been published yet.", ""] + run_details(attempt, None))
    data = completed["results"]
    counts = Counter(c["status"] for c in data["correctness"])
    old_counts = Counter(c["status"] for c in baseline["correctness"])
    comparison = data.get("comparison")
    regressions = comparison["regressions"] if comparison else []
    improvements = comparison["improved_cases"] if comparison else []
    failed = counts["FAIL"] + counts["TIMEOUT"]
    if attempt["state"] != "COMPLETED":
        lines += ["## Last completed suite (older results)", "",
                  f"The results below are from `{data['build']['git_commit']}` at {data['recorded_at']}; they do **not** validate the failed attempt above.", ""]
    if failed:
        lines += ["> [!CAUTION]", f"> **{failed} failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.", ""]
    if comparison:
        marker = "🟠 Attention required" if regressions else "🟢 No new regression signals"
        lines += [f"**Baseline comparison: {marker}** · {len(regressions)} regression {'signal' if len(regressions) == 1 else 'signals'} · {len(improvements)} newly passing {'check' if len(improvements) == 1 else 'checks'}.", "",
                  "A passing comparison does not mean all functionality passes.", ""]
        if regressions:
            lines += ["<details open>", "<summary>🟠 Comparison signals — investigation required</summary>", ""]
            lines += ["- " + cell(p) for p in regressions] + ["", "</details>", ""]
        if improvements:
            lines += ["<details>", "<summary>🟢 Newly passing checks</summary>", ""]
            lines += ["- `" + cell(p) + "`" for p in improvements] + ["", "</details>", ""]
    else:
        lines += ["> [!NOTE]", "> No regression comparison was requested for this run.", ""]
    lines += ["| Reference | Commit |", "| --- | --- |",
              f"| **Baseline** · original unchanged-driver run | `{baseline['build']['git_commit'][:12]}` |",
              f"| **Current** · latest completed run | `{data['build']['git_commit'][:12]}` |", "",
              "Both comparison tables use these same two runs.", "",
              "## Correctness", "",
              "Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.", "",
              "| Status | Baseline | Current | Change vs baseline |", "| --- | ---: | ---: | ---: |"]
    for status in ("PASS", "FAIL", "TIMEOUT", "UNSUPPORTED", "ENVIRONMENT_UNAVAILABLE"):
        change = counts[status] - old_counts[status]
        delta = f"{change:+d}" if change else "0"
        if change and status in ("PASS", "FAIL", "TIMEOUT"):
            better = change > 0 if status == "PASS" else change < 0
            delta = ("🟢 " if better else "🔴 ") + delta
        lines.append(f"| {status_label(status)} | {old_counts[status]} | **{counts[status]}** | {delta} |")
    for statuses, title in [({"FAIL", "TIMEOUT"}, "🔴 Failed or timed-out checks"),
                            ({"UNSUPPORTED"}, "🔵 Missing driver APIs"),
                            ({"ENVIRONMENT_UNAVAILABLE"}, "🟡 Unavailable environment fixtures")]:
        cases = [c for c in data["correctness"] if c["status"] in statuses]
        if not cases:
            continue
        lines += ["", "<details>", f"<summary>{title} ({len(cases)}) — expand all findings</summary>", "",
                  "| Test | Current status | Detail |", "| --- | --- | --- |"]
        for case in cases:
            detail = case.get("detail", "").strip().splitlines()
            lines.append(f"| `{cell(case['id'])}` | {status_label(case['status'])} | {cell(detail[0] if detail else 'process deadline exceeded')} |")
        lines += ["", "</details>"]
    speed_comparable = compatible(data, baseline)
    lines += ["", "## Benchmarks", "",
              "**Lower time is faster.** Both timing columns show median **ns/unit**; p95 describes complete operations in the Current run. [Coverage](COVERAGE.md) defines each workload's unit.", "",
              "**Change = 100 × (Current − Baseline) / Baseline**, using unrounded medians. 🟢 Negative = faster · 🟡 Positive = slower · 🔴 More than 20% slower = investigate. ⚪ Zero at displayed precision = unchanged.", "",
              "> [!NOTE]", "> A benchmark marked PASS completed its workload. Its timing can still trigger a slowdown alert.", ""]
    if not speed_comparable:
        lines += ["> [!WARNING]", "> Performance profiles differ or comparability was not established; speed deltas are withheld.", ""]
    else:
        lines += ["Environment, compiler, dependencies and benchmark workloads match the original baseline.", ""]
    engines = sorted({ident.partition("/")[0] for ident in data["benchmarks"]}, key=lambda engine: (engine != "haskell", engine))
    for engine in engines:
        title = {"haskell": "Haskell driver", "connector-c": "MariaDB Connector/C control"}.get(engine, engine)
        lines += [f"### {title}", "",
                  "| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |",
                  "| --- | ---: | ---: | --- | ---: | --- |"]
        for ident, bench in sorted(data["benchmarks"].items()):
            if ident.partition("/")[0] != engine:
                continue
            name = cell(ident.partition("/")[2])
            old = baseline["benchmarks"].get(ident, {})
            before = f"{old['median_ns_per_unit']:.1f}" if old.get("status") == "PASS" else "—"
            if bench["status"] != "PASS":
                lines.append(f"| `{name}` | {before} | — | — | — | {status_label(bench['status'])} |")
                continue
            delta = "—"
            if speed_comparable and before != "—":
                percent = (bench["median_ns_per_unit"] / old["median_ns_per_unit"] - 1) * 100
                if round(percent, 1) == 0:
                    delta = "⚪ +0.0% unchanged"
                elif percent < 0:
                    delta = f"🟢 {percent:+.1f}% faster"
                else:
                    delta = f"{'🔴' if percent > 20 else '🟡'} {percent:+.1f}% slower"
            lines.append(f"| `{name}` | {before} | **{bench['median_ns_per_unit']:.1f}** | {delta} | {bench['p95_operation_ns']/1e6:.3f} | {status_label('PASS')} |")
        lines.append("")
    lines += ["— means no successful measurement is available, or the runs cannot be compared for Change.", "",
              f"Each measured process has two warm-ups; this run has **{data['repetitions']} repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).", ""]
    lines += run_details(attempt, data)
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
    overview = render_overview(document)
    atomic_write(current, json.dumps(document, indent=2) + "\n")
    atomic_write(report, text)
    atomic_write(current.parent / "overview.svg", overview)


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
        if OVERVIEW.read_text() != render_overview(document):
            raise ValueError("overview.svg does not match current.json")
    except (ValueError, KeyError, FileNotFoundError) as error:
        raise SystemExit(str(error))
    print("Live report covers current committed test/build inputs; results-only publication commits are allowed.")


if __name__ == "__main__":
    main()
