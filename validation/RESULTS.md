# Live MariaDB validation results

Current measured source, compared with the original unchanged-driver baseline. Uncommitted review builds are identified by input fingerprints below.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

## Implementation acceptance

Stage 1 targeted failures now passing: **23 / 23**. Original-baseline and last-accepted correctness protection: **PASS**.

Timing investigations above 5%: **4**; allocation investigations above 5%: **0**. These are investigation signals, not automatically accepted costs.

The frozen baseline retains its original meaning in all comparison tables. The last-accepted reference separately prevents an improvement being lost. [Acceptance evidence](results/stage1-gates.json) · [Confirmation history](results/stage1-confirmation.json) · [Supplementary evidence](results/references/stage1-after-final.json) · [Review notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

Confirmation and supplementary files identify their own input fingerprints. Evidence with a different fingerprint is historical and does not confirm the current source.

Stage 2 native-connection targets passing: **14 / 14**. Published Stage 1 correctness is separately protected. [Stage 2 implementation and validation](../docs/STAGE2_IMPLEMENTATION.md).

> [!WARNING]
> **Performance acceptance remains open.** Timing/allocation signals require investigation across the entire confirmation window; they have not been waived or accepted automatically.

> [!CAUTION]
> **19 failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.

**Baseline comparison: 🟢 No new regression signals** · 0 regression signals · 37 newly passing checks.

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
- `auth.mutual-tls-helper-client`
- `connection.mozilla-ca-store-installed`

</details>

| Reference | Commit |
| --- | --- |
| **Baseline** · original unchanged-driver run | `5deb205d5835` |
| **Current** · latest completed run | `d5c71bd59902` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **401** | 🟢 +155 |
| 🔴 FAIL | 56 | **19** | 🟢 -37 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **11** | 0 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **2** | 0 |

<details>
<summary>🔴 Failed or timed-out checks (19) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `protocol.prepared-out-capability` | 🔴 FAIL | user error (CLIENT_PS_MULTI_RESULTS is absent) |
| `sql.procedure-prepared-out` | 🔴 FAIL | user error (prepared OUT result: expected [[42]], got []) |
| `reliability.timeout-before-metadata` | 🔴 FAIL | ConnectionUnavailable Broken |
| `cdc.multiple-table-maps` | 🔴 FAIL | user error (both mapped row events: expected 2, got 0) |
| `cdc.repeated-row-events` | 🔴 FAIL | user error (map reused for both row events: expected 2, got 1) |
| `cdc.table-id-mismatch` | 🔴 FAIL | user error (row matched correct table ID: expected 1, got 2) |
| `cdc.crc32-corruption-rejected` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `cdc.native-event-160` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (160) is outside of enumeration's range (0,35) |
| `cdc.native-event-161` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (161) is outside of enumeration's range (0,35) |
| `cdc.native-event-162` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (162) is outside of enumeration's range (0,35) |
| `cdc.native-event-163` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (163) is outside of enumeration's range (0,35) |
| `cdc.native-event-164` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (164) is outside of enumeration's range (0,35) |
| `cdc.native-event-165` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (165) is outside of enumeration's range (0,35) |
| `cdc.native-event-166` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (166) is outside of enumeration's range (0,35) |
| `cdc.native-event-167` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (167) is outside of enumeration's range (0,35) |
| `cdc.native-event-168` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (168) is outside of enumeration's range (0,35) |
| `cdc.native-event-169` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (169) is outside of enumeration's range (0,35) |
| `cdc.native-event-170` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (170) is outside of enumeration's range (0,35) |
| `cdc.native-event-171` | 🔴 FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (171) is outside of enumeration's range (0,35) |

</details>

<details>
<summary>🔵 Missing driver APIs (11) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `capability.binary-bulk` | 🔵 UNSUPPORTED | no COM_STMT_BULK_EXECUTE command/API in this driver |
| `capability.metadata-cache` | 🔵 UNSUPPORTED | no MARIADB_CLIENT_CACHE_METADATA negotiation or statement metadata cache |
| `capability.extended-metadata` | 🔵 UNSUPPORTED | ColumnDef has no MariaDB extended metadata attributes |
| `capability.session-tracking` | 🔵 UNSUPPORTED | OK/session-state payloads are not exposed |
| `capability.reset-connection` | 🔵 UNSUPPORTED | no COM_RESET_CONNECTION API |
| `capability.progress-reporting` | 🔵 UNSUPPORTED | no negotiated MariaDB progress callback |
| `capability.cursor-fetch` | 🔵 UNSUPPORTED | no COM_STMT_FETCH/cursor API |
| `capability.long-data` | 🔵 UNSUPPORTED | no COM_STMT_SEND_LONG_DATA API |
| `capability.compression` | 🔵 UNSUPPORTED | no compressed packet transport |
| `cdc.gtid-resume` | 🔵 UNSUPPORTED | BinLogTracker only exposes filename/32-bit position; MariaDB GTID resume is absent |
| `cdc.durable-ack-control` | 🔵 UNSUPPORTED | semisync acknowledgements happen in the reader, before a consumer durability checkpoint |

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

Environment, compiler, dependencies and benchmark workloads match the original baseline.

### Haskell driver

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.prepared` | 3.1 | **3.1** | 🟢 -1.4% faster | 4.478 | 🟢 PASS |
| `blob.text` | 3.2 | **3.1** | 🟢 -2.4% faster | 4.635 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **38084.0** | 🟢 -8.9% faster | 0.081 | 🟢 PASS |
| `latency.text` | 39354.0 | **41344.0** | 🟡 +5.1% slower | 0.073 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **237.0** | 🟢 -3.7% faster | 23.925 | 🟢 PASS |
| `micro.text-row` | 313.2 | **287.1** | 🟢 -8.3% faster | 29.079 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **100.3** | 🟢 -6.8% faster | 17.398 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **118.8** | 🟡 +0.7% slower | 6.536 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **281.6** | 🟢 -10.5% faster | 4.457 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2303.4** | 🟢 -5.0% faster | 23.661 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **337.9** | 🟢 -0.4% faster | 3.557 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **317.2** | 🟡 +3.8% slower | 3.381 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2654.5** | 🟢 -7.7% faster | 27.599 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **374.9** | 🟡 +1.2% slower | 5.102 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **342.9** | 🟢 -6.3% faster | 3.749 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **7959.0** | 🟢 -17.7% faster | 8.655 | 🟢 PASS |
| `write.prepared` | 39408.0 | **38399.0** | 🟢 -2.6% faster | 39.379 | 🟢 PASS |
| `write.text` | 38324.0 | **41325.0** | 🟡 +7.8% slower | 41.552 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.1** | 🟡 +1.4% slower | 4.081 | 🟢 PASS |
| `latency.text` | 26568.0 | **26768.0** | 🟡 +0.8% slower | 0.072 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **208.8** | 🟡 +5.8% slower | 2.230 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1166.0** | 🟢 -7.5% faster | 12.682 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **7526.0** | 🟢 -1.4% faster | 7.692 | 🟢 PASS |
| `write.text` | 28478.0 | **29571.0** | 🟡 +3.8% slower | 29.883 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 0 |
| Parent commit (working-tree inputs are identified separately) | [`d5c71bd59902e7350b773a306d93f1947626b1b0`](https://github.com/aantich/mariadb-haskell/commit/d5c71bd59902e7350b773a306d93f1947626b1b0) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-07T12:59:44.630978+00:00 / 2026-11-07T13:00:22.659034+00:00 |
| Input fingerprint | `0c4456b8f17af803344b7ad73a2b75e14c0e65c7b8d2be53be43891cd08ff6e1` |
| Local logs and build plan | `validation/results/runs/stage2-publication-1` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |

Committed runs identify their tested revision. An uncommitted review run identifies its parent revision plus SHA-256 hashes of the actual working-tree inputs; it does not claim the parent commit contains these changes. A following results-only commit does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
