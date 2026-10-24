# SWI callback-stall investigation — 24 October 2026

## Finding

The callback is rejected correctly and the expected sandbox error reaches the HTTP client. The intermittent stall occurs afterward, while the fixture calls `http_stop_server/2`. The cause is a shutdown exception swallowed by SWI's HTTP worker-scheduling error handler, not callback execution or Web Prolog's timeout policy.

This investigation uses the separate staged SWI build at:

`~/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/install/bin/swipl`

Core commit: `09b6299f696574c9230f23e53b1ab041a942b6f3`. This identifies the tested build; this report makes no claim about later upstream revisions.

No runtime source changes or fixes were applied. Installed runtimes and the existing n3/n5 processes were left unchanged.

## Cause and evidence

The original test is `node:isobase_yield_timeout_callback_is_sandboxed` in `tests/tiers/node/node_tests.pl`. It requests a promise and attempts `nb_getval(secret,_)` in the timeout callback. Its assertions require an error JSON answer containing `sandboxed`. The unmodified test reaches fixture cleanup after receiving that error.

In the staged library `library/ext/http/http/thread_httpd.pl`, `http_enough_workers/3` catches errors from `http:schedule_workers/1` (around line 589):

```prolog
catch(http:schedule_workers(Data),
      Error,
      print_message(error, Error))
```

The server's shutdown routine signals the acceptor with `throw(http_stop(Main))`. If this arrives inside the scheduling hook, the inner catch consumes it and prints it as an ordinary error. The acceptor continues to `tcp_accept/3`, instead of allowing the outer `accept_server/3` shutdown handler to retire it and notify the caller. The shutdown caller remains blocked in `thread_join/2`.

The library already distinguishes this control exception elsewhere with `accept_rethrow_error(http_stop(_))`, around line 501. The scheduling error handler bypasses that distinction.

`schedule-trace-02-stages.log`, lines 184–191, and `schedule-trace-14-stages.log` capture the exception leaving the hook, its conversion to an error message, and successful continuation of worker scheduling. The library's own fallback wake-up connection succeeds, but the acceptor goes back to accepting connections because the stop exception has already been consumed. The accompanying native samples show the caller in `thread_join` and the acceptor in native `accept`.

## Standalone reproduction

`http-stop-gated.pl` imports only SWI HTTP/socket libraries, with no Web Prolog code. One request holds the sole HTTP worker; another triggers the public scheduling hook. A test-only gate in that hook holds the acceptor until the main thread initiates normal `http_stop_server/2` shutdown. This forces the relevant timing window without modifying library code.

The one fixed gated trial reproduces the stall:

```text
control(...,scheduler_gate(...,'http@62114')).
control(...,releasing_worker('httpd@62114_1')).
control(...,stop_begin(62114,'http@62114')).
ERROR: [Thread http@62114] Unknown message: http_stop(main)
```

There is no `stop_completed` marker; the original 30-second outer watchdog terminates the process. See `gated-01.log`, `gated-01-sample.txt` and `gated-results.json`. This is a controlled reproduction of the same interleaving observed naturally in the original test, not an estimate of its frequency.

Run with the same outer watchdog via:

```sh
python3 docs/verification/swi-callback-stall-2026-10-24/run-gated.py
```

The driver records trial exit status in JSON; its own successful exit means collection completed, not that the deliberately stalled trial passed.

## Fixed batches

Every phase had a fixed trial count, no retry of failed trials, and the same 30-second outer process watchdog. The original test's assertions and timeouts were not edited. Process-local wrappers add stage logging while preserving the wrapped goal's solutions and exceptions. Native sampling uses the external macOS `sample` tool; it does not send Prolog messages or introduce additional wake-up connections.

| Phase | Trials | Outcome |
| --- | ---: | --- |
| Initial stderr trace | 20 | 14 pass; 1 stall; 3 code-point errors; 2 stream-lock assertion aborts |
| Separate-file stage trace | 20 | 19 pass; 1 stall |
| Accept/wake-up trace | 20 | 19 pass; 1 stall |
| Scheduling/exception trace | 20 | 18 pass; 2 stalls |
| Plain HTTP shutdown, ungated | 20 | 20 pass |
| Nested HTTP request, ungated | 20 | 20 pass |
| Standalone scheduling gate | 1 | 1 reproduced shutdown stall |

The initial stderr probe interacted badly with plunit's captured output, producing three `representation_error(code_point)` failures and two `Sunlock` assertion aborts. Those five results are retained as instrumentation-confounded diagnostics, not evidence about the callback's correctness. They were not reproduced in the subsequent dedicated-file phases. Their underlying stream/capture behaviour has not been independently diagnosed here.

Passing ungated standalone batches do not disprove the race. The gated standalone and natural scheduling traces isolate the failing operation. Trial commands, durations, outcomes, samples and preservation snapshots are recorded in the corresponding `*-results.json` files; `summary.json` consolidates counts.

## Smallest proposed repair — not applied

Narrow the scheduling hook's recovery so shutdown control exceptions are rethrown, while ordinary scheduling errors retain their current reporting:

```prolog
catch(http:schedule_workers(Data),
      Error,
      ( accept_rethrow_error(Error)
      -> throw(Error)
      ;  print_message(error, Error)
      ))
```

This is a small SWI HTTP-library repair. It does not require changing callbacks, Web Prolog receive handling, public protocols, or test deadlines. The next bounded step would be to apply it in a separate candidate build, add a deterministic scheduling-hook shutdown regression, rerun the original callback batches and HTTP cleanup checks, then prepare an upstream report and patch. No such patch has been applied in this investigation.

## Preservation and acceptance decision

Every phase records before/after source hashes, executable hashes and protected process commands. `final-preservation.json` compares against the investigation's initial snapshot: all tracked Prolog/shell sources in the demonstrator and extracted SWI node, the recorded runtime executables, and the existing n3/n5 process identities/commands are unchanged. The investigation files are new evidence only.

The earlier acceptance results remain valid, but the decision remains to hold the n3 runtime switch until this shutdown repair has been separately verified. Explaining the stall does not make the failing cleanup acceptable.

## Subsequent repair and submission

The separately authorized [HTTP shutdown repair](../swi-http-shutdown-2026-10-24/REPORT.md) now passes the regression, callback and cleanup checks. The complete candidate patch and standalone reproducer were submitted as [SWI-Prolog/packages-http #176](https://github.com/SWI-Prolog/packages-http/issues/176). The earlier findings above describe the unpatched candidate; installed runtimes and n3/n5 have not been switched.
