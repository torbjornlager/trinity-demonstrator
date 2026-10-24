# Separate SWI HTTP shutdown repair — 24 October 2026

## Outcome

The bounded repair passes the new regression tests, callback batches, HTTP cleanup checks and complete native T4 suite. The report, standalone reproducer and complete verified patch were submitted as [SWI-Prolog/packages-http #176](https://github.com/SWI-Prolog/packages-http/issues/176).

The repair changes only `http_enough_workers/3` in `thread_httpd.pl`. It rethrows exceptions recognized by the existing `accept_rethrow_error/1` predicate, including `http_stop(_)`, allowing the acceptor's shutdown handler to run. Ordinary scheduling errors retain their existing reporting and recovery.

## Candidate isolation

The original staged candidate remains at:

`~/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23`

The new private candidate is:

`~/.local/share/trinity-runtime-tests/swipl-http-shutdown-2026-10-24`

Its executable is `install/bin/swipl`. The entire staged installation was copied to the new prefix, then only the installed Prolog HTTP-library file was patched. Native binaries are identical to the original tested build; no C compilation is necessary for this Prolog-library repair. A private HTTP package source copy contains the matching change, regression module and CMake test registration. Matching SSL source-tree certificate fixtures were also copied for the upstream proxy tests.

`candidate.json` identifies the exact core and HTTP package commits. The patch is relative to the HTTP package root and passes `patch --dry-run` against the original package source.

## Verification

| Check | Result |
| --- | --- |
| Original standalone gated reproducer, unpatched candidate | Reproduces the stall; original 30-second watchdog expires |
| New three-case regression suite, patched candidate | 20/20 fresh processes pass; 60 case executions |
| Unmodified callback-sandbox test | 30/30 fresh processes pass |
| Native paging and HTTP cache eviction/TTL/isolation cleanup | 5/5 batches pass, 14 scheduled cases each |
| Complete native T4 | All 983 scheduled cases pass |
| Upstream HTTP test entry point | pass |
| Upstream CGI-stream, multipart, WebSocket, GraphQL and SSE entry points | pass |
| Upstream proxy, with source-tree certificates present | All 13 cases pass |
| Patch application dry run | pass |

The original test assertions and timeouts were preserved. The callback trials and new regression batches retain the 30-second outer watchdog. Existing cleanup-case timeouts are unchanged; their batch watchdog is 60 seconds, and complete T4 retains its 300-second outer watchdog. No failed trial was silently retried to count it as passing.

The initial proxy run failed because the copied HTTP test tree did not include its sibling SSL certificate fixtures. Its subsequent address-in-use failures followed the failed fixture setup within that process. `upstream-proxy.log` preserves that failed run. After restoring the matching fixtures, `upstream-proxy-fixtures-restored.log` records all 13 passing cases. This is a separate corrected test setup, not a hidden rerun of an unexplained runtime failure.

The ordinary-scheduling-error regression deliberately throws `error(test_scheduler_error,_)`. Its logged error is expected; successful completion of both HTTP requests and shutdown is the asserted recovery behaviour. Occasional `current_output closed; set to user_output` messages are retained in logs and did not fail the assertions.

## Deliverables

- `http-shutdown.patch`: minimal library change, regression module and CMake registration.
- `test_thread_httpd.pl`: runnable standalone regression module.
- `UPSTREAM-REPORT.md`: prepared issue/report text with cause, reproducer instructions and verification qualifications.
- `run.py`, `results.json`, individual logs: commands, per-process status, elapsed time and watchdogs.
- `summary.json`: consolidated outcomes and preservation result.
- `before.json`, `after.json`: source/binary hashes and protected live process commands.

The original investigation and raw standalone reproducer remain in `../swi-callback-stall-2026-10-24/`.

## Preservation and next step

All recorded tracked Prolog/shell source hashes and installed runtime executable hashes remain unchanged. The full original staged installation manifest also matches, with no changed files. Protected n3/n5 process identities and commands are unchanged. The new source, patch, tests and runtime prefix are private candidate artifacts only.

This closes the identified callback-stall blocker for the tested candidate. It does not switch n3 or install a new default runtime. The next step is upstream review of the prepared patch, followed by a separately authorized runtime update decision.
