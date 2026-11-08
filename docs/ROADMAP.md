# MariaDB driver roadmap

Accepted sequence, 7 November 2026. This file is the continuation point for future
work. It records priorities, dependencies and completion evidence; an unchecked
item is not an implemented feature. The [live validation report](../validation/RESULTS.md)
and its original frozen baseline remain the source of measured results.

## Implementation sequence

Anton approved proceeding with steps 1–2 below. Work started from published
Stage 2 `e12462a`, on `codex/stage3-native-statements`.

1. **Prepared result and statement foundations — implemented and validated.** Resolve the two
   prepared OUT failures, expose complete prepared multiple results, and provide
   connection-owned statement handles with explicit close/reset and metadata
   lifetime. Preserve the existing streaming/raw-ID APIs. Reject foreign/closed
   handles and incorrect parameter counts before sending bytes.
2. **Native MariaDB performance — implemented and validated.** Add bounded
   binary bulk execution, prepared metadata caching and extended column metadata.
   Distinguish aggregate bulk results from optional per-operation results. Never
   replay or silently split a failed batch. Cache by statement ownership and
   result shape; replace metadata on server refresh/reprepare and invalidate on
   close or terminal failure. Preserve matching metadata on statement reset,
   which does not reset server omission state. Enable only fully implemented
   negotiated capabilities.
   Measure new workloads separately while preserving every frozen workload.
3. **Safe connection reuse — implemented and validated; publication approved.** Expose session changes already
   processed internally and add `COM_RESET_CONNECTION` for clean sessions.
   Invalidate prepared handles/caches and restore required session settings.
   Resetting a session does not recover a desynchronized transport.
4. **Complete CDC — future stage.** First fix the 16 existing event/table-map/
   checksum failures. Design GTID resume and explicit acknowledgement/checkpoint
   controls alongside the event model, then implement them on the corrected
   decoder. Test rotation, transaction boundaries, corruption and recovery using
   real MariaDB logs. Move this stage earlier if the first application needs CDC.
5. **Workload-specific features — future stage.** Cursor fetch, long-data upload,
   compression, progress callbacks and PAM/GSSAPI fixtures, ordered by actual
   workloads and measured benefit. These are separate API/environment gaps.

## Timeout contract

The frozen `reliability.timeout-before-metadata` test requires immediate reuse
after cancelling `SELECT SLEEP(0.2)`. Published Stage 1's
`stage1.timeout.connection-retired` performs the same operation and requires
terminal retirement. Both expectations cannot pass unchanged. Keep retirement
as the default, retain the original failure and baseline, and document the
conflict rather than weakening assertions. Any future bounded recovery API
needs an explicit contract and independent cancellation/desynchronization tests;
it must never replay SQL or claim an uncertain transaction succeeded.

## Acceptance and continuation record

- [x] Stage 1 query correctness and Stage 2 native connections published.
- [x] Five-step sequence saved and linked from the main README.
- [x] Step 1 prepared statement/result implementation and regression tests.
- [x] Step 2 bulk/cache/extended metadata implementation and regression tests.
- [x] Existing published PASS records preserved; new feature inventory entries
      replaced with executable checks. Remaining CDC/timeout gaps stay visible.
- [x] Full unchanged suite and seven-repetition benchmarks rerun on stable
      inputs; additive native benchmarks retain checksums, allocations and all
      samples. Preserve original and accepted performance references.
- [x] Public API/migration comments and implementation evidence reviewed.

Each completed stage should add its implementation/evidence link here and leave
the next unchecked item as the resumption point. Previously deferred narrow-read,
text-write and setup-cost investigations remain open; new features do not waive
those measurements or advance the accepted performance reference.

## Stage 3 continuation checkpoint — 7 November 2026

Steps 1–2 are implemented and validated on `codex/stage3-native-statements`,
with review completed and publication authorized on 7 November 2026. Read the
[implementation/API and measured results](STAGE3_IMPLEMENTATION.md) and [live report](../validation/RESULTS.md).
Post-review Mac and Linux results: **462 PASS / 17 FAIL / 8 UNSUPPORTED / 2 unavailable**;
all 56 additive cases and 101 policy tests pass. Native bulk and metadata caching
have measured same-build benefits; ordinary-profile timing investigations remain
open, with no accepted-reference advancement. The four review issues are fixed,
including buffered cleanup deadlines, incremental metadata accounting, required
native baseline publication checks and overflow-safe bulk bounds. Dependency
JSON normalization also restores native baseline comparisons. The three new
full runs and the 38.2% large-registry diagnostic improvement are recorded in the
[review-fix evidence](STAGE3_IMPLEMENTATION.md#review-fix-validation-and-measurements).

- [x] Review Stage 3 and authorize publication using the committed-input workflow.
- [x] Test committed implementation `ef4e52b23418` on `main` and record the
      full publication results: wrapper exit 0, all 56 Stage 3 cases passing,
      nine stricter ordinary timing investigations and no allocation signals.
      [Publication evidence](STAGE3_IMPLEMENTATION.md#committed-publication--7-november-2026)
      retains the historical timing alarms; performance acceptance remains open.
- [x] Step 3 clean-session reset and public session-state reporting approved
      and implemented in Stage 4 below. Default timeout retirement is preserved;
      an out-of-sync transport is never reset and statements are never replayed.
- [ ] Then complete step 4 CDC before adding GTID resume/durable acknowledgement.
- [ ] Prioritize step 5 features using actual workload demand.

## Stage 4 continuation checkpoint — 7 November 2026

Anton approved clean-session reset and public session-state reporting after Stage
3 publication. Work is on `codex/stage4-session-reuse`, based on `7b545e8`, and
remains uncommitted for review. [Contracts and validation record](STAGE4_IMPLEMENTATION.md).
The initial focused pass covered 38 cases and the two former unsupported
capabilities. Final Mac/Linux results are **517 PASS / 17 FAIL / 6 UNSUPPORTED /
2 unavailable**, including all 53 Stage 4 cases and 129 policy tests. Three full
Mac runs each include 39 profiles with seven repetitions and complete with exit
0. Full-cycle reset requests improve on reconnects on all three transports;
strict timing signals remain open, including the hot snapshot microbenchmark.
The previous-stage correctness reference now protects all 462 published Stage 3
passes. Original, accepted and first-native performance baselines are unchanged.

- [x] Approve step 3 implementation and its full validation/benchmark scope.
- [x] Complete review, full Mac/Linux correctness and reuse measurements.
- [x] Update the live report with declared run 3 and retain the full window.
- [x] Human review and publication authorized on 8 November 2026.
- [ ] Resume CDC planning after separate approval.

### Stage 4 review corrections — 8 November 2026

All three follow-up findings are fixed, including exact Unicode role identity
under narrow/binary result charsets. Final Mac and Linux profiles record 535
PASS / 17 FAIL / 6 UNSUPPORTED / 2 unavailable; all 71 Stage 4 cases and all 517
pre-review passes survive. Policy tests pass 129/129 and Base Haddock is 91/91.
Three full final Mac runs retain every benchmark and timing alarm; the declared
third run supplies the live report. Allocation checks pass; timing investigations
remain open and no performance reference advances. All changes remain
uncommitted. [Fixes and final evidence](STAGE4_IMPLEMENTATION.md#review-fix-final-validation--8-november-2026).
The next roadmap step remains CDC planning after separate approval.

### Publication authorized — 8 November 2026

Anton approved commit and push after the review fixes. Publish the reviewed
implementation and retained evidence, run the complete suite on the committed
inputs, then publish refreshed live results with that tested commit. Earlier
uncommitted records above remain historical; no performance reference advances.
