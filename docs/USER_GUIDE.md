# MariaDB Haskell user guide

**Alpha software:** automated validation is extensive, but real-world application
validation is still outstanding. Evaluate the driver with your own workloads;
APIs and behavior may change. The documented test scope is not a production
readiness claim.

Start with `Database.MySQL.Base`; add `Database.MySQL.TLS`,
`Database.MySQL.Field` and `Database.MySQL.BinLog` as needed. The historical
`MySQL` names are API/wire identifiers, not a server support claim.

[Quickstart.hs](https://github.com/aantich/mariadb-haskell/blob/main/examples/Quickstart.hs)
is a complete program.
[GuideExamples.hs](https://github.com/aantich/mariadb-haskell/blob/main/examples/GuideExamples.hs)
contains compilable helpers for the APIs below. Both ship in the source tarball.
Snippets use `OverloadedStrings`, `DB` for `Database.MySQL.Base`, `TLS` for
`Database.MySQL.TLS`, `Streams` for `System.IO.Streams`, and `bracket` from
`Control.Exception`. `ci`, credentials and handlers come from your application.

* [Connections and TLS](#installation-and-connections)
* [Streaming, parameters and values](#streaming-rows-binding-and-values)
* [Results and transactions](#multiple-results-and-transactions)
* [Bulk and metadata](#native-bulk-and-cached-metadata)
* [Uploads, cursors and optional wire features](#uploads-cursors-progress-and-compression)
* [Sessions and pools](#session-observations-and-pool-reuse)
* [PAM and Kerberos](#pam-and-kerberos-authentication)
* [Durable CDC](#cdc-and-durable-resume)
* [Failures and budgets](#errors-and-budgets)

## Installation and connections

The package is `mariadb-haskell`, version `0.1.0.0`; public modules remain
`Database.MySQL.*`. Add `mariadb-haskell >=0.1 && <0.2` to Cabal dependencies once
the release is published, or build this checkout with `cabal build lib:mariadb-haskell`.
The [release status](https://github.com/aantich/mariadb-haskell/blob/main/docs/RELEASING.md)
distinguishes prepared artifacts/candidates from public publication.

Linux builds need a C compiler, zlib and MIT Kerberos headers/libraries
(`build-essential zlib1g-dev libkrb5-dev` on Debian/Ubuntu), even without GSSAPI
use. macOS uses Apple's GSS framework and command-line tools. The driver does
not link Connector/C; validation's independent C controls do. Build GSSAPI
applications with `-threaded`. Full profiles use GHC 9.10.3 on Mac and 9.4.7 on
Linux; the broader dependency bounds are not a tested compiler matrix.

```haskell
let ci = DB.defaultConnectInfo
      { DB.ciHost = "127.0.0.1"
      , DB.ciPort = 3306
      , DB.ciUser = "application"
      , DB.ciPassword = passwordFromConfiguration
      , DB.ciDatabase = "application"
      }
bracket (DB.connect ci) DB.close $ \conn -> do
  (_, rows) <- DB.query_ conn "SELECT VERSION(), CURRENT_USER()"
  Streams.foldM (\() row -> print row) () rows
```

Load secrets from configuration rather than source code or logs.
`Show ConnectInfo` redacts the password; keep other configuration and SQL diagnostics appropriately scoped.
`defaultConnectInfo` uses full Unicode `utf8mb4`; `defaultConnectInfoMB4` is an
equivalent compatibility name. TCP does not automatically enable TLS.

For verified TLS, build parameters once and reuse them when opening connections.
The tuple's name is the certificate DNS name, which can differ from `ciHost`:

```haskell
params <- TLS.makeClientParams (TLS.CustomCAStore "/etc/application/mariadb-ca.pem")
bracket (TLS.connect ci (params, "db.example.com")) DB.close useConnection
```

`SystemCAStore` reads OS trust roots; `MozillaCAStore` uses the installed bundled
snapshot, currently **5 November 2026**. Its source, checksum, separate MPL-2.0
license and update policy are in
[CA provenance](https://github.com/aantich/mariadb-haskell/blob/main/docs/CA_BUNDLE.md).
It is not automatically refreshed with the OS. Missing/malformed CA files fail
at parameter construction. `makeClientParams'` also loads a
client certificate, chain and private key for X.509-required accounts. Retain
peer/hostname verification. Repository fixture keys/certificates are public
test material, never production credentials.

For local sockets use `DB.connectUnixSocket "/path/to/mariadb.sock" ci`.
Unix-socket authentication maps the OS identity to a configured MariaDB account;
a SQL password does not change that OS identity.

## Streaming rows, binding and values

`query_` sends literal SQL. `query` renders checked text parameters using the
session's SQL mode/charset. Prefer managed prepared bindings for repeated
queries and untrusted data:

```haskell
DB.withPreparedStatement conn
  "SELECT id, name FROM customers WHERE id >= ? ORDER BY id" $ \statement -> do
    (_, rows) <- DB.queryPrepared statement [DB.MySQLInt64 minimumId]
    Streams.foldM (\() row -> handleRow row) () rows
```

Placeholders bind **values**, not identifiers, keywords or arbitrary SQL
fragments. Raw `Query`/`_` APIs leave quoting to the caller. Never concatenate
untrusted input into SQL.

Queries stream rows rather than collect the whole result; one large field still
occupies memory up to the message budget. Read on the creating thread, inside
the connection/statement lifetime, and consume to EOF before another command.
Use `Streams.skipToEof` for intentional discard. An unfinished ordinary stream
prevents another command. A statement bracket attempts bounded cleanup and
retires the connection if synchronization cannot be restored. Do not return a
live stream from its bracket. Use separate connections for concurrent workers.

The examples use `Streams.foldM` to consume through EOF. io-streams' `mapM_`
attaches effects to a returned stream; calling it without consuming that stream
does not run the whole row consumer.

`MySQLValue` preserves width/signedness: `MySQLInt64`, `MySQLInt64U`,
`MySQLDecimal`, `MySQLText`, `MySQLBytes`, `MySQLNull`, etc.
`Database.MySQL.Field.fromField` returns `Either DecodeError a`. Fixed-width
instances require a matching constructor; they do not silently narrow or parse
arbitrary text. Use `Maybe a` for nullable columns, `Scientific` for exact
decimals and explicit fixed-width integer types. There are no machine-width
`Int`/`Word` instances. After checking row shape, for example:

```haskell
case (fromField value :: Either DecodeError Int64) of
  Left problem -> reportSchemaMismatch problem
  Right number -> useNumber number
```

JSON, UUID, INET4/INET6, VECTOR and GEOMETRY are tested through wire
representations/SQL conversions; the package does not supply a Haskell domain
type for every SQL type. NULL differs from empty text/bytes. Zero/partial dates
have raw constructors with `DateParts`; handle these explicitly. SQL TIME can
be negative or exceed 24 hours, so cannot always become `TimeOfDay`.

Text codecs strictly handle UTF-8, ASCII and MariaDB latin1 (CP1252 mapping).
Other result charsets remain bytes for application decoding. Unrepresentable
text parameters fail rather than replace characters. `preparedMetadata` reads
owned metadata without SQL, including negotiated extended attributes.

## Multiple results and transactions

`execute_`/`executePrepared` return `OK`, including affected rows and the full
64-bit insert ID. Single-result APIs reject unexpected/extra row results with
`ExtraResultSets` after draining. Use `queryMulti_`/`queryMulti` for every text
result or `queryPreparedMulti` for all prepared results and OUT parameters.
`StatementResult` distinguishes OK/rows; `PreparedResult` also distinguishes OUT
parameters. These multi-result APIs **buffer all rows**: use bounded procedure
results rather than unbounded exports.

```haskell
DB.withTransaction conn $
  DB.withPreparedStatement conn
    "UPDATE accounts SET balance = balance - ? WHERE id = ?" $ \statement -> do
      _ <- DB.executePrepared statement [DB.MySQLInt64 amount, DB.MySQLInt64 accountId]
      pure ()
```

`withTransaction` commits on success and attempts bounded rollback on failure.
It does not implement nested transactions/savepoints. Consume results inside
the action. DDL can implicitly commit; the helper cannot make such statements
transactional. Use transactional tables where required.

If COMMIT was sent but its reply was lost, inspect `connectionFailure` and
`commitOutcomeUncertain`. Reconcile using your application's transaction
identity rather than replaying writes automatically. The original exception
survives rollback/cleanup failure; secondary cleanup diagnostics are recorded
on the connection.

## Native bulk and cached metadata

`executeBulk` uses MariaDB's native binary bulk command, avoiding a round trip
per row:

```haskell
DB.withPreparedStatement conn
  "INSERT INTO measurements(sensor_id, reading) VALUES (?, ?)" $ \statement -> do
    result <- DB.executeBulk statement
      [ [DB.BulkValue (DB.MySQLInt64 1), DB.BulkValue (DB.MySQLDouble 12.5)]
      , [DB.BulkValue (DB.MySQLInt64 2), DB.BulkValue DB.MySQLNull]
      ]
    print result
```

Each row must match arity. Each parameter column uses one compatible concrete
wire type/signedness. `BulkValue MySQLNull` is NULL; `BulkDefault` requests the
server default; `BulkIgnore` supplies MariaDB's ignore indicator. MariaDB decides
indicator legality for the statement. `executeBulkUnitResults` returns per-unit
IDs/affected counts with extra response/allocation costs.

The default row budget is 10,000 and message limits also apply. Oversized or
mixed-type batches are rejected, never silently split. Chunk input explicitly;
wrap chunks in a transaction if all-or-nothing behavior is required. Server
constraints and storage-engine semantics still apply.

Prepared metadata caching defaults on with a connection-wide budget, subject
to server negotiation. DDL/reprepare, close and reset refresh/invalidate it.
Never keep handles after reset or use them on a different connection.

## Uploads, cursors, progress and compression

```haskell
DB.withPreparedStatement conn "INSERT INTO files(contents) VALUES (?)" $ \statement -> do
  _ <- DB.executePreparedStream statement [DB.PreparedBytes byteSource]
  pure ()
```

`byteSource :: InputStream ByteString` is consumed once. `PreparedText` takes
`InputStream Text`; `PreparedValue` supplies scalars. Empty streams mean empty
non-NULL values. Bracket input files around the whole execution. Produce bounded
fresh chunks rather than retaining the source in a list. Upload chunks are at
most 64 KiB; the default cumulative execution budget is 64 MiB. Source failures,
encoding errors or cancellation after upload starts retire the connection.
MariaDB can defer upload errors until EXECUTE. Streaming reduces retained input
memory, not necessarily allocation or elapsed time.

For controlled fetches, nest `withCursor` inside `withPreparedStatement`, then
repeatedly `fetchCursor cursor batchSize`. Fully consume each batch before
checking `cursorExhausted` or fetching again. Sizes must be positive and at most
the configured maximum (65,536 by default). Cursors may materialize results on
the server and add round trips; ordinary row streams are the throughput starting
point. See the complete cursor helper in `GuideExamples.hs`.

Set `enableProgressReporting = True` in `ConnectionOptions` before connecting,
then `setProgressCallback conn (Just callback)`. Callbacks run synchronously
while consuming supported server operations' replies. Keep them quick and do
not reenter the same connection. Callback failure/cancellation retires it.

Set `enableCompression = True` before connecting for negotiated zlib transport
compression. It composes with TLS and other supported features. The default
threshold is 1 KiB and raw frames are used when compression saves no bytes.
Compression costs CPU and makes the measured local workloads slower; measure
your real data/network first.

## Session observations and pool reuse

`getSessionState` issues no SQL and returns schema/variable/status/transaction
observations, a change number and the last received changes. Unknown facts
remain explicit. After ERR/opaque context-changing SQL, explicitly
`refreshSessionState` before text rendering when needed; binary binding avoids
SQL quoting but still needs correct text encoding.

`resetConnection` resets server state and restores the constructor's database,
charset/collation and original active role. It restores server session defaults,
not every custom setting. `resetConnectionWith conn initialize` reapplies your
settings under the same exclusive lease and cleanup deadline. The initializer
must consume all results and leave no active transaction.

There is no built-in pool. A pool must ensure exclusive checkout, reject broken
connections, reset between requests, and retain no live streams/cursors/handles.
Reset invalidates every prepared handle. Use an explicit constructor database:
MariaDB cannot restore a selected database to "none". Reset needs server 10.2.4+
(the full tested profile is 12.3.3). Failed/cancelled reset discards the connection.

## PAM and Kerberos authentication

Native password, ed25519, PARSEC and SHA-2 negotiate according to the account's
server plugin/transport. Certificates and Unix-socket identity also need matching
server configuration. The driver does not install plugins or configure accounts.
External credentials require explicit `AuthenticationOptions`:

```haskell
let auth = DB.defaultAuthenticationOptions
      { DB.authenticationDialog = Just (DB.passwordDialog pamPassword) }
bracket (TLS.connectWithAuthentication DB.defaultConnectionOptions auth ci
          (params, "db.example.com")) DB.close useConnection
```

PAM replies require TLS or a Unix socket. `passwordDialog` answers only the first
hidden prompt. For usernames/PINs/multiple factors inspect `dialogEcho`,
`dialogRound`, `dialogLast` and `dialogText` in your callback. Prompts are untrusted
server bytes, not trusted terminal control text. No terminal fallback occurs.
Exceptions propagate and close the transport. Dialogs are bounded to 16 exchanges
and 65,535-byte prompts/replies; replies cannot contain NUL.

For Kerberos use
`authenticationGSSAPIPrincipal = Just "mariadb/db.example.com@EXAMPLE.COM"`.
The service principal is exact, including realm. Configure credentials/ticket
cache before connecting and build with `-threaded`. GSSAPI does not use the SQL
password; pinning the principal requires GSSAPI rather than password-only success.
There is no NTLM/SSPI or credential delegation. Login does not encrypt SQL:
use TLS when required. A native provider call can finish after cancellation
under OS/Kerberos policy, while the deadline retires the client transport.
Windows GSSAPI is unavailable.

## CDC and durable resume

Use `Database.MySQL.BinLog` (qualified as `CDC`), a dedicated connection, a
unique nonzero replica server ID, row binlogging and the replication permissions
required by the server. Check binlog retention and grants before connecting.
A CDC connection cannot issue ordinary queries.

```haskell
gtids <- either (ioError . userError) pure (CDC.parseGtidSet savedGtidBytes)
let options = (CDC.defaultCDCOptions (CDC.FromGtid gtids))
      { CDC.cdcAcknowledgements = CDC.AcknowledgeManually }
bracket (CDC.openCDC conn replicaId options) CDC.cdcClose consumeCDC
```

MariaDB GTIDs are `domain-server-sequence`, not UUID intervals. Persist
`renderGtidSet` from `checkpointGtids` for GTID starts, or `checkpointPosition`'s
file/next position for file starts. Reconstruct `FromGtid`/`FromBinLog` from those
durable coordinates on a fresh connection. Do not persist opaque tokens using
`Show`. `resumeFromCheckpoint` helps with an in-memory token; purged history is
an error, never a silent fallback.

`cdcLatestCheckpoint` is a **decoded complete-group boundary**, not a destination
commit. Consume/apply every event through it, atomically persist destination
changes and resume coordinates, then `cdcAcknowledge` its active-stream token.
The driver persists nothing and does not promise exactly-once delivery. Manual
mode requires server semisync. ACKs release receipt waits, not application
distributed transactions. Disabled ACK mode is the default. Legacy `dumpBinLog`
on-read ACKs mean receipt only and do not prove downstream durability.

The pull-driven decoder retains bounded table metadata, not whole transactions.
Consumers must avoid unbounded transaction accumulation. Future, foreign,
incomplete and backward tokens are rejected. EOF/failure/close ends the connection;
reopen and resume from your last durable coordinates. Advanced XA checkpointing,
two-phase ALTER and storage-engine-binlog GTID semisync fail closed. Other
unknown non-ignorable events are rejected too. File dump starts have a 32-bit
wire position limit even though observed/checkpoint positions are 64-bit.

## Errors and budgets

Keep the original exception; inspect `connectionStatus`/`connectionFailure` for
lifecycle and secondary cleanup diagnostics. A complete `ERRException` normally
preserves wire synchronization while invalidating session facts. Malformed
replies, transport failure and cancellation during I/O retire the connection.
Ownership, stale-handle and parameter errors may fail locally before sending.

| Default budget | Value |
| --- | ---: |
| Establishment deadline | 10 seconds |
| Cleanup/reset deadline | 1 second |
| Logical query message | 64 MiB |
| Connection-wide metadata | 16 MiB |
| Registered prepared statements | 1,024 |
| Bulk rows per command | 10,000 |
| Streamed parameter bytes per execution | 64 MiB |
| Cursor rows per fetch | 65,536 |

See `ConnectionOptions`/`DecodeLimits` Haddock for all fields and server-limit
intersections. The establishment deadline is not an automatic query timeout.
Apply your own deadline when required, accepting terminal retirement if it
interrupts protocol I/O. Never automatically retry uncertain writes.

Start with prepared bindings and ordinary streams. Use bulk for similar writes,
cached metadata for repeated results, reset for request reuse, and optional
features for measured resource/network needs. Read the
[benchmark guide](https://github.com/aantich/mariadb-haskell/blob/main/docs/BENCHMARKS.md).
Report sanitized reproducers with server/compiler versions through
[issues](https://github.com/aantich/mariadb-haskell/issues); never include passwords,
ticket caches, keytabs or private keys.
