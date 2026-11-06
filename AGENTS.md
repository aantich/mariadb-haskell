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

Compare performance only with matching workloads, compiler, dependencies,
machine and server settings. Preserve old profiles when another environment
needs its own baseline. Document actual commands and results, including failures.
