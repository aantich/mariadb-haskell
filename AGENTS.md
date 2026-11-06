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
`validation/RESULTS.md` and `validation/results/current.json` are that live record.
Before pushing code or test/build input changes to `main`, commit those inputs,
run the full `python3 validation/check.py` on the committed code, then commit and
push both updated results files. The wrapper rebuilds first, compares with the
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

Compare performance only with matching workloads, compiler, dependencies,
machine and server settings. Preserve old profiles when another environment
needs its own baseline. Document actual commands and results, including failures.
