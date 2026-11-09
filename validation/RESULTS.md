# Live MariaDB validation results

Current measured source, compared with the original unchanged-driver baseline. Uncommitted review builds are identified by input fingerprints below.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

## Implementation acceptance

Stage 1 targeted failures now passing: **23 / 23**. Original-baseline and last-accepted correctness protection: **PASS**.

Timing investigations above 5%: **18**; allocation investigations above 5%: **0**. These are investigation signals, not automatically accepted costs.

The frozen baseline retains its original meaning in all comparison tables. The last-accepted reference separately prevents an improvement being lost. [Acceptance evidence](results/stage1-gates.json) · [Confirmation history](results/stage1-confirmation.json) · [Supplementary evidence](results/references/stage1-after-final.json) · [Review notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

Confirmation and supplementary files identify their own input fingerprints. Evidence with a different fingerprint is historical and does not confirm the current source.

Stage 4 session/reset targets passing: **2 / 2**. [Session reuse and observations](../docs/STAGE4_IMPLEMENTATION.md).

Stage 3 prepared/native targets passing: **5 / 5**. [Roadmap and continuation](../docs/ROADMAP.md) · [Stage 3 implementation and validation](../docs/STAGE3_IMPLEMENTATION.md).

Stage 2 native-connection targets passing: **14 / 14**. Every PASS from the previous published stage is separately protected. [Stage 2 implementation and validation](../docs/STAGE2_IMPLEMENTATION.md).

> [!WARNING]
> **Performance acceptance remains open.** Timing/allocation signals require investigation across the entire confirmation window; they have not been waived or accepted automatically.

> [!CAUTION]
> **1 failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.

**Baseline comparison: 🟠 Attention required** · 1 regression signal · 66 newly passing checks.

A passing comparison does not mean all functionality passes.

<details open>
<summary>🟠 Comparison signals — investigation required</summary>

- haskell/read.parallel-4: median slowed by more than 20%; confirm on an idle machine

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
| **Current** · latest completed run | `9c4bac0cbeab` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **793** | 🟢 +547 |
| 🔴 FAIL | 56 | **1** | 🟢 -55 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **0** | -11 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **2** | 0 |

<details>
<summary>🔴 Failed or timed-out checks (1) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `reliability.timeout-before-metadata` | 🔴 FAIL | ConnectionUnavailable Broken |

</details>

<details>
<summary>🟡 Unavailable environment fixtures (2) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `auth.pam-environment` | 🟡 ENVIRONMENT_UNAVAILABLE | PAM helper from the Homebrew bottle could not acquire root ownership; no OS PAM login fixture is configured |
| `auth.gssapi-environment` | 🟡 ENVIRONMENT_UNAVAILABLE | no Kerberos realm, keytab or GSSAPI login fixture configured on this Mac |

</details>

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
| `native_vs_sequential` | 40,348.4 | 1,859.8 | -95.4% | -91.1% |
| `native_vs_text_batch` | 11,089.2 | 1,859.8 | -83.2% | -78.2% |
| `unit_vs_aggregate` | 1,859.8 | 2,039.8 | +9.7% | +49.1% |
| `cached_vs_uncached_narrow` | 38,184.0 | 37,546.0 | -1.7% | -15.8% |
| `cached_vs_uncached_wide` | 73,248.0 | 55,182.0 | -24.7% | -73.5% |

Native timing units are rows for bulk inserts and complete queries for cached/uncached reads. Seven or more independent processes per profile each perform two warm-ups; all samples, CPU/GC counters and checksums are embedded in [current.json](results/current.json).

Native feature baseline comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [Immutable native baseline](baselines/macos-arm64-native-statements/results.json).

### Session reuse

Baseline = reconnect, initialize, prepare, execute and close. Current = reset, restore, prepare and execute the same request on one connection. All application settings and absence of prior-request data are verified; preparation and restoration are inside timing. Changes are `(current / baseline - 1) × 100`; lower is better.

| Transport | Baseline ns/request | Current ns/request | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `tcp` | 464,733.3 | 369,800.0 | -20.4% | -16.6% |
| `tls` | 38,831,933.3 | 446,800.0 | -98.8% | -77.1% |
| `socket` | 362,300.0 | 269,633.3 | -25.6% | -13.8% |

Public snapshot read: **3.5 ns/call**, **0.0 allocated bytes/call**, no SQL. Seven or more independent processes per profile, with two warmups; raw samples and checksums are embedded in [current.json](results/current.json).

Immutable reuse baseline comparison: **comparable**; timing investigations above 5%: **2**; allocation investigations: **0**. [First reuse baseline](baselines/macos-arm64-session-reuse/results.json).

### MariaDB CDC

[CDC contracts and limits](../docs/STAGE5_IMPLEMENTATION.md) describe transaction checkpoints and explicit acknowledgements. XA-aware checkpointing and storage-engine-binlog GTID semisync remain outside this implementation.

Separate immutable first CDC capture; no equivalent CDC throughput measurement exists in the unchanged-driver baseline. Units are rows, except framing/CRC uses events. Live profiles include source connection/setup and checkpoint observation; source log creation is outside timing. Retention timing includes four forced major collections and is a memory workload.

| Workload | Baseline ns/unit | Current ns/unit | Change vs baseline | Current allocated B/unit |
| --- | ---: | ---: | ---: | ---: |
| `cdc.decode.single-table` | 454.9 | 468.0 | +2.9% | 3,720.5 |
| `cdc.decode.interleaved` | 537.8 | 513.9 | -4.4% | 3,744.3 |
| `cdc.decode.sparse-update` | 805.0 | 799.0 | -0.7% | 4,465.9 |
| `cdc.decode.compressed` | 1,897.0 | 1,912.0 | +0.8% | 43,745.6 |
| `cdc.framing.crc32` | 1,242.5 | 1,141.8 | -8.1% | 17,823.8 |
| `cdc.live.rows` | 4,192.0 | 4,067.0 | -3.0% | 19,093.9 |
| `cdc.live.checkpoints` | 13,890.0 | 12,190.0 | -12.2% | 32,623.1 |
| `cdc.retention` | 640.0 | 646.2 | +1.0% | 8,688.0 |

Streaming retained heap at 1,000,000 rows: **83,992–86,240 bytes** after major GC across the measured processes. All warmup/measured checkpoints are retained in [current.json](results/current.json). This is live heap, not a process high-water mark.

CDC comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [First CDC capture](baselines/macos-arm64-cdc/results.json).

### Streamed parameters and optional wire features

Same-build alternatives use identical values and checksums. Lower time/allocation is better; change is `(current / baseline - 1) × 100`. Upload units are bytes, cursor/transport units are rows, and progress units are complete SELECT queries. Preparation/connection setup are excluded. Progress measures the negotiated idle-callback path; real progress delivery is tested separately.

| Comparison | Baseline ns/unit | Current ns/unit | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `streamed upload` | 4.98 | 5.03 | +1.1% | +97.0% |
| `cursor batch 32` | 364.60 | 1,961.30 | +437.9% | +49.0% |
| `cursor batch 512` | 364.60 | 855.50 | +134.6% | +4.4% |
| `cursor batch 4096` | 364.60 | 752.30 | +106.3% | +0.9% |
| `narrow compression` | 337.50 | 698.00 | +106.8% | +5.0% |
| `wide compression` | 4,519.50 | 10,222.50 | +126.2% | +42.7% |
| `progress negotiation` | 40,706.00 | 39,838.00 | -2.1% | +0.8% |

Server cursors materialize results and add fetch round trips. Compression is optional and trades CPU/allocations for fewer network bytes; local timing is not a WAN result. These features need not outperform ordinary streaming on this Mac.

[First wire-feature capture](baselines/macos-arm64-wire-features/results.json): **comparable**; timing investigations above 5%: **1**; allocation investigations: **0**. All seven-repetition samples are retained in [current.json](results/current.json).

### Haskell driver

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.prepared` | 3.1 | **3.1** | 🟢 -0.3% faster | 3.530 | 🟢 PASS |
| `blob.text` | 3.2 | **3.2** | 🟡 +0.8% slower | 5.176 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **38388.0** | 🟢 -8.2% faster | 0.087 | 🟢 PASS |
| `latency.text` | 39354.0 | **42738.0** | 🟡 +8.6% slower | 0.080 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **242.6** | 🟢 -1.5% faster | 24.733 | 🟢 PASS |
| `micro.text-row` | 313.2 | **290.3** | 🟢 -7.3% faster | 30.167 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **110.5** | 🟡 +2.7% slower | 20.359 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **147.2** | 🔴 +24.8% slower | 6.948 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **304.4** | 🟢 -3.2% faster | 5.528 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2397.8** | 🟢 -1.1% faster | 25.133 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **352.7** | 🟡 +4.0% slower | 3.815 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **328.4** | 🟡 +7.5% slower | 3.745 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2853.5** | 🟢 -0.8% faster | 29.705 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **391.8** | 🟡 +5.7% slower | 5.895 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **361.7** | 🟢 -1.1% faster | 5.133 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **8709.0** | 🟢 -9.9% faster | 9.436 | 🟢 PASS |
| `write.prepared` | 39408.0 | **38813.0** | 🟢 -1.5% faster | 40.544 | 🟢 PASS |
| `write.text` | 38324.0 | **42507.0** | 🟡 +10.9% slower | 44.847 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.1** | 🟡 +1.2% slower | 3.891 | 🟢 PASS |
| `latency.text` | 26568.0 | **24572.0** | 🟢 -7.5% faster | 0.068 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **210.8** | 🟡 +6.8% slower | 2.246 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1174.5** | 🟢 -6.9% faster | 15.304 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **7603.0** | 🟢 -0.4% faster | 10.436 | 🟢 PASS |
| `write.text` | 28478.0 | **30669.0** | 🟡 +7.7% slower | 30.947 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 1 |
| Parent commit (working-tree inputs are identified separately) | [`9c4bac0cbeabc269d41ec307aa53e4f2da50f345`](https://github.com/aantich/mariadb-haskell/commit/9c4bac0cbeabc269d41ec307aa53e4f2da50f345) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-09T10:27:29.254533+00:00 / 2026-11-09T10:30:26.422430+00:00 |
| Input fingerprint | `dbc3c49dc9042610a46bb0c70651e7541a8d3d26fbe6641a0c367c3b192aff0e` |
| Local logs and build plan | `validation/results/runs/stage6-publication-1` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |

Committed runs identify their tested revision. An uncommitted review run identifies its parent revision plus SHA-256 hashes of the actual working-tree inputs; it does not claim the parent commit contains these changes. A following results-only commit does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
