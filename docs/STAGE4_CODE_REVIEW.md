# Stage 4 code review — 7 November 2026

Reviewed all uncommitted Stage 4 implementation, public API/comments, validation
changes and benchmark/publication policy on `codex/stage4-session-reuse`, parent
`7b545e8`. The executable input fingerprint remains
`870add4dff23c16bc4d2acf0529b47f4bead589bad45edfb818948b392879d4a`.
This historical pass made no implementation changes. All three findings were
subsequently fixed on 8 November 2026; see the [fix implementation and validation](STAGE4_IMPLEMENTATION.md#review-fixes--8-november-2026).

## P1 — reset preserves the preceding borrower's active role

Location: `src/Database/MySQL/Connection.hs:1345` (reset/restoration) and
`InitialSession` at line 280 (restoration facts).

On the real MariaDB 12.3.3 server, a new validation connection reports
`CURRENT_ROLE() = NULL`. After selecting a temporary granted role,
`resetConnection` succeeds but `CURRENT_ROLE()` still reports that role. The
wrapper restores database and charset, but never restores the initial active
role. Reusing the connection can therefore carry a borrower's role/privilege
context into the next request, contrary to the clean-session/default-settings
contract. `resetConnectionWith` has the same default behavior unless its caller
explicitly restores a role.

This matches the checked-out server: RESET calls `THD::change_user()` in
`sql/sql_parse.cc:1737`; its resource cleanup/init path in
`sql/sql_class.cc:1588` does not reauthenticate/reinitialize the security context.
A successful RESET acknowledgement is insufficient to establish this property.

Capture the constructor's initial role and restore it before database/application
initialization, or explicitly narrow the API contract and require an initializer
that establishes the intended role. Preserve configured default roles; forcing
`NONE` unconditionally is not equivalent to a fresh connection. Add real-server
checks for both initially inactive and initially active roles, with cleanup of
all temporary grants. Prefer sharing an existing startup snapshot exchange for
new restoration facts, and benchmark the complete resulting reset path.

The reproduction's temporary role/grant was removed in a `finally` block; the
validation user's default role was not changed.

## P2 — public snapshots retain stale connection collations

Location: `src/Database/MySQL/Connection.hs:1411` and lines 1454–1458;
`src/Database/MySQL/Session.hs:169`.

The startup/refresh helper seeds `collation_connection` into `sessionVariables`,
but the required tracking selection omits it. With the normal local selection,
`SET collation_connection='utf8mb4_bin'` succeeds while the snapshot still returns
`utf8mb4_unicode_ci`. A separate `SET NAMES latin1` probe returns the new
`character_set_connection = latin1` alongside the old UTF-8 collation, while
MariaDB reports `latin1_swedish_ci`.

The rendering cache already invalidates its dependent collation when the
connection charset changes; the new public observation cache does not. Track
collation changes or invalidate the public value whenever it can become stale,
including a direct collation change with no charset change. Do not add a SELECT
per snapshot or ordinary command. Test both `SET NAMES` and direct
`collation_connection` assignment, with default and explicit tracker selections.

## P2 — tracker downgrade leaves obsolete transaction characteristics

Location: `src/Database/MySQL/Session.hs:174`.

The cache clears transaction characteristics only when
`session_track_transaction_info` becomes `OFF`. MariaDB also stops emitting
characteristics when it becomes `STATE` (see `sql/session_tracker.cc:749` and
line 823). A live sequence enabling `CHARACTERISTICS`, starting `READ ONLY`,
switching to `STATE`, rolling back and starting `READ WRITE` leaves
`sessionTransactionCharacteristics = Just "START TRANSACTION READ ONLY;"`.
The new transaction is active/read-write; the cached replay text describes its
predecessor.

Invalidate characteristics whenever that tracker ceases to report them,
including the `CHARACTERISTICS` → `STATE` transition. Keep transaction-state
observations available under `STATE`. Add a literal control-transition fixture
and a live test spanning different transactions.

## Verification and review limits

- All **129 Python policy tests pass** again.
- The working-tree results freshness guard and tracked whitespace check pass.
- Focused real-server probes reproduce all three findings using the current
  built library; registered tests and executable inputs are unchanged.
- Existing full Mac/Linux results and all immutable baselines are retained.
  Full benchmarks were not rerun for this read-only review. The previously
  recorded timing investigations remain open.
- No additional release-blocking defect was identified in reset ownership,
  cancellation, statement generation handling, retained-state byte accounting,
  or the shared recorder refactor. Haskell layout and public comments are
  generally maintainable; the reset contract needs the role qualification above.

The current 53 Stage 4 checks miss these transitions, despite passing. Add the
regressions before fixing, rerun focused correctness and the full Mac/Linux
checks, then measure the complete reset path and update the live report. Any
new executable-input change requires new measurements; this review does not
relabel the existing run as evidence of fixed behavior.

[Structured evidence](../validation/results/experiments/stage4-code-review.json)
· [Collation/transaction probe](../validation/results/experiments/stage4-review-probe2.hs.txt)
· [Role probe](../validation/results/experiments/stage4-review-role.hs.txt).
