# Migrating from upstream mysql-haskell

This fork supports MariaDB only. Its independent package identity is
`mariadb-haskell`, starting at `0.1.0.0`; replace the upstream `mysql-haskell`
Cabal dependency when migrating.
Keep imports of `Database.MySQL.*`; they are retained intentionally. The
[user guide](https://github.com/aantich/mariadb-haskell/blob/main/docs/USER_GUIDE.md)
has examples for the new APIs.

Depend on the fork rather than both packages:
their module names overlap and their connection/statement types are distinct.
Change the Cabal dependency and rebuild downstream consumers together.

## Behavior to review when upgrading

* **Unicode:** `defaultConnectInfo` now selects `utf8mb4`. `defaultConnectInfoMB4`
  remains an equivalent alias. Explicit narrow client charsets use strict
  encoding; unsupported result charsets remain bytes.
* **Connection ownership:** one command/stream owns a connection at a time.
  Consume on the creating thread and drain before reuse. Concurrent workers
  need separate connections. Raw connection record access bypasses these rules.
* **Timeout/cancellation:** interruption during protocol I/O retires the
  connection. Replace timeout-and-reuse code with discard-and-reconnect.
  There is no automatic SQL retry. Uncertain COMMIT must be reconciled by the
  application rather than retried blindly.
* **Text parameters:** rendering follows observed SQL mode/charset. Unknown
  context is an error, not guessed quoting. Refresh session facts after relevant
  server errors/opaque SQL; prefer prepared bindings. Identifiers are not values.
* **Limits:** logical messages default to 64 MiB, metadata to 16 MiB and
  cleanup/reset to one second. Configure `ConnectionOptions` explicitly for
  workloads that legitimately exceed these budgets; server limits still apply.
* **Values:** generated/affected IDs preserve unsigned 64-bit width. Raw zero
  and partial dates are represented explicitly. `Field` conversions require
  matching fixed-width constructors; applications must handle decode failures.
* **Result shape:** use multi-result APIs for procedures and OUT parameters.
  Single-result APIs drain and report `ExtraResultSets`; multi-result APIs
  buffer rows, so they are not an unbounded streaming export facility.
* **Prepared handles:** prefer `withPreparedStatement` and managed APIs over
  raw statement IDs. Close/reset/reprepare and connection reset have explicit
  generation/cache lifetimes. Reset invalidates every existing handle.
* **Transactions:** `withTransaction` is not nested. DDL can implicitly commit.
  Bounded cleanup preserves the primary exception and records secondary failure.
* **TLS/build:** Linux builds need MIT Kerberos development libraries in addition
  to zlib/C tooling. macOS uses GSS.framework. Use a managed system/custom CA
  store; the bundled Mozilla snapshot now has dated provenance and its own MPL-2.0 notice.
* **External authentication:** PAM and Kerberos are explicit opt-ins. PAM needs
  TLS/socket transport; Kerberos needs an exact service principal, existing
  credentials and `-threaded`. Windows GSSAPI is unavailable.
* **CDC:** prefer `openCDC`, complete-group checkpoints and manual ACKs after
  durable destination/checkpoint storage. Legacy on-read ACKs mean receipt only.
  Unsupported non-ignorable events fail closed. Persist coordinates/GTIDs,
  not opaque checkpoint `Show` output.

* **Diagnostics:** `Show ConnectInfo` now redacts password bytes, including empty
  passwords, while retaining endpoint/account context. Authentication bytes are unchanged.
* **Developer tooling:** the Hackage package builds the library by default.
  The validation executable requires `-fvalidation`; the repository's own
  `cabal.project` opts in, while source archives omit that development project.

## New APIs to adopt deliberately

Native bulk and metadata caching reduce repeated command/metadata costs.
Session reset supports clean external-pool reuse. Streamed parameters and
cursors give resource control; progress and compression are opt-in. Their
performance tradeoffs are described in the
[benchmark guide](https://github.com/aantich/mariadb-haskell/blob/main/docs/BENCHMARKS.md).

The full tested server profile is MariaDB 12.3.3 on macOS/Linux. Wider server,
compiler and OS support needs additional validation; inherited dependency
bounds or exposed protocol modules do not establish that support.
