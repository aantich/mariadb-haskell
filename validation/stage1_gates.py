#!/usr/bin/env python3
"""Additive acceptance policy. Never rewrites frozen workloads or measured values."""
from __future__ import annotations
import argparse
import hashlib
import json
import statistics
from pathlib import Path

HERE=Path(__file__).resolve().parent
TARGETS=[
'protocol.continuation-sequence-rejected','protocol.large-row-is-not-eof','protocol.empty-packet-predicate',
'packets.live-blob-16777216','packets.live-blob-16777217','packets.live-blob-33554430',
'protocol.column-definition-roundtrip','protocol.reset-does-not-consume-pending-row',
'reliability.reset-unread-result','reliability.server-kill-query','reliability.tls-cancellation-propagates',
'transaction.partial-result-exception','transaction.nested-preserves-outer',
'protocol.unsigned-last-insert-id','protocol.text-field-trailing-data','protocol.text-field-integer-overflow',
'sql.unsigned-generated-id','sql.zero-date-preservation','connection.default-full-unicode','types.non-utf8-results',
'parameters.literal-question-mark','parameters.comment-question-mark','parameters.no-backslash-text']

# Native-connection work is independent of the deferred CDC/prepared-output work.
NATIVE_TARGETS = [
    'protocol.binary-plugin-challenge', 'protocol.unknown-plugin-rejected',
    'protocol.native-extension-handshake',
    *['auth.' + plugin + '.' + transport for plugin in ['ed25519', 'parsec']
      for transport in ['tcp', 'tls', 'socket']],
    'auth.sha2.tcp', 'auth.sha2.socket', 'auth.mutual-tls-helper-client',
    'connection.localhost-address-fallback', 'connection.mozilla-ca-store-installed',
]

def results(document):
    """Accept either a portable raw run or the live publication envelope."""
    if "latest_completed_run" in document:
        return document["latest_completed_run"]["results"]
    return document


def reference(path=HERE / "results/accepted.json"):
    """Load the separately approved reference, never the candidate itself."""
    manifest = json.loads(path.read_text())
    root = path.parent.resolve()
    target = (root / manifest["reference"]).resolve()
    if not target.is_relative_to(root):
        raise ValueError("accepted reference escapes results directory")
    if target == root / "current.json":
        raise ValueError("live current results cannot be their own accepted reference")
    raw = target.read_bytes()
    if hashlib.sha256(raw).hexdigest() != manifest["sha256"]:
        raise ValueError("accepted reference hash mismatch")
    accepted = results(json.loads(raw))
    if (not manifest.get("tested_commit")
            or accepted.get("build", {}).get("git_commit") != manifest["tested_commit"]):
        raise ValueError("accepted reference and manifest disagree about the tested commit")
    return accepted, manifest


def median_allocation(benchmark):
    """Normalize raw Haskell samples; absent C heap metrics stay unavailable."""
    samples = [
        sample["allocated_bytes"] / sample["units"]
        for sample in benchmark.get("samples", [])
        if sample.get("allocated_bytes") is not None and sample.get("units", 0) > 0
    ]
    return statistics.median(samples) if samples else None


def compare(candidate, previous, original, *, require_targets=True, previous_stage=None):
    """Keep correctness acceptance separate from measurement/investigation gates.

    Known original failures remain visible. New failures cannot be added to that
    deferred set, and an accepted improvement cannot be lost just because its
    original-baseline status was FAIL. Timing signals require human resolution;
    they are never silently treated as accepted costs.
    """
    failures, timing, allocation, evidence = [], [], [], []
    if (not candidate.get("complete_suite")
            or candidate.get("repetitions", 0) < 7
            or not candidate.get("source_unchanged_during_run")):
        evidence.append("candidate is not a stable complete seven-repetition run")
    new = {case["id"]: case for case in candidate["correctness"]}
    if len(new) != len(candidate["correctness"]):
        failures.append("duplicate correctness IDs")
    references = [("original", original), ("accepted", previous)]
    if previous_stage is not None:
        references.append(("previous_stage", previous_stage))
    for label, old in references:
        for case in old["correctness"]:
            latest = new.get(case["id"])
            if latest is None:
                failures.append(f"{label}: removed {case['id']}")
            elif case["status"] == "PASS" and latest["status"] != "PASS":
                failures.append(f"{label}: lost PASS {case['id']} -> {latest['status']}")
            elif (case["status"] in ("FAIL", "TIMEOUT")
                  and latest["status"] in ("UNSUPPORTED", "ENVIRONMENT_UNAVAILABLE")):
                failures.append(f"{label}: hidden failure {case['id']}")
    original_ids = {case["id"] for case in original["correctness"]}
    deferred_ids = {case["id"] for case in original["correctness"]
                    if case["status"] in ("FAIL", "TIMEOUT")}
    statuses = {"PASS", "FAIL", "TIMEOUT", "UNSUPPORTED", "ENVIRONMENT_UNAVAILABLE"}
    for ident, case in new.items():
        if case["status"] not in statuses:
            failures.append("unknown correctness status: " + ident)
        # Reusing an inventory ID is not permission to extend the known failure
        # set. A newly implemented/available feature must pass its real case.
        if case["status"] in ("FAIL", "TIMEOUT") and ident not in deferred_ids:
            failures.append("failure outside original deferred set: " + ident)
        if ident not in original_ids and case["status"] != "PASS":
            failures.append("new case not passing: " + ident)
    if require_targets:
        for ident in TARGETS:
            if new.get(ident, {}).get("status") != "PASS":
                failures.append("required target not passing: " + ident)

    if require_targets and previous_stage is not None:
        for ident in NATIVE_TARGETS:
            if new.get(ident, {}).get("status") != "PASS":
                failures.append("required native target not passing: " + ident)

    for ident, benchmark in candidate.get("benchmarks", {}).items():
        prior_status = original.get("benchmarks", {}).get(ident, {}).get("status")
        if benchmark["status"] not in statuses:
            failures.append("unknown benchmark status: " + ident)
        if benchmark["status"] in ("FAIL", "TIMEOUT") and prior_status not in ("FAIL", "TIMEOUT"):
            failures.append("new failed benchmark: " + ident)

    for label, old in references:
        comparable = profile_matches(candidate, old)
        if old.get("benchmarks") and not comparable:
            evidence.append(label + ": performance profile differs; no speed/allocation comparison is valid")
        for ident, benchmark in old.get("benchmarks", {}).items():
            current = candidate.get("benchmarks", {}).get(ident)
            if current is None:
                failures.append(f"{label}: removed benchmark {ident}")
                continue
            if benchmark["status"] != "PASS":
                continue
            if current["status"] != "PASS":
                failures.append(f"{label}: missing/failed benchmark {ident}")
                continue
            if not comparable:
                continue
            before, after = benchmark["median_ns_per_unit"], current["median_ns_per_unit"]
            if after > before * 1.05:
                timing.append({"reference": label, "id": ident, "percent": 100 * (after / before - 1)})
            before_bytes, after_bytes = median_allocation(benchmark), median_allocation(current)
            if before_bytes and after_bytes and after_bytes > before_bytes * 1.05:
                allocation.append({"reference": label, "id": ident,
                                   "percent": 100 * (after_bytes / before_bytes - 1)})
    return {
        "schema": 1,
        "correctness_failures": failures,
        "evidence_failures": evidence,
        "evidence_accepted": not evidence,
        "timing_investigations": timing,
        "allocation_investigations": allocation,
        "target_passes": sum(new.get(ident, {}).get("status") == "PASS" for ident in TARGETS),
        "target_count": len(TARGETS),
        "native_target_passes": sum(new.get(ident, {}).get("status") == "PASS" for ident in NATIVE_TARGETS),
        "native_target_count": len(NATIVE_TARGETS),
        "correctness_accepted": not failures,
        "performance_requires_confirmation": bool(timing or allocation),
    }


def profile_matches(candidate, reference):
    """Refuse performance claims across different environments or workloads."""
    for key in ("machine", "server", "dependency_plan_sha256", "connector_c_version"):
        if key not in candidate or candidate[key] != reference.get(key):
            return False
    for key in ("ghc", "cabal"):
        if (key not in candidate.get("build", {})
                or candidate["build"][key] != reference.get("build", {}).get(key)):
            return False
    files = reference.get("build", {}).get("workload_files", {})
    frozen = [
        (path, digest) for path, digest in files.items()
        if path.endswith(("Validation/Benchmark.hs", "Validation/Common.hs", "connector_c.c", "run.py"))
    ]
    return len(frozen) == 4 and all(
        candidate.get("build", {}).get("workload_files", {}).get(path) == digest
        for path, digest in frozen
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--output", type=Path, default=HERE / "results/stage1-gates.json")
    args = parser.parse_args()
    accepted, manifest = reference()
    original = json.loads((HERE / "baselines/macos-arm64-mariadb-12.3.3/results.json").read_text())
    document = json.loads(args.candidate.read_text())
    data = results(document)
    if "latest_attempt" in document:
        import publish_results as live
        live.verify(document, live.input_snapshot(),
                    allow_working_tree=document["latest_attempt"].get("uncommitted_review", False))
    previous_stage, stage_manifest = reference(HERE / "results/previous-stage.json")
    report = compare(data, accepted, original, previous_stage=previous_stage)
    report["previous_stage_reference"] = stage_manifest
    report["accepted_reference"] = manifest
    report["tested_input_sha256"] = document.get("latest_attempt", {}).get("inputs", {}).get("sha256")
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if (report["correctness_accepted"] and report["evidence_accepted"]
                 and not report["performance_requires_confirmation"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
