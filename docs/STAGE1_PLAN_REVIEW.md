# Stage 1 plan review: findings and corrections

**Reviewed: 6 November 2026**

**Outcome: Version 2 is ready for Anton’s approval; implementation has not started.**

This review checks the first draft against the driver, MariaDB server source, existing tests, current measurements and publication policy. It does not certify an implementation that has not yet been written. The [final proposed plan](STAGE1_IMPLEMENTATION_PLAN.md) contains the resulting contract.

Draft 1 SHA-256: `b318af4f7e09040fd467e629845f4df483c8cf568ad8f03aef0af4c2ca11958b`. The original draft was retained locally during review. Version 2 supersedes its proposed decisions; neither version is an approved implementation.

## Performance and experiment design

| Finding in the first draft | Why it matters | Correction in Version 2 |
| --- | --- | --- |
| One context SELECT before every text-parameter call | Adds a network/server exchange on precisely the small operations where latency matters; existing raw/prepared benchmarks would not expose it. | Negotiate bounded internal tracking and cache validated context. Add direct parameterized/mixed-call benchmarks and command-count assertions. |
| Authoritative transaction SELECT on every helper entry | Pays an extra exchange even when the preceding final status already proves transaction state. Existing write benchmarks use explicit SQL and would miss the helper overhead. | Use cached final IN_TRANS status; probe only when genuinely unknown, under the helper lease. Benchmark helper entry separately. |
| Discovery queries treated as observationally harmless | An internal SELECT can change the value seen by subsequent ROW_COUNT(), not just timing. | No hidden rendering refresh between application statements. Unknown context yields a typed error; refresh is explicit. Test preceding-statement/session-information semantics. |
| Session tracking deferred while the design depends on session state | A fast safe context cannot be obtained simply by reading ordinary status bits; complete lexer context includes more than escape mode. | Bring forward implemented capability negotiation, internal tracking payloads and OK result terminators. Keep complete public tracking APIs deferred. |
| Only the original 20% timing alarm | A repeatable 10–19% slowdown could pass despite the project’s emphasis on performance. | Keep the original alarm; add a separate 5% acceptance investigation gate for timing and allocation against original and preceding accepted measurements. |
| Scan/value fixes without a specific allocation work item | The current wide scan allocates about 30.5 KB per row, so adding more repeated dispatch could compound a visible cost. | Profile and implement bounded per-result decoder preparation, one-pass checked parsing and buffer/template improvements; retain only measured benefits. |
| Startup excluded from original benchmark timing | New session initialization could look free in every original result. | Add supplementary connection-setup measurements without changing original timing regions. |
| Unspecified ownership-check cost | A state redesign can introduce per-field locks/allocations or a global bottleneck. | Keep ownership at command/stream boundaries, no per-cell synchronization, no global lock; measure latency and parallel profiles. |
| Generic advice to avoid copying | Zero-copy slices can retain a huge packet for a tiny surviving value; indiscriminate copying has the opposite cost. | Add a retained-heap experiment and require evidence for any targeted slice-copy policy. |
| New experiments appended to the original benchmark list | The frozen recorder would execute them without an original reference and could complicate comparison/dispatch. | Separate supplementary module/runner, manifest and old-driver reference; preserve original enumeration and functions. |
| Timing retries without a predefined decision rule | Repeated runs can accidentally become selection of a favorable sample. | Predeclare a three-run confirmation window, retain all evidence and C controls, and keep inconclusive timing explicitly unresolved. |

## Robustness, semantics and scope

| Finding in the first draft | Why it matters | Correction in Version 2 |
| --- | --- | --- |
| Per-command ownership alone | Another thread can enter between statements of a transaction body while the response state is Ready. | Add an owner lease spanning the entire helper body and completion. Keep response phase separate from operation/transaction ownership. |
| Automatic sequential fallback for uncertain batches | Changes one COM_QUERY into multiple commands, altering execution boundaries and performance. A lexer cannot prove arbitrary SQL side effects. | Preserve supported flat batches as one command; reject ambiguous parameterized batches before any part executes. Explicit caller sequencing remains possible. |
| Session-tracker configuration ownership unspecified | Replacing a tracker list could drop proxy-installed selections; an application could invalidate the driver’s cache by disabling tracking. | Extend the current session list, preserve '*' and unrelated entries, track/validate configuration, invalidate on uncertainty and provide explicit refresh. Bypassing these invariants is unsupported. |
| Stored routines assumed to leave readily inferred mode state | MariaDB saves/restores routine SQL mode directly; intermediate result notifications need not prove the final outer context. | Validate real CALL/multi-result behavior and invalidate opaque context rather than trusting a prefix or intermediate notification. |
| Legacy EOF retained without the OK-terminator dependency | Legacy EOF cannot carry the full session-change payload needed at all result boundaries. | Implement and test both formats before negotiating; cover text/binary rows, prepare/execute and metadata omission separately. |
| 384 MiB default copied from the local fixture | An environment setting is not a reason for a product’s default memory policy. A per-message limit also does not bound aggregate metadata. | Explicit 64 MiB message default, 16 MiB metadata budget, configurable larger messages and checked count/allocation limits. No full-result buffering. |
| Blanket cancellation classification | Timeout exceptions need not be SomeAsyncException; pure pre-send failures should not automatically destroy a healthy connection. | Base cleanup on phase and whether I/O could have advanced. Preserve the original exception; cleanly release claims on validated pre-send failures. |
| Close could wait behind blocked I/O | A lock-held read can prevent the very abort needed to cancel it. | Active close aborts the transport without waiting for the command lock; graceful close is only for a clean connection and is bounded. |
| Stale statement-ID safety overstated | A raw numeric ID cannot distinguish an old statement from a later statement with the same reused ID. | Guard unread responses and track useful local state, but explicitly defer generation-safe typed statement handles. |
| Metadata round-trip failure omitted | It is a small core protocol defect and can also corrupt synthetic fixtures for the planned refactor. | Include protocol.column-definition-roundtrip and validate byte fixtures independently; target becomes 23 original failures. |
| Numeric/date checks could normalize valid MariaDB values | Checked parsing must preserve zero/invalid dates and TIME durations while rejecting malformed wire values. | Separate raw date components, calendar types and TIME duration ranges; one shared text/binary preservation contract. |
| Unknown charset behavior insufficiently explicit | Guessing UTF-8 corrupts values; returning bytes without explaining Field Text behavior surprises callers. | Strict supported decoders, exact bytes plus ColumnDef for unmapped charsets, and checked text-conversion behavior. |

## Evidence and acceptance integrity

| Finding in the first draft | Why it matters | Correction in Version 2 |
| --- | --- | --- |
| Original-baseline comparison is the only correctness gate | run.py compares each candidate with the original status. An original FAIL fixed in one revision may fail again without a regression alarm. | Add a last-accepted correctness ratchet, preserving all new passes as well as original passes. |
| Live current results can overwrite the previous comparison candidate | A failing attempt must not become its own reference or erase the accepted state. | Capture the accepted result/hash before publication; advance the accepted manifest only after gates pass. Keep failed attempts visible. |
| Acceptance reference’s Git provenance left implicit | A publication commit cannot contain its own future commit hash without a self-reference problem. | Reference tested-input/source hashes and the accepted result blob/hash. Git history retains the publication; no self-referential publication SHA is required. |
| Broad claims about tested server coverage | Source inspection of 13.2 alpha is not an integration run on that version. | Distinguish the runtime 12.3.3 profile, checked-out server source and separately identified CI environments. |
| Public shape/API migrations not fully bounded | Internal tracking does not require another public OK record-shape break; custom rendering and raw constructors do need explicit migration. | Keep tracking in internal envelopes; list intended public changes, typed unknown-context error and refresh behavior. |
| The timeout and partial-result transaction cases look similar but require different outcomes | Safe retirement cannot satisfy a same-session temporary-table assertion. | Preserve both original contracts: timeout reuse deferred; intact partial-response drain plus rollback is a required pass. |

## Source evidence

The review used driver main `90f4f54ce17d8336011f0193326819563acd29df`, whose library source remains the original fork implementation, and server checkout `b439f350ce3a8306c77e64bc1679681320244d17`. These source findings are design inputs; runtime behavior still requires the planned tests.

- Driver [parameter rendering](../src/Database/MySQL/Query.hs), [transaction and result APIs](../src/Database/MySQL/Base.hs), [connection state](../src/Database/MySQL/Connection.hs), [value decoders](../src/Database/MySQL/Protocol/MySQLValue.hs), [packet helpers](../src/Database/MySQL/Protocol/Packet.hs) and [column serialization](../src/Database/MySQL/Protocol/ColumnDef.hs) establish the existing behavior and affected paths.
- [Original protocol cases](../validation/hs/Validation/Protocol.hs), [multi-result contracts](../test/MultipleResults.hs), [frozen workloads](../validation/hs/Validation/Benchmark.hs), [comparison logic](../validation/run.py) and [publication provenance](../validation/publish_results.py) establish the assertions, measurement boundaries and original-only comparison limitation.
- The server’s [OK/EOF production](https://github.com/MariaDB/server/blob/b439f350ce3a8306c77e64bc1679681320244d17/sql/protocol.cc#L210) shows tracking payload handling and negotiated result terminators. [Tracker serialization](https://github.com/MariaDB/server/blob/b439f350ce3a8306c77e64bc1679681320244d17/sql/session_tracker.cc#L455) and [variable update hooks](https://github.com/MariaDB/server/blob/b439f350ce3a8306c77e64bc1679681320244d17/sql/set_var.cc#L250) show the source mechanism. [Routine execution](https://github.com/MariaDB/server/blob/b439f350ce3a8306c77e64bc1679681320244d17/sql/sp_head.cc#L1222) saves SQL mode and restores it directly later in the same function; the plan therefore requires runtime evidence around intermediate results and restoration.
- Official [result-set rules](https://mariadb.com/docs/server/reference/clientserver-protocol/4-server-response-packets/result-set-packets), [OK packet/tracking format](https://mariadb.com/docs/server/reference/clientserver-protocol/4-server-response-packets/ok_packet) and [session variables](https://mariadb.com/docs/server/server-management/variables-and-modes/server-system-variables) support the protocol design. Retrieved 6 November 2026.
- Official [ROW_COUNT](https://mariadb.com/docs/server/reference/sql-functions/secondary-functions/information-functions/row_count) documents preceding-statement semantics. The [diagnostics area](https://mariadb.com/docs/server/reference/sql-statements/programmatic-compound-statements/programmatic-compound-statements-diagnostics/diagnostics-area) has its own preservation rules, so the plan does not assume all diagnostic information resets identically. Retrieved 6 November 2026.
- [MariaDB executable comments](https://mariadb.com/docs/server/reference/sql-statements/comment-syntax) and [charset/collation rules](https://mariadb.com/docs/server/reference/data-types/string-data-types/character-sets/setting-character-sets-and-collations) support the lexer and explain why replacing every text literal with a convenient alternative representation requires semantic tests. Retrieved 6 November 2026.
- The [current JSON](../validation/results/current.json), run timestamp `2026-11-06T21:57:01.429300+00:00`, supplies the observed timings/allocation figures. Allocation values in the plan are medians of per-sample allocated_bytes / units. No new driver speedup was measured during this document review.

## Remaining implementation risks

Session tracking across intermediate routine results, the checked lexer’s grammar and exception-safe ownership are the highest-risk parts. Deterministic fixtures plus real-server tests are mandatory before enabling the relevant fast path. The per-result decoder plan and extra checks may help or hurt different workload sizes; the performance gates decide which implementation survives. Legacy capability paths and raw statement IDs have explicit limits, not implied guarantees.

Scope remains deliberately bounded: no bulk protocol, cross-execution metadata cache, new auth plugin or CDC feature implementation. The review improves the proposed first stage without claiming to resolve those later projects.
