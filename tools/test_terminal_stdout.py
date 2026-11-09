#!/usr/bin/env python3
"""Check terminal output on local ACTOR nodes using the conformance WebSocket harness."""

import argparse
import importlib
from pathlib import Path
import sys


def check_stdout(harness):
    cases = [
        ("write(a), write(b)", "ab"),
        ("write(a), sleep(0.2), write(b)", "ab"),
        ("write(a), nl, nl, writeln(b), write(c)", "a\n\nb\nc"),
        ("format('a~nb~n~n'), write(c)", "a\nb\n\nc"),
    ]
    flush = "self(Me), Me ! a, Me ! b, flush"
    cases.append((flush, "Shell got a\nShell got b\n"))
    harness.spawn_shell()
    try:
        for goal, expected in cases:
            harness.call(goal)
            chunks = []
            for _ in range(16):
                event = harness.recv()
                if event["type"] == "success":
                    break
                harness.acknowledge_output(event)
                output = event["event"] if event["type"] == "io_request" else event
                if output["type"] != "output":
                    raise AssertionError((goal, event))
                if "stdout" in output:
                    chunks.append(output["stdout"])
                elif goal == flush:
                    chunks.append(output["data"] + "\n")
                else:
                    raise AssertionError((goal, "missing stdout", event))
            else:
                raise AssertionError((goal, "query did not finish"))
            actual = "".join(chunks)
            if actual != expected:
                raise AssertionError((goal, actual, expected))
            print(f"PASS {goal}", flush=True)
    finally:
        harness.halt()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", type=Path, required=True, help="conformance runner/run.py")
    parser.add_argument("--origin")
    parser.add_argument("--insecure-tls", action="store_true")
    parser.add_argument("ws_url")
    args = parser.parse_args()
    sys.path.insert(0, str(args.runner.resolve().parent))
    runner = importlib.import_module(args.runner.stem)
    candidate = runner.Candidate(args.ws_url, "actor", 10, None, args.origin, args.insecure_tls, ())
    with runner.Harness(candidate) as harness:
        check_stdout(harness)


if __name__ == "__main__":
    main()
