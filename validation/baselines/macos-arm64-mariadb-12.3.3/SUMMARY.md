# MariaDB driver baseline

This run tests the current driver without implementation fixes.

Server: **12.3.3-MariaDB-log**. Driver commit: `5deb205d5835`.

PASS: **246** | FAIL: **56** | UNSUPPORTED: **11** | ENVIRONMENT_UNAVAILABLE: **2**

## Correctness findings

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

## Benchmarks

Two warm-up operations precede every measured process. Seven repetitions are the default. Raw samples and operation latencies are retained in JSON. A query/transaction/decoder batch is the latency unit; ns/unit normalizes by rows, bytes or decoder rows as specified in COVERAGE.md.

| Workload | Status | Median ns/unit | p95 operation ms |
| --- | --- | ---: | ---: |
| connector-c/read.text.wide | PASS | 1261.0 | 17.668 |
| connector-c/latency.text | PASS | 26568.0 | 0.060 |
| haskell/blob.text | PASS | 3.2 | 3.901 |
| haskell/native.metadata-cache | UNSUPPORTED | | |
| haskell/blob.prepared | PASS | 3.1 | 3.971 |
| haskell/micro.binary-row | PASS | 246.1 | 30.185 |
| haskell/read.prepared.narrow | PASS | 314.6 | 4.503 |
| haskell/latency.text | PASS | 39354.0 | 0.070 |
| haskell/read.parallel-4 | PASS | 118.0 | 6.516 |
| haskell/read.prepared.wide | PASS | 2425.1 | 35.309 |
| haskell/write.execute-many | PASS | 9670.0 | 17.099 |
| haskell/read.text.wide | PASS | 2876.4 | 32.083 |
| haskell/read.vector.narrow | PASS | 365.8 | 4.413 |
| haskell/write.text | PASS | 38324.0 | 67.783 |
| haskell/read.socket.narrow | PASS | 339.2 | 4.159 |
| haskell/native.bulk | UNSUPPORTED | | |
| connector-c/write.execute-many | PASS | 7635.0 | 10.841 |
| connector-c/read.text.narrow | PASS | 197.4 | 2.112 |
| haskell/read.tls.narrow | PASS | 370.6 | 5.282 |
| haskell/read.parallel-16 | PASS | 107.6 | 33.007 |
| connector-c/write.text | PASS | 28478.0 | 31.150 |
| haskell/write.prepared | PASS | 39408.0 | 47.979 |
| haskell/micro.text-row | PASS | 313.2 | 33.353 |
| haskell/latency.prepared | PASS | 41826.0 | 0.099 |
| haskell/read.text.narrow | PASS | 305.5 | 12.229 |
| connector-c/blob.text | PASS | 3.0 | 3.997 |
