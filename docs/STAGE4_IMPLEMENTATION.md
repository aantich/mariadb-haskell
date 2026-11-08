# Stage 4 — clean-session reuse and public session observations

Approved on 7 November 2026, following Stage 3 publication `7b545e8`. This
implements step 3 of the [roadmap](ROADMAP.md). Publication was approved on
8 November after the review fixes. The live report now identifies the committed
implementation tested for publication. Earlier review runs retain their original
working-tree fingerprints, measurements, outliers and failed development evidence.

## Contracts and implementation

`getSessionState` reads a bounded snapshot without SQL or a wire claim. Fields
that are unknown remain `Nothing`; absent system variables are not assumed to
have default values. Schema, system-variable deltas, generic state changes,
transaction characteristics/state and unknown tracker payloads are represented
explicitly. Transaction/autocommit flags also come from ordinary status flags.
The snapshot describes replies consumed so far; an unfinished stream may still
carry later changes. `sessionLastChanges` is the latest tracker envelope, in
wire order, with a replacement counter. It is not a lossless event queue.

Retained bytes own their storage. Cumulative variables and latest changes share
the connection metadata budget, with incremental accounting and bounded item
counts. Removed subscriptions discard affected observations. Errors, opaque or
untracked effects, reset and terminal failure invalidate potentially stale facts.
Explicit rendering refresh seeds observed rendering facts without fabricating a
wire event. Session data may contain application values and should not be logged
indiscriminately.

`resetConnection` sends `COM_RESET_CONNECTION` only on a synchronized connection.
It restores the constructor's nonempty database and authentication charset,
required tracking and a rendering snapshot. Other session settings return to
server defaults. `resetConnectionWith` runs application initialization under the
same exclusive lease and one cleanup deadline. The initializer must consume all
results and leave no active transaction. All registered raw IDs, managed handles
and compiled metadata are invalidated before sending RESET. Numeric ID reuse
cannot revive a previous generation.

Reset cannot borrow a transaction/refresh lease, race another command, consume
an unfinished result or revive a broken connection. Once reset starts, any
failure, cancellation, malformed reply or unsuccessful initializer retires the
transport. No SQL is replayed. The returned OK belongs to RESET; restoration
SQL changes preceding-statement diagnostics. Cleanup runs with the caller's
masking state, while ownership and retirement transitions remain protected.

MariaDB preserves the selected database on RESET. A constructor without a
database can therefore reset only while the absence of a selected database is
known. Pools should use an explicit constructor database. An unsafe attempt to
restore “no database” is rejected before sending; it must not silently retain a
previous borrower's schema. Server versions before MariaDB 10.2.4 are rejected
locally. The reset path stores restoration facts without retaining credentials.

## Performance design and validation

Ordinary replies update public flags only when their status changes; normal rows
do not allocate snapshot records. Tracker updates use logarithmic map replacement
and incremental byte totals. Subscription changes alone require a map recount.
Snapshots issue no queries. Reset avoids redundant database/charset exchanges
when the previously observed database and server-restored charset suffice.

New additive benchmarks compare complete reset/restoration/preparation/request
cycles with equivalent reconnect/initialization/preparation/request/close cycles
on TCP, TLS and Unix sockets. Both paths check application settings and absence
of the preceding request's user variable, then leave the same pollution behind.
Prepared statements are recreated inside timing. A separate profile measures
public snapshot calls. Frozen workloads and native Stage 3 workloads stay intact.

Validation preserves all 462 published PASS records and replaces the two
unsupported capability entries with real checks. The 16 deferred CDC defects and
the conflicting original timeout-reuse expectation remain visible. Fault fixtures
cover reset, restoration, initializer failure/cancellation, ownership and resource
budgets. The full wrapper includes old and new benchmarks with seven repetitions
and publishes complete measurements even when timing investigations remain open.

Source reference: local MariaDB `b439f350ce3`, `sql/sql_parse.cc` RESET dispatch,
`sql/sql_class.cc` session cleanup, `sql/session_tracker.cc` and
`include/mysql_com.h`. [RESET protocol](https://mariadb.com/docs/server/reference/clientserver-protocol/2-text-protocol/com_reset_connection).


## API use and migration

Consume every result before resetting. The pool boundary is after a request's
statements/streams/transaction helpers finish, not before every query. Reset
removes server statements, so discard every legacy numeric ID; managed handles
reject reuse through their registration generation. Recreate statements needed by
the next request. Initializers use ordinary commands, cannot nest a reset or
`withTransaction` helper, and must finish with no active transaction or stream.

```haskell
void $ resetConnectionWith conn $ \session ->
    void $ execute_ session
        "SET time_zone='+00:00',sql_mode='STRICT_TRANS_TABLES',autocommit=1"
state <- getSessionState conn
-- sessionSchema, sessionAutocommit and sessionVariables carry known observations.
-- Check Nothing/absent entries explicitly; they do not mean server defaults.
```

The existing safe-retirement timeout contract remains unchanged. Connection reset
and prepared-statement reset are different operations: `resetPrepared` preserves
its statement/metadata lifetime; connection reset ends every statement lifetime.

## Final validation record — 7 November 2026

The final executable-input fingerprint is
`870add4dff23c16bc4d2acf0529b47f4bead589bad45edfb818948b392879d4a`,
on uncommitted branch `codex/stage4-session-reuse`, parent `7b545e8`.
Each of three complete Mac runs records **517 PASS / 17 FAIL / 6 UNSUPPORTED /
2 ENVIRONMENT_UNAVAILABLE**, across **542 records**. All **53 new Stage 4 cases**,
the two newly implemented inventory checks, both inherited suites and every
published Stage 3 PASS remain passing. Wrapper exit codes are **0, 0, 0**.

The independent Linux profile records the same counts using GHC **9.4.7** and
MariaDB **12.3.3**; all driver and registered Haskell harness hashes, plus the
library configuration hash, match the current source. All eight native and seven
reuse paths pass Linux smoke checks. Linux timings are not compared with the Mac
baselines. All **129 Python policy tests** pass. Library Haddock succeeds with
**91/91 public Base symbols documented**; internal/inherited link warnings remain
in the retained log.

[Three-run manifest and all reference checksums](../validation/results/stage4-confirmation.json)
· [Linux results](../validation/results/references/stage4-linux.json)
· [Linux log](../validation/results/experiments/stage4-linux.log)
· [Policy log](../validation/results/experiments/stage4-policy.log)
· [Haddock log](../validation/results/experiments/stage4-haddock.log).

### Review corrections

Review found and fixed a retained-byte accounting edge: explicit snapshot seeding
must charge the old tracker envelope that remains retained, rather than charging
only the new helper facts. A regression verifies that this combination cannot
exceed the shared budget. Helpers also preserve the actual latest wire envelope
and do not fabricate tracker events. Opaque SQL invalidates final facts while
retaining the latest real envelope for observers.

The added real-server transaction-tracker-reset check exposed an incorrect
assumption in the first decoder/fixture: `SESSION_TRACK_STATE_CHANGE` carries the
raw byte `1` after its outer length, without the redundant inner string length
used by schema/transaction trackers. The parser and independent literal fixture
were corrected against MariaDB source, then the entire Linux profile was rerun.
The advisory-lock check also passes. The failed development result is retained;
no assertion was weakened or failure reclassified.
[Failed Linux capture](../validation/results/references/stage4-linux-before-state-marker-fix.json)
· [Correction/source identity](../validation/results/experiments/stage4-before-state-marker-fix.json).

### Complete request-boundary measurements

All 39 runnable profiles (24 frozen, eight native, seven reuse) have seven
independent process repetitions in each run. The reuse table below uses the
median of each profile's three run medians; percentages are calculated from
those medians. Baseline is reconnect/initialize/prepare/request/close; Current is
reset/restore/prepare/request on one connection. Both perform identical checked
application work and leave the same state behind. Lower time/allocation is better.
These alternatives are measured on the same build, separately from all historical
baseline comparisons. The live report uses run 3 directly, rather than these
window medians.

| Transport | Baseline ns/request | Current ns/request | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| TCP | 472,666.7 | 346,633.3 | -26.7% | -16.9% |
| TLS | 39,797,300.0 | 437,400.0 | -98.9% | -77.3% |
| Unix socket | 324,200.0 | 264,633.3 | -18.4% | -15.0% |

These local request-boundary results do not predict the speedup of a whole
application with different query or network costs. Original and native benchmark
workloads, the original baseline and the accepted performance reference remain
unchanged. The first reuse capture is separately immutable and checksummed.
Its executable source is reconstructible from `7b545e8`; applying the retained
patch to a clean archive reproduces every input in its fingerprint.
[First reuse baseline](../validation/baselines/macos-arm64-session-reuse/SUMMARY.md)
· [Verified reconstruction](../validation/results/experiments/stage4-first-reuse-source-audit.json)
· [Source patch](../validation/results/experiments/stage4-first-reuse-source.patch).

### Timing investigations remain open

No run has an original/native/reuse >20% timing alarm or an allocation
investigation. Stricter ordinary-profile/reference timing signals number **5,
10, 7** across the window, including unchanged Connector/C controls. Native
baseline comparison has zero timing/allocation signals in every run.

The reuse snapshot profile remains a >5% timing signal in all three runs:
**3.49 ns/call** in the first capture versus **3.87 ns/call** in the final run
(**+10.9%**, or **0.38 ns/call**). The strict loop measures hot snapshot reads,
including its checks, without a result list or SQL. Final measured allocation is
**0.01112 bytes/call**, the amortized fixed measurement/GC cost; it is not a
claim that every call allocates a fractional object. This small absolute signal
is retained rather than waived. No baseline or accepted performance reference
advanced, and the earlier deferred investigations remain open.

The next roadmap stage remains CDC planning after separate approval. This stage
does not implement GTID resume, acknowledgement controls, cursor/long-data APIs,
compression or the missing authentication environment fixtures.

## Follow-up review — 7 November 2026

A later read-only review reproduced three gaps in the current implementation:
active roles survive reset, public collations can remain stale, and switching
transaction tracking from CHARACTERISTICS to STATE retains old characteristics.
These are open findings; the passing checks above do not cover these cases.
See the [review and focused evidence](STAGE4_CODE_REVIEW.md). No implementation
change or benchmark replacement was made in this review pass.

## Review fixes — 8 November 2026

Anton authorized fixing all three findings in the [follow-up review](STAGE4_CODE_REVIEW.md).
Role restoration now captures the constructor's actual active role (including
configured defaults) and reads the post-reset role in the existing rendering
snapshot exchange. A changed role is restored with charset/mode-aware parameter
rendering before database selection and application initialization. The common
unchanged-role path sends no additional command. Disabled tracking can require
an explicit refresh after role/database restoration; any error or deadline
still retires the connection. Initial-role bytes are bounded and owned; later
public refreshes never redefine that restoration target.

MariaDB keys charset/collation trackers by their shared storage offset. Merely
subscribing to both does not provide two independent deltas. The observation
cache therefore discards an unreported alias, releasing its byte charge before
applying replacements. Explicit deltas in either order remain valid. A
collation-only update also invalidates rendering context when it cannot establish
the required charset. No ordinary command or public snapshot gains a helper
query. An explicit refresh establishes both values again.

Downgrading transaction tracking from CHARACTERISTICS to STATE now drops old
characteristics while retaining transaction-state observations. OFF still drops
both. The server's latest actual envelope remains observable.

Sixteen regressions bring Stage 4 to 69 cases. Dedicated role accounts exercise
initially absent/default roles, a Unicode name containing quotes/backticks, latin1
clients, role-dependent database access, initializer overrides and refresh, all
transports, disabled tracking, failure/deadline retirement and bounded snapshots.
Alias tests cover both delta orders, explicit subscription selection and budget
release; transaction tests span read-only/read-write transactions. All 69 focused
cases and 129 policy tests pass; Base Haddock remains 91/91. Full confirmation
results follow after the declared three-run window.

Development evidence is retained: the initial regressions, a 67/69 attempt that
exposed the server's alias behavior, and an explicitly invalid manual run started
before its rebuild completed. The latter is excluded from validation claims.
The role-none initial red fixture also stopped at unknown rendering context
before SET ROLE; that fixture setup was corrected. The earlier review and the
other role cases independently reproduced role leakage.

A final charset-isolation probe reproduced a further variant of the role finding:
two distinct Unicode role names both became the same `?` string in latin1
results. Role snapshots now use `CAST(CURRENT_ROLE() AS BINARY)`, retain validated
UTF-8 bytes in forced owned storage, and compare exact identities. If the initial
role cannot be rendered in the reset client charset, the reset lease temporarily
uses utf8mb4 to set that role, then restores the original charset/collation.
Failures still retire the connection; no target SQL is replayed. Two additional
regressions bring Stage 4 to 71 cases and verify the original latin1 client is
restored. The three earlier full confirmations are retained as superseded evidence,
with their intermediate source versions reconstructible from archived files.

The request-boundary benchmarks measure the usual unchanged-role path. Role
changes require a SET ROLE exchange; unrepresentable role names additionally
require the temporary charset setup/restoration path. These cases have correctness
and deadline coverage but should not be assigned the ordinary path's speedup.

## Review-fix final validation — 8 November 2026
All three review findings, including the Unicode identity collision found during
final review, are fixed and validated. Work remains uncommitted. The final
executable fingerprint is `274775cc0a96c788dded692e1bbd8339fe76dc8ae9c2d92b94b8d7825686bad0`. The live report uses the
declared third run, `stage4-unicode-final-3`.
- Mac and matching Linux: **535 PASS / 17 FAIL / 6 UNSUPPORTED / 2 unavailable**.
- All **71 Stage 4 cases**, both inherited suites and all **517 pre-review passes**
  are preserved. The 18 new regressions pass.
- All **129 policy tests** pass; Base Haddock remains **91/91**.
- Every final Mac run includes **24 frozen + 8 native + 7 reuse profiles**, with
  seven process repetitions each. Original/accepted/native/reuse baselines remain
  unchanged; no performance reference advanced.
The table uses the median of the three run medians for each alternative. Baseline
is reconnect/initialize/prepare/request/close; Current is reset/restore/prepare/
request on the same build. Lower time and allocation are better. The live results
table uses run 3 directly. These are the ordinary unchanged-role request paths.
| Transport | Baseline ns/request | Current ns/request | Change vs baseline | Allocation change |
| --- | ---: | ---: | ---: | ---: |
| tcp | 516,133.3 | 376,533.3 | -27.0% | -16.8% |
| tls | 39,670,466.7 | 465,000.0 | -98.8% | -77.1% |
| socket | 347,333.3 | 293,833.3 | -15.4% | -14.7% |

The final live run measures reset/reconnect time changes of **-26.1% TCP,
-98.8% TLS and -14.8% socket**. No original/native/reuse allocation investigation
is present in any final run. Timing acceptance remains open. Ordinary strict
timing/reference signals number **48, 45, 38** across the window; native signals
number **0, 1, 1**, and reuse signals **5, 4, 6**. The first run exits 1 after
>20% alarms in the unchanged C wide-read control and Haskell text writes; both
subsequent runs exit 0 with no original-baseline >20% alarm. The outlier is
retained, not waived. Final native bulk timing is +7.7% against its first capture;
reuse signals range from +6.4% to +11.8%, including reconnect controls. These
measurements do not isolate how much is host variation versus driver cost.
The final snapshot measurement is 3.72 ns/call and 0.01112 allocated bytes/call.

Linux matched every current driver file, registered Haskell harness file and
normalized library build configuration. It passed all correctness and feature
smoke paths. Its timings were not compared with Mac baselines. A preliminary
Docker disk-full startup failure is retained; four exact task-owned Stage 4 cache
records were removed, with unrelated containers/images/volumes untouched.

[Full final confirmation](../validation/results/stage4-fixes-confirmation.json)
· [Final Linux evidence](../validation/results/references/stage4-unicode-linux.json)
· [Superseded initial window and reconstructible source](../validation/results/stage4-fixes-initial-confirmation.json)
· [Initial red regressions](../validation/results/experiments/stage4-fixes-before.json)
· [Final focused regressions](../validation/results/experiments/stage4-fixes-focused-final.json)
· [Reproduced charset collision](../validation/results/experiments/stage4-role-charset-probe.log)
· [Current live results](../validation/RESULTS.md).

## Publication approval — 8 November 2026

Anton approved committing and pushing the reviewed implementation and evidence.
The review measurements above retain their original working-tree fingerprints.
Publication runs the complete suite again after the implementation commit, then
publishes the generated live report in a separate results-only commit. The live
report identifies the actual tested revision. All timing investigations and
immutable/accepted references retain their previous status.

## Committed publication — 8 November 2026

Implementation commit `f2835647de4b650a8755d0216d384159a6b858e5` passed a fresh complete
committed-input run with exit 0: **535 PASS / 17 FAIL / 6 UNSUPPORTED /
2 unavailable**. All 71 Stage 4 checks and both inherited suites pass. The
17 existing CDC/timeout-expectation failures retain their original status.
All 129 publication/policy tests pass, and the strict committed-results guard
passes without a working-tree override.

Each of the 24 frozen, eight native and seven reuse profiles has seven process
repetitions. This run has no original/native/reuse >20% timing alarm or allocation
investigation. Six stricter ordinary timing/reference signals remain open; native
and reuse comparisons have no >5% timing signals in this capture. Earlier timing
outliers and investigations remain retained, and no baseline or accepted
performance reference advances. Reset request times are 25.1% lower over TCP,
98.9% lower over TLS and 20.3% lower over Unix sockets than same-build reconnect
requests. These measurements apply to the ordinary unchanged-role path.

The input fingerprint is `16a2d8939fb7c44241deaa7662391c846af97821b291e177a50887e4d5703365`. Driver, registered
Haskell harness and normalized library configuration match the final Linux
535-pass evidence. A trailing-blank-line cleanup in the shared Python recorder
preceded this publication run; the exact earlier review bytes are archived.

[Publication manifest](../validation/results/stage4-publication.json)
· [Committed correctness/frozen run](../validation/results/references/stage4-publication-1.json)
· [Native benchmarks](../validation/results/references/stage4-publication-1-native.json)
· [Reuse benchmarks](../validation/results/references/stage4-publication-1-reuse.json)
· [Full process log](../validation/results/experiments/stage4-publication-1.log).
