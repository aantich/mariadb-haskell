# Stage 1 migration notes

This fork supports MariaDB only. Stage 1 changes several contracts to preserve data and prevent reuse of an uncertain connection. Package/module names still match the inherited API; renaming them is a separate migration.

## Connections and streams

Use `connect`, `connectUnixSocket`, TLS `connect`, or their `WithOptions` variants. `MySQLConn` is abstract in the public `Database.MySQL.Base` module. The exposed `Connection` module is an internal transport/testing interface; constructing or modifying its records bypasses the public safety contract.

`defaultConnectInfo` now requests full Unicode (`utf8mb4`); `defaultConnectInfoMB4` remains an alias. Default client limits are 64 MiB per logical message, 16 MiB metadata, 65,535 columns and a one-second transaction cleanup deadline. Customize `ConnectionOptions` before connecting. Outgoing SQL/parameters must fit both the client limit and the server's captured `max_allowed_packet`; oversized messages fail before sending any bytes. Limits apply to complete logical messages, including all continuation fragments.

One connection has one owner during a command or unfinished stream. Consume each stream on the thread that created it. Concurrent commands, cross-thread stream reads and stale streams fail locally. Consume every result before starting another command, resetting or closing a statement. Repeated reads of a completed stream return EOF. Different connections remain independent and can run concurrently.

`connectionStatus` and `connectionFailure` expose bounded diagnostics. A timeout, cancellation, malformed response, partial write or transport failure can leave the connection `Broken`; open a new connection. A complete server ERR can leave the wire reusable while making cached session facts unknown. `close` is idempotent and interrupts an active connection by releasing its transport.

TCP and Unix sockets start with a 4 KiB receive allocation and grow on full reads to the existing 16 KiB ceiling. Each read returns independent immutable bytes. This reduces small-response allocation without reusing storage underneath returned values; large scans retain the larger receive size. The low-level fixed-size `socketToConnection` helper remains available unchanged in behavior.

## Transactions

`withTransaction` owns the connection for the entire body, including gaps between commands. Nested helpers and entry while a manual transaction is active are rejected. If a prior ERR made transaction status unknown, entry may perform a controlled status query under the lease; known-state entry adds no status probe. It rolls back on a body exception or an unread returned result, within one absolute cleanup deadline. An ordinary cleanup failure does not replace the original exception. A new cancellation during cleanup propagates and retires the connection.

If COMMIT may have reached MariaDB but its acknowledgement is lost, synchronous failures become `CommitOutcomeUnknown originalException`. Cancellation is rethrown unchanged, with `commitOutcomeUncertain` recorded in connection diagnostics. Concurrent close while a COMMIT reply is in flight follows the same uncertainty policy; a fully received server ERR retains its original meaning. The helper never retries COMMIT or replays the transaction. Resolve uncertain durability using application identifiers and an independent connection.

## Session-aware parameters

Connected query APIs retain their signatures. Setup uses one tracker-configuration exchange and one snapshot exchange on a capable server. Ordinary parameter calls use that context and final response deltas without extra discovery SQL. This preserves preceding-statement values such as `ROW_COUNT()`.

An ERR, opaque routine/dynamic execution, raw multi-statement SQL or tracking-configuration replacement makes rendering context unknown. Text rendering then raises `SessionContextUnavailable` before sending the target command. Refresh explicitly when appropriate:

```haskell
refreshSessionState conn
(_, stream) <- query conn "SELECT ?" [MySQLText "a'b"]
```

Refresh performs SQL and therefore changes MariaDB's preceding-statement diagnostics. It preserves existing session tracker selections, including `*` and proxy entries. If tracking is disabled through `enableSessionTracking=False`, a snapshot can be used for one operation; subsequent operations that require text context need explicit refresh. Prepared binary/numeric binding does not require a text-rendering snapshot. Prepared `MySQLText` uses the current client encoding and requires a known context.

Custom `QueryParam` instances and direct renderer calls must accept a context and return a checked builder:

```haskell
render :: RenderContext -> a -> Either ParameterError Put
renderParams :: QueryParam p => RenderContext -> Query -> [p]
             -> Either ParameterError Query
```

Use `getRenderContext` for a connection's validated snapshot. `defaultRenderContext` is for isolated fixtures/direct callers with independently established settings; it is not a substitute for a live connection's state. Custom instances are trusted to render one safe parameter and report encoding/validation errors. MariaDB aliases collation and charset tracking entries: `renderConnectionCollation` can be `Nothing` after a charset delta. A custom renderer that needs its exact value must request an explicit refresh.

Active executable comments are conservatively opaque: refresh explicitly afterward before further text rendering. Inactive comment bodies preserve known context. Reversed-looking executable comments (`/*!!...*/`, `/*M!!...*/`) are rejected by parameter rendering; raw pass-through remains available.

The lexer recognizes quoted strings/identifiers, comments, MariaDB executable-comment version gates, `ANSI_QUOTES`, `NO_BACKSLASH_ESCAPES` and ordinary quotes under Oracle mode. Built-in text parameters use the verified charset and SQL mode; byte/geometry parameters use hex literals. Supported text encodings are UTF-8, ASCII and MariaDB latin1/cp1252. Unencodable text fails before execution.

Parameterized batches accept stable flat INSERT/UPDATE/DELETE/REPLACE/SELECT/DO templates and a conservative set of known expressions. SET, CALL, dynamic/compound SQL, unknown routine calls (including quoted names), and ambiguous context changes raise `AmbiguousParameterizedBatch` before any statement executes. Templates may end in a statement delimiter; joining does not add a duplicate. Every server OK is returned, including a final comment-only result after a delimiter. There is no implicit sequential fallback or atomicity promise. Sequence such operations explicitly, adding a transaction when needed. Raw multi-statement APIs still pass SQL through and invalidate context afterward.

## Values

`okAffectedRows` and `okLastInsertID` are `Word64`; update explicit `Int` signatures and perform checked conversions when your application needs a narrower type.

`MySQLDateRaw DateParts`, `MySQLDateTimeRaw DateParts TimeOfDay` and `MySQLTimeStampRaw DateParts TimeOfDay` preserve zero, partial-zero and invalid calendar dates. Normal representable values retain the existing constructors. Both text and prepared binding preserve raw forms. `Field Day`/`Field LocalTime` conversion rejects an unrepresentable raw value; it never clips or normalizes it.

Integers are range checked, numeric text must be fully consumed, temporal precision/sign/range is validated, and invalid built-in parameters are rejected before a command starts writing. UTF-8 is decoded strictly. MariaDB latin1 is decoded as cp1252; binary and unmapped charsets remain exact `MySQLBytes`. A malformed value is forced at the guarded row-read boundary, before yielding the row.

## Validation and review

The original baseline and its workloads remain immutable. For publication, commit executable inputs, run `python3 validation/check.py`, check with `python3 validation/publish_results.py --check`, then commit the generated results. An explicitly authorized uncommitted review can use the `--working-tree` option on both commands instead. Read the live results and implementation notes for measured changes, retained failures, profile comparability and deferred performance investigations. A review run does not validate its parent commit or publish anything to main.
