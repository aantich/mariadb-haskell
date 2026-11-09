# Benchmarks: choosing the right API

This is the **9 November 2026** release-input capture from committed source
`6bbcf13`. [The live report](https://github.com/aantich/mariadb-haskell/blob/main/validation/RESULTS.md)
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
| Native bulk vs sequential prepared | ns/row | 41,574.20 | 1,966.40 | -95.27% | -91.12% |
| Native bulk vs text batch | ns/row | 11,001.40 | 1,966.40 | -82.13% | -77.94% |
| Wide prepared metadata cache | ns/execution | 76,824.00 | 56,378.00 | -26.61% | -73.49% |
| TLS reset vs reconnect | ns/request | 38,469,366.67 | 464,833.33 | -98.79% | -77.11% |
| Streamed upload vs buffered | ns/byte | 5.16 | 5.19 | +0.55% | +96.99% |
| Cursor batch 512 vs ordinary stream | ns/row | 372.80 | 858.70 | +130.34% | +4.64% |
| Wide zlib vs plain transport | ns/row | 4,744.00 | 10,539.00 | +122.15% | +42.88% |

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

The retained [capture JSON](https://github.com/aantich/mariadb-haskell/blob/main/validation/results/references/release-0.1.0.0-final-live.json)
contains these numbers under `latest_completed_run.attempt`. The tested source
is commit `6bbcf13fa3b66d96f26c8c4b36f5d69d5f69c25f` with **209 committed executable
inputs**, fingerprint `23135d7aba3c73c1b39691f9b6ae3ea21104c45838d753a47ce9fa6a73892153`. All families preserve
seven repetitions and the matching 149-entry dependency plan. Source/workload
inputs remained stable throughout the run.

The package rename uses a separately recorded metadata adapter around the
byte-for-byte frozen original recorder; see
[release provenance](https://github.com/aantich/mariadb-haskell/blob/main/docs/RELEASING.md#preserve-benchmark-history-through-the-rename).
It changes only the manifest filename/self-package exclusion and entry-point
dispatch. Sampling, workload bodies and comparison policy remain frozen.

All 844 correctness records pass. The complete command exits 1 because timing
gates remain open: **51 ordinary/reference, 0 native, 4 reuse, 0 CDC,
6 wire and 1 authentication timing signals**, with no allocation signals.
These are not silently waived or presented as accepted performance. The original
and each feature baseline, failed/interrupted attempts, and the earlier
[Stage 7 review capture](https://github.com/aantich/mariadb-haskell/blob/d5a005c9e2adf753b5f6b2a4d04763d309159130/validation/results/references/stage7-fixes-full-1-live.json)
remain intact. The final capture follows the committed Alpha metadata, rendered-documentation
corrections and CI linker-profile fix. Every prior full/interrupted capture is
retained; these are source-validation captures, not a selected timing-confirmation window.

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
