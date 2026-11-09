# MariaDB validation coverage

The initial baseline targets the installed MariaDB **12.3.3 LTS** server and GHC **9.10.3** on macOS arm64, using unchanged driver source from upstream commit `92a94012bc553a672c73d409dad1d17e9db1e53f`. Current implementation results describe the fingerprinted source separately. The suite checks the driver surfaces below; assertions describe correct behavior rather than adapting expected values to current defects.

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

The initial harness has **313 entries**: 300 executable checks, 11 explicit missing-API inventory entries and two environment inventory entries. The inherited suites add **179 unit/property cases** and **32 integration cases**, run without editing their test code. The inherited unit suite retains one ignored external HTTPS test; the new suite exercises MariaDB TLS directly. Seeded QuickCheck checks run 100 examples per property. The runner's own eight unit checks verify regression classification and percentile calculation.

Inventory entries are not counted as passing tests. At this baseline, native bulk execution, prepared metadata caching, extended metadata/session tracking, connection reset, progress callbacks, cursor fetch, long-data upload, transport compression, GTID resume and durable CDC acknowledgement controls have no public implementation to invoke. Their absence is retained as `UNSUPPORTED`, including in the benchmark inventory where applicable.

Stage 1 adds **88 executable cases** separately from the frozen 300: real lost-COMMIT-acknowledgement/fragmenting/disconnecting proxies; actual command counts; pre-body continuation limits; malformed metadata/OK/rows; ownership, stale streams and transaction leases; bounded cleanup and new cancellation; unknown-context refresh, raw/prepared tracking replacement, selection preservation, unknown tracker items and both terminator modes; generation-safe command handoff, terminal close transitions, comment-ended batches, cancellation in transport cleanup, replication setup retirement, strict session snapshots and fractional-TIME bounds; executable-comment tracking invalidation, server-prepared lexer parity, optional batch delimiters and bounded startup facts; charset binding and strict decoding; raw dates; Word64 boundaries; injection/quote/comment/mode/batch cases. The Stage 1 run has 403 records including the same 13 inventory entries and two inherited suite summaries. Assertions and original workloads are preserved. The eight original runner-policy tests, fifteen publication tests, twenty-two acceptance/reference tests and six wrapper-failure tests run independently of MariaDB.

The separate memory experiments measure live heap at GC checkpoints across 10,000 and 1,000,000 rows, plus one retained byte after a 16 MiB result. They supplement process high-water statistics and do not change any frozen throughput benchmark. Exact current outcomes and open investigations are recorded in the live report and [implementation notes](../docs/STAGE1_IMPLEMENTATION_NOTES.md).

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

## Stage 2 native connections

Stage 2 adds 30 executable cases without changing the frozen 300 or Stage 1's 88 cases. Coverage includes both capability words and exact client extension offsets; server-offered flag intersection; the independent MariaDB ed25519 signing vector; binary/terminated challenges; unknown plugins and bounded switches; PARSEC salt and work limits; malformed SHA-2 continuations and RSA inputs; real SNI with explicit opt-out; greeting deadlines and cancellation with peer-observed closure; and wrong-password rejection across three plugins and transports. All 14 original native-connection targets are required separately, and every published Stage 1 PASS is protected. There are 59 Python policy tests, including installed-data selection/failure paths and Linux/CI/reference fingerprints.

The isolated Linux profile uses real MariaDB 12.3.3, GHC 9.4.7 and Cabal 3.14.1.1. It runs all correctness checks and both inherited suites, with no cross-platform timing comparison. The macOS profile retains the original GHC 9.10.3/Cabal 3.16.1.0 benchmark comparison. See [Stage 2 evidence](../docs/STAGE2_IMPLEMENTATION.md). Windows and other server versions require additional profiles.

## Stage 3 native statements

Stage 3 adds 56 cases for complete prepared/OUT results, managed generations and
cleanup, malformed/omitted/refreshed metadata, aggregate cache budgets, owned
metadata buffers, native type attributes, bulk indicators/types/limits/encoding,
full unsigned IDs, scalar/NULL parity, 16 MiB fragmentation, transaction rollback
and observed wire command counts. The original assertions and all earlier
stage assertions are preserved. Bulk, cache and extended-metadata inventory
entries now execute real server checks. A MariaDB session counter independently
proves metadata omission. The timeout's conflicting original expectation remains
visible, with safe-retirement regressions retained. Six review regressions add
buffered statement/rollback deadlines, asynchronous cleanup cancellation,
incremental accounting through replacement/rejection/close/ID reuse, released
metadata budgets and valid bulk execution with `maxBound` resource limits.

There are 101 Python policy tests, including native record identity, checksums,
units, repetition/summary consistency, immutable-reference matching and wrapper
failure/interruption/publication behavior. Review additions cover required
baseline artifacts, recomputed publication deltas/alarms, dependency JSON
round-trips, workload versus policy changes and zero-allocation rejection.
Every complete run adds eight native
benchmark profiles to the 24 frozen runnable profiles. Native comparisons use
the same current build's alternatives and a separate immutable first native
capture; the original benchmark workloads and recorder are unchanged. Linux
also checks all eight native benchmark paths as correctness smoke runs.

## Stage 4: clean-session reuse and observations

Additive cases exercise initial snapshots, schema/variable/status and transaction
trackers, wire ordering, unknown kinds, repeated deltas, retained-byte ownership,
length/count/cumulative budgets, subscription replacement, disabled tracking and
error invalidation. Latest real envelopes remain observable after opaque SQL,
while final-state facts become explicitly unknown. Snapshot reads issue no SQL.

Reset checks cover TCP/TLS/sockets, same-session identity, rollback, server defaults,
charset and database restoration, user variables, temporary tables, advisory locks,
transaction-tracker reset, custom initialization, stale handles and raw IDs, repeated
metadata release, pending results, transaction ownership, unsupported versions,
no-database restoration limits, malformed/ERR replies, wire/restoration/buffered
deadlines, cancellation, exclusive initialization and a concurrent close.
The original session-tracking and reset capability inventory entries now run
actual server checks. CDC defects and the original timeout conflict remain visible.

Seven new profiles measure complete reset/restoration/preparation requests versus
equivalent reconnect requests on three transports, plus repeated snapshot reads.
Both alternatives check returned values and absence of preceding request state.
The first reuse reference is separate from both earlier immutable baselines; all
39 runnable profiles (24 frozen, eight native and seven reuse) have seven process
repetitions in a full run. Frozen benchmark source and enumeration stay unchanged.

Stage 4 review fixes add 16 regressions (69 Stage 4 cases total). They cover
initially absent and configured default roles; Unicode/quoted role names, latin1
clients, initializer role overrides, preservation across explicit refresh, role
restoration before database access, all transports and disabled tracking; role
restoration ERR/deadline and bounded snapshots; charset/collation alias ordering,
explicit selection and released cache budgets; and CHARACTERISTICS-to-STATE
transitions across different transactions. Role fixtures use separate reserved
accounts and leave the ordinary benchmark account's default role unchanged.

Two further role regressions (71 Stage 4 cases total) cover exact binary role
identity when a latin1 result charset collapses distinct Unicode names, temporary
UTF-8 restoration with the original narrow charset restored afterward, and binary
result settings. A third dedicated role account and two Unicode roles provide
these fixtures; provisioning remains separate from the benchmark account.

## Stage 5 CDC

83 additive cases and both converted inventory entries cover total event IDs,
known/checksummed/truncated packets, exact event lengths, owned optional TLVs,
interleaved/repeated/replaced/stale maps and budgets, bitmap boundaries and sparse
NULL/omitted fields, complete/incomplete/standalone/rollback/multidomain GTIDs,
overflow and checkpoint origin, backpressure, compressed queries/rows, fragmented
rows, foreign/backwards/idempotent ACKs, ACK cancellation, decode retirement and
ownership. Real disposable servers test actual semisync wait/release, CRC-mode
changes, rotation, DDL/minimal images and persisted-data server restart followed
by GTID resume. The managed-server fixture also tests GTID resume and cancellation.

Eight new benchmark profiles preserve all 39 previous profiles. They check actual
row values and separate pure decoding, framing/CRC, live delivery/checkpoints and
retention timing. The million-row streaming workload records post-major-GC live
heap at four checkpoints in both warmups and the measured region. Advanced XA
checkpointing and storage-engine-binlog GTID semisync are explicitly unsupported
by the transaction-aware API; new non-ignorable events fail closed.

The follow-up review adds 58 regressions (141 Stage 5 cases total): every temporal
fractional precision, negative whole/subsecond times, malformed fractions, full
GTID history after domain-origin changes, history flags/entry bounds, GTID header
and extension truncation, two-phase ALTER rejection, actual sparse-value budgets,
preserved row/value limits, `maxBound` event budgets and early continuation
rejection, and large queries with control-keyword prefixes. Disposable real servers reproduce temporal values, origin changes
across rotation and two-phase ALTER. The correctness ratchet protects all 636
published Stage 5 passes; the benchmark workloads and first captures are unchanged.

## Stage 6: streamed parameters, cursors, progress and compression

The four remaining API inventory rows now execute real feature checks. Added
coverage includes one-shot upload arity/ownership, empty non-NULL values,
byte/text charset parity, bounded chunks and cumulative budgets, source failure,
cancellation, later ordinary execution and complete procedure/OUT results.
Cursor checks cover incremental batches, final empty fetches, close/reset,
ownership, legacy/cached metadata, NULL/Unicode/DECIMAL parity and transaction
cleanup. Progress checks cover the literal MariaDB envelope, malformed fields,
callback reentry/failure/cancellation and real ALTER callbacks. Compression
checks cover raw/zlib frames, byte splits, sequence/length/expansion/trailer
errors, pre-body bounds, TCP/TLS/socket setup, 16 MiB logical continuations and
combined feature use. Transparent byte counters verify actual wire savings.
All 694 previously published passes are protected independently.

Thirteen new seven-repetition profiles measure uploads, cursor batch sizes,
narrow/wide compressed transfers and progress negotiation costs. Their separate
first reference preserves all earlier baselines. Linux smoke runs exercise every
new benchmark path without comparing its timings to Mac measurements. PAM/GSSAPI
and the retained timeout-contract conflict remain explicit.

Review-fix correctness on 9 November records **793 PASS / 1 known FAIL /
0 UNSUPPORTED / 2 unavailable** on both Mac and Linux. All 95 Stage 6 cases and
155 policy tests pass. Seven new regressions cover repeated cancellation of both
cursor brackets, compressed semisync manual/legacy on-read ACKs over three
transactions, reconnect/resume, preservation of incoming buffers across ACKs,
and rejection of whole-source buffering by the actual retained-heap guard.
The producer allocates fresh storage per chunk and the guard checks every
checkpoint. Two full captures measure all 60 profiles seven times; the second
supplied the review report. The independent first wire-feature reference and
all earlier references remain immutable. Timing investigations remain explicit.
See the [current confirmation manifest](results/stage6-confirmation.json).


The [committed publication](results/stage6-publication.json) now supplies the
[live report](RESULTS.md), preserving the same correctness counts and all 95
Stage 6 passes. All 60 profiles have seven repetitions; timing alarms stay
explicit and no reference advances.


## Stage 7: external authentication and timeout-contract correction

The two former environment inventory entries now run actual PAM and Kerberos
logins from the Haskell client. Forty-eight additional cases cover dialog
prompt kinds/rounds, optional terminators, empty plugin-switch acknowledgement,
continuation envelopes, response/prompt/token bounds, embedded NUL rejection,
secure transport and explicit opt-in, callback exceptions/deadlines, premature
or disguised terminal OKs, principal pinning, mechanisms, wrong credentials,
second factors, wrong Kerberos identity, missing caches, TLS GSSAPI, repeated
native-context cleanup and cancellation before the server's mutual token.
A separate compiled non-threaded client proves that the runtime guard rejects
GSSAPI before native credential access.

Mac and exact-source Linux correctness record **844 PASS / 0 FAIL /
0 UNSUPPORTED / 0 unavailable**; all 793 published passes are preserved. All 173
policy tests pass. Linux smoke-tests all 39 additive benchmark paths. Complete
Mac runs measure 63 profiles seven times, including three new external-authentication
setup paths. The immutable first authentication reference is separate from all
previous references.

The timeout case is an approved test-contract correction, with explicit
retirement/rejection/fresh-connection assertions. Its original baseline/failure
history is preserved and it is excluded from the driver-improvement list. These
records cover the Mac/Linux client and isolated authentication services; they do
not configure host OS accounts or certify Windows SSPI or every PAM module/realm.
See [Stage 7](../docs/STAGE7_IMPLEMENTATION.md).


The 11 Stage 7 review regressions cover wrapped/initial ERR-shaped plugin data,
malformed terminal OK/ERR redaction, preservation of actual server ERR and callback
exceptions, oversized clear-password challenges before credential callbacks,
header-only initial/continuation limits, smaller caller budgets and full query
budgets after authentication. Eight added policy tests cover partial-failure
classification/interruption, selective fixture setup, source-inventory routing,
private configuration, failed/interrupted container starts, diagnostic failures
and ownership collisions. See the [resolved review](../docs/STAGE7_CODE_REVIEW.md).
