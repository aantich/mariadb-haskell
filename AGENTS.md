# MariaDB driver development

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
