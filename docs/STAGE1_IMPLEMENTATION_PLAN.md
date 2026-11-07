# Stage 1: a dependable and efficient MariaDB query core

**Version 2 — approved for implementation, night of 6–7 November 2026**

**Reviewed: 6 November 2026**

**Starting repository revision: `90f4f54ce17d8336011f0193326819563acd29df`**

Stage 1 will make ordinary queries, streaming results and transactions reliable while keeping the query path efficient. Each operation must produce accurate values and a synchronized connection, or clearly retire the connection. It also establishes the measurement and ownership rules needed for later bulk execution, metadata caching and pooling.

Anton approved implementation of Version 2, with the later instruction to implement, repeatedly check/fix, run the full suite and benchmarks, update the results locally, and leave every change uncommitted for morning review. That instruction supersedes the commit/push steps below during this run. No release or Stage 2 work is included.

Read the [review findings](STAGE1_PLAN_REVIEW.md) for the errors corrected in the first draft and their source evidence.

## What changed after review

1. **Remove routine extra round trips and their SQL side effects.** Use server status for transaction entry and tracked context for ordinary repeated parameterized queries. An uncertain rendering context requires an explicit refresh, rather than a hidden SELECT that changes `ROW_COUNT()`. Measure initialization separately.
2. **Bring forward the protocol support that makes this possible.** Implement negotiated session tracking and OK result terminators, including prepared and multi-result paths. Retain a tested legacy EOF path.
3. **Make performance an acceptance condition.** Add a 5% investigation gate alongside the unchanged original 20% alarm, check allocation and streaming memory, and implement a bounded decoder/buffer optimization pass.
4. **Protect improvements already achieved.** Compare correctness against both the original baseline and the last accepted implementation, so an originally failing case cannot quietly regress after being fixed.
5. **Preserve batch semantics.** Keep supported batches as one server command. Reject ambiguous parameterized batches before execution instead of silently converting them into separate commands.
6. **Close lifecycle gaps.** Reserve the connection throughout a transaction helper, distinguish validation errors from interrupted I/O, and state the limits of raw statement IDs honestly.
7. **Use explicit resource policies.** Replace the Mac fixture’s arbitrary 384 MiB default with configurable 64 MiB logical messages and a separate metadata budget. Include the existing column-definition round-trip defect, increasing the original-failure target from 22 to 23.

## Decisions included in approval

| Decision | Proposed contract |
| --- | --- |
| Interrupted or damaged protocol exchange | Retire and abort the connection when synchronization is uncertain. Never reconnect or replay SQL automatically. |
| Application failure with an intact unread response | Drain and roll back within one configurable cleanup deadline; preserve the original exception. Abort if cleanup cannot complete. |
| Transaction ownership | One helper owns the connection for its entire body. Reject another thread’s commands and nested helpers before sending SQL. Explicit SQL savepoints remain available. |
| Lost COMMIT acknowledgement | Report unknown outcome; do not retry. Preserve asynchronous cancellation identity and record outcome uncertainty in diagnostics. |
| Public OK fields | Change affected rows and last insert ID from `Int` to `Word64`. |
| Low-level connection construction | Replace the exposed old record constructor with shared smart construction. `Base.MySQLConn` remains abstract. Document low-level caller migration. |
| Raw dates | Add exact date-component value constructors for zero, partial-zero and invalid calendar dates. Keep normal `Day`/`LocalTime` constructors. |
| Default encoding | Use `utf8mb4_unicode_ci` for both default connect settings. Preserve explicitly selected encodings. |
| Parameter rendering | Introduce checked, explicit `RenderContext` rendering, including a source migration for custom `QueryParam` instances. Keep connected query call signatures. An unknown context produces `SessionContextUnavailable`; explicit refresh or prepared binding remains available. |
| Protocol negotiation | Add internal session tracking and OK result terminators now. Negotiate only implemented capabilities offered by MariaDB. |
| Client limits | Defaults: 64 MiB per logical message, 16 MiB aggregate metadata per result, 65,535 columns, one second for the whole cleanup sequence. Options variants cover TCP, Unix and TLS without adding required `ConnectInfo` fields. |
| Performance | Investigate repeatable timing or allocation increases above 5%; unresolved material costs require Anton’s decision. Do not weaken original benchmark alarms. |
| Publication | Preserve the original reference. Publish each accepted implementation batch and its current measured report together on `main`. |

The intentional cancellation policy does not satisfy the existing test that requires reuse after an interrupted response. That original failure remains visible. New tests must prove safe retirement, exception propagation and successful explicit reconnection without claiming recovery on the old connection.

## Starting evidence and success target

The [live report](../validation/RESULTS.md) contains a complete run recorded at `2026-11-06T21:57:01.429300+00:00`, testing code revision `3b45fd34276b2ceffec5da6abb7bcb2a6c6571ec`. The following result-publication commit is the current `main`. Driver source still matches original revision `92a94012bc553a672c73d409dad1d17e9db1e53f`.

| Record | Starting result |
| --- | ---: |
| Original new executable correctness checks | 244 PASS / 56 FAIL, across 300 checks |
| Missing public API inventory | 11 UNSUPPORTED |
| Environment inventory | 2 ENVIRONMENT_UNAVAILABLE |
| Inherited suites | Both PASS: 179 unit/property cases, with one inherited ignore, and 32 integration cases |
| Runnable benchmark profiles | 18 Haskell workloads and 6 Connector/C controls; seven repetitions each |
| Latest original-baseline comparison | No regression signals; no newly passing cases |

The target is to convert **23 identified original failures** to passes, preserve all previous passes, and pass every new Stage 1 case. Those 23 improvements alone would produce **267 PASS / 33 FAIL** among the original 300 checks. This is a target, not a measured outcome. Additional tests and the two inherited suite aggregate records have separate counts.

The reference environment is the existing managed MariaDB **12.3.3** installation on this Mac, GHC 9.10.3, the pinned dependency plan and existing server configuration. Server source inspection uses the checked-out MariaDB 13.2-alpha source; it does not establish runtime compatibility with an untested server version. Retain the MariaDB CI environment as an additional correctness profile, identify its actual version, and retain compiler/OS build coverage. Do not compare its timing with this Mac.

Current measurements also identify useful optimization targets:

| Haskell workload | Current median | Current median allocation per unit |
| --- | ---: | ---: |
| Narrow text scan | 315.68 ns/row | 2,831.95 bytes/row |
| Wide text scan | 2,831.53 ns/row | 30,532.35 bytes/row |
| Wide prepared scan | 2,399.67 ns/row | 24,468.35 bytes/row |
| Text decoder microbenchmark | 318.24 ns/row | 2,952.02 bytes/row |
| Binary decoder microbenchmark | 245.36 ns/row | 2,048.02 bytes/row |

These are observations from the current JSON, not forecasts. Allocations include the existing workload’s measured region. They justify profiling and reducing repeated dispatch, parsing and copying; they do not establish how much improvement is achievable.

## Scope boundaries

Stage 1 includes physical/logical framing, result terminators, bounded internal session tracking, connection/result ownership, transport cleanup, transaction safety, statement reset/close guards, exact numeric and temporal values, charset decoding, parameter lexing/rendering and focused query-path optimization.

Defer native bulk execution, metadata reuse across executions, prepared OUT parameters, new authentication plugins, native extension negotiation beyond the two required ordinary capability bits, compression, cursors, long-data upload, connection reset, pooling, CDC correctness and package/module renaming. Also defer localhost fallback, installed CA packaging and a mutual-TLS helper. Preserve all existing passes in those areas and keep their failures visible.

Session tracking in this stage is an internal correctness/performance mechanism, not a public session migration or complete tracking API. Missing public-API inventory entries remain accurately described. Replication receives only the lifecycle integration needed to keep it working; ordinary result-terminator rules must not be imposed on binlog exchanges indiscriminately.

Remove the inherited MySQL 8 server CI target. Preserve wire identifiers and names used by MariaDB itself and the upstream attribution.

## Architecture contracts

### 1. Framing, terminators and resource limits

Separate physical packet framing, logical message assembly and command-response interpretation. Check the exchange sequence across writes, replies, continuations and modulo-256 wrap. A fragment of `0xFFFFFF` bytes requires a following fragment; an exact multiple ends with an empty fragment. Preserve chunks and stored lengths rather than repeatedly concatenating or rescanning the whole message. [Packet specification](https://mariadb.com/docs/server/reference/clientserver-protocol/0-packet)

Classify using response phase, negotiated capabilities, header and validated length. In legacy mode, `0xFE` alone is not EOF; validate the short EOF structure. In negotiated OK-terminator mode, parse the correct OK format, allow its session payload, and distinguish it from a large text row. Binary row header `0x00` is not a command OK in row phase. Test metadata terminator omission and the actual prepared-statement layouts, not just text SELECT. [Result-set specification](https://mariadb.com/docs/server/reference/clientserver-protocol/4-server-response-packets/result-set-packets)

Do not advertise `CLIENT_SESSION_TRACK` or `CLIENT_DEPRECATE_EOF` until their live decoders and all affected response paths exist. Negotiate the intersection with server capabilities. Legacy EOF remains independently tested. Authentication and replication retain their own phase/sequence rules; semi-sync acknowledgement writes remain under the replication owner.

All packet predicates must be total on empty input. Use checked unsigned length accumulation and convert to `Int` only after bounds checks. Reject NULL length markers where a non-null counter is required. Live fixed-format decoders must consume the specified structure completely; explicitly parse or allow negotiated trailers instead of globally rejecting valid protocol extensions.

The 64 MiB default logical limit permits all existing large-row cases, including 33,554,430 bytes, and avoids treating the validation server’s 384 MiB setting as a product default. Larger legitimate messages require an explicit option; test a raised limit as well as rejection. Advertise the client receive limit consistently in ordinary and TLS handshakes. Validate configured values against representable lengths before opening a socket. Check outgoing encoded size before any target command bytes are written; use the server’s session packet limit when known, without a per-command discovery query.

Enforce the separate aggregate metadata budget before allocating a vector from an untrusted column count. Check cumulative bytes while reading metadata. Limits do not preallocate their maximum and do not claim to bound all decoded heap overhead. Ordinary rows remain streamed; result cardinality must not cause retention of the entire result. An over-limit incoming exchange is retired rather than left partially consumed and reusable.

Fix `ColumnDef` serialization’s missing fixed-length marker and validate its actual structure. Synthetic transcripts must be checked against independent byte fixtures or real server captures; a broken encoder and decoder must not validate each other accidentally.

### 2. Connection and stream ownership

Replace `isConsumed :: IORef Bool` with explicit internal response state and an atomic command claim.

| State | Permitted activity | Completion |
| --- | --- | --- |
| Ready | Claim a command, subject to any transaction lease, or close | Ready |
| Executing | The owner sends SQL and consumes response metadata | Terminal reply or Streaming |
| Streaming | The owning consumer reads rows and all later results | Ready only after final response |
| Replicating | Dedicated binlog consumption and required acknowledgement writes | Close |
| Broken | Inspect failure information or close | Explicit new connection |
| Closed | Idempotent close/status inspection | Explicit new connection |

Track metadata, rows, later results and commit phases internally. Claim before writing bytes. Reject a concurrent command immediately; do not introduce a global lock or a queue that silently serializes accidental misuse. Different connections remain independent and retain parallel throughput. Distinguish logical operation ownership from wire phase: explicit refresh and transaction entry may perform controlled internal exchanges under one lease, without recursively claiming the public command API. Internal query helpers carry the caller's context effect; a parameterized API must not accidentally invalidate its cache merely by delegating to a raw public wrapper.

Streams have a generation token. A stale unfinished stream cannot read another command’s reply; an already completed stream keeps returning end-of-stream. Concurrent reads of one stream are rejected. The enforcement must cover actual I/O ownership, not just two reads of a shared Boolean. Keep checks at command and stream/I/O boundaries, not once per field. Benchmark the chosen mechanism; do not add per-cell synchronization or unconditional per-row diagnostic allocation.

A transaction lease spans entry, body and completion, including intervals when the response state is Ready. Commands from its owner are permitted; another thread’s commands are rejected. Nested helper entry is rejected locally, even if the outer body explicitly committed. Moving work to another thread requires a separately designed API and is outside this stage.

Use short masked state transitions and restore interruptibility for blocking I/O. A new exception before any command bytes are sent releases a clean claim. Once a read/write starts, an exception with uncertain framing retires the connection. Do not identify cancellation solely through `SomeAsyncException`: timeout implementations can use other exception types. Preserve the original thrown exception object through catch/rethrow paths.

Consume complete terminal ERR responses before allowing reuse. Preserve `ExtraResultSets` behavior by draining later results before reporting that the chosen API could not return them. A `Field` conversion failure on an already returned value is an application conversion error; it does not retroactively corrupt a synchronized connection. Force transport-level decoding at the guarded boundary so malformed values do not escape as surprising delayed exceptions.

Expose read-only connection status/failure diagnostics. Store phases, outcome uncertainty and bounded secondary cleanup information. Do not retain full SQL, parameter payloads or credentials in long-lived error records. Closing invalidates streams and releases the underlying transport exactly once, including connect/authentication/initialization failure paths. Closing an active/unread connection aborts directly; it must not wait for a command owner's state lock before it can interrupt blocked I/O.

### 3. Session state without routine query probes

Keep authoritative transaction/autocommit/escape status from every final OK/EOF, including later results and server-killed ERR completion handling. Use final status, not a transient metadata packet, for decisions about a completed command. An ERR without transaction status makes that fact unknown; a later authoritative status or an explicit refresh resolves it.

On capable MariaDB servers, negotiate session tracking with OK result terminators. Track `sql_mode`, client/connection/results charsets and connection collation, plus the tracking configuration required to know whether the cache is usable. Read server version once. Preserve existing session tracker selections: extend the **session** list, retaining `*` and proxy-installed entries, rather than replacing it from global defaults. Do not enable tracking every variable merely for convenience. Consume and safely skip unknown length-delimited tracking items. [OK/session payload specification](https://mariadb.com/docs/server/reference/clientserver-protocol/4-server-response-packets/ok_packet), [tracking variables](https://mariadb.com/docs/server/server-management/variables-and-modes/server-system-variables)

Initialize a validated context during connection setup, with at most one configuration exchange plus one snapshot exchange in the normal path. Capture the actual final context after setup. Measure that startup cost explicitly: existing benchmarks exclude connection establishment. Do not change application SQL mode to simplify the driver.

Represent cache validity explicitly: known snapshot with an epoch, or unknown. Ordinary repeated parameterized queries, and ordinary raw SQL covered by verified tracking, use that snapshot and tracking deltas without an added SELECT. `executeMany` compiles its template once and renders all parameter sets against one validated context when the template is supported for batching.

Do not assume tracking makes every arbitrary SQL string safe. Invalidate rendering context after an ERR, opaque stored-routine/dynamic execution, unsupported state changes or changed tracking configuration when final state cannot be proved. For raw constructs whose effects are not covered by the verified tracking contract, invalidate conservatively; ordinary tracked SET NAMES/SQL-mode changes must update the context correctly. Unrecognized parameterized statements can execute as a single command but invalidate context afterward; recognized ordinary stable templates retain the fast path. Classification may conservatively declare uncertainty, but must not claim a SQL prefix proves absence of session side effects.

Do not hide discovery SQL between application statements: it can change the preceding-statement value observed through `ROW_COUNT()` and other session information. If rendering context is unknown, reject text binding with `SessionContextUnavailable` before sending the target SQL. The caller may explicitly invoke `refreshSessionState`, or use raw/prepared APIs that do not need text rendering. Document the refresh's observable SQL effects. Initial setup occurs before application statements. A transaction-entry probe remains permissible when needed because BEGIN itself already changes preceding-statement semantics. Test `ROW_COUNT()`, `FOUND_ROWS()` and diagnostics behavior rather than assuming every form of session information has identical reset rules. [ROW_COUNT semantics](https://mariadb.com/docs/server/reference/sql-functions/secondary-functions/information-functions/row_count)

Driver-maintained tracking settings are internal invariants. Explicit refresh verifies/restores required selections while preserving unrelated session selections. Document that bypassing the driver's transport or mutating tracking settings without invalidating its context is unsupported. Legacy servers or disabled negotiated support use an explicitly refreshed context conservatively and invalidate it when its continued accuracy cannot be established; do not claim the tracked fast path there. Keep the public OK record shape apart from its approved unsigned field changes; internal response envelopes carry tracking data.

Tests must count actual commands: no extra probe before ordinary repeated parameter calls or known-state transaction entry; unknown rendering context fails with no SQL sent; an explicit refresh restores cache reuse. Include mixed raw/parameter calls, raw SET, SET NAMES, CALL, stored-routine errors, changing tracker selections, unknown items and both result-terminator modes. Verify stored-routine temporary/restored modes against real MariaDB, not assumptions about another server. If a legacy fixture lacks tracking, exercise the documented explicit-context path rather than silently weakening a supported-server assertion.

### 4. Cancellation, cleanup and transactions

| Event | Behavior |
| --- | --- |
| Start a command/reset/close-statement with unread results | Reject before sending bytes; the existing response remains consumable. |
| Pure validation/rendering error before send | Return the error; retain a clean reusable connection. |
| Interrupted/failed I/O with uncertain response boundary | Broken; direct transport abort; rethrow the original exception. |
| Complete query-killed ERR | Finish the response; reuse is allowed if the final boundary is known. |
| Application exception with an intact partial transaction result | Drain all remaining results and roll back under one absolute cleanup deadline; rethrow the original exception. |
| Cleanup fails/expires | Abort; retain secondary diagnostics; rethrow the original application exception. |
| New cancellation during cleanup | Abort and propagate that cancellation; retain earlier failure as diagnostic context. |
| Close | Invalidate state; bounded best-effort QUIT/TLS shutdown on a clean connection; always release the transport. |

The default one-second cleanup budget is configurable and applies to the entire drain plus rollback, not each packet. Use a monotonic deadline. A slow or trickling peer cannot extend it indefinitely. Avoid unbounded `uninterruptibleMask`, unbounded helper threads or waiting for a COM_QUIT reply. Direct abort must not perform a blocking graceful TLS exchange. Test Unix, TCP and TLS, including cancellation while acquiring/releasing ownership and initialization failure.

`withTransaction` uses known final `IN_TRANS` state to reject an active manual transaction. Probe `@@in_transaction` only if that fact is unknown, under the transaction lease. Never send a second BEGIN merely to test whether nesting exists: MariaDB can implicitly commit the active transaction. [Transaction semantics](https://mariadb.com/docs/server/reference/sql-statements/transactions/start-transaction)

A body that returns while results remain unread fails with `UnconsumedResultSet`; bounded drain/rollback follows, and no COMMIT is sent. An ordinary application exception with successful cleanup preserves the session and temporary tables, satisfying the original test. Uncertain I/O instead retires the session. A caught nested-helper rejection must allow the outer transaction to continue safely.

For COMMIT, distinguish failure before sending from uncertain outcome after sending. A synchronous missing acknowledgement after possible transmission produces `CommitOutcomeUnknown`; asynchronous cancellation remains the original exception and records commit uncertainty separately. Never replay a command. An independent connection may prove what happened in a fault test, but does not change what the original client could know.

Keep explicit DDL, COMMIT, savepoints and autocommit changes subject to MariaDB’s semantics. Document that the helper cannot undo server-side implicit commits and does not promise atomicity for nontransactional tables. Test these boundaries rather than silently rewriting SQL.

Reset must consume and validate its own reply. Statement close has no reply to wait for. Preserve the raw statement-ID API; maintain useful local open/closed bookkeeping where possible, but do not promise generation-safe stale-handle detection after a server ID is reused. That requires a typed prepared handle, deferred to a later stage. Unread-response guards apply regardless of statement identity.

### 5. Exact values and decoding

Use a checked, non-nullable `Word64` path for OK counters and IDs. Keep lengths/counts that drive allocation separate. Update serializers and callers together. Numeric text parsing must consume the entire field and check signed/unsigned width, including MEDIUMINT’s actual range, before conversion. Use a bounded one-pass accumulator on hot paths rather than parsing every ordinary integer through `String` or arbitrary-precision `Integer`.

Add `DateParts` and proposed `MySQLDateRaw`, `MySQLDateTimeRaw` and `MySQLTimeStampRaw` constructors. Preserve zero, partial-zero and invalid calendar dates accepted under MariaDB modes; use normal constructors for representable dates. Share text/binary preservation rules and encode raw forms through both binding paths. `Field Day`/`Field LocalTime` return checked errors for unrepresentable values and never clip/normalize them. [DATE behavior](https://mariadb.com/docs/server/reference/data-types/date-and-time-data-types/date)

Validate separators, payload lengths, precision and ranges without losing fractional seconds. Distinguish calendar time from MariaDB TIME duration: TIME legitimately spans negative values and hours up to 838, whereas DATETIME’s clock does not. Preserve the existing timestamp/session-timezone distinction and use exact microsecond boundaries in tests.

Decode text according to each column’s collation metadata, not just the connection default. Implement strict UTF-8 and MariaDB latin1 using the checked-out cp1252 mapping, including extended/control bytes. Binary columns remain bytes. For other unmapped textual charsets, return exact `MySQLBytes` with the existing `ColumnDef` metadata; document that `Field Text` requires a supported text decoding and must not guess. Unknown collations must not silently fall through to UTF-8. Preserve explicit session charset choices and reject unencodable bound text. [Charset reference](https://mariadb.com/docs/server/reference/data-types/string-data-types/character-sets/supported-character-sets-and-collations)

Resolve stable field type, unsignedness, charset and decimal handling once per result where measurement supports it. A compact decoder plan can serve every row in that result. It must not reuse metadata across later executions or ignore reprepare/changed metadata. Keep list/vector and text/binary paths behaviorally consistent.

### 6. Parameter lexing, rendering and batching

Replace splitting on every `?` with a byte scanner using the validated encoding and SQL mode. Recognize ordinary quotes, doubled delimiters, backslash behavior, backticks, ANSI double quotes, relevant Oracle quoting, `#`, `--` with MariaDB’s whitespace rule, and block/executable comments. Respect version gates and MariaDB’s ignored range for MySQL-style executable comments; those constructs are part of MariaDB’s grammar. Restrict unsupported encodings/quoting with a typed error before sending rather than treating multibyte trail bytes as syntax. [String literal rules](https://mariadb.com/docs/server/reference/sql-structure/sql-language-structure/string-literals), [comment rules](https://mariadb.com/docs/server/reference/sql-statements/comment-syntax)

The proposed pure rendering contract is:

```haskell
class QueryParam a where
    render :: RenderContext -> a -> Either ParameterError Put

renderParams
    :: QueryParam p
    => RenderContext -> Query -> [p] -> Either ParameterError Query
```

Connected APIs obtain the context under their command claim and keep existing call signatures. The context carries modes, encodings, collation and server version. Map arity errors to existing `WrongParamsCount` at the connected boundary. Direct renderer callers and custom instances require the documented migration; there is no unsafe mode-unaware fallback.

Validate arity, syntax, representability and all built-in parameter values before writing the target command. Force the outgoing chunk structure and encoded size, avoiding a whole-payload strict copy. A custom instance is responsible for its SQL-value contract; unexpected rendering exceptions must still occur before the send. Preserve `One`, `Many`, empty `Many` as NULL, NULL, scalars and all original passing cases. Values are not SQL identifiers or arbitrary fragments.

Use quoted rendering appropriate to the context, including `NO_BACKSLASH_ESCAPES`, NUL, quotes and backslashes. Binary values may use unambiguous binary literal encoding, but do not replace every text value with a hex expression without checking collation/coercibility and wire-size costs. Prepared binary binding remains the preferred repeated typed execution path and must not acquire text-rendering probes.

Preserve one-command execution for supported flat batches, including the existing parameterized INSERT/SELECT and two-INSERT `executeMany` tests. Compile the placeholder plan once per batch call; emit a chunked builder without quadratic concatenation or reparsing for every row. Preserve one OK per statement, ordering, first-error stopping and complete draining before `ExtraResultSets`.

The scanner is not a complete SQL interpreter. Document and test a conservative stable flat-template grammar for parameterized batching. SET/CALL/dynamic SQL, compound bodies, opaque routine expressions or other constructs whose later parsing context cannot be established are rejected **before any batch statement executes**. Do not silently split them into separate commands, claim the batch is atomic, or assume INSERT/SELECT prefixes prove safety. Callers can explicitly sequence statements through the existing APIs, with an explicit transaction when appropriate. Raw multi-statement APIs continue passing SQL through and invalidate cached rendering context afterward.

Single-statement parameterized SET/CALL remains supported when its placeholders can be lexed in the current context; tracking/invalidation handles the next command. A no-parameter raw operation is passed through byte-for-byte; any conservative context-effect inspection must not reinterpret or rewrite it.

## Ordered work packages

Implementation remains sequential in this chat. Each package is a coherent measured review boundary, not an excuse to ship incomplete guards.

| Package | Deliverable | Depends on | Size |
| --- | --- | --- | --- |
| 0 | Freeze/check evidence; acceptance ratchet; fault fixtures; supplementary pre-change measurements; MariaDB-only CI cleanup | Approval | Medium |
| 1 | Framing, limits, strict packet boundaries and column-definition fix; decoders for both terminator formats | 0 | Large |
| 2 | Connection/stream ownership, transport cleanup, status cache and negotiated internal session tracking | 1 | Large |
| 3 | Transaction lease/cleanup, statement guards and uncertain-commit reporting | 2 | Large |
| 4 | Exact unsigned/temporal values, charset handling and per-result decoder preparation | 1, 2 | Large |
| 5 | Checked context-aware parameters, stable batching and focused hot-path optimization | 2, 4 | Large |
| 6 | Complete acceptance, source review, migration documentation and final publication | 3–5 | Medium |

Package 0 prepares fixtures; introduce each later package’s behavioral tests immediately before its fix. Record their failures locally before implementation. New-API tests start at the first compiling revision; label that limitation rather than inventing an old-driver result. Main receives completed batches, not tests disabled until a later package.

### Package 0: evidence and instrumentation

Verify the real managed server, frozen checksums, clean source provenance and dependency profile before a fresh unchanged-driver run. Preserve every run, including timing noise.

Add Stage 1 correctness and fake-transport modules through the validation entry point, plus a loopback fault proxy. Use phase barriers, deterministic transcripts and fixed seeds instead of sleeps as the sole evidence of progress. The proxy can fragment/coalesce packets, interrupt selected phases and suppress a COMMIT reply after forwarding it. Keep credentials and parameter payloads out of logs. TLS uses real integration plus transport injection, without weakening certificate validation.

Before implementing the tracking fast path, characterize the real 12.3.3 server's notifications for SET NAMES, SQL-mode changes, partial failures and CALL with intermediate results and restored routine modes. Use MariaDB's native client/Connector-C tracking interface or independently captured protocol fixtures, separate from the frozen C benchmark source. Establish when the context is provably final and when it must be unknown. This feasibility evidence must precede capability enablement; source inspection alone is insufficient.

Implement the additive acceptance ratchet described below without changing the frozen recorder/workloads. Add meaningful policy tests for lost improvements, missing cases, failed runs, unchanged docs-only publications and supplementary evidence provenance. Keep development failures publishable as failures; the ratchet governs acceptance, not whether a report tells the truth.

Capture supplementary old-driver measurements for parameterized SELECT, mixed raw/parameter calls, `executeMany` sizes, transaction-helper overhead, connection setup, streaming heap retention and error paths. New-API-only profiles begin at first implementation and say so. Use a separate supplementary benchmark module/runner, not the original benchmark enumeration or frozen definitions.

Remove `integrated-checks-mysql80` and `pkgs.mysql80` from `nix/ci.nix`, retaining MariaDB and compiler/OS coverage. The existing CI provenance check remains required; do not claim unexecuted Nix/OS jobs passed.

### Packages 1–3: protocol and lifecycle foundation

Implement the contracts above in that order. Land terminator parsers before advertising their capabilities. Migrate every command entry point through ownership, including text/prepared/vector/multi-result APIs, ping, reset/close and the replication adapter. Exercise constructor failure and all transports. Session initialization cannot publish a connection before it is ready or leak a socket on failure.

For the lost COMMIT acknowledgement fixture, prove independently that the row became durable and prove that the client sent no replay; its own outcome still remains unknown. Stress cleanup with a peer that trickles packets and with new cancellation during drain/rollback. A local exception with intact unread data must preserve the existing temporary-table test.

Likely files: `Protocol/Packet.hs`, `Protocol/ColumnDef.hs`, `Protocol/Auth.hs`, `Connection.hs`, `Base.hs`, `TLS.hs`, `BinLog.hs`, `System/IO/Streams/TLS.hs`, small internal ownership/session modules, and the validation additions. Keep low-level compilation migrations separate and documented.

### Packages 4–5: exact data and measured hot paths

Implement value preservation before context-aware rendering so raw dates and charsets can bind correctly. Reuse checked length helpers rather than introducing parallel implementations. Test text/prepared and list/vector parity. Review shared CDC callers for compilation and behavior preservation.

Profile allocation/CPU on the existing narrow/wide scans and decoder workloads. Implement low-risk improvements within the changed paths: one-pass checked numeric parsing, per-result field dispatch/charset resolution, fewer intermediate buffers, one template scan per batch, strict compact state and no normal-path diagnostic construction. Keep fast paths for small ordinary rows; optimizing a wide scan must not silently slow small queries.

Check ByteString slice lifetimes: a tiny returned value must not unexpectedly retain a huge backing packet. Do not copy every field by default; measure retained heap and use a bounded targeted copy policy only where needed. Preserve streaming memory proportional to active row/metadata buffers rather than result cardinality. Keep cache lifetime per result or per batch call; global or unbounded query caches and metadata reuse across executions remain Stage 2.

Use focused before/after experiments against the preceding accepted implementation to establish that each optimization helps. Drop an unsuccessful optimization rather than retaining complexity for an unmeasured future benefit. Safety/value correctness is mandatory; speedup magnitude is measured, not promised.

Likely files: `Protocol/MySQLValue.hs`, `Field.hs`, `Query.hs`, `Protocol/Escape.hs`, connection/session helpers and separate diagnostic modules. Avoid dependency upgrades or library build-option changes for incidental convenience.

### Package 6: review and publication

Review every command owner, final status update, catch/finalizer, length conversion and lazy decoding boundary. Confirm behavior across transports, APIs and result formats. Update migration notes, examples, coverage and the explicit deferred-failure register.

Run final full validation and all supplementary gates on committed executable inputs. Publish the live Markdown, JSON and colored summary; show supplementary timing/ratchet evidence clearly without replacing the original baseline comparison. Provenance CI must pass. Documentation alone does not authorize implementation or count as measured improvement.

## Original failures targeted

Keep original IDs, inputs and success conditions. These 23 original failures must pass:

| Area | Existing IDs | Count |
| --- | --- | ---: |
| Framing/classification | `protocol.continuation-sequence-rejected`, `protocol.large-row-is-not-eof`, `protocol.empty-packet-predicate`, `packets.live-blob-16777216`, `packets.live-blob-16777217`, `packets.live-blob-33554430` | 6 |
| Metadata | `protocol.column-definition-roundtrip` | 1 |
| Lifecycle/transactions | `protocol.reset-does-not-consume-pending-row`, `reliability.reset-unread-result`, `reliability.server-kill-query`, `reliability.tls-cancellation-propagates`, `transaction.partial-result-exception`, `transaction.nested-preserves-outer` | 6 |
| Numeric | `protocol.unsigned-last-insert-id`, `protocol.text-field-trailing-data`, `protocol.text-field-integer-overflow`, `sql.unsigned-generated-id` | 4 |
| Dates/text | `sql.zero-date-preservation`, `connection.default-full-unicode`, `types.non-utf8-results` | 3 |
| Parameters | `parameters.literal-question-mark`, `parameters.comment-question-mark`, `parameters.no-backslash-text` | 3 |
| **Total** | | **23** |

`reliability.timeout-before-metadata` still requires reuse of the interrupted connection and remains an honest deferred failure. Do not relabel it UNSUPPORTED or count a new safe-abort case as satisfying it. `transaction.partial-result-exception`, by contrast, explicitly requires the same connection and surviving temporary table; bounded drain/rollback must satisfy it.

The public type/constructor changes need mechanical compilation adaptations. For example, widen `test/MultipleResults.hs`’s OK helper annotation from `Either Int`; adapt the synthetic old `MySQLConn` fixture to shared construction. Do not change statements, expected values, exception requirements or assertion strength. List every adaptation in review and preserve the original baseline snapshot.

## Required additional validation

| Area | Required coverage |
| --- | --- |
| Framing | Small-packet splits at every position; coalescing; wrong first/continuation sequence; wrap; exact-multiple terminators; truncated headers/bodies; empty predicates; limit−1/limit/limit+1; raised limits; no allocation from unchecked lengths. |
| Results | Both negotiated terminator modes; long OK tracking payloads; large `0xFE` text rows; binary `0x00` rows; metadata omission rules; prepare/execute layouts; later-result status and errors; list/vector parity. |
| Session context | Zero extra probes on stable/mixed raw-parameter hot paths; explicit invalidation/refresh counts; no hidden changes to ROW_COUNT/FOUND_ROWS/diagnostics; mode/charset changes; opaque CALL and errors; tracker-list preservation and replacement; unknown tracking items; unsupported-capability fallback. |
| Ownership | Simultaneous commands/readers; stale/completed streams; transaction-wide exclusion; cancellation before send/during partial send/metadata/rows/later results; constructor failure; repeated close; replication ownership/ACKs. |
| Cleanup | One absolute deadline; trickling/stalled peers; failed rollback; primary exception preserved; second cancellation wins; no leaked transport/worker after repeated faults. |
| Transactions | Manual BEGIN, autocommit off, unknown status after ERR, caught nested rejection, returned unread stream, explicit savepoints/DDL, deadlock/lock timeout, lost COMMIT reply and no replay. |
| Values | IDs at 2^63−1, 2^63 and 2^64−1; signed/unsigned width boundaries; complete numeric input; malformed length/NULL markers; zero/partial/invalid dates; TIME durations and microseconds; checked Haskell conversions. |
| Text | Supplementary Unicode; strict malformed UTF-8; cp1252 complete mapping; charset switches; binary columns; unknown collation exact bytes/metadata; no guessed text decoding. |
| Parameters | Quotes/comments containing `?` and semicolons; ANSI/Oracle/no-backslash forms; executable comment version gates; NUL/all byte values; representability and malformed syntax; list expansion; stable batch parity; ambiguous batch rejection with zero SQL sent. |
| Performance/resources | Original 24 profiles; parameter and transaction command counts; batch rendering complexity; per-row allocations/GC; heap retention as row count grows; tiny-slice/large-packet retention; concurrent connections and startup cost. |

Fault transcripts prove deterministic phase behavior; real MariaDB integration proves session and data outcomes. Keep fixture/environment failures separate from driver failures. Use fixed seeds and bounded deadlines. Extend existing property tests where useful for fragmentation, numeric boundaries and lexer states; do not add tests that merely reproduce an implementation’s branching.

## Baseline, improvement ratchet and performance gates

### Preserve the original experiment

The [frozen baseline](../validation/baselines/macos-arm64-mariadb-12.3.3/SUMMARY.md), raw JSON and checksums remain immutable. Keep original SQL, counts, checksums, warm-ups, seven repetitions, optimization/RTS settings, dependency profile and C controls. Do not change `Validation/Benchmark.hs`, `Validation/Common.hs`, `connector_c.c` or `run.py` to make a comparison pass. Existing benchmark enumeration/dispatch continues running the same functions.

Supplementary experiments have their own module, runner, versioned manifest, raw results and separate reference. Fingerprint their executable inputs and include them in publication freshness checks. Preserve old references if those experiments change. Capture old-driver results before the affected implementation; never imply a newly invented workload existed in the frozen baseline.

### Never lose an accepted improvement

Add an acceptance check comparing a candidate with both the original baseline and the last accepted main result. The old comparison alone misses a regression from an original FAIL that became PASS in an intermediate implementation.

Before a run overwrites the live report, capture the accepted reference from the committed main publication, including its result hash and tested-input provenance. The candidate report is never its own reference. Update acceptance only after all batch gates pass; a failed full attempt remains visible without advancing it. A small manifest records the tested source/input hashes and accepted result hash/blob object ID; Git history or an immutable accepted snapshot retains that JSON. It does not require the results-publication commit to contain its own future commit hash.

Reject loss/removal/reclassification of any accepted PASS, including new Stage 1 cases; missing benchmark profiles; hidden failures; stale/partial evidence; and any new failure outside the explicitly recorded original deferred set. Required target IDs must pass at their package boundary. Policy tests must demonstrate that an improvement cannot disappear unnoticed, even if it was originally FAIL. Every accepted package becomes the next reference; it never replaces the original baseline.

### Performance acceptance

1. **No new routine round trips or hidden state probes:** count commands for known-state transaction entry, ordinary repeated/mixed parameter queries and stable batch execution. Binary prepared binding does not acquire a rendering probe. Report explicit setup/refresh costs separately; never refresh rendering context silently between application statements.
2. **Timing:** retain the original recorder’s >20% alarm unchanged. Add an acceptance investigation trigger for median latency/ns-per-unit increases above **5%**, against both the original and preceding accepted comparable result. Improvements are reported with units and direction; no automatic speedup claim from a single noisy run.
3. **Allocation/GC:** investigate allocated bytes/unit increases above **5%**, growing retained heap or material GC increases. Permit no unbounded per-connection cache, result-cardinality retention, repeated whole-message copy or avoidable quadratic batch construction.
4. **Noise procedure:** a triggered comparison gets a predeclared three-run confirmation window on the same idle machine/profile, retaining all raw runs and matching C controls. Judge the whole window and variability, not the fastest run. C movement diagnoses host/server noise; do not blindly subtract it from unmatched Haskell workloads or turn an inconclusive comparison into a pass. A repeatable unexplained >5% cost blocks acceptance pending resolution or Anton’s explicit tradeoff decision.
5. **Positive optimization evidence:** report before/after CPU, allocation and memory evidence for the decoder/template/buffer changes. Keep only measured improvements, with ordinary latency and all correctness gates intact. There is no invented percentage speedup promise.

Report process high-water/live-heap statistics using their actual meaning. Existing `max_live_bytes` is not proof of bounded streaming retention by itself; use supplementary row-count/retention experiments. Tail percentiles from sparse operations remain descriptive. Connection/statement creation remains outside original workload timing, with setup measured separately.

The main report keeps the streamlined **Baseline / Current / Change vs baseline** columns, clear units and defined arithmetic. Put last-accepted ratchet outcomes and supplementary references in separately labeled sections rather than changing what “baseline” means. Use colors plus text, and keep failures, unsupported entries and unavailable environments visible.

## Branch, commit and publication workflow

After approval, create `codex/stage1-core-correctness` from current `main`, preserving any user changes. Save the approved plan/review with the first planning commit. Keep each implementation batch coherent and locally reviewable.

For each batch:

1. Verify the real managed MariaDB server and original checksums; capture the preceding accepted reference. Add relevant cases and record pre-fix outcomes on the branch. Do not publish intentionally incomplete packages to main.
2. Implement and run focused checks during development. Preserve new/known failures in raw evidence.
3. Commit all executable inputs locally. Run `python3 -m unittest discover -s validation -p 'test_*.py'` and the full `python3 validation/check.py` with seven repetitions and the unchanged original-baseline comparison.
4. Run the new additive acceptance/ratchet and supplementary checks. Review source/workload hashes, profile comparability, command counts, all target outcomes and performance signals. Run `python3 validation/publish_results.py --check`; verify frozen checksums.
5. Commit the generated `validation/RESULTS.md`, `validation/results/current.json`, `validation/results/overview.svg`, supplementary evidence and acceptance manifest. Identify the actual tested source commit; a results-only publication does not pretend another execution occurred.
6. Review the diff and complete evidence. Once the approved package gates pass, fast-forward `main` to the accepted batch and push code plus measured artifacts together. Revalidate after conflict resolution or executable-input changes. Identical tested inputs do not need an endless rerun for a results-only commit or branch transition. Verify provenance CI.

A failed attempt updates live status honestly and cannot become the accepted reference. Routine implementation and publication within the approved contract do not require repeated permission. Return to Anton for broader scope, a materially different API/behavior contract or acceptance of a repeatable material regression. A release and Stage 2 remain outside this approval.

## Final acceptance and approval

Stage 1 is complete only when:

- All 23 listed original failures pass without weakened contracts; every original and accepted later PASS remains passing; all new Stage 1 cases pass.
- Both result formats, all ordinary command entry points and TCP/Unix/TLS follow ownership, status and bounded cleanup rules. Stale streams cannot consume later replies. Transaction helpers cannot commit outer work or admit interleaved commands.
- Intact application-error cleanup preserves a usable session; uncertain I/O retires it. Cancellation identity propagates. Writes and commits are never automatically replayed.
- Supported values round-trip exactly; unknown encodings preserve bytes; parameter rendering follows validated session context. Unsupported ambiguous batches fail before execution.
- All 24 frozen runnable benchmark profiles complete with preserved comparability. The command-count, timing/allocation, memory and positive optimization evidence gates are satisfied; any accepted cost has an explicit recorded decision.
- Main contains the current measured report and graphic, supplementary evidence and accepted-reference provenance. The original baseline is unchanged and publication CI passes.
- Remaining failures are listed honestly, including timeout reuse, authentication, prepared OUT, connection setup and CDC. Stage 1 does not claim complete MariaDB feature coverage.

**Approval requested:** approve Version 2 in full, including the API migrations, bounded resource defaults, negotiated internal tracking, conservative cancellation, batch restrictions, 23-case target and measured main-publication workflow. Approval starts Package 0, followed by packet/protocol implementation and the remaining packages.
