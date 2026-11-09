# MariaDB driver development

User instruction, 8 November 2026: develop directly on `main` unless Anton
explicitly requests a new branch. Inspect and preserve the working tree first.
The current Stage 5 follow-up review authorizes finding and fixing code errors,
with regression coverage and refreshed validation results.

This fork targets MariaDB only. Preserve protocol identifiers that MariaDB uses;
do not add a MySQL server support target.

Before changing `src/` or the library's build options, read `validation/README.md`
and `validation/COVERAGE.md`. Install, start and verify a real MariaDB server
before integration or performance runs. A missing server is a failed preflight,
not permission to substitute synthetic results.

Keep the initial files under `validation/baselines/` immutable. Run the same suite
before and after driver changes and compare against the recorded baseline. Do
not remove checks, weaken assertions, or hide failures with expected-failure
wrappers to obtain a green result. Keep unsupported APIs and unavailable
environment fixtures explicit. Record newly passing checks as improvements.

User requirement, 6 November 2026: `main` must contain a LIVE results document,
clearly linked from the main README, updated for every tested code change.
`validation/RESULTS.md`, `validation/results/current.json` and the generated
`validation/results/overview.svg` are that live record.
Before pushing code or test/build input changes to `main`, commit those inputs,
run the full `python3 validation/check.py` on the committed code, then commit and
push all three updated results files. The wrapper rebuilds first, compares with the
original baseline by default, and publishes complete results including failures.
Partial/short development runs do not replace the full report. A failed full
attempt updates the live status and labels retained older results explicitly.
Run `python3 validation/publish_results.py --check` before pushing; CI repeats
this stale-results guard. Results-only publication and other documentation-only
commits do not require an endless rerun cycle. If executable inputs change after
a run, rerun before publishing. Never hand-edit measured values or substitute
older results for the current source. Preserve the original reference separately.

Keep comparison tables consistent: Baseline, Current, then Change vs baseline.
Label units and define the change calculation and direction explicitly.
Keep the report readable on GitHub: use the generated colored summary, status
markers with text labels, native callouts and expandable detailed findings.
Colors must not imply a missing feature is a pass or hide a timing regression.

Compare performance only with matching workloads, compiler, dependencies,
machine and server settings. Preserve old profiles when another environment
needs its own baseline. Document actual commands and results, including failures.

Historical override, night of 6–7 November 2026: implement the approved Stage 1 plan
and repeatedly validate/fix it, but leave ALL changes uncommitted for Anton's
morning diff review. Do not commit or push during this implementation run.
Use `python3 validation/check.py --working-tree` for an honestly fingerprinted
uncommitted full run, and `python3 validation/publish_results.py --check
--working-tree` for review freshness. Normal committed-publication/CI checks
remain strict; a review run does not claim its parent commit contains the code.
Publication to main follows human review, not this overnight authorization.

Superseding user instruction, 7 November 2026 after two review passes: commit
and push the reviewed Stage 1 changes. Publish on main using the committed-input
validation workflow above. Performance investigations are postponed; retain
their evidence and open status, preserve the original baseline and do not
silently advance the accepted performance reference. Propose the next stage
without implementing it before approval.

User requirement, 7 November 2026: this is a public open source project; write
maintainable, idiomatic Haskell and useful comments with every change. Document
public types/functions with Haddock, including ownership, lifetime, error and
resource-limit contracts. Explain protocol invariants, cancellation boundaries,
SQL-classification assumptions and measured performance choices where they are
implemented. Prefer named fields, ordinary layout and small composable helpers
over positional Boolean arguments or compressed imperative-looking code. Keep
comments accurate and explain why a subtle choice exists; avoid narrating
obvious expressions. Apply the same readability standard to validation tools.

User approval, 7 November 2026: implement Stage 2 native connections and
MariaDB authentication fully, repeatedly check/fix, then run the unchanged
correctness/benchmark suite and report. Include 64-bit native capability
negotiation, ed25519/PARSEC/SHA-2 authentication, TLS/certificate/CA fixes,
bounded address fallback and Linux integration coverage. The previously deferred
Stage 1 performance work remains deferred. Preserve original and accepted
references and protect every published Stage 1 PASS separately.

Superseding user instruction, 7 November 2026 after idle-host confirmation:
commit and push the reviewed Stage 2 changes. Publish on main using the
committed-input validation workflow above. Preserve the original and accepted
performance references and all review evidence. The next stage is a proposal
until separately approved; this publication does not authorize its implementation.

User approval, 7 November 2026: proceed with roadmap steps 1–2 (prepared
statement/result foundations, then binary bulk, metadata caching and extended
metadata), and record the full five-step sequence for continuation. See
docs/ROADMAP.md. Keep safe retirement as the timeout default and retain the
conflicting original baseline expectation explicitly. Steps 3–5 remain future
work. Preserve frozen workloads and original/accepted performance references.

Stage 3 full runs include the additive native-feature benchmarks automatically.
Retain their embedded evidence and process logs; never omit them to obtain a
passing publication. The first native-feature baseline under
validation/baselines/macos-arm64-native-statements is immutable independently of
the original unchanged-driver baseline. Maintain docs/ROADMAP.md as the
continuation point and update its completed/remaining work with measured evidence.


Superseding user instruction, 7 November 2026 after the Stage 3 review fixes:
commit and push the reviewed prepared/native implementation and retained evidence.
Publish on main using the committed-input validation workflow above. Preserve
original, accepted and first-native baselines and the open timing investigations.
Roadmap steps 3–5 remain future work until separately approved.

User approval, 7 November 2026: proceed with roadmap step 3, clean-session reset
and public session-state reporting, following the proposed scope. Implement and
review, exercise real-server isolation/fault cases, measure full reset/restoration/
preparation versus TCP/TLS/socket reconnection, and refresh the full live report.
Keep default timeout retirement and all immutable/accepted performance baselines.
The current implementation pass remains uncommitted for review; later CDC and
workload-specific stages are outside this authorization.

User approval, 8 November 2026: fix all three Stage 4 follow-up findings: active
role restoration, charset/collation observation coherence and transaction tracker
downgrade invalidation. Add real regressions, rerun full correctness/performance
and refresh the live report. Keep this work uncommitted for review and preserve
every immutable baseline and deferred timing investigation.

Superseding user instruction, 8 November 2026 after the Stage 4 review fixes:
commit and push the reviewed session-reset/session-observation implementation
and retained evidence. Publish on main using the committed-input validation
workflow above. Preserve original, accepted, native and first-reuse baselines
and all open timing investigations. Later roadmap stages still require approval.

User approval, 8 November 2026: proceed with Stage 5 CDC implementation as
proposed: decoder correctness, transaction/checkpoint model, MariaDB GTID resume,
consumer-controlled acknowledgements, bounded streaming and additive correctness/
performance validation. Preserve all published passes and immutable references;
leave implementation uncommitted for review. See docs/STAGE5_IMPLEMENTATION.md.

Superseding user instruction, 8 November 2026: merge all current Stage 5 work
into main, commit and push it to GitHub. Use the committed-input publication
workflow above, retaining the review captures and immutable baselines. Keep
deferred timing investigations and explicit CDC limitations visible. Later
workload-specific APIs remain outside this publication authorization.

Superseding user instruction, 8 November 2026 after the Stage 5 follow-up review:
commit and push all reviewed CDC fixes and retained evidence directly on main.
Use the committed-input publication workflow above, preserve immutable references
and earlier unsuccessful attempts, and keep deferred timing investigations visible.

User approval, 8 November 2026: implement phase 1 of the remaining capabilities:
streamed long-data parameters, server cursor fetch, MariaDB progress callbacks
and opt-in transport compression. Add correctness/fault tests and independent
benchmarks, protect all 694 published passes and preserve frozen workloads and
references. Develop on main and leave changes uncommitted for review. PAM/GSSAPI
and a different timeout-recovery contract remain outside this phase.

User approval, 9 November 2026: fix all Stage 6 review findings, then run the
complete documented correctness/benchmark workflow and refresh the live report.
Include repeated cursor cancellation, compressed semisync acknowledgements and
an effective fresh-chunk heap workload with a buffering negative control.
Keep prior evidence and references intact. Continue on main, leaving the work
uncommitted for review; no commit or push was requested.

Superseding user instruction, 9 November 2026 after the Stage 6 review fixes:
commit and push the reviewed implementation and retained evidence directly on
main. Use the committed-input publication workflow above, preserve all immutable
references and unsuccessful attempts, and keep timing investigations visible.
Provide the GitHub link to the refreshed live report after verifying the push.


User approval, 9 November 2026: close the PAM/GSSAPI authentication gaps with
real client support and isolated reproducible fixtures. Keep safe retirement
and correct the obsolete timeout-reuse expectation to explicit retirement
assertions. Preserve the original baseline/history and label the change as a
test-contract correction, not a driver fix. This supersedes the earlier rule
requiring that particular contradictory assertion to remain unchanged. Work on
main and leave implementation uncommitted for review unless publication is
separately requested. Avoid unnecessary repeated full benchmark runs when a
complete matching capture already exists.


User approval, 9 November 2026 after the Stage 7 review: fix all five findings
in docs/STAGE7_CODE_REVIEW.md. Preserve callback exception identity and real
server errors while sanitizing malformed authentication decodes; enforce the
authentication limit before body reads without adding query-loop phase checks;
share full-run classification; clean up owned partial container creation; and
avoid external services for non-live filtered checks. Add regressions and refresh
the required complete correctness/performance report. Continue on main with all
changes uncommitted for review; preserve earlier captures and immutable baselines.


User instruction, 9 November 2026 after the Stage 7 review fixes: commit and
push the reviewed changes and existing complete results directly on main. Keep
the exact pre-commit measurements and their provenance; do not relabel them as
a fresh committed-input run. No additional benchmark confirmation is requested.
