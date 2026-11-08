# Live MariaDB validation results

Current measured source, compared with the original unchanged-driver baseline. Uncommitted review builds are identified by input fingerprints below.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

## Implementation acceptance

Stage 1 targeted failures now passing: **23 / 23**. Original-baseline and last-accepted correctness protection: **PASS**.

Timing investigations above 5%: **5**; allocation investigations above 5%: **0**. These are investigation signals, not automatically accepted costs.

The frozen baseline retains its original meaning in all comparison tables. The last-accepted reference separately prevents an improvement being lost. [Acceptance evidence](results/stage1-gates.json) · [Confirmation history](results/stage1-confirmation.json) · [Supplementary evidence](results/references/stage1-after-final.json) · [Review notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

Confirmation and supplementary files identify their own input fingerprints. Evidence with a different fingerprint is historical and does not confirm the current source.

Stage 4 session/reset targets passing: **2 / 2**. [Session reuse and observations](../docs/STAGE4_IMPLEMENTATION.md).

Stage 3 prepared/native targets passing: **5 / 5**. [Roadmap and continuation](../docs/ROADMAP.md) · [Stage 3 implementation and validation](../docs/STAGE3_IMPLEMENTATION.md).

Stage 2 native-connection targets passing: **14 / 14**. Every PASS from the previous published stage is separately protected. [Stage 2 implementation and validation](../docs/STAGE2_IMPLEMENTATION.md).

> [!WARNING]
> **Performance acceptance remains open.** Timing/allocation signals require investigation across the entire confirmation window; they have not been waived or accepted automatically.

> [!CAUTION]
> **1 failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.

**Baseline comparison: 🟢 No new regression signals** · 0 regression signals · 62 newly passing checks.

A passing comparison does not mean all functionality passes.

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
| **Current** · latest completed run | `ba99d8cb5554` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **694** | 🟢 +448 |
| 🔴 FAIL | 56 | **1** | 🟢 -55 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **4** | -7 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **2** | 0 |

<details>
<summary>🔴 Failed or timed-out checks (1) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `reliability.timeout-before-metadata` | 🔴 FAIL | ConnectionUnavailable Broken |

</details>

<details>
<summary>🔵 Missing driver APIs (4) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `capability.progress-reporting` | 🔵 UNSUPPORTED | no negotiated MariaDB progress callback |
| `capability.cursor-fetch` | 🔵 UNSUPPORTED | no COM_STMT_FETCH/cursor API |
| `capability.long-data` | 🔵 UNSUPPORTED | no COM_STMT_SEND_LONG_DATA API |
| `capability.compression` | 🔵 UNSUPPORTED | no compressed packet transport |

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
| `native_vs_sequential` | 39,670.2 | 1,837.8 | -95.4% | -91.1% |
| `native_vs_text_batch` | 9,866.8 | 1,837.8 | -81.4% | -77.7% |
| `unit_vs_aggregate` | 1,837.8 | 2,031.6 | +10.5% | +49.1% |
| `cached_vs_uncached_narrow` | 37,256.0 | 36,126.0 | -3.0% | -15.7% |
| `cached_vs_uncached_wide` | 70,442.0 | 53,070.0 | -24.7% | -73.6% |

Native timing units are rows for bulk inserts and complete queries for cached/uncached reads. Seven or more independent processes per profile each perform two warm-ups; all samples, CPU/GC counters and checksums are embedded in [current.json](results/current.json).

Native feature baseline comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [Immutable native baseline](baselines/macos-arm64-native-statements/results.json).

### Session reuse

Baseline = reconnect, initialize, prepare, execute and close. Current = reset, restore, prepare and execute the same request on one connection. All application settings and absence of prior-request data are verified; preparation and restoration are inside timing. Changes are `(current / baseline - 1) × 100`; lower is better.

| Transport | Baseline ns/request | Current ns/request | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| `tcp` | 479,600.0 | 357,633.3 | -25.4% | -16.6% |
| `tls` | 39,779,133.3 | 438,866.7 | -98.9% | -77.1% |
| `socket` | 335,733.3 | 270,966.7 | -19.3% | -13.7% |

Public snapshot read: **3.5 ns/call**, **0.0 allocated bytes/call**, no SQL. Seven or more independent processes per profile, with two warmups; raw samples and checksums are embedded in [current.json](results/current.json).

Immutable reuse baseline comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [First reuse baseline](baselines/macos-arm64-session-reuse/results.json).

### MariaDB CDC

[CDC contracts and limits](../docs/STAGE5_IMPLEMENTATION.md) describe transaction checkpoints and explicit acknowledgements. XA-aware checkpointing and storage-engine-binlog GTID semisync remain outside this implementation.

Separate immutable first CDC capture; no equivalent CDC throughput measurement exists in the unchanged-driver baseline. Units are rows, except framing/CRC uses events. Live profiles include source connection/setup and checkpoint observation; source log creation is outside timing. Retention timing includes four forced major collections and is a memory workload.

| Workload | Baseline ns/unit | Current ns/unit | Change vs baseline | Current allocated B/unit |
| --- | ---: | ---: | ---: | ---: |
| `cdc.decode.single-table` | 454.9 | 444.1 | -2.4% | 3,720.5 |
| `cdc.decode.interleaved` | 537.8 | 497.2 | -7.5% | 3,744.3 |
| `cdc.decode.sparse-update` | 805.0 | 784.4 | -2.6% | 4,465.9 |
| `cdc.decode.compressed` | 1,897.0 | 1,792.0 | -5.5% | 43,745.6 |
| `cdc.framing.crc32` | 1,242.5 | 1,134.2 | -8.7% | 17,823.8 |
| `cdc.live.rows` | 4,192.0 | 3,898.0 | -7.0% | 19,093.0 |
| `cdc.live.checkpoints` | 13,890.0 | 10,940.0 | -21.2% | 32,578.5 |
| `cdc.retention` | 640.0 | 607.4 | -5.1% | 8,688.0 |

Streaming retained heap at 1,000,000 rows: **83,992–86,240 bytes** after major GC across the measured processes. All warmup/measured checkpoints are retained in [current.json](results/current.json). This is live heap, not a process high-water mark.

CDC comparison: **comparable**; timing investigations above 5%: **0**; allocation investigations: **0**. [First CDC capture](baselines/macos-arm64-cdc/results.json).

### Haskell driver

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.prepared` | 3.1 | **3.2** | 🟡 +0.1% slower | 4.427 | 🟢 PASS |
| `blob.text` | 3.2 | **3.1** | 🟢 -2.4% faster | 4.375 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **37918.0** | 🟢 -9.3% faster | 0.082 | 🟢 PASS |
| `latency.text` | 39354.0 | **41462.0** | 🟡 +5.4% slower | 0.071 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **238.0** | 🟢 -3.3% faster | 24.166 | 🟢 PASS |
| `micro.text-row` | 313.2 | **287.6** | 🟢 -8.2% faster | 29.800 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **101.9** | 🟢 -5.2% faster | 23.185 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **119.2** | 🟡 +1.1% slower | 6.637 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **281.2** | 🟢 -10.6% faster | 3.785 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2304.0** | 🟢 -5.0% faster | 24.179 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **330.8** | 🟢 -2.5% faster | 3.579 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **314.2** | 🟡 +2.9% slower | 3.248 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2664.6** | 🟢 -7.4% faster | 27.854 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **378.5** | 🟡 +2.1% slower | 5.648 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **342.4** | 🟢 -6.4% faster | 3.815 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **8022.0** | 🟢 -17.0% faster | 8.721 | 🟢 PASS |
| `write.prepared` | 39408.0 | **38469.0** | 🟢 -2.4% faster | 38.813 | 🟢 PASS |
| `write.text` | 38324.0 | **41296.0** | 🟡 +7.8% slower | 41.431 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.0** | 🟢 -0.4% faster | 3.727 | 🟢 PASS |
| `latency.text` | 26568.0 | **26436.0** | 🟢 -0.5% faster | 0.061 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **210.3** | 🟡 +6.5% slower | 2.209 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1163.7** | 🟢 -7.7% faster | 11.857 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **7722.0** | 🟡 +1.1% slower | 7.996 | 🟢 PASS |
| `write.text` | 28478.0 | **27473.0** | 🟢 -3.5% faster | 29.895 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 0 |
| Parent commit (working-tree inputs are identified separately) | [`ba99d8cb5554c993bdefba341ebce7923295cf31`](https://github.com/aantich/mariadb-haskell/commit/ba99d8cb5554c993bdefba341ebce7923295cf31) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-08T15:31:58.162815+00:00 / 2026-11-08T15:34:16.480455+00:00 |
| Input fingerprint | `fcf5026a5b1e70ef66e2f60e0e2e20b611dcf34eb838672f9c59514e3211cba6` |
| Local logs and build plan | `validation/results/runs/stage5-review-publication-1` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |

Committed runs identify their tested revision. An uncommitted review run identifies its parent revision plus SHA-256 hashes of the actual working-tree inputs; it does not claim the parent commit contains these changes. A following results-only commit does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
