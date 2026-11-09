# Benchmarks: choosing the right API

This is the **9 November 2026** release-input capture from committed source
`c6838df`. [The live report](https://github.com/aantich/mariadb-haskell/blob/main/validation/RESULTS.md)
contains all profiles, failures, allocations, latency percentiles and open
investigations. Values here are not refreshed merely because documentation or
package metadata changes.

## Same-build alternatives

In this table **Baseline** is the named alternative in the *same measured build*,
not upstream mysql-haskell and not a previous release. **Current** is the native
or optional path named in the row. Every elapsed column is a median normalized
by the displayed unit. Change is `(Current / Baseline - 1) × 100`; negative means
less time. Allocation change uses the same comparison and GHC allocation counts.

| Comparison (Current vs Baseline) | Unit | Baseline | Current | Time change vs baseline | Allocation change vs baseline |
| --- | --- | ---: | ---: | ---: | ---: |
| Native bulk vs sequential prepared | ns/row | 40,327.00 | 1,826.20 | -95.47% | -91.12% |
| Native bulk vs text batch | ns/row | 10,557.00 | 1,826.20 | -82.70% | -77.91% |
| Wide prepared metadata cache | ns/execution | 72,896.00 | 54,240.00 | -25.59% | -73.49% |
| TLS reset vs reconnect | ns/request | 38,945,033.33 | 461,166.67 | -98.82% | -77.11% |
| Streamed upload vs buffered | ns/byte | 5.04 | 5.05 | +0.24% | +97.23% |
| Cursor batch 512 vs ordinary stream | ns/row | 356.30 | 860.30 | +141.45% | +4.49% |
| Wide zlib vs plain transport | ns/row | 4,612.00 | 10,271.00 | +122.70% | +42.66% |

Bulk reduces command round trips; wide metadata caching avoids repeated metadata
transfer/decoding. Reuse measures complete equivalent request boundaries,
including reset/restoration or reconnect and statement preparation. The TLS
comparison includes the cost of fresh connection establishment. It is not a
claim that every query becomes 98% faster.

Streaming upload is a retained-memory feature. In this run it allocates about
97% more than buffered upload for the measured 1 MiB payload. The separate
64 MiB fresh-chunk retention workload checks live heap after major GC at four
positions in both warmups and measurement; it is not a throughput comparison
with a buffered source. See raw samples for every checkpoint rather than using
process high-water memory as proof of bounded retention.

Cursors add fetch round trips and server materialization; choose batch size for
resource/control needs. Compression saves wire bytes for compressible data but
adds CPU cost; these local narrow/wide transfers are slower with zlib. There is
no measured WAN speedup claim. Authentication setup profiles include PAM's fresh
TLS/CA construction and GSSAPI's existing service-ticket cache; their timings are
not interchangeable measures of authentication mechanisms.

## Environment and method

* Apple M4 Max, 16 logical CPUs, arm64, macOS 26.4; GHC 9.10.3 with `-O2`,
  `-threaded`, `+RTS -N4 -T`.
* Homebrew MariaDB 12.3.3 on the same machine, UTC, ROW/FULL binlog and CRC32,
  128 MiB InnoDB buffer pool, `innodb_flush_log_at_trx_commit=1`, `sync_binlog=0`.
  These durability settings are part of the profile, not production advice.
* Seven independent processes per profile, two warmups per process, shuffled
  order, value/count/checksum validation. Complete operation latency and
  normalized throughput are different metrics.
* 63 runnable profiles: 24 frozen original/C controls, eight native-statement,
  seven reuse, eight CDC, thirteen wire-feature and three authentication profiles.
  Two frozen historical unsupported placeholders remain as history; actual APIs
  have separate executable measurements.
* The host was **not idle**: Hearthstone and Zoom were active. The isolated
  Linux compiler was paused during Mac measurements. Anton requested that
  validation continue with timing contention explicitly labeled.
  Original-baseline and previous-stage timing investigations remain open,
  including ordinary narrow reads, text writes and setup/helper costs.
  Unchanged C controls also slowed, but contention is not proven to explain
  every difference. These measurements do not establish universal performance
  superiority over upstream or Connector/C.
* Linux correctness uses its own MariaDB 12.3.3/GHC 9.4.7 profile. Its smoke-run
  timings are not compared with Mac benchmarks.

## Evidence and provenance

The retained [capture JSON](https://github.com/aantich/mariadb-haskell/blob/main/validation/results/references/release-0.1.0.0-alpha-live.json)
contains these numbers under `latest_completed_run.attempt`. The tested source
is commit `c6838dfb262aaa938692fa753ff77c1f1d6c85d2` with **209 committed executable
inputs**, fingerprint `76ceed62fb6aafbcf1b62c260692afe744055c01ef5c6141d2d69fad065d7bd8`. All families preserve
seven repetitions and the matching 149-entry dependency plan. Source/workload
inputs remained stable throughout the run.

The package rename uses a separately recorded metadata adapter around the
byte-for-byte frozen original recorder; see
[release provenance](https://github.com/aantich/mariadb-haskell/blob/main/docs/RELEASING.md#preserve-benchmark-history-through-the-rename).
It changes only the manifest filename/self-package exclusion and entry-point
dispatch. Sampling, workload bodies and comparison policy remain frozen.

All 844 correctness records pass. The complete command exits 1 because timing
gates remain open: **16 ordinary/reference, 0 native, 3 reuse, 0 CDC,
2 wire and 0 authentication timing signals**, with no allocation signals.
These are not silently waived or presented as accepted performance. The original
and each feature baseline, failed/interrupted attempts, and the earlier
[Stage 7 review capture](https://github.com/aantich/mariadb-haskell/blob/d5a005c9e2adf753b5f6b2a4d04763d309159130/validation/results/references/stage7-fixes-full-1-live.json)
remain intact. A final full capture was required by the new Alpha manifest/documentation inputs;
the pre-Alpha full capture is retained, not discarded to select better timings.

The live report also compares **Baseline** (immutable original-driver capture),
**Current** (latest complete capture), and **Change vs baseline** for the frozen
workloads. Each later feature family has its own immutable first capture because
its API did not exist in the original driver. Never compare different workloads,
server settings, compiler/dependency plans or hardware as a driver speedup.

## Reproducing and extending

Use a Git checkout with history and provision a real server **first**, following
[validation/README.md](https://github.com/aantich/mariadb-haskell/blob/main/validation/README.md).
The source tarball contains developer harness sources but is not the complete
historical evidence checkout. The full command is `python3 validation/check.py`;
Python policy checks run with
`python3 -m unittest discover -s validation -p 'test_*.py'`.
Do not silently replace frozen workloads or references. New machine/version/WAN
profiles need separate baselines. Final publication checks require committed
executable inputs, a complete run, and `python3 validation/publish_results.py --check`.
