# MariaDB validation and baseline

This suite tests the real Haskell driver against MariaDB. The first baseline must use the inherited implementation unchanged. Failures, unsupported APIs and unavailable environment fixtures remain visible; they are not converted into passing expected-failure tests.

Install and verify the database **before** building or running the validation suite. [macOS setup](MACOS.md) uses a Homebrew binary package and its managed service. No MariaDB Server source build is needed.

## Run the suite

From the repository root, after the server setup:

```sh
python3 validation/provision.py
cabal update
cabal build exe:mariadb-validation test:test test:integration --enable-tests -O2
python3 validation/test_runner.py
python3 validation/check.py
```

The `check.py` entry point verifies MariaDB before building, rebuilds the current source and invokes the recorder. This prevents stale executables being measured after source edits. The recorder checks connectivity, server identity, the reserved database, packet limits and binlog configuration. If preflight fails, it runs no tests or benchmarks. It then runs every new correctness case in a separate process, runs both inherited suites unchanged, seeds the reserved benchmark table, and interleaves seven repetitions of Haskell and matching MariaDB Connector/C workloads. Every measured process performs two warm-ups before recording timings. A hung/crashed case cannot stop the remaining new cases. `run.py` is the lower-level recorder for an already-built harness.

Both MariaDB's default session timezone and the test-process timezone are pinned to UTC. This avoids seasonal timezone assumptions in inherited binlog tests. The runner verifies password-plugin and client-certificate fixtures with MariaDB's own client before attributing failures to the Haskell driver.

`validation/.local/environment.json` holds generated local connection settings and credentials with mode 0600. It is ignored by Git. The runner also accepts `--config FILE`. Haskell cases read the `MB_*` environment variables supplied by that file. No password is written into the baseline JSON or passed to the CLI on its command line.

Runs are retained under `validation/results/runs/`, including raw logs, machine/server/compiler details, resolved dependency versions, source/workload hashes, per-case outcomes, raw benchmark repetitions, operation latency samples, allocations and checksums. A summary is generated even when the driver has known failures. Initial capture exits nonzero on correctness failures; that does not invalidate its role as an honest baseline.

## Freeze the first baseline

Use a new directory name; existing baselines cannot be overwritten:

```sh
python3 validation/check.py \
  --freeze validation/baselines/macos-arm64-mariadb-12.3.3
```

Freezing requires the complete suite and at least seven repetitions. The driver source and workloads are hashed before and after the run. The baseline contains raw results, a readable summary and SHA-256 checksums. Raw per-process logs remain in the associated run directory. The inherited code under `src/` must still match the initial source tree when creating the first baseline.

## Compare every improvement

```sh
python3 validation/check.py \
  --compare validation/baselines/macos-arm64-mariadb-12.3.3/results.json
```

Comparison rejects removal of old cases, loss of a previous pass, hiding a failure as unsupported/unavailable, failed previously working benchmarks and a median slowdown over 20%. Newly passing cases are reported as improvements. A slowdown is a signal to repeat on an idle machine and investigate, not a precise statistical claim.

Speed comparisons require matching machine, server version/settings, compiler, resolved dependencies and benchmark workload hashes. This prevents comparing a changed workload or another machine to the Mac baseline. To compare only behavior across environments, add `--correctness-only-comparison`. Preserve the initial baseline; use a separate directory for another server/version/hardware profile. `--only SUBSTRING --no-upstream --no-benchmarks` is available for harness development but cannot freeze a baseline.

The initial [frozen baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md) contains 300 executable checks, 11 missing-API entries and two unavailable-environment entries. The two inherited suites appear as aggregate records in JSON; their logs contain the individual 179 unit/property cases (one inherited external HTTPS ignore) and 32 integration cases.

## Scope and interpretation

[COVERAGE.md](COVERAGE.md) maps the cases, workloads and environment requirements. The suite covers the driver's relevant protocol, connection, value, SQL, transaction, streaming, error and replication surfaces. It is not a certification of every MariaDB storage engine, query optimizer plan, Galera topology or backup tool.

Capability inventory entries explicitly report `UNSUPPORTED` where the current driver has no API to exercise, including native bulk and metadata caching. These entries must become real tests and benchmarks when those APIs are added. They are not successful feature tests. Environment gaps remain separate from missing driver APIs.

The C control links the **installed MariaDB Connector/C** and consumes the same text-protocol SQL, ASCII fields, integer values and checksums. Binary prepared, vector, TLS, socket, concurrency and decoder microbenchmarks are currently Haskell-only and must not be presented as C comparisons. The write workload includes table truncation, a transaction, all inserts, commit and count/sum verification on both clients. Its operation latency is the whole transaction, not one insert.

Benchmark ns/unit uses rows for SELECT/INSERT, bytes for the 1 MiB BLOB workload and decoded rows for microbenchmarks. p50/p95/p99 operation latency uses complete queries, transactions or decoder batches. Large scans have few operation samples, so their tail percentiles are descriptive. RTS allocations/GC/live heap are Haskell metrics; unavailable C metrics are null. Connection and statement creation happen outside timing, including for concurrent readers. `-O2`, `+RTS -N4 -T`, warm-ups, repetition counts and durability settings are recorded.
