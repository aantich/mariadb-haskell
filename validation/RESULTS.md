# Live MariaDB validation results

**This is the current results document on `main`.** Every full `python3 validation/check.py` run refreshes it, including failed attempts. Commit this file and [the machine-readable results](results/current.json) with each tested change. Git history retains earlier results.

The [original unchanged-driver baseline](baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md) remains the reference for measuring improvements.

## Latest validation attempt

- State: **COMPLETED**; process exit code: **1**.
- Tested commit: [`67ebea7c43bb5bf0d4e10a7bf4abcb93208f110d`](https://github.com/aantich/mariadb-haskell/commit/67ebea7c43bb5bf0d4e10a7bf4abcb93208f110d) on `main`.
- Started: 2026-11-06T21:47:19.056350+00:00; finished: 2026-11-06T21:47:54.146398+00:00.
- Input fingerprint: `8433cf5dd182165650f75efb842ecfe50d4413db2b52d9cec5de3fed7989d61b`.
- Local raw logs and build plan: `validation/results/runs/20261106T214719.056007Z` (ignored by Git).

The tested commit identifies the code used for execution. A following results-only commit publishes this document; it does not claim another test run. CI checks that the recorded inputs still match the current code.

## Current complete suite

Server: **12.3.3-MariaDB-log**. Machine: **Apple M4 Max**, macOS 26.4. GHC 9.10.3; Cabal 3.16.1.0; MariaDB Connector/C 3.4.10.

Full suite: **True**. Benchmark repetitions: **7**. Driver/workloads unchanged during execution: **True**.

**Baseline** is the original unchanged-driver run at `5deb205d5835`. **Current** is the completed run at `67ebea7c43bb`. Both tables compare these same two runs.

### Correctness

Counts include two aggregate records for the inherited unit/property and integration suites. Their individual cases are described in [coverage](COVERAGE.md). Unsupported APIs and unavailable environments are separate from passes.

Values are numbers of checks. Change = Current − Baseline, in checks.

| Status | Baseline | Current | Change vs baseline |
| --- | ---: | ---: | ---: |
| PASS | 246 | 246 | 0 |
| FAIL | 56 | 56 | 0 |
| TIMEOUT | 0 | 0 | 0 |
| UNSUPPORTED | 11 | 11 | 0 |
| ENVIRONMENT_UNAVAILABLE | 2 | 2 | 0 |

Regression comparison: **FAIL**; **1** regression signals; **0** newly passing cases. This gate compares against the baseline; a passing gate does not mean all functionality passes.

Regression signals:

- haskell/read.parallel-4: median slowed by more than 20%; confirm on an idle machine

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

Baseline and Current are **median times in ns/unit; lower is faster**. Change = 100 × (Current − Baseline) / Baseline. **Positive = slower; negative = faster; zero = unchanged.** p95 and status describe the Current run.

Environment, compiler, dependencies and benchmark workloads match the original baseline. More than 20% slower triggers investigation.

| Workload | Baseline (ns/unit) | Current (ns/unit) | Change vs baseline | Current p95 (ms) | Current status |
| --- | ---: | ---: | ---: | ---: | --- |
| connector-c/blob.text | 3.0 | 3.2 | +4.8% | 5.121 | PASS |
| connector-c/latency.text | 26568.0 | 28112.0 | +5.8% | 0.071 | PASS |
| connector-c/read.text.narrow | 197.4 | 215.8 | +9.3% | 11.269 | PASS |
| connector-c/read.text.wide | 1261.0 | 1289.6 | +2.3% | 33.856 | PASS |
| connector-c/write.execute-many | 7635.0 | 7858.0 | +2.9% | 10.128 | PASS |
| connector-c/write.text | 28478.0 | 30569.0 | +7.3% | 39.097 | PASS |
| haskell/blob.prepared | 3.1 | 3.2 | +2.2% | 4.745 | PASS |
| haskell/blob.text | 3.2 | 3.2 | +1.0% | 8.074 | PASS |
| haskell/latency.prepared | 41826.0 | 41058.0 | -1.8% | 0.076 | PASS |
| haskell/latency.text | 39354.0 | 46676.0 | +18.6% | 0.078 | PASS |
| haskell/micro.binary-row | 246.1 | 254.2 | +3.3% | 27.024 | PASS |
| haskell/micro.text-row | 313.2 | 340.8 | +8.8% | 48.672 | PASS |
| haskell/native.bulk | — | — | — | — | UNSUPPORTED |
| haskell/native.metadata-cache | — | — | — | — | UNSUPPORTED |
| haskell/read.parallel-16 | 107.6 | 128.4 | +19.3% | 88.294 | PASS |
| haskell/read.parallel-4 | 118.0 | 146.5 | +24.2% | 7.218 | PASS |
| haskell/read.prepared.narrow | 314.6 | 365.2 | +16.1% | 4.763 | PASS |
| haskell/read.prepared.wide | 2425.1 | 2663.9 | +9.8% | 31.304 | PASS |
| haskell/read.socket.narrow | 339.2 | 373.0 | +9.9% | 5.007 | PASS |
| haskell/read.text.narrow | 305.5 | 314.3 | +2.9% | 4.592 | PASS |
| haskell/read.text.wide | 2876.4 | 3016.0 | +4.9% | 46.811 | PASS |
| haskell/read.tls.narrow | 370.6 | 377.1 | +1.8% | 6.250 | PASS |
| haskell/read.vector.narrow | 365.8 | 380.2 | +3.9% | 4.605 | PASS |
| haskell/write.execute-many | 9670.0 | 10716.0 | +10.8% | 21.467 | PASS |
| haskell/write.prepared | 39408.0 | 38784.0 | -1.6% | 58.812 | PASS |
| haskell/write.text | 38324.0 | 41366.0 | +7.9% | 48.566 | PASS |

— means no successful measurement is available, or the runs cannot be compared for Change.
