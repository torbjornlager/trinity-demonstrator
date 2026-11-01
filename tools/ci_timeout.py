#!/usr/bin/env python3
"""Bound one disposable test process group, including signal-resistant children."""
import argparse
import os
import signal
import subprocess
from contextlib import suppress


def run(command, seconds, grace=10):
    process = subprocess.Popen(command, start_new_session=True)
    # A containing CI watchdog may terminate us first. Our child has its own
    # process group, so explicitly retire it before this watchdog exits.
    def interrupted(signum, _frame):
        with suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        raise SystemExit(128 + signum)

    previous = {sig: signal.signal(sig, interrupted)
                for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        with suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        finally:
            # The shell may have exited while a Prolog child ignored TERM.
            # Retire the whole original group even if its leader has exited.
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124
    except SystemExit:
        # Reap after unwinding the interrupted wait; waiting from a signal
        # handler could re-enter Popen's non-reentrant wait lock.
        process.wait()
        raise
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('seconds', type=float)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if args.seconds <= 0 or not command:
        parser.error('a positive deadline and command are required')
    return run(command, args.seconds)


if __name__ == '__main__':
    raise SystemExit(main())
