#!/usr/bin/env python3
"""Probe query control and optionally interactive I/O over local HTTP."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, nullcontext
import json
import sys
from time import monotonic, sleep
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def post(base, command, fields, *, expected_status=200, open_url=urlopen):
    if command == "spawn":
        payload = json.dumps(fields)
        content_type = "application/json"
    else:
        payload = urlencode(fields)
        content_type = "application/x-www-form-urlencoded"
    request = Request(f"{base}/toplevel_{command}", payload.encode(),
                      {"Content-Type": content_type})
    try:
        response = open_url(request, timeout=8)
    except HTTPError as error:
        response = error
    with response:
        event = json.load(response)
        if response.code != expected_status:
            raise RuntimeError(f"{command}: HTTP {response.code}, {event}")
        return event


def expect(actual, expected):
    if actual != expected:
        raise RuntimeError(f"Expected {expected}, got {actual}")


@contextmanager
def open_session(base, *, request=post):
    pid = request(base, "spawn", {"options": "[session(true)]"})["pid"]
    session = {"pid": pid, "format": "json"}
    try:
        yield pid, session
    except Exception:
        try:
            request(base, "halt", session)
        except Exception as cleanup_error:
            print(f"Cleanup for PID {pid}: {cleanup_error}", file=sys.stderr)
        raise
    else:
        request(base, "halt", session)


def probe(base):
    with open_session(base) as (pid, session):
        for command in ("stop", "abort"):
            page = post(base, "call", {
                **session, "goal": "(X=a; X=b)", "limit": 1,
            })
            expect(page, {"type": "success", "pid": pid,
                          "data": [{"X": "a"}], "more": True})
            expect(post(base, command, session), {"type": command, "pid": pid})
            expect(post(base, "next", session, expected_status=400)["type"], "error")
            page = post(base, "call", {**session, "goal": "X=fresh"})
            expect(page, {"type": "success", "pid": pid,
                          "data": [{"X": "fresh"}], "more": False})
            print(f"{command}: discarded continuation and reused PID {pid}")
        expect(post(base, "abort", session), {"type": "abort", "pid": pid})
        print(f"abort: idle session {pid} acknowledged")


def probe_io(base):
    with open_session(base) as (pid, session):
        expect(post(base, "call", {
            **session, "goal": "(output(before), input(first, X))",
        }), {"type": "output", "pid": pid, "data": "before"})
        old_prompt = post(base, "poll", session)
        expect((old_prompt["type"], old_prompt["pid"], old_prompt["data"]),
               ("prompt", pid, "first"))
        expect(post(base, "abort", session), {"type": "abort", "pid": pid})

        fresh_prompt = post(base, "call", {
            **session, "goal": "(read(X), output(X))",
        })
        expect((fresh_prompt["type"], fresh_prompt["pid"]), ("prompt", pid))
        if old_prompt["prompt_ref"] == fresh_prompt["prompt_ref"]:
            raise RuntimeError("Prompt reference was reused after abort")
        for late_fields in ({"prompt_ref": old_prompt["prompt_ref"]}, {}):
            expect(post(base, "respond", {
                **session, **late_fields, "input": "late.",
            }, expected_status=400)["type"], "error")
        expect(post(base, "respond", {
            **session, "prompt_ref": fresh_prompt["prompt_ref"], "input": "fresh.",
        }), {"type": "responded", "pid": pid})
        expect(post(base, "poll", session),
               {"type": "output", "pid": pid, "data": "fresh"})
        expect(post(base, "poll", session),
               {"type": "success", "pid": pid, "data": [{"X": "fresh"}], "more": False})
        print(f"I/O: rejected late replies after abort and answered fresh prompt on PID {pid}")


def probe_running_abort(base, *, parallel=False):
    other_session = open_session(base) if parallel else nullcontext((None, None))
    with open_session(base) as (pid, session), other_session as (other_pid, other):
        expected_abort = {"type": "abort", "pid": pid}
        with ThreadPoolExecutor(max_workers=1) as clients:
            started = monotonic()
            running = clients.submit(post, base, "call", {
                **session, "goal": "(assertz(abort_marker(written)), repeat, fail)",
            })
            # Give the first connection time to submit its request. The fact
            # checked below proves the goal actually ran before the interrupt.
            sleep(0.15)
            expect(running.done(), False)
            if parallel:
                page = post(base, "call", {
                    **other, "goal": "(assertz(abort_marker(other)), X=other)",
                })
                expect(page, {"type": "success", "pid": other_pid,
                              "data": [{"X": "other"}], "more": False})
                expect(running.done(), False)
            expect(post(base, "abort", session), expected_abort)
            expect(running.result(timeout=2), expected_abort)
            if monotonic() - started >= 3:
                raise RuntimeError("Abort did not beat the query timeout")
        page = post(base, "call", {**session, "goal": "once(abort_marker(X))"})
        expect(page, {"type": "success", "pid": pid,
                      "data": [{"X": "written"}], "more": False})
        if parallel:
            page = post(base, "call", {**other, "goal": "once(abort_marker(X))"})
            expect(page, {"type": "success", "pid": other_pid,
                          "data": [{"X": "other"}], "more": False})
            print(f"sessions: PID {other_pid} answered while PID {pid} was running, "
                  "and both retained separate private facts after Abort")
        else:
            print(f"abort: interrupted an in-flight HTTP call and preserved private state on PID {pid}")


def require_capability(base, *, parallel):
    builds = {"parallel-sessions"} if parallel else {"running-abort", "parallel-sessions"}
    with urlopen(f"{base}/examples/APIs/http_example-1.html", timeout=8) as response:
        if response.headers.get("X-Eclipse-Bridge") not in builds:
            raise SystemExit(f"The adapter at {base} predates this probe. "
                             "Restart it with the updated isotope_http.py.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8088)
    parser.add_argument("--io", action="store_true", help="also check interactive I/O")
    parser.add_argument("--running-abort", action="store_true",
                        help="also abort a running query from a second HTTP connection")
    parser.add_argument("--parallel-sessions", action="store_true",
                        help="also check that a running query leaves another PID responsive")
    args = parser.parse_args()
    base = f"http://127.0.0.1:{args.port}"
    if args.running_abort or args.parallel_sessions:
        require_capability(base, parallel=args.parallel_sessions)
    probe(base)
    if args.io:
        probe_io(base)
    if args.running_abort:
        probe_running_abort(base)
    if args.parallel_sessions:
        probe_running_abort(base, parallel=True)
