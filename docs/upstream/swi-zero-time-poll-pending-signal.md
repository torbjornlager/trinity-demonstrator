# Draft upstream report: zero-time thread_get_message/3 can spin with a pending signal during cleanup

Status: **prepared, not submitted**. The attached reproducer has no dependency
on Web Prolog. This report concerns the tested build; other versions and
platforms have not been established as affected.

## Environment

- SWI-Prolog 10.1.17, `version_data = swi(10,1,17,[])`.
- `swipl --version`: SWI-Prolog version 10.1.17 for fat-darwin.
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

Actual on the tested build: the process does not complete. An external process
timeout is required; a Prolog time-limit signal cannot reliably interrupt this
signal-masked context. Native sampling of the application failure showed repeated
`thread_get_message___LD`, `get_message___LD`, `cv_timedwait` and
`PL_handle_signals` execution rather than an orderly zero-time return.

The attached [reproducer](repro-zero-time-poll.pl) includes controls. To execute
all modes with a hard bound, use a Python subprocess watchdog (adjust `swipl`
to the executable to test):

```python
import subprocess

for mode in ("control", "pending", "peek"):
    try:
        result = subprocess.run(
            ["swipl", "-q", "-s", "repro-zero-time-poll.pl", "--", mode],
            capture_output=True, text=True, timeout=2)
        print(mode, result.returncode, result.stdout.strip(), result.stderr.strip())
    except subprocess.TimeoutExpired:
        print(mode, "TIMEOUT; child killed by subprocess watchdog")
```

Observed:

| Mode | Result |
|---|---|
| `control`: same cleanup/poll without a pending signal | Prints `completed`, exits 0. |
| `pending`: signal queued within cleanup before timed polling | Exceeds the external two-second bound. |
| `peek`: same pending signal, nonblocking peek followed by read only if available | Prints `completed`, exits 0. |

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

A focused public search for the exact cleanup/pending-signal combination did
not identify a matching report. This is not an exhaustive duplicate check;
check the current issue tracker before submission. No issue has been filed.
