# MariaDB validation coverage

The initial baseline targets the installed MariaDB **12.3.3 LTS** server and GHC **9.10.3** on macOS arm64. The source implementation is unchanged from upstream commit `92a94012bc553a672c73d409dad1d17e9db1e53f`. The suite checks the driver surfaces below; assertions describe correct behavior rather than adapting expected values to current defects.

## Correctness coverage

| Surface | Checks |
| --- | --- |
| Protocol and framing | Length integer boundaries, packet round trips, every split within a small packet, coalesced packets, short headers/bodies, continuation sequence errors and wrap, EOF/large-row distinction, unsigned OK IDs, column metadata encoding, binary authentication challenges, unknown plugins, capability markers, empty packet handling, numeric overflow/trailing input, synthetic reset state and NULL bitmaps |
| Connections and TLS | Native TCP, Unix sockets, verified TLS, missing/invalid credentials/schema, hostname and CA rejection, IPv4/IPv6 localhost fallback, full-Unicode defaults and installed CA-bundle lookup |
| Authentication | Native password, OS-mapped Unix socket, ed25519/parsec/SHA-2 over TCP/TLS/socket, X.509-required users, valid/expired client certificates, certificate-request callback selection and helper behavior. CLI controls establish that the configured accounts work independently of the driver. |
| Scalar values | Signed/unsigned integer widths and extrema, MariaDB MEDIUMINT, DECIMAL precision 65 with scale 30/38, exact float/double values, BIT 1/8/16/64, YEAR 0/1901/2155, valid date extrema/leap day, fractional DATETIME/TIMESTAMP/TIME, TIMESTAMP beyond 2038, TIME ±838 hours, NULL, ENUM/SET, empty strings/bytes, all 256 byte values, NUL/control characters, multilingual/combining/supplementary Unicode |
| Text and binary parity | Each of 47 scalar fixtures is inserted using binary binding and fetched independently through text and prepared binary results. NULL row bitmaps cross 1/2/7/8/9/15/16/17/63/64/65 columns. |
| Native MariaDB values | JSON with supplementary Unicode, UUID, INET4/INET6, packed VECTOR values and textual conversion, GEOMETRY and coordinate functions, zero-date reinsertion, unsigned generated IDs, non-UTF-8 results |
| SQL and results | CTE/recursive CTE, window functions, JSON functions, sequence tables/objects, generated columns, CHECK/foreign-key constraints, text/prepared INSERT/DELETE RETURNING, procedure multiple results and prepared OUT parameters, Oracle mode, system-versioned history, list/vector streams, empty/non-row results, mixed multi-statements and deliberate draining |
| Parameters and prepared lifecycle | Literal/comment question marks, NO_BACKSLASH_ESCAPES through both APIs, SQL-looking bound data, IN-list/empty-list substitution, parameter type changes, arity, metadata names/unsigned/scale/counts, reset, closed IDs and DDL reprepare |
| Session and errors | Schema switching, warning counts, TIMESTAMP versus DATETIME timezone behavior, syntax/table/duplicate errors followed by a valid query |
| Large packets | Live first-field BLOB results below/at/above 16 KiB and 16 MiB, up to 33,554,430 bytes. Prepared and text outbound parameters cross physical packet boundaries. Every live case checks content and follows with another query. Inherited tests add their original large-table/value cases. |
| Transactions | Commit, rollback, savepoints, original exception preservation after unfinished rows, nesting, read-committed visibility, lock timeout, deadlock and reuse, MariaDB DDL implicit commit |
| Failures and cancellation | Unread-result guard, reset with pending rows, timeout before metadata, server-side query kill, peer disconnect, TCP and TLS asynchronous cancellation |
| Binlog and CDC | Live insert, synthetic single/multiple/reused table maps, table-ID mismatch, damaged checksum rejection, total decoding of MariaDB event IDs 160–171. GTID resume and durable acknowledgement controls are explicit unsupported inventory entries. |

The new harness has **313 entries**: 300 executable checks, 11 explicit missing-API inventory entries and two environment inventory entries. The inherited suites add **179 unit/property cases** and **32 integration cases**, run without editing their test code. The inherited unit suite retains one ignored external HTTPS test; the new suite exercises MariaDB TLS directly. Seeded QuickCheck checks run 100 examples per property. The runner's own eight unit checks verify regression classification and percentile calculation.

Inventory entries are not counted as passing tests. At this baseline, native bulk execution, prepared metadata caching, extended metadata/session tracking, connection reset, progress callbacks, cursor fetch, long-data upload, transport compression, GTID resume and durable CDC acknowledgement controls have no public implementation to invoke. Their absence is retained as `UNSUPPORTED`, including in the benchmark inventory where applicable.

PAM and GSSAPI have no configured OS/realm login fixtures on this Mac. The Homebrew PAM helper could not acquire root ownership during installation, and there is no Kerberos realm/keytab. They are `ENVIRONMENT_UNAVAILABLE`. Platform-specific Windows authentication/transports require a Windows test profile; this Mac run makes no claim about them.

## Performance coverage

| Workload | Timing unit and validation | Control |
| --- | --- | --- |
| Text/prepared SELECT 1 | One query; 500 measured queries/process; checksum 1 each | C text |
| Narrow scans | 10,000 rows with two BIGINTs and one 128-byte ASCII payload; text/prepared/vector, TCP/TLS/socket | C text TCP |
| Wide scans | 10,000 rows with two BIGINTs and 30 payload columns; text/prepared | C text |
| Independent readers | 4/16 connections, each streaming the narrow dataset; connections established before timing | Haskell only |
| INSERT transactions | 1,000 rows, sequential text/prepared or semicolon batch; same TRUNCATE/BEGIN/inserts/COMMIT/count/sum work | C text and semicolon batch |
| BLOB reads | 1 MiB value per query, text/prepared; checksum equals byte length | C text |
| Decoder microbenchmarks | 100,000 text/binary rows with varying integers and a 128-byte payload; actual driver decoders and consumption | Haskell only |
| Native bulk/metadata cache | Explicit `UNSUPPORTED` until APIs exist; no substitute workload presented as equivalent | None |

There are **18 runnable Haskell workloads and six matching C controls**, plus two unsupported native-feature entries. The frozen run uses seven independently started processes per workload, each with two warm-ups. Execution order is deterministically shuffled per repetition to interleave clients. C uses MariaDB Connector/C, not a MySQL server/client compatibility target.

Raw operation samples provide p50/p95/p99 latency. Throughput is normalized by rows, BLOB bytes or decoder rows; the summary labels it ns/unit. Allocation, GC CPU and live-heap counters come from GHC RTS and are not compared to nonexistent C heap counters. Both clients verify numeric/text-byte consumption and insert count/sum. No client silently discards result payloads to inflate throughput.

## Additional environment profiles

The captured profile is one real server/OS/compiler combination. The `MB_*` connection configuration supports another prepared MariaDB instance, but its packet limit, row binlog, TLS and authentication fixtures must satisfy preflight. Capture separate baselines for a rolling release or another maintained LTS, Linux/Windows, WAN latency, compression or a different durability configuration. Compare correctness across profiles; compare performance only within matching recorded environments.

Server optimizer correctness, storage-engine internals, Galera failover, backup/recovery tools and exhaustive SQL grammar/function combinations are outside this driver's baseline. SQL pass-through is exercised by representative MariaDB features; it does not need a driver wrapper for each server function. The unsupported/environment inventory prevents those gaps being mistaken for completed validation.
