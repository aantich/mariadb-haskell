# Live MariaDB validation results

**This is the current results document on `main`.** Every full `python3 validation/check.py` run refreshes it, including failed attempts. Commit this file and [the machine-readable results](results/current.json) with each tested change. Git history retains earlier results.

The [original unchanged-driver baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md) remains the reference for measuring improvements.

## Latest validation attempt

- State: **COMPLETED**; process exit code: **1**.
- Tested commit: [`7e036feca5e5157195495f61df046812493ccf9b`](https://github.com/aantich/mariadb-haskell/commit/7e036feca5e5157195495f61df046812493ccf9b) on `main`.
- Started: 2026-11-06T21:35:57.629034+00:00; finished: 2026-11-06T21:36:35.509854+00:00.
- Input fingerprint: `2e595c80a87cada9f5ee35f293b9410c2cc089243d51bdb5c65cb28bca2fff88`.
- Local raw logs and build plan: `validation/results/runs/20261106T213557.628683Z` (ignored by Git).

The tested commit identifies the code used for execution. A following results-only commit publishes this document; it does not claim another test run. CI checks that the recorded inputs still match the current code.

## Current complete suite

Server: **12.3.3-MariaDB-log**. Machine: **Apple M4 Max**, macOS 26.4. GHC 9.10.3; Cabal 3.16.1.0; MariaDB Connector/C 3.4.10.

Full suite: **True**. Benchmark repetitions: **7**. Driver/workloads unchanged during execution: **True**.

### Correctness

Counts include two aggregate records for the inherited unit/property and integration suites. Their individual cases are described in [coverage](COVERAGE.md). Unsupported APIs and unavailable environments are separate from passes.

| Status | Current | Original baseline |
| --- | ---: | ---: |
| PASS | 246 | 246 |
| FAIL | 56 | 56 |
| TIMEOUT | 0 | 0 |
| UNSUPPORTED | 11 | 11 |
| ENVIRONMENT_UNAVAILABLE | 2 | 2 |

Regression comparison: **FAIL**; **21** regression signals; **0** newly passing cases. This gate compares against the baseline; a passing gate does not mean all functionality passes.

Regression signals:

- connector-c/read.text.wide: median slowed by more than 20%; confirm on an idle machine
- connector-c/latency.text: median slowed by more than 20%; confirm on an idle machine
- haskell/blob.text: median slowed by more than 20%; confirm on an idle machine
- haskell/micro.binary-row: median slowed by more than 20%; confirm on an idle machine
- haskell/read.prepared.narrow: median slowed by more than 20%; confirm on an idle machine
- haskell/latency.text: median slowed by more than 20%; confirm on an idle machine
- haskell/read.parallel-4: median slowed by more than 20%; confirm on an idle machine
- haskell/read.prepared.wide: median slowed by more than 20%; confirm on an idle machine
- haskell/write.execute-many: median slowed by more than 20%; confirm on an idle machine
- haskell/read.text.wide: median slowed by more than 20%; confirm on an idle machine
- haskell/read.vector.narrow: median slowed by more than 20%; confirm on an idle machine
- haskell/write.text: median slowed by more than 20%; confirm on an idle machine
- haskell/read.socket.narrow: median slowed by more than 20%; confirm on an idle machine
- connector-c/write.execute-many: median slowed by more than 20%; confirm on an idle machine
- connector-c/read.text.narrow: median slowed by more than 20%; confirm on an idle machine
- haskell/read.parallel-16: median slowed by more than 20%; confirm on an idle machine
- connector-c/write.text: median slowed by more than 20%; confirm on an idle machine
- haskell/write.prepared: median slowed by more than 20%; confirm on an idle machine
- haskell/micro.text-row: median slowed by more than 20%; confirm on an idle machine
- haskell/latency.prepared: median slowed by more than 20%; confirm on an idle machine
- connector-c/blob.text: median slowed by more than 20%; confirm on an idle machine

### Outstanding correctness findings

| Test | Status | Detail |
| --- | --- | --- |
| protocol.continuation-sequence-rejected | FAIL | user error (operation unexpectedly succeeded) |
| protocol.large-row-is-not-eof | FAIL | user error (valid 16 MiB text field classified as EOF) |
| protocol.unsigned-last-insert-id | FAIL | user error (unsigned ID: expected 18446744073709551615, got -1) |
| protocol.column-definition-roundtrip | FAIL | DecodePacketFailed "\NUL" 21 "not enough bytes" |
| protocol.binary-plugin-challenge | FAIL | user error (binary challenge: expected "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t\NUL\v\f\r\SO\SI\DLE\DC1\DC2\DC3\DC4\NAK\SYN\ETB\CAN\EM\SUB\ESC\FS\GS\RS\US ", got "\SOH\STX\ETX\EOT\ENQ\ACK\a\b\t") |
| protocol.unknown-plugin-rejected | FAIL | user error (operation unexpectedly succeeded) |
| protocol.native-extension-handshake | FAIL | user error (CLIENT_MYSQL legacy marker is still advertised) |
| protocol.prepared-out-capability | FAIL | user error (CLIENT_PS_MULTI_RESULTS is absent) |
| protocol.empty-packet-predicate | FAIL | user error (empty packet crashes classifier) |
| protocol.text-field-trailing-data | FAIL | user error (operation unexpectedly succeeded) |
| protocol.text-field-integer-overflow | FAIL | user error (operation unexpectedly succeeded) |
| protocol.reset-does-not-consume-pending-row | FAIL | user error (reset marked connection reusable with prior result/reset packets still unread) |
| connection.default-full-unicode | FAIL | user error (default wire charset: expected "utf8mb4", got "utf8mb3") |
| auth.ed25519.tcp | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| auth.ed25519.tls | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| auth.ed25519.socket | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_ed25519'@'localhost' (using password: YES)"}) |
| auth.parsec.tcp | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| auth.parsec.tls | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| auth.parsec.socket | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_parsec'@'localhost' (using password: NO)"}) |
| auth.sha2.tcp | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_sha2'@'localhost' (using password: YES)"}) |
| auth.sha2.socket | FAIL | user error (RSA key parse: empty PEM) |
| sql.procedure-prepared-out | FAIL | user error (prepared OUT result: expected [[42]], got []) |
| sql.zero-date-preservation | FAIL | user error (zero date after driver round trip: expected [["0000-00-00"],["0000-00-00"]], got [["0000-00-00"],["0000-01-01"]]) |
| sql.unsigned-generated-id | FAIL | user error (generated unsigned ID: expected 9223372036854775808, got -9223372036854775808) |
| parameters.literal-question-mark | FAIL | WrongParamsCount |
| parameters.comment-question-mark | FAIL | WrongParamsCount |
| parameters.no-backslash-text | FAIL | ERRException (ERR {errCode = 1064, errState = "42000", errMsg = "You have an error in your SQL syntax; check the manual that corresponds to your MariaDB server version for the right syntax to use near '\\\\c'' at line 1"}) |
| packets.live-blob-16777216 | FAIL | user error (expected one cell: []) |
| packets.live-blob-16777217 | FAIL | user error (expected one cell: []) |
| packets.live-blob-33554430 | FAIL | DecodePacketFailed "\NUL\NUL\STX\NUL" 1 "not enough bytes" |
| transaction.partial-result-exception | FAIL | user error (original error replaced by UnconsumedResultSet |
| transaction.nested-preserves-outer | FAIL | user error (nested call must not implicitly commit outer work: expected 0, got 2) |
| reliability.reset-unread-result | FAIL | user error (expected one cell: []) |
| reliability.timeout-before-metadata | FAIL | user error (following query: expected 937, got 0) |
| reliability.server-kill-query | FAIL | UnconsumedResultSet |
| reliability.tls-cancellation-propagates | FAIL | user error (cancellation replaced by Short read, expected 4 bytes |
| connection.localhost-address-fallback | FAIL | Network.Socket.connect: <socket: 14>: does not exist (Connection refused) |
| types.non-utf8-results | FAIL | Cannot decode byte '\xe9': Data.Text.Encoding: Invalid UTF-8 stream |
| capability.binary-bulk | UNSUPPORTED | no COM_STMT_BULK_EXECUTE command/API in this driver |
| capability.metadata-cache | UNSUPPORTED | no MARIADB_CLIENT_CACHE_METADATA negotiation or statement metadata cache |
| capability.extended-metadata | UNSUPPORTED | ColumnDef has no MariaDB extended metadata attributes |
| capability.session-tracking | UNSUPPORTED | OK/session-state payloads are not exposed |
| capability.reset-connection | UNSUPPORTED | no COM_RESET_CONNECTION API |
| capability.progress-reporting | UNSUPPORTED | no negotiated MariaDB progress callback |
| capability.cursor-fetch | UNSUPPORTED | no COM_STMT_FETCH/cursor API |
| capability.long-data | UNSUPPORTED | no COM_STMT_SEND_LONG_DATA API |
| capability.compression | UNSUPPORTED | no compressed packet transport |
| auth.mutual-tls-helper-client | FAIL | ERRException (ERR {errCode = 1045, errState = "28000", errMsg = "Access denied for user 'mariadb_x509'@'localhost' (using password: YES)"}) |
| connection.mozilla-ca-store-installed | FAIL | /Users/aantich/.cabal/share/aarch64-osx-ghc-9.10.3-fe9c/mysql-haskell-1.3.3/mozillaCAStore.pem: withBinaryFile: does not exist (No such file or directory) |
| auth.pam-environment | ENVIRONMENT_UNAVAILABLE | PAM helper from the Homebrew bottle could not acquire root ownership; no OS PAM login fixture is configured |
| auth.gssapi-environment | ENVIRONMENT_UNAVAILABLE | no Kerberos realm, keytab or GSSAPI login fixture configured on this Mac |
| cdc.multiple-table-maps | FAIL | user error (both mapped row events: expected 2, got 0) |
| cdc.repeated-row-events | FAIL | user error (map reused for both row events: expected 2, got 1) |
| cdc.table-id-mismatch | FAIL | user error (row matched correct table ID: expected 1, got 2) |
| cdc.crc32-corruption-rejected | FAIL | user error (operation unexpectedly succeeded) |
| cdc.gtid-resume | UNSUPPORTED | BinLogTracker only exposes filename/32-bit position; MariaDB GTID resume is absent |
| cdc.durable-ack-control | UNSUPPORTED | semisync acknowledgements happen in the reader, before a consumer durability checkpoint |
| cdc.native-event-160 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (160) is outside of enumeration's range (0,35) |
| cdc.native-event-161 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (161) is outside of enumeration's range (0,35) |
| cdc.native-event-162 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (162) is outside of enumeration's range (0,35) |
| cdc.native-event-163 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (163) is outside of enumeration's range (0,35) |
| cdc.native-event-164 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (164) is outside of enumeration's range (0,35) |
| cdc.native-event-165 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (165) is outside of enumeration's range (0,35) |
| cdc.native-event-166 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (166) is outside of enumeration's range (0,35) |
| cdc.native-event-167 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (167) is outside of enumeration's range (0,35) |
| cdc.native-event-168 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (168) is outside of enumeration's range (0,35) |
| cdc.native-event-169 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (169) is outside of enumeration's range (0,35) |
| cdc.native-event-170 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (170) is outside of enumeration's range (0,35) |
| cdc.native-event-171 | FAIL | user error (partial event decoder: toEnum{BinLogEventType}: tag (171) is outside of enumeration's range (0,35) |

### Benchmarks

Two warm-ups precede each measured process. ns/unit means rows, bytes or decoded rows according to [coverage](COVERAGE.md); p95 measures whole operations. All repetitions, allocations, GC statistics, checksums and latency samples are retained in [current.json](results/current.json).

Environment, compiler, dependencies and benchmark workloads match the original baseline. Deltas below compare medians; more than 20% slower triggers investigation.

| Workload | Status | Median ns/unit | Baseline ns/unit | Change | p95 operation ms |
| --- | --- | ---: | ---: | ---: | ---: |
| connector-c/blob.text | PASS | 4.5 | 3.0 | +46.5% | 5.166 |
| connector-c/latency.text | PASS | 37310.0 | 26568.0 | +40.4% | 0.079 |
| connector-c/read.text.narrow | PASS | 242.0 | 197.4 | +22.5% | 3.690 |
| connector-c/read.text.wide | PASS | 2074.7 | 1261.0 | +64.5% | 29.561 |
| connector-c/write.execute-many | PASS | 12652.0 | 7635.0 | +65.7% | 15.760 |
| connector-c/write.text | PASS | 35955.0 | 28478.0 | +26.3% | 40.798 |
| haskell/blob.prepared | PASS | 3.8 | 3.1 | +19.2% | 5.590 |
| haskell/blob.text | PASS | 4.2 | 3.2 | +32.1% | 5.790 |
| haskell/latency.prepared | PASS | 62330.0 | 41826.0 | +49.0% | 0.122 |
| haskell/latency.text | PASS | 49088.0 | 39354.0 | +24.7% | 0.107 |
| haskell/micro.binary-row | PASS | 347.9 | 246.1 | +41.4% | 58.580 |
| haskell/micro.text-row | PASS | 407.5 | 313.2 | +30.1% | 63.121 |
| haskell/native.bulk | UNSUPPORTED | | | | |
| haskell/native.metadata-cache | UNSUPPORTED | | | | |
| haskell/read.parallel-16 | PASS | 293.9 | 107.6 | +173.2% | 89.123 |
| haskell/read.parallel-4 | PASS | 181.0 | 118.0 | +53.5% | 12.134 |
| haskell/read.prepared.narrow | PASS | 390.5 | 314.6 | +24.1% | 4.602 |
| haskell/read.prepared.wide | PASS | 3407.8 | 2425.1 | +40.5% | 43.834 |
| haskell/read.socket.narrow | PASS | 543.4 | 339.2 | +60.2% | 6.491 |
| haskell/read.text.narrow | PASS | 349.9 | 305.5 | +14.5% | 5.461 |
| haskell/read.text.wide | PASS | 4026.5 | 2876.4 | +40.0% | 59.169 |
| haskell/read.tls.narrow | PASS | 422.9 | 370.6 | +14.1% | 5.380 |
| haskell/read.vector.narrow | PASS | 459.2 | 365.8 | +25.5% | 6.382 |
| haskell/write.execute-many | PASS | 12652.0 | 9670.0 | +30.8% | 17.799 |
| haskell/write.prepared | PASS | 51413.0 | 39408.0 | +30.5% | 64.093 |
| haskell/write.text | PASS | 56854.0 | 38324.0 | +48.4% | 421.745 |
