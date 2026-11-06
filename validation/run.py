#!/usr/bin/env python3
"""Run the actual driver in isolated processes and retain immutable evidence.

No expected-failure wrappers. A broken/unsupported case remains visible.
Server availability is a hard prerequisite, before any test/benchmark starts.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
HERE = ROOT / "validation"


def command(args, *, env=None, timeout=60, check=True, input=None):
    return subprocess.run(args, cwd=ROOT, env=env, input=input, capture_output=True,
                          text=True, timeout=timeout, check=check)


def executable(target):
    return command(["cabal", "list-bin", "-O2", "--enable-tests", target]).stdout.strip().splitlines()[-1]


def digest_files(paths):
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths) if p.is_file()}


def snapshot():
    cabal = (ROOT / "mysql-haskell.cabal").read_text()
    library = cabal[cabal.index("library\n"):cabal.index("test-suite test\n")]
    return {
        "git_commit": command(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "git_branch": command(["git", "branch", "--show-current"]).stdout.strip(),
        "driver_source_files": digest_files((ROOT / "src").rglob("*.hs")),
        "library_cabal_sha256": hashlib.sha256(library.encode()).hexdigest(),
        "workload_files": digest_files([*HERE.rglob("*.hs"), HERE / "connector_c.c", HERE / "run.py"]),
        "ghc": command(["ghc", "--numeric-version"]).stdout.strip(),
        "cabal": command(["cabal", "--numeric-version"]).stdout.strip(),
    }


def percentile(values, p):
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p
    lo = math.floor(position)
    return ordered[lo] + (ordered[math.ceil(position)] - ordered[lo]) * (position - lo)


def cli_path():
    override = os.environ.get("MB_CLIENT")
    if override:
        return override
    found = shutil.which("mariadb")
    if found:
        return found
    path = Path("/opt/homebrew/opt/mariadb@12.3/bin/mariadb")
    if path.exists():
        return str(path)
    raise RuntimeError("mariadb client not found; install/start the managed server first")


def sql_client(env, query, client_certificate=False):
    # Keep the generated development password out of argv, logs and artifacts.
    with tempfile.TemporaryDirectory(prefix="mariadb-validation-client-") as folder:
        cnf = Path(folder) / "client.cnf"
        options=[
            "user=" + env["MB_USER"], "password=" + env["MB_PASSWORD"],
            "host=" + env["MB_HOST"], "port=" + env["MB_PORT"],
            "protocol=tcp", "ssl=" + ("1" if client_certificate else "0")]
        if client_certificate:
            options += ["ssl-verify-server-cert=1", "ssl-ca="+env["MB_TLS_CA"],
                        "ssl-cert="+env["MB_TLS_CLIENT_CERT"], "ssl-key="+env["MB_TLS_CLIENT_KEY"]]
        cnf.write_text("[client]\n" + "\n".join(options) + "\n")
        cnf.chmod(0o600)
        return command([cli_path(), "--defaults-extra-file=" + str(cnf),
                        "--batch", "--skip-column-names", env["MB_DATABASE"]],
                       input=query, timeout=60).stdout.strip()


def server_metadata(env):
    query = "SELECT VERSION(), @@version_comment, @@version_compile_machine;"
    query += " SHOW VARIABLES WHERE Variable_name IN ('port','bind_address','character_set_server','collation_server','max_allowed_packet','binlog_format','binlog_row_image','binlog_checksum','log_bin','innodb_flush_log_at_trx_commit','sync_binlog','innodb_buffer_pool_size','sql_mode','lower_case_table_names','have_ssl','max_connections','time_zone');"
    lines = sql_client(env, query).splitlines()
    return {"identity": lines[0].split("\t"), "variables": dict(line.split("\t", 1) for line in lines[1:])}


def case_result(binary, ident, area, env, log, timeout=20):
    start = time.monotonic()
    try:
        result = command([binary, "case", ident], env=env, timeout=timeout, check=False)
        status = {0: "PASS", 3: "UNSUPPORTED", 4: "ENVIRONMENT_UNAVAILABLE"}.get(result.returncode, "FAIL")
        stdout, stderr = result.stdout, result.stderr
        code = result.returncode
    except subprocess.TimeoutExpired as exc:
        status, code = "TIMEOUT", None
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes): stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode(errors="replace")
    log.write_text(stdout + stderr)
    return {"id": ident, "area": area, "status": status, "returncode": code,
            "seconds": time.monotonic() - start, "detail": (stderr or stdout)[-4000:]}


def compile_control():
    config = os.environ.get("MB_CONFIG") or shutil.which("mariadb_config")
    if not config:
        config = "/opt/homebrew/opt/mariadb@12.3/bin/mariadb_config"
    flags = shlex.split(command([config, "--include", "--libs"]).stdout)
    binary = HERE / ".local" / "connector-c"
    binary.parent.mkdir(exist_ok=True)
    command([os.environ.get("CC", "cc"), "-O2", str(HERE / "connector_c.c"),
             *flags, "-o", str(binary)])
    return str(binary), command([str(binary), "--version"]).stdout.strip()


def benchmark_sample(binary, ident, iterations, env, log):
    args = [binary, "bench", ident, str(iterations), "+RTS", "-N4", "-T", "-RTS"] if Path(binary).name != "connector-c" else [binary, ident, str(iterations)]
    try:
        result = command(args, env=env, timeout=180, check=False)
    except subprocess.TimeoutExpired:
        log.write_text("benchmark process exceeded 180 seconds\n")
        return {"status": "TIMEOUT", "detail": "benchmark process deadline exceeded"}
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        return {"status": "UNSUPPORTED" if result.returncode == 3 else "FAIL",
                "detail": (result.stderr or result.stdout)[-2000:]}
    line = next((line for line in result.stdout.splitlines() if line.startswith("BENCH\t")), None)
    if not line:
        return {"status": "FAIL", "detail": "missing benchmark record"}
    fields = line.split("\t")
    names = ["units", "elapsed_ns", "allocated_bytes", "gc_cpu_ns", "max_live_bytes", "cpu_ns", "checksum"]
    sample = {name: (int(value) if int(value) >= 0 else None) for name, value in zip(names, fields[2:9])}
    sample["operation_latencies_ns"] = [int(x) for x in fields[9].split(",")]
    sample["ns_per_unit"] = sample["elapsed_ns"] / sample["units"]
    sample["status"] = "PASS"
    return sample


def compare(current, baseline, performance):
    problems, improvements = [], []
    old = {case["id"]: case for case in baseline["correctness"]}
    new = {case["id"]: case for case in current["correctness"]}
    for ident, previous in old.items():
        latest = new.get(ident)
        if latest is None:
            problems.append("test removed: " + ident)
        elif previous["status"] == "PASS" and latest["status"] != "PASS":
            problems.append(f"{ident}: PASS -> {latest['status']}")
        elif previous["status"] != "PASS" and latest["status"] == "PASS":
            improvements.append(ident)
        elif previous["status"] in ("FAIL", "TIMEOUT") and latest["status"] in ("UNSUPPORTED", "ENVIRONMENT_UNAVAILABLE"):
            problems.append(f"{ident}: failure reclassified as {latest['status']}")
    for ident, latest in new.items():
        if ident not in old and latest["status"] in ("FAIL","TIMEOUT","ENVIRONMENT_UNAVAILABLE"):
            problems.append("new failing/unavailable test: " + ident)
    # A changed workload is a new experiment, never a direct speed comparison.
    same_workloads = all(current["build"]["workload_files"].get(path) == value
                         for path,value in baseline["build"]["workload_files"].items()
                         if path.endswith(("Validation/Benchmark.hs", "Validation/Common.hs", "connector_c.c", "run.py")))
    if performance:
        same_machine = current["machine"] == baseline["machine"]
        same_server = current["server"] == baseline["server"]
        same_build = all(current["build"][key] == baseline["build"][key] for key in ("ghc", "cabal"))
        same_dependencies = current["dependency_plan_sha256"] == baseline["dependency_plan_sha256"]
        if not (same_workloads and same_machine and same_server and same_build and same_dependencies):
            problems.append("performance profile differs: same workload, machine, server settings, compiler and dependency plan are required")
        else:
            for ident, previous in baseline["benchmarks"].items():
                latest = current["benchmarks"].get(ident)
                if previous["status"] != "PASS": continue
                if not latest or latest["status"] != "PASS":
                    problems.append("benchmark no longer completes: " + ident)
                elif latest["median_ns_per_unit"] > previous["median_ns_per_unit"] * 1.20:
                    problems.append(f"{ident}: median slowed by more than 20%; confirm on an idle machine")
    return {"regressions": problems, "improved_cases": improvements,
            "same_workloads": same_workloads, "performance_checked": performance}


def report(data):
    counts = {}
    for case in data["correctness"]: counts[case["status"]] = counts.get(case["status"], 0) + 1
    lines = ["# MariaDB driver baseline", "", "This run tests the current driver without implementation fixes.", "",
             f"Server: **{data['server']['identity'][0]}**. Driver commit: `{data['build']['git_commit'][:12]}`.", "",
             " | ".join(f"{key}: **{value}**" for key, value in counts.items()), "",
             "## Correctness findings", "", "| Test | Status | Detail |", "| --- | --- | --- |"]
    for case in data["correctness"]:
        if case["status"] != "PASS":
            detail = case["detail"].strip().splitlines()[0] if case["detail"].strip() else "process deadline exceeded"
            lines.append(f"| {case['id']} | {case['status']} | {detail.replace('|', '/')} |")
    lines += ["", "## Benchmarks", "", "Two warm-up operations precede every measured process. Seven repetitions are the default. Raw samples and operation latencies are retained in JSON. A query/transaction/decoder batch is the latency unit; ns/unit normalizes by rows, bytes or decoder rows as specified in COVERAGE.md.", "",
              "| Workload | Status | Median ns/unit | p95 operation ms |", "| --- | --- | ---: | ---: |"]
    for ident, bench in data["benchmarks"].items():
        if bench["status"] == "PASS":
            lines.append(f"| {ident} | PASS | {bench['median_ns_per_unit']:.1f} | {bench['p95_operation_ns']/1e6:.3f} |")
        else: lines.append(f"| {ident} | {bench['status']} | | |")
    if data.get("comparison"):
        lines += ["", "## Comparison", "", json.dumps(data["comparison"], indent=2)]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=HERE / ".local" / "environment.json")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--only", help="substring filter for harness development; cannot freeze a partial run")
    parser.add_argument("--no-upstream", action="store_true")
    parser.add_argument("--no-benchmarks", action="store_true")
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--correctness-only-comparison", action="store_true")
    parser.add_argument("--freeze", type=Path, help="new immutable baseline directory; must not exist")
    args = parser.parse_args()
    if args.repetitions < 1: parser.error("repetitions must be positive")
    if args.freeze and (args.only or args.no_upstream or args.no_benchmarks or args.repetitions < 7):
        parser.error("a frozen baseline requires the complete suite and at least seven repetitions")
    if args.freeze and args.freeze.exists(): parser.error("baseline already exists; refusing to overwrite")
    env = os.environ.copy()
    env.update(json.loads(args.config.read_text()))
    env["TZ"] = "UTC"
    binary = executable("exe:mariadb-validation")
    # Hard dependency gate: there is no synthetic fallback for a missing server.
    preflight = command([binary, "preflight"], env=env, timeout=15, check=False)
    if preflight.returncode:
        raise SystemExit("MariaDB preflight failed; no tests or benchmarks started:\n" + preflight.stdout + preflight.stderr)
    print(preflight.stdout.strip(), flush=True)
    output = args.output or HERE / "results" / "runs" / dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output.mkdir(parents=True, exist_ok=False)
    logs = output / "logs"; logs.mkdir()
    build = snapshot()
    reference="92a94012bc553a672c73d409dad1d17e9db1e53f"
    unchanged=command(["git","diff","--quiet",reference,"--","src"],check=False).returncode==0
    original_cabal=command(["git","show",reference+":mysql-haskell.cabal"]).stdout
    original_library=original_cabal[original_cabal.index("library\n"):original_cabal.index("test-suite test\n")]
    library_unchanged=hashlib.sha256(original_library.encode()).hexdigest()==build["library_cabal_sha256"]
    if args.freeze and not (unchanged and library_unchanged):
        raise SystemExit("initial baseline requires unchanged driver source and library configuration")
    build.update(reference_driver_commit=reference,driver_matches_reference=unchanged,library_configuration_matches_reference=library_unchanged)
    plan = ROOT / "dist-newstyle/cache/plan.json"
    # Compare resolved dependencies, not absolute compiler/store paths or targets.
    plan_data = json.loads(plan.read_text())
    dependencies = sorted({(p["pkg-name"],p["pkg-version"]) for p in plan_data["install-plan"] if p["pkg-name"] != "mysql-haskell"})
    data = {"schema": 1, "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "complete_suite": not (args.only or args.no_upstream or args.no_benchmarks),
            "build": build, "server": server_metadata(env), "dependencies": dependencies,
            "dependency_plan_sha256": hashlib.sha256(json.dumps(dependencies).encode()).hexdigest(),
            "machine": {"system": platform.system(), "release": platform.release(), "machine": platform.machine(),
                        "macos": platform.mac_ver()[0], "cpu_count": os.cpu_count(),
                        "cpu_model": command(["sysctl","-n","machdep.cpu.brand_string"],check=False).stdout.strip() if sys.platform == "darwin" else platform.processor()},
            "correctness": [], "benchmarks": {}, "repetitions": args.repetitions,
            "haskell_benchmark_rts": ["-N4", "-T"], "process_timezone":"UTC"}
    data["fixture_controls"]={}
    for plugin,user in [("native","mariadb_haskell_test"),("ed25519","mariadb_ed25519"),
                        ("parsec","mariadb_parsec"),("sha2","mariadb_sha2"),("mutual_tls","mariadb_x509")]:
        control_env={**env,"MB_USER":user}
        value=sql_client(control_env,"SELECT 937",client_certificate=(plugin=="mutual_tls"))
        if value!="937": raise RuntimeError("invalid authentication fixture: "+plugin)
        data["fixture_controls"][plugin]="PASS"
    listed = command([binary, "list"]).stdout.splitlines()
    ids = [line.split("\t")[0] for line in listed]
    if len(set(ids)) != len(ids): raise RuntimeError("duplicate test IDs")
    for line in listed:
        ident, area = line.split("\t")
        if args.only and args.only not in ident: continue
        result = case_result(binary, ident, area, env, logs / (ident + ".log"), 45 if area == "large-packets" else 20)
        data["correctness"].append(result)
        (output / "partial-results.json").write_text(json.dumps(data,indent=2) + "\n")
        print(result["status"], ident, flush=True)
    if not args.no_upstream and not args.only:
        for target, name, extra, timeout in [("test:test", "inherited.unit", ["--quickcheck-replay=730208","--quickcheck-tests=100"], 300),
                                             ("test:integration", "inherited.integration", ["--num-threads=1","--timeout=180s"], 300)]:
            testenv = env.copy(); testenv["MYSQL_TLS_CA_PATH"] = env["MB_TLS_CA"]; testenv["MYSQL_UNIX_SOCKET"] = env["MB_SOCKET"]
            started = time.monotonic()
            try:
                result = command([executable(target), *extra], env=testenv, timeout=timeout, check=False)
                status = "PASS" if result.returncode == 0 else "FAIL"
                full_log = result.stdout + result.stderr
                detail = full_log[-12000:]
            except subprocess.TimeoutExpired:
                status, detail = "TIMEOUT", "inherited test process exceeded its deadline"
                full_log = detail
            (logs / (name + ".log")).write_text(full_log)
            data["correctness"].append({"id": name,"area":"inherited","status":status,"seconds":time.monotonic()-started,"detail":detail})
            print(status, name, flush=True)
    if not args.no_benchmarks and not args.only:
        sql_client(env, "DROP TABLE IF EXISTS mb_bench_data; CREATE TABLE mb_bench_data(id BIGINT PRIMARY KEY,n BIGINT NOT NULL,payload VARCHAR(128) NOT NULL) ENGINE=InnoDB; INSERT INTO mb_bench_data SELECT seq,seq*3,RPAD('x',128,'x') FROM seq_1_to_10000;")
        control, version = compile_control()
        data["connector_c_version"] = version
        controls = {"latency.text","read.text.narrow","read.text.wide","write.text","write.execute-many","blob.text"}
        workloads = [line.split("\t") for line in command([binary,"list-benchmarks"]).stdout.splitlines()]
        schedule = [("haskell", ident, int(n), binary) for ident,n in workloads]
        schedule += [("connector-c", ident, int(n), control) for ident,n in workloads if ident in controls]
        for repetition in range(args.repetitions):
            random.Random(730208 + repetition).shuffle(schedule)
            for engine, ident, n, program in schedule:
                key = engine + "/" + ident
                sample = benchmark_sample(program, ident, n, env, logs / f"bench.{engine}.{ident}.{repetition}.log")
                data["benchmarks"].setdefault(key,{"samples":[]})["samples"].append(sample)
                (output / "partial-results.json").write_text(json.dumps(data,indent=2) + "\n")
                print("BENCH", repetition+1, key, sample["status"], flush=True)
        for bench in data["benchmarks"].values():
            samples = bench["samples"]
            bench["status"] = "PASS" if all(s["status"] == "PASS" for s in samples) else next(s["status"] for s in samples if s["status"] != "PASS")
            if bench["status"] == "PASS":
                values = [s["ns_per_unit"] for s in samples]
                latencies = [ns for s in samples for ns in s["operation_latencies_ns"]]
                bench.update(median_ns_per_unit=statistics.median(values),
                             min_ns_per_unit=min(values),max_ns_per_unit=max(values),
                             p50_operation_ns=percentile(latencies,.50),p95_operation_ns=percentile(latencies,.95),p99_operation_ns=percentile(latencies,.99))
    final = snapshot()
    if final["driver_source_files"] != build["driver_source_files"]:
        raise RuntimeError("driver source changed during baseline run")
    if final["workload_files"] != build["workload_files"]:
        raise RuntimeError("test/benchmark workloads changed during run")
    data["source_unchanged_during_run"] = True
    if args.compare:
        data["comparison"] = compare(data,json.loads(args.compare.read_text()),not args.correctness_only_comparison)
    (output / "results.json").write_text(json.dumps(data,indent=2) + "\n")
    (output / "SUMMARY.md").write_text(report(data))
    shutil.copy2(plan, output / "build-plan.json")
    if args.freeze:
        args.freeze.mkdir(parents=True)
        for name in ("results.json","SUMMARY.md"): shutil.copy2(output/name,args.freeze/name)
        (args.freeze / "SHA256SUMS").write_text("".join(hashlib.sha256((args.freeze/name).read_bytes()).hexdigest()+"  "+name+"\n" for name in ("results.json","SUMMARY.md")))
        print("Frozen baseline:",args.freeze)
    print("Results:",output / "SUMMARY.md")
    if args.compare and data["comparison"]["regressions"]: return 1
    # Initial capture deliberately returns nonzero when correctness fails.
    if not args.compare and any(c["status"] in ("FAIL","TIMEOUT","ENVIRONMENT_UNAVAILABLE") for c in data["correctness"]): return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
