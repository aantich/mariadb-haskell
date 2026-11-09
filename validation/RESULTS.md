# Live MariaDB validation results

Current measured source, compared with the original unchanged-driver baseline. Uncommitted review builds are identified by input fingerprints below.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

## Implementation acceptance

Stage 1 targeted failures now passing: **23 / 23**. Original-baseline and last-accepted correctness protection: **PASS**.

Timing investigations above 5%: **51**; allocation investigations above 5%: **0**. These are investigation signals, not automatically accepted costs.

The frozen baseline retains its original meaning in all comparison tables. The last-accepted reference separately prevents an improvement being lost. [Acceptance evidence](results/stage1-gates.json) · [Confirmation history](results/stage1-confirmation.json) · [Supplementary evidence](results/references/stage1-after-final.json) · [Review notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

Confirmation and supplementary files identify their own input fingerprints. Evidence with a different fingerprint is historical and does not confirm the current source.

Stage 4 session/reset targets passing: **2 / 2**. [Session reuse and observations](../docs/STAGE4_IMPLEMENTATION.md).

Stage 3 prepared/native targets passing: **5 / 5**. [Roadmap and continuation](../docs/ROADMAP.md) · [Stage 3 implementation and validation](../docs/STAGE3_IMPLEMENTATION.md).

Stage 2 native-connection targets passing: **14 / 14**. Every PASS from the previous published stage is separately protected. [Stage 2 implementation and validation](../docs/STAGE2_IMPLEMENTATION.md).

> [!WARNING]
> **Performance acceptance remains open.** Timing/allocation signals require investigation across the entire confirmation window; they have not been waived or accepted automatically.

> [!NOTE]
> **Approved test-contract correction:** `reliability.timeout-before-metadata` now asserts safe retirement, rejection of further commands and a healthy fresh connection after cancellation. Its former reuse expectation contradicted the passing retirement test. The original baseline and failure history remain unchanged. This passing assertion is excluded from the driver-improvement list below. [Contract and evidence](../docs/STAGE7_IMPLEMENTATION.md).

**Baseline comparison: 🟠 Attention required** · 1 regression signal · 68 newly passing checks.

A passing comparison does not mean all functionality passes.

<details open>
<summary>🟠 Comparison signals — investigation required</summary>

- haskell/latency.prepared: median slowed by more than 20%; confirm on an idle machine

</details>

<details>
<summary>🟢 Newly passing checks</summary>

- `protocol.continuation-sequence-rejected`
- `protocol.large-row-is-not-eof`
- `protocol.unsigned-last-insert-id`
- `protocol.column-definition-roundtrip`
- `protocol.binary-plugin-challenge`
- `protocol.unknown-plugin-rejected`
- `protocol.native-extension-handshake`
- `protocol.prepared-out-capability`
- `protocol.empty-packet-predicate`
- `protocol.text-field-trailing-data`
- `protocol.text-field-integer-overflow`
- `protocol.reset-does-not-consume-pending-row`
- `connection.default-full-unicode`
- `auth.ed25519.tcp`
- `auth.ed25519.tls`
- `auth.ed25519.socket`
- `auth.parsec.tcp`
- `auth.parsec.tls`
- `auth.parsec.socket`
- `auth.sha2.tcp`
- `auth.sha2.socket`
- `sql.procedure-prepared-out`
- `sql.zero-date-preservation`
- `sql.unsigned-generated-id`
- `parameters.literal-question-mark`
- `parameters.comment-question-mark`
- `parameters.no-backslash-text`
- `packets.live-blob-16777216`
- `packets.live-blob-16777217`
- `packets.live-blob-33554430`
- `transaction.partial-result-exception`
- `transaction.nested-preserves-outer`
- `reliability.reset-unread-result`
- `reliability.server-kill-query`
- `reliability.tls-cancellation-propagates`
- `connection.localhost-address-fallback`
- `types.non-utf8-results`
- `capability.binary-bulk`
- `capability.metadata-cache`
- `capability.extended-metadata`
- `capability.session-tracking`
- `capability.reset-connection`
- `capability.progress-reporting`
- `capability.cursor-fetch`
- `capability.long-data`
- `capability.compression`
- `auth.mutual-tls-helper-client`
- `connection.mozilla-ca-store-installed`
- `auth.pam-environment`
- `auth.gssapi-environment`
- `cdc.multiple-table-maps`
- `cdc.repeated-row-events`
- `cdc.table-id-mismatch`
- `cdc.crc32-corruption-rejected`
- `cdc.gtid-resume`
- `cdc.durable-ack-control`
- `cdc.native-event-160`
- `cdc.native-event-161`
- `cdc.native-event-162`
- `cdc.native-event-163`
- `cdc.native-event-164`
- `cdc.native-event-165`
- `cdc.native-event-166`
- `cdc.native-event-167`
- `cdc.native-event-168`
- `cdc.native-event-169`
- `cdc.native-event-170`
- `cdc.native-event-171`

</details>

| Reference | Commit |
| --- | --- |
| **Baseline** · original unchanged-driver run | `5deb205d5835` |
| **Current** · latest completed run | `6bbcf13fa3b6` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **844** | 🟢 +598 |
| 🔴 FAIL | 56 | **0** | 🟢 -56 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **0** | -11 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **0** | -2 |

## Benchmarks

**Lower time is faster.** Both timing columns show median **ns/unit**; p95 describes complete operations in the Current run. [Coverage](COVERAGE.md) defines each workload's unit.

**Change = 100 × (Current − Baseline) / Baseline**, using unrounded medians. 🟢 Negative = faster · 🟡 Positive = slower · 🔴 More than 20% slower = investigate. ⚪ Zero at displayed precision = unchanged.

> [!NOTE]
> A benchmark marked PASS completed its workload. Its timing can still trigger a slowdown alert.

> [!NOTE]
> Native bulk execution and metadata caching are implemented. The two original native benchmark inventory slots remain frozen historical placeholders; current feature measurements and same-build comparisons are recorded in the [Stage 3 evidence](../docs/STAGE3_IMPLEMENTATION.md).

Environment, compiler, dependencies and benchmark workloads match the original baseline.

### Native MariaDB features

Same-build alternatives below use identical data, transactions and checksums. These new feature comparisons are separate from the original frozen baseline. Lower time/allocation is better; changes are `(current / baseline - 1) × 100`.

| Comparison | Baseline ns/unit | Current ns/unit | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `native_vs_sequential` | 41,574.2 | 1,966.4 | -95.3% | -91.1% |
| `native_vs_text_batch` | 11,001.4 | 1,966.4 | -82.1% | -77.9% |
| `unit_vs_aggregate` | 1,966.4 | 2,185.6 | +11.1% | +49.1% |
| `cached_vs_uncached_narrow` | 39,226.0 | 37,980.0 | -3.2% | -15.9% |
| `cached_vs_uncached_wide` | 76,824.0 | 56,378.0 | -26.6% | -73.5% |

Native timing units are rows for bulk inserts and complete queries for cached/uncached reads. Seven or more independent processes per profile each perform two warm-ups; all samples, CPU/GC counters and checksums are embedded in [current.json](results/current.json).

Native feature baseline comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [Immutable native baseline](baselines/macos-arm64-native-statements/results.json).

### Session reuse

Baseline = reconnect, initialize, prepare, execute and close. Current = reset, restore, prepare and execute the same request on one connection. All application settings and absence of prior-request data are verified; preparation and restoration are inside timing. Changes are `(current / baseline - 1) × 100`; lower is better.

| Transport | Baseline ns/request | Current ns/request | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `tcp` | 510,800.0 | 367,900.0 | -28.0% | -16.8% |
| `tls` | 38,469,366.7 | 464,833.3 | -98.8% | -77.1% |
| `socket` | 357,466.7 | 275,566.7 | -22.9% | -14.8% |

Public snapshot read: **3.5 ns/call**, **0.0 allocated bytes/call**, no SQL. Seven or more independent processes per profile, with two warmups; raw samples and checksums are embedded in [current.json](results/current.json).

Immutable reuse baseline comparison: **comparable**; timing investigations above 5%: **4**; allocation investigations: **0**. [First reuse baseline](baselines/macos-arm64-session-reuse/results.json).

### MariaDB CDC

[CDC contracts and limits](../docs/STAGE5_IMPLEMENTATION.md) describe transaction checkpoints and explicit acknowledgements. XA-aware checkpointing and storage-engine-binlog GTID semisync remain outside this implementation.

Separate immutable first CDC capture; no equivalent CDC throughput measurement exists in the unchanged-driver baseline. Units are rows, except framing/CRC uses events. Live profiles include source connection/setup and checkpoint observation; source log creation is outside timing. Retention timing includes four forced major collections and is a memory workload.

| Workload | Baseline ns/unit | Current ns/unit | Change vs baseline | Current allocated B/unit |
| --- | ---: | ---: | ---: | ---: |
| `cdc.decode.single-table` | 454.9 | 465.7 | +2.4% | 3,720.5 |
| `cdc.decode.interleaved` | 537.8 | 513.2 | -4.6% | 3,744.3 |
| `cdc.decode.sparse-update` | 805.0 | 806.6 | +0.2% | 4,465.9 |
| `cdc.decode.compressed` | 1,897.0 | 1,953.5 | +3.0% | 43,745.6 |
| `cdc.framing.crc32` | 1,242.5 | 1,148.0 | -7.6% | 17,823.8 |
| `cdc.live.rows` | 4,192.0 | 4,251.0 | +1.4% | 19,094.4 |
| `cdc.live.checkpoints` | 13,890.0 | 13,670.0 | -1.6% | 32,594.9 |
| `cdc.retention` | 640.0 | 641.0 | +0.2% | 8,688.0 |

Streaming retained heap at 1,000,000 rows: **86,240–86,240 bytes** after major GC across the measured processes. All warmup/measured checkpoints are retained in [current.json](results/current.json). This is live heap, not a process high-water mark.

CDC comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [First CDC capture](baselines/macos-arm64-cdc/results.json).

### Streamed parameters and optional wire features

Same-build alternatives use identical values and checksums. Lower time/allocation is better; change is `(current / baseline - 1) × 100`. Upload units are bytes, cursor/transport units are rows, and progress units are complete SELECT queries. Preparation/connection setup are excluded. Progress measures the negotiated idle-callback path; real progress delivery is tested separately.

| Comparison | Baseline ns/unit | Current ns/unit | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `streamed upload` | 5.16 | 5.19 | +0.5% | +97.0% |
| `cursor batch 32` | 372.80 | 2,023.10 | +442.7% | +49.4% |
| `cursor batch 512` | 372.80 | 858.70 | +130.3% | +4.6% |
| `cursor batch 4096` | 372.80 | 774.10 | +107.6% | +1.2% |
| `narrow compression` | 341.50 | 747.50 | +118.9% | +4.9% |
| `wide compression` | 4,744.00 | 10,539.00 | +122.2% | +42.9% |
| `progress negotiation` | 41,960.00 | 42,392.00 | +1.0% | +0.8% |

Server cursors materialize results and add fetch round trips. Compression is optional and trades CPU/allocations for fewer network bytes; local timing is not a WAN result. These features need not outperform ordinary streaming on this Mac.

[First wire-feature capture](baselines/macos-arm64-wire-features/results.json): **comparable**; timing investigations above 5%: **6**; allocation investigations: **0**. All seven-repetition samples are retained in [current.json](results/current.json).

### External authentication setup

Complete connect/authenticate/session-initialize/query/close costs; units are verified connections. PAM uses TLS and GSSAPI uses a pre-acquired Kerberos service ticket over TCP. KDC ticket acquisition is excluded. The fixture image identity must match before timing deltas are compared.

| Profile | Baseline ns/connection | Current ns/connection | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `auth.pam.password` | 45,259,300.00 | 44,998,800.00 | -0.6% | +0.1% |
| `auth.pam.multiple` | 45,725,900.00 | 44,843,500.00 | -1.9% | +0.1% |
| `auth.gssapi.cached-ticket` | 3,941,800.00 | 4,279,400.00 | +8.6% | +1.1% |

[First authentication capture](baselines/macos-arm64-external-authentication/results.json): timing investigations **1**; allocation investigations **0**. These authentication alternatives have different security/transport work and are not compared against one another.

### Haskell driver

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.prepared` | 3.1 | **3.3** | 🟡 +4.4% slower | 4.300 | 🟢 PASS |
| `blob.text` | 3.2 | **3.3** | 🟡 +2.6% slower | 4.241 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **51584.0** | 🔴 +23.3% slower | 0.088 | 🟢 PASS |
| `latency.text` | 39354.0 | **44460.0** | 🟡 +13.0% slower | 0.079 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **255.4** | 🟡 +3.8% slower | 26.289 | 🟢 PASS |
| `micro.text-row` | 313.2 | **308.9** | 🟢 -1.4% faster | 31.596 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **107.7** | 🟡 +0.1% slower | 19.250 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **134.2** | 🟡 +13.8% slower | 7.445 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **351.4** | 🟡 +11.7% slower | 5.067 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2583.9** | 🟡 +6.6% slower | 27.358 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **386.3** | 🟡 +13.9% slower | 4.758 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **349.9** | 🟡 +14.5% slower | 3.802 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2913.1** | 🟡 +1.3% slower | 31.608 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **409.7** | 🟡 +10.6% slower | 5.826 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **371.0** | 🟡 +1.4% slower | 4.171 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **9367.0** | 🟢 -3.1% faster | 9.709 | 🟢 PASS |
| `write.prepared` | 39408.0 | **40821.0** | 🟡 +3.6% slower | 41.394 | 🟢 PASS |
| `write.text` | 38324.0 | **43576.0** | 🟡 +13.7% slower | 47.089 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.2** | 🟡 +5.6% slower | 4.632 | 🟢 PASS |
| `latency.text` | 26568.0 | **28256.0** | 🟡 +6.4% slower | 0.059 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **213.2** | 🟡 +8.0% slower | 2.343 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1346.0** | 🟡 +6.7% slower | 15.163 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **8581.0** | 🟡 +12.4% slower | 9.124 | 🟢 PASS |
| `write.text` | 28478.0 | **31197.0** | 🟡 +9.5% slower | 31.680 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 1 |
| Parent commit (working-tree inputs are identified separately) | [`6bbcf13fa3b66d96f26c8c4b36f5d69d5f69c25f`](https://github.com/aantich/mariadb-haskell/commit/6bbcf13fa3b66d96f26c8c4b36f5d69d5f69c25f) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-09T15:39:49.706665+00:00 / 2026-11-09T15:43:16.106989+00:00 |
| Input fingerprint | `23135d7aba3c73c1b39691f9b6ae3ea21104c45838d753a47ce9fa6a73892153` |
| Local logs and build plan | `validation/results/runs/release-0.1.0.0-final-ci` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |
| Frozen recorder source | `e756bc0f593b54bc9207fd88d2a53120a4654832650d0a148555a69ebd413346` |
| Package metadata adapter | `082bee446a000e93bd0e55904134f49ce6f5fc1f4328f40d8e94443bbd99a9e7` |
| Adapted recorder body | `6a7d130df9ad7421f83940b3b6f6daf8e3de9ac6a3e7a3f91d357766e062b16f` |

The independent package uses a separately fingerprinted metadata adapter. It substitutes only the manifest filename and self-package exclusion in the digest-pinned original recorder; entry-point dispatch is handled by the adapter. Frozen workload bodies, sampling and comparison policy remain unchanged. The original file hash is not presented as the adapter's hash.


Committed runs identify their tested revision. An uncommitted review run identifies its parent revision plus SHA-256 hashes of the actual working-tree inputs; it does not claim the parent commit contains these changes. A following results-only commit does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
