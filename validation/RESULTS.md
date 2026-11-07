# Live MariaDB validation results

Current measured source, compared with the original unchanged-driver baseline. Uncommitted review builds are identified by input fingerprints below.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

## Stage 1 acceptance

Original targeted failures now passing: **23 / 23**. Original-baseline and last-accepted correctness protection: **PASS**.

Timing investigations above 5%: **12**; allocation investigations above 5%: **0**. These are investigation signals, not automatically accepted costs.

The frozen baseline retains its original meaning in all comparison tables. The last-accepted reference separately prevents an improvement being lost. [Acceptance evidence](results/stage1-gates.json) · [Confirmation history](results/stage1-confirmation.json) · [Supplementary evidence](results/references/stage1-after-final.json) · [Review notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

Confirmation and supplementary files identify their own input fingerprints. Evidence with a different fingerprint is historical and does not confirm the current source.

> [!WARNING]
> **Performance acceptance remains open.** Timing/allocation signals require investigation across the entire confirmation window; they have not been waived or accepted automatically.

> [!CAUTION]
> **33 failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.

**Baseline comparison: 🟢 No new regression signals** · 0 regression signals · 23 newly passing checks.

A passing comparison does not mean all functionality passes.

<details>
<summary>🟢 Newly passing checks</summary>

- `protocol.continuation-sequence-rejected`
- `protocol.large-row-is-not-eof`
- `protocol.unsigned-last-insert-id`
- `protocol.column-definition-roundtrip`
- `protocol.empty-packet-predicate`
- `protocol.text-field-trailing-data`
- `protocol.text-field-integer-overflow`
- `protocol.reset-does-not-consume-pending-row`
- `connection.default-full-unicode`
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
- `types.non-utf8-results`

</details>

| Reference | Commit |
| --- | --- |
| **Baseline** · original unchanged-driver run | `5deb205d5835` |
| **Current** · latest completed run | `0128b7908e8a` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **357** | 🟢 +111 |
| 🔴 FAIL | 56 | **33** | 🟢 -23 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **11** | 0 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **2** | 0 |

<details>
<summary>🔴 Failed or timed-out checks (33) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `protocol.binary-plugin-challenge` | 🔴 FAIL | user error (binary challenge: expected "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t\NUL\v\f\r\SO\SI\DLE\DC1\DC2\DC3\DC4\NAK\SYN\ETB\CAN\EM\SUB\ESC\FS\GS\RS\US ", got "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t") |
| `protocol.unknown-plugin-rejected` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `protocol.native-extension-handshake` | 🔴 FAIL | user error (CLIENT_MYSQL legacy marker is still advertised) |
| `protocol.prepared-out-capability` | 🔴 FAIL | user error (CLIENT_PS_MULTI_RESULTS is absent) |
| `auth.ed25519.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.ed25519.tls` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.ed25519.socket` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.parsec.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.parsec.tls` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.parsec.socket` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.sha2.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_sha2'@'localhost' (using password: YES)"}) |
| `auth.sha2.socket` | 🔴 FAIL | user error (RSA key parse: empty PEM) |
| `sql.procedure-prepared-out` | 🔴 FAIL | user error (prepared OUT result: expected [[42]], got []) |
| `reliability.timeout-before-metadata` | 🔴 FAIL | ConnectionUnavailable Broken |
| `connection.localhost-address-fallback` | 🔴 FAIL | Network.Socket.connect: <socket: 14>: does not exist (Connection refused) |
| `auth.mutual-tls-helper-client` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_x509'@'localhost' (using password: YES)"}) |
| `connection.mozilla-ca-store-installed` | 🔴 FAIL | /Users/aantich/.cabal/share/aarch64-osx-ghc-9.10.3-fe9c/mysql-haskell-1.3.3/mozillaCAStore.pem: withBinaryFile: does not exist (No such file or directory) |
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
| `blob.prepared` | 3.1 | **3.2** | 🟡 +2.2% slower | 3.904 | 🟢 PASS |
| `blob.text` | 3.2 | **3.2** | 🟢 -0.2% faster | 4.178 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **47410.0** | 🟡 +13.4% slower | 0.081 | 🟢 PASS |
| `latency.text` | 39354.0 | **41880.0** | 🟡 +6.4% slower | 0.068 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **245.2** | 🟢 -0.4% faster | 25.625 | 🟢 PASS |
| `micro.text-row` | 313.2 | **289.3** | 🟢 -7.6% faster | 31.041 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **104.9** | 🟢 -2.5% faster | 21.262 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **114.1** | 🟢 -3.3% faster | 6.865 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **285.7** | 🟢 -9.2% faster | 3.871 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2409.6** | 🟢 -0.6% faster | 26.216 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **365.9** | 🟡 +7.9% slower | 4.319 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **321.6** | 🟡 +5.3% slower | 3.457 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2869.9** | 🟢 -0.2% faster | 30.741 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **398.1** | 🟡 +7.4% slower | 5.383 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **347.7** | 🟢 -5.0% faster | 4.502 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **9199.0** | 🟢 -4.9% faster | 12.964 | 🟢 PASS |
| `write.prepared` | 39408.0 | **38480.0** | 🟢 -2.4% faster | 42.431 | 🟢 PASS |
| `write.text` | 38324.0 | **41557.0** | 🟡 +8.4% slower | 45.272 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.2** | 🟡 +5.3% slower | 4.071 | 🟢 PASS |
| `latency.text` | 26568.0 | **26662.0** | 🟡 +0.4% slower | 0.057 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **205.5** | 🟡 +4.1% slower | 2.238 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1402.5** | 🟡 +11.2% slower | 15.311 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **7919.0** | 🟡 +3.7% slower | 9.582 | 🟢 PASS |
| `write.text` | 28478.0 | **28554.0** | 🟡 +0.3% slower | 30.517 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 0 |
| Parent commit (working-tree inputs are identified separately) | [`0128b7908e8ac594d6dea5110fbc5b1a2a71ad1b`](https://github.com/aantich/mariadb-haskell/commit/0128b7908e8ac594d6dea5110fbc5b1a2a71ad1b) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-07T11:17:27.116561+00:00 / 2026-11-07T11:18:04.380558+00:00 |
| Input fingerprint | `835058eb17a5c841fc1e038764a295c70aac439e8ae5bd09ed11dbd79c50cce8` |
| Local logs and build plan | `validation/results/runs/stage1-publication-1` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |

Committed runs identify their tested revision. An uncommitted review run identifies its parent revision plus SHA-256 hashes of the actual working-tree inputs; it does not claim the parent commit contains these changes. A following results-only commit does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
