# MariaDB validation and baseline

This suite tests the real Haskell driver against MariaDB. The first baseline must use the inherited implementation unchanged. Failures, unsupported APIs and unavailable environment fixtures remain visible; they are not converted into passing expected-failure tests.

**[Live results for the current tested code](RESULTS.md)** are committed on `main` and linked from the root README. Full runs update this document, its [colored summary](results/overview.svg) and [current.json](results/current.json) automatically. Status colors always include text labels; complete findings remain available in expandable sections. The original frozen baseline remains the comparison reference; Git history preserves earlier versions of the live report.

Install and verify the database **before** building or running the validation suite. [macOS setup](MACOS.md) uses a Homebrew binary package and its managed service. No MariaDB Server source build is needed.

## Run the suite

From the repository root, after the server setup:

```sh
python3 validation/provision.py
cabal update
python3 -m unittest discover -s validation -p 'test_*.py'
python3 validation/check.py
```

The `check.py` entry point verifies MariaDB before building, rebuilds the current source and invokes the recorder. This prevents stale executables being measured after source edits. The recorder checks connectivity, server identity, the reserved database, packet limits and binlog configuration. If preflight fails, it runs no tests or benchmarks. It then runs every new correctness case in a separate process, runs both inherited suites with their assertions preserved, seeds the reserved benchmark table, and interleaves seven repetitions of Haskell and matching MariaDB Connector/C workloads. Every measured process performs two warm-ups before recording timings. A hung/crashed case cannot stop the remaining new cases. `run.py` is the lower-level recorder for an already-built harness.

Both MariaDB's default session timezone and the test-process timezone are pinned to UTC. This avoids seasonal timezone assumptions in inherited binlog tests. The runner verifies password-plugin and client-certificate fixtures with MariaDB's own client before attributing failures to the Haskell driver.

`validation/.local/environment.json` holds generated local connection settings and credentials with mode 0600. It is ignored by Git. The runner also accepts `--config FILE`. Haskell cases read the `MB_*` environment variables supplied by that file. No password is written into the baseline JSON or passed to the CLI on its command line.

Runs are retained under `validation/results/runs/`, including raw logs, machine/server/compiler details, resolved dependency versions, source/workload hashes, per-case outcomes, raw benchmark repetitions, operation latency samples, allocations and checksums. A summary is generated even when the driver has known failures. Initial capture exits nonzero on correctness failures; that does not invalidate its role as an honest baseline.

## Keep the live report current on main

For every change to driver code, tests, benchmarks or build inputs:

1. Commit the code being tested locally, so the run identifies its actual revision.
2. Run `python3 validation/check.py` with the complete suite and at least seven benchmark repetitions. It rebuilds, compares against the original baseline by default and refreshes `validation/RESULTS.md`, `validation/results/overview.svg` and `validation/results/current.json`, including when tests fail.
3. Run `python3 validation/publish_results.py --check`, then commit all three results files and push the code and results to `main` together.

The live report includes the tested commit, input hashes, environment, individual findings, raw samples and median performance changes. A subsequent results-only commit publishes it; that commit does not pretend that another run occurred. CI verifies the recorded inputs against the current files and flags a stale report. Documentation-only changes do not invalidate executable inputs.

A server/preflight/build/recorder failure updates the latest-attempt status. Any retained last-completed results are explicitly labeled as older, and the freshness check fails. Runs with filters, skipped suites/benchmarks or fewer than seven repetitions remain development runs and cannot replace the live full-suite report. Raw per-process logs stay in the ignored run directory; the committed JSON retains all completed measurements.

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

### Stage 1 review runs and supplementary evidence

For the explicitly requested uncommitted review, use `python3 validation/check.py --working-tree`, followed by `python3 validation/publish_results.py --check --working-tree`. The report records the parent commit and hashes every actual build/test input. Normal CI and publication checks still reject dirty inputs. No command commits or pushes changes.

The frozen workloads, shared helpers, Connector/C source and recorder remain unchanged. `Validation.Stage1` adds deterministic transport fixtures, real loopback-proxy faults and live MariaDB cases. `stage1_gates.py` checks the 23 targeted original failures, preserves every original/last-accepted pass, rejects hidden failures, requires comparable complete evidence and flags timing/allocation increases above 5%. It does not turn a known deferred failure into a successful feature test. The accepted reference manifest is advanced only after human review, never by a failed attempt or an unreviewed working tree.

`python3 validation/supplementary.py --output PATH` builds first and records separate setup/parameter/transaction/batch measurements plus retention experiments. Its before-change reference covers only the original six supplementary profiles. New retention experiments have no invented before measurement: they sample current live heap after major GC at row checkpoints across 10,000 and 1,000,000 rows and hold a one-byte slice after a 16 MiB result. GC checkpoints occur inside those memory experiments; their timing is not comparable with frozen throughput workloads. Existing `max_live_bytes` remains explicitly labeled as a process high-water metric.

`python3 validation/profile_workloads.py --profiles PROFILE ... --output PATH` runs selected **unchanged** frozen workloads as separate development experiments. It requires a successful fresh build and stable input hashes; failures stop measurement. It never replaces the complete live report. All optimization experiments, including unsuccessful ones and the explicitly invalid stale-binary experiment, are retained for review. See [implementation evidence](../docs/STAGE1_IMPLEMENTATION_NOTES.md) for the final confirmation window and performance investigations.

[COVERAGE.md](COVERAGE.md) maps the cases, workloads and environment requirements. The suite covers the driver's relevant protocol, connection, value, SQL, transaction, streaming, error and replication surfaces. It is not a certification of every MariaDB storage engine, query optimizer plan, Galera topology or backup tool.

Capability inventory entries explicitly report `UNSUPPORTED` where the current driver has no API to exercise, including native bulk and metadata caching. These entries must become real tests and benchmarks when those APIs are added. They are not successful feature tests. Environment gaps remain separate from missing driver APIs.

The C control links the **installed MariaDB Connector/C** and consumes the same text-protocol SQL, ASCII fields, integer values and checksums. Binary prepared, vector, TLS, socket, concurrency and decoder microbenchmarks are currently Haskell-only and must not be presented as C comparisons. The write workload includes table truncation, a transaction, all inserts, commit and count/sum verification on both clients. Its operation latency is the whole transaction, not one insert.

Benchmark ns/unit uses rows for SELECT/INSERT, bytes for the 1 MiB BLOB workload and decoded rows for microbenchmarks. p50/p95/p99 operation latency uses complete queries, transactions or decoder batches. Large scans have few operation samples, so their tail percentiles are descriptive. RTS allocations/GC/live heap are Haskell metrics; unavailable C metrics are null. Connection and statement creation happen outside timing, including for concurrent readers. `-O2`, `+RTS -N4 -T`, warm-ups, repetition counts and durability settings are recorded.

## Stage 2 data installation and Linux profile

After a successful build, `check.py` uses the built library's Cabal Setup configuration to copy declared runtime data into its installation prefix. This tests the installed CA snapshot independently of the working directory and avoids stale package data. A copy failure or interruption is a visible failed attempt; no older binary/data combination is measured.

Linux integration is defined in `.github/workflows/mariadb-linux.yml` and `validation/linux/Dockerfile`. The pinned official MariaDB image and the current signed-index Cabal client provide disposable server, authentication, TLS and certificate fixtures. The source checkout must include Git history because the unchanged recorder verifies the original source revision. Run from the repository root:

```sh
docker build -f validation/linux/Dockerfile -t mariadb-haskell-linux .
docker run --name mariadb-haskell-linux --tmpfs /var/lib/mysql:size=2147483648 mariadb-haskell-linux
docker cp mariadb-haskell-linux:/workspace/validation/results/runs/stage2-linux ./validation/results/runs/
docker rm -v mariadb-haskell-linux
```

Use a new container name/output location for each retained run. Linux correctness requires every published Stage 1 pass, every Stage 2 native target and every additive Stage 2 case. Its results stay separate from the Mac live benchmark profile. The container uses its own database and private test CA; it does not install trust roots or change the host MariaDB service. Ensure sufficient Docker disk/build space; the local Stage 2 run used separate task-local build storage after encountering the existing Docker disk limit.

## Stage 3 statements and native feature benchmarks

Every complete `check.py` run now also runs eight native-feature profiles with
seven or more process repetitions. These compare native aggregate/unit bulk,
sequential prepared inserts, text batching and cached/uncached narrow/wide
prepared queries. Work, transaction boundaries and content verification match
within each comparison. Connection/statement setup is outside timing. Each
process performs two warm-ups. Wall time excludes the final GC; allocation,
CPU and GC counters include that collection consistently across alternatives.

The native recorder stores all samples and process logs under the complete run's
`native/` directory. Validated native evidence is embedded in the live JSON and
rendered in the main results document. Missing, partial, stale or inconsistent
native measurements block publication. A native failure updates the failed
attempt and retains the raw frozen-suite candidate, rather than presenting old
native measurements as current. Filtered development runs skip these timings.

The first native-feature capture is preserved separately under
`baselines/macos-arm64-native-statements/`; it does not replace the original
unchanged-driver baseline. Subsequent runs verify its checksum and compare only
matching native workloads, server, machine, compiler and dependencies. Native
timing increases above 20% fail the wrapper; increases above 5% in timing or
allocation remain explicit investigation signals. The accepted performance
reference is not advanced automatically.

For a separate native experiment, use a new output directory:

```sh
python3 validation/stage3_benchmarks.py --output validation/results/runs/NEW_NATIVE_RUN
```

The frozen native benchmark inventory slots remain historical placeholders;
they are not a statement that the new APIs are unsupported. The three correctness
inventory entries for bulk/cache/extended metadata now run actual feature tests.
See the [Stage 3 implementation and migration notes](../docs/STAGE3_IMPLEMENTATION.md)
and [continuation roadmap](../docs/ROADMAP.md). Linux CI also smoke-tests all eight
native benchmark paths without comparing their timings with Mac baselines.

The native baseline's `results.json`, `SUMMARY.md` and `SHA256SUMS` are required
and fingerprinted build/test inputs. Missing or changed artifacts fail validation.
Publication rereads the checksummed baseline and recalculates comparability,
deltas and alarms, so an incomplete or edited comparison cannot suppress a
regression. Matching uses the Haskell workload/fixture hashes, verified profile
units, compiler, dependencies, RTS, machine and server settings. Python admission
policy changes do not invalidate identical measured workloads. Dependency pairs
are normalized across JSON serialization.

## Stage 4 session reset, observations and reuse measurements

`getSessionState` exposes bounded observed schema/variables, transaction status
and the latest actual tracker envelope. `resetConnection` and
`resetConnectionWith` reset synchronized sessions, restore required state and
invalidate previous statements. See [API contracts and migration](../docs/STAGE4_IMPLEMENTATION.md).
The two former session-tracking/reset inventory entries now invoke real checks.
The previous-stage correctness reference protects all 462 published Stage 3 passes;
the original, accepted and first-native performance references remain unchanged.

Every full wrapper run also executes seven reuse profiles: reset versus reconnect
for TCP, TLS and Unix sockets, plus public snapshot reads. Reset/restoration and
statement preparation are inside timing, as are new connection setup and close
for reconnects. Both alternatives initialize and verify the same settings and
request result, then leave identical per-request state. Each process performs two
warmups; all seven repetitions, counters and checksums are retained under `reuse/`
and embedded in the live report. Snapshot measurements use a strict loop without
an allocated result list and represent hot repeated reads, not server round trips.

The first reuse capture is separately immutable under
`baselines/macos-arm64-session-reuse/`. Its results, summary and checksum manifest
are required fingerprinted inputs. The shared `feature_benchmarks.py` recorder
retains the existing native recorder's evidence checks and applies the same
checksum, workload, compiler, dependency, machine and server comparison rules to
reuse. Publication independently verifies both additive suites, including source
file maps and tested commits, rather than trusting recorded comparison flags.
A missing/failed/interrupted reuse phase publishes a failed attempt and preserves
the raw candidate; it cannot present older measurements as current.

Run a separate complete reuse experiment without replacing the live report:

```sh
python3 validation/stage4_benchmarks.py --output validation/results/runs/NEW_REUSE_RUN
```

The one-time `--freeze` option refuses an existing baseline directory. It is not
a way to advance a reference after a regression. The first capture precedes its
own checksummed artifact creation; later full runs fingerprint those artifacts.
Timing increases above 20% fail the wrapper, while timing/allocation increases
above 5% remain open investigations. Linux runs all new correctness cases and
smoke-tests these seven paths without comparing timings across platforms.

Stage 4 review fixtures include three dedicated role accounts and four roles,
created by `provision.py` on both Mac and Linux. One account has no default role;
the other reaches the reserved database through its configured default role only.
They test restoration order and quoted Unicode role names without altering the
ordinary benchmark user's role settings. Run provisioning before the new role
checks when updating an existing validation installation.

## Stage 5 CDC

[CDC API, migration, bounds and evidence](../docs/STAGE5_IMPLEMENTATION.md)
cover transaction-aware streaming, MariaDB GTID resume and manual semisync ACKs.
The two original CDC API inventory entries now execute real checks. A disposable
socket-only MariaDB fixture uses the installed binaries to test ACK waiting,
rotation, CRC32/NONE transitions, sparse images, schema change and actual restart.
It leaves the managed server's data/configuration unchanged and cleans up its
owned child processes and datadir.

Full runs require eight additional CDC profiles (47 profiles total), seven
process repetitions and two warmups per process. The separate first CDC capture
under `baselines/macos-arm64-cdc` is immutable; it does not replace an earlier
reference. Streaming retained heap checkpoints are mandatory, including warmups.
Use `python3 validation/stage5_benchmarks.py --output NEW_DIRECTORY` for a separate
complete CDC measurement. The full wrapper and publication guard independently
require current CDC evidence and verify all baseline deltas and heap checkpoints.
