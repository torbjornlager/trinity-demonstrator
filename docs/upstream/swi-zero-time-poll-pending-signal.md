# Upstream report: zero-time thread_get_message/3 can spin with a pending signal during cleanup

Status: **fixed upstream and verified locally in an isolated build**.

Reported by Torbjörn Lager on SWI-Prolog Discourse. Jan Wielemaker fixed it in
[commit 09b6299f696574c9230f23e53b1ab041a942b6f3](https://github.com/SWI-Prolog/swipl-devel/commit/09b6299f696574c9230f23e53b1ab041a942b6f3).
The upstream change makes queue waits respond only to signals that can currently
be handled, and adds regression tests for signal-blocked waits. This confirms
the pending-signal retry mechanism described below.

Our installed 10.1.17 and official 10.1.18 test package predate this fix.
The isolated source build below includes it. The actor-runtime workaround is
retained for supported SWI builds that do not yet contain the upstream fix.

Upstream discussion: [thread_get_message/3 can spin with a pending signal during cleanup](https://swi-prolog.discourse.group/t/thread-get-message-3-can-spin-with-a-pending-signal-during-cleanup/9870).

The attached reproducer has no dependency on Web Prolog. This report concerns the two tested builds; other versions and
platforms have not been established as affected.

## Environment

- SWI-Prolog 10.1.17 and 10.1.18, with `version_data = swi(10,1,17,[])`
  and `swi(10,1,18,[])` respectively; both report `fat-darwin`.
- 10.1.18 was extracted separately from the official `swipl-10.1.18-1.fat.pkg`
  and verified to use its own framework and Prolog home. Package SHA256:
  `603bd311efb03176e87065acf80f9a2f26264e06e7856154b8b92b2a3e2f3a53`.
- Runtime architecture: `arm64-darwin`; host: macOS 26.6.2, arm64.
- Reproduced in a fresh command-line process with no application libraries.

## Minimal reproduction

```prolog
:- initialization(main, main).
main :-
    setup_call_cleanup(true, true,
        ( thread_self(Self),
          thread_signal(Self, true),
          ( thread_get_message(Self, absent, [timeout(0)]) -> true ; true )
        )),
    writeln(completed).
```

Expected: an empty-queue zero-time poll fails immediately, cleanup finishes,
and the harmless queued signal runs when signal handling becomes available.
The process prints `completed` and exits.

Actual on both tested builds: the process does not complete. An external process
timeout is required; a Prolog time-limit signal cannot reliably interrupt this
signal-masked context. Native sampling of the application failure showed repeated
`thread_get_message___LD`, `get_message___LD`, `cv_timedwait` and
`PL_handle_signals` execution rather than an orderly zero-time return.

The following standalone reproducer includes controls. Save it as
`repro-zero-time-poll.pl`:

```prolog
% Standalone SWI-Prolog reproducer; no Web Prolog modules or packages.
% Run in a disposable process: pending mode can spin and ignore Ctrl-C.
% Modes: control (no signal), pending (failing poll), peek (local workaround).
:- initialization(main, main).

main :-
    current_prolog_flag(argv,[Mode]),
    memberchk(Mode,[control,pending,peek]),
    setup_call_cleanup(true,true,poll(Mode)),
    writeln(completed).

poll(Mode) :-
    thread_self(Self),
    (Mode==control -> true;thread_signal(Self,true)),
    (   Mode==peek
    ->  (thread_peek_message(Self,_) -> thread_get_message(Self,_);true)
    ;   (thread_get_message(Self,absent,[timeout(0)]) -> true;true)
    ).
```

To execute all modes with a hard bound, use a Python subprocess watchdog
(adjust `swipl` to the executable to test):

```python
import subprocess

for mode in ("control", "pending", "peek"):
    try:
        result = subprocess.run(
            ["swipl", "-f", "none", "-q", "-s", "repro-zero-time-poll.pl", "--", mode],
            capture_output=True, text=True, timeout=2)
        print(mode, result.returncode, result.stdout.strip(), result.stderr.strip())
    except subprocess.TimeoutExpired:
        print(mode, "TIMEOUT; child killed by subprocess watchdog")
```

Retested on 2026-10-20 with `-f none`, in three fresh processes per mode
per version (18 runs). Both versions gave identical outcomes:

| Mode | Result |
|---|---|
| `control`: same cleanup/poll without a pending signal | Prints `completed`, exits 0. |
| `pending`: signal queued within cleanup before timed polling | Exceeds the external two-second bound in all three runs per version. |
| `peek`: same pending signal, nonblocking peek followed by read only if available | Prints `completed`, exits 0. |

Successful controls completed in 17–40 ms; timed-out processes were killed
and reaped by the external watchdog after approximately 2,004–2,005 ms.

The peek/read control assumes a private mailbox with a single consumer; it is
not proposed as a general replacement for atomic reads on shared queues.

## Investigation and application impact

SWI documents that cleanup runs with signal handling blocked, and that
`timeout(0)` inspects the queue without suspending:

- [sig_atomic/1 and protected contexts](https://www.swi-prolog.org/pldoc/doc_for?object=sig_atomic/1)
- [thread_get_message/3 timeout semantics](https://www.swi-prolog.org/pldoc/man?predicate=thread_get_message/3)

The [10.1.17 message-queue implementation](https://github.com/SWI-Prolog/swipl-devel/blob/V10.1.17/src/pl-thread.c)
retries after `MSG_WAIT_INTR` when `PL_handle_signals()` returns nonnegative.
The POSIX wait path checks pending signals before reporting timeout. A blocked
signal apparently keeps that retry condition active while it cannot be
processed. This is a proposed explanation for the reduced reproduction, not an
upstream-reviewed engine diagnosis or a proposed engine patch.

In our actor runtime the issue surfaced during final monitor flushing in
cleanup, after the supervised processes had already terminated correctly.
Avoiding timed polling for the documented zero-time actor receive path removes
that stall. This workaround does not change normal finite waits and is not a
claim that every timed wait in a protected context has been repaired.

A focused search of open and closed `SWI-Prolog/swipl-devel` issues on
2026-10-20 for `thread_get_message signal` did not identify a matching report.

## Local verification of the upstream fix

Built exact commit `09b6299f696574c9230f23e53b1ab041a942b6f3`, with its
matching package submodule revisions, in a separate local directory. This
post-release source build still identifies itself as 10.1.18; the commit hash
is what distinguishes it from the affected official 10.1.18 package.

Test configuration: macOS arm64, Release build using the installed macOS 15.4
SDK, LibBF bignums (`USE_GMP=OFF`), and a separately built static OpenSSL 3.5.4.
This is a focused correctness check, not full qualification of a replacement
production installation.

Results:

- Standalone reproducer: all nine runs passed (three repetitions of each mode).
  Crucially, `pending` now prints `completed` and exits 0 in 14–15 ms,
  rather than exceeding the two-second watchdog. Controls passed in 14–18 ms.
- Jan's four `signal_wait` tests passed, including finite waits and pending
  signals under `sig_atomic/1` and cleanup handlers.
- Full T0 actor/receive suite: 90 test entries passed, including parameterized
  protected-cleanup polling cases and the final empty-mailbox check.
- Focused T3 server, promise/request cleanup, supervisor startup/restart/intensity,
  and worker-scope suites: 75 test entries passed, including their parameterized
  instances and the final empty-mailbox check.
- Focused T4 mailbox-accounting and lifetime/worker/supervisor ownership suites:
  43 test entries passed, including parameterized instances and a final
  empty-mailbox check.

Our actor tests exercised the existing runtime workaround as well as its
surrounding receive and cleanup semantics; the standalone reproducer and upstream
tests exercised the fixed host primitives directly.

The original SWI executable and framework hashes are unchanged, and all original
native SWI/Trealla runtime processes retained their PIDs and commands. No running
node was restarted, and no application code or tests were changed for this check.
