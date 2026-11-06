# Live MariaDB validation results

Current measurements for `main`, compared with the original unchanged-driver baseline.

![Validation overview: passing records, failures, unsupported APIs and environment gaps](results/overview.svg)

[Correctness](#correctness) · [Benchmarks](#benchmarks) · [Run details](#run-details) · [Raw results](results/current.json) · [Original baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md)

> [!CAUTION]
> **56 failed or timed-out check records remain.** Missing APIs and environment gaps are tracked separately; they are not passing tests.

**Baseline comparison: 🟢 No new regression signals** · 0 regression signals · 0 newly passing checks.

A passing comparison does not mean all functionality passes.

| Reference | Commit |
| --- | --- |
| **Baseline** · original unchanged-driver run | `5deb205d5835` |
| **Current** · latest completed run | `3b45fd34276b` |

Both comparison tables use these same two runs.

## Correctness

Counts include two aggregate records for the inherited unit/property and integration suites; see [coverage](COVERAGE.md). Change = Current − Baseline, in check records.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| 🟢 PASS | 246 | **246** | 0 |
| 🔴 FAIL | 56 | **56** | 0 |
| 🟠 TIMEOUT | 0 | **0** | 0 |
| 🔵 UNSUPPORTED | 11 | **11** | 0 |
| 🟡 ENVIRONMENT_UNAVAILABLE | 2 | **2** | 0 |

<details>
<summary>🔴 Failed or timed-out checks (56) — expand all findings</summary>

| Test | Current status | Detail |
| --- | --- | --- |
| `protocol.continuation-sequence-rejected` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `protocol.large-row-is-not-eof` | 🔴 FAIL | user error (valid 16 MiB text field classified as EOF) |
| `protocol.unsigned-last-insert-id` | 🔴 FAIL | user error (unsigned ID: expected 18446744073709551615, got -1) |
| `protocol.column-definition-roundtrip` | 🔴 FAIL | DecodePacketFailed "\NUL" 21 "not enough bytes" |
| `protocol.binary-plugin-challenge` | 🔴 FAIL | user error (binary challenge: expected "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t\NUL\v\f\r\SO\SI\DLE\DC1\DC2\DC3\DC4\NAK\SYN\ETB\CAN\EM\SUB\ESC\FS\GS\RS\US ", got "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t") |
| `protocol.unknown-plugin-rejected` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `protocol.native-extension-handshake` | 🔴 FAIL | user error (CLIENT_MYSQL legacy marker is still advertised) |
| `protocol.prepared-out-capability` | 🔴 FAIL | user error (CLIENT_PS_MULTI_RESULTS is absent) |
| `protocol.empty-packet-predicate` | 🔴 FAIL | user error (empty packet crashes classifier) |
| `protocol.text-field-trailing-data` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `protocol.text-field-integer-overflow` | 🔴 FAIL | user error (operation unexpectedly succeeded) |
| `protocol.reset-does-not-consume-pending-row` | 🔴 FAIL | user error (reset marked connection reusable with prior result/reset packets still unread) |
| `connection.default-full-unicode` | 🔴 FAIL | user error (default wire charset: expected "utf8mb4", got "utf8mb3") |
| `auth.ed25519.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.ed25519.tls` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.ed25519.socket` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| `auth.parsec.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.parsec.tls` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.parsec.socket` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| `auth.sha2.tcp` | 🔴 FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_sha2'@'localhost' (using password: YES)"}) |
| `auth.sha2.socket` | 🔴 FAIL | user error (RSA key parse: empty PEM) |
| `sql.procedure-prepared-out` | 🔴 FAIL | user error (prepared OUT result: expected [[42]], got []) |
| `sql.zero-date-preservation` | 🔴 FAIL | user error (zero date after driver round trip: expected [["0000-00-00"],["0000-00-00"]], got [["0000-00-00"],["0000-01-01"]]) |
| `sql.unsigned-generated-id` | 🔴 FAIL | user error (generated unsigned ID: expected 9223372036854775808, got -9223372036854775808) |
| `parameters.literal-question-mark` | 🔴 FAIL | WrongParamsCount |
| `parameters.comment-question-mark` | 🔴 FAIL | WrongParamsCount |
| `parameters.no-backslash-text` | 🔴 FAIL | ERRException (ERR {errCode = 1064, errState = "42000", errMsg = "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '\\\\c'' at line 1"}) |
| `packets.live-blob-16777216` | 🔴 FAIL | user error (expected one cell: []) |
| `packets.live-blob-16777217` | 🔴 FAIL | user error (expected one cell: []) |
| `packets.live-blob-33554430` | 🔴 FAIL | DecodePacketFailed "\NUL\NUL\STX\NUL" 1 "not enough bytes" |
| `transaction.partial-result-exception` | 🔴 FAIL | user error (original error replaced by UnconsumedResultSet |
| `transaction.nested-preserves-outer` | 🔴 FAIL | user error (nested call must not implicitly commit outer work: expected 0, got 2) |
| `reliability.reset-unread-result` | 🔴 FAIL | user error (expected one cell: []) |
| `reliability.timeout-before-metadata` | 🔴 FAIL | user error (following query: expected 937, got 0) |
| `reliability.server-kill-query` | 🔴 FAIL | UnconsumedResultSet |
| `reliability.tls-cancellation-propagates` | 🔴 FAIL | user error (cancellation replaced by Short read, expected 4 bytes |
| `connection.localhost-address-fallback` | 🔴 FAIL | Network.Socket.connect: <socket: 14>: does not exist (Connection refused) |
| `types.non-utf8-results` | 🔴 FAIL | Cannot decode byte '\xe9': Data.Text.Encoding: Invalid UTF-8 stream |
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
| `blob.prepared` | 3.1 | **3.3** | 🟡 +3.6% slower | 4.492 | 🟢 PASS |
| `blob.text` | 3.2 | **3.2** | 🟢 -0.7% faster | 4.569 | 🟢 PASS |
| `latency.prepared` | 41826.0 | **40356.0** | 🟢 -3.5% faster | 0.083 | 🟢 PASS |
| `latency.text` | 39354.0 | **40112.0** | 🟡 +1.9% slower | 0.070 | 🟢 PASS |
| `micro.binary-row` | 246.1 | **245.4** | 🟢 -0.3% faster | 25.467 | 🟢 PASS |
| `micro.text-row` | 313.2 | **318.2** | 🟡 +1.6% slower | 32.672 | 🟢 PASS |
| `native.bulk` | — | — | — | — | 🔵 UNSUPPORTED |
| `native.metadata-cache` | — | — | — | — | 🔵 UNSUPPORTED |
| `read.parallel-16` | 107.6 | **108.9** | 🟡 +1.2% slower | 24.530 | 🟢 PASS |
| `read.parallel-4` | 118.0 | **100.1** | 🟢 -15.1% faster | 6.707 | 🟢 PASS |
| `read.prepared.narrow` | 314.6 | **309.1** | 🟢 -1.7% faster | 4.582 | 🟢 PASS |
| `read.prepared.wide` | 2425.1 | **2399.7** | 🟢 -1.0% faster | 25.412 | 🟢 PASS |
| `read.socket.narrow` | 339.2 | **352.7** | 🟡 +4.0% slower | 4.097 | 🟢 PASS |
| `read.text.narrow` | 305.5 | **315.7** | 🟡 +3.3% slower | 3.308 | 🟢 PASS |
| `read.text.wide` | 2876.4 | **2831.5** | 🟢 -1.6% faster | 29.115 | 🟢 PASS |
| `read.tls.narrow` | 370.6 | **370.7** | ⚪ +0.0% unchanged | 5.874 | 🟢 PASS |
| `read.vector.narrow` | 365.8 | **371.6** | 🟡 +1.6% slower | 4.272 | 🟢 PASS |
| `write.execute-many` | 9670.0 | **9972.0** | 🟡 +3.1% slower | 10.240 | 🟢 PASS |
| `write.prepared` | 39408.0 | **37565.0** | 🟢 -4.7% faster | 44.097 | 🟢 PASS |
| `write.text` | 38324.0 | **40820.0** | 🟡 +6.5% slower | 43.004 | 🟢 PASS |

### MariaDB Connector/C control

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | --- | ---: | --- |
| `blob.text` | 3.0 | **3.1** | 🟡 +0.4% slower | 4.007 | 🟢 PASS |
| `latency.text` | 26568.0 | **26856.0** | 🟡 +1.1% slower | 0.057 | 🟢 PASS |
| `read.text.narrow` | 197.4 | **212.5** | 🟡 +7.6% slower | 2.272 | 🟢 PASS |
| `read.text.wide` | 1261.0 | **1200.6** | 🟢 -4.8% faster | 15.289 | 🟢 PASS |
| `write.execute-many` | 7635.0 | **7646.0** | 🟡 +0.1% slower | 7.947 | 🟢 PASS |
| `write.text` | 28478.0 | **29766.0** | 🟡 +4.5% slower | 30.686 | 🟢 PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.

Each measured process has two warm-ups; this run has **7 repetitions** per profile. All samples, allocations, GC statistics, checksums and latency measurements are retained in [current.json](results/current.json).

## Run details

<details>
<summary>Revision, environment and reproducibility</summary>

| Field | Latest attempt |
| --- | --- |
| State / exit code | COMPLETED / 0 |
| Tested commit | [`3b45fd34276b2ceffec5da6abb7bcb2a6c6571ec`](https://github.com/aantich/mariadb-haskell/commit/3b45fd34276b2ceffec5da6abb7bcb2a6c6571ec) |
| Branch | `main` |
| Started / finished (UTC) | 2026-11-06T21:56:58.884270+00:00 / 2026-11-06T21:57:32.058116+00:00 |
| Input fingerprint | `0d52bce29bd8be23c24cf1a3a8f853064003e52e1b8bcf292ae91f448c23eb89` |
| Local logs and build plan | `validation/results/runs/20261106T215658.883987Z` (ignored by Git) |
| Server of completed run | 12.3.3-MariaDB-log |
| Host | Apple M4 Max; macOS 26.4 |
| Compiler / build tool | GHC 9.10.3; Cabal 3.16.1.0 |
| MariaDB Connector/C | 3.4.10 |
| Complete suite / repetitions | True / 7 |
| Driver/workloads stable during execution | True |

The tested commit identifies the code used for execution. A following results-only commit publishes this document; it does not claim another test run. CI checks that the report, graphic and raw results match the current inputs.

Full `python3 validation/check.py` runs refresh this live document, [overview.svg](results/overview.svg) and [current.json](results/current.json), including failed attempts. Commit all three with each tested change. Git history retains previous results.

</details>
