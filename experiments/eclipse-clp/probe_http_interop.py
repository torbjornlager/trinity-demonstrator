#!/usr/bin/env python3
"""Run the same ISOTOPE paging and prompt exchanges against two nodes."""

import argparse
from functools import partial
from http.cookiejar import CookieJar
import json
from urllib.request import HTTPCookieProcessor, build_opener

from probe_http_control import expect, open_session, post


def transcript(base, request):
    events = []
    with open_session(base, request=request) as (pid, session):
        def exchange(command, kind, **fields):
            event = request(base, command, {**session, **fields})
            expect((event.get("type"), event.get("pid")), (kind, pid))
            # Compare protocol payloads independently of allocated identifiers.
            events.append({key: event[key] for key in ("type", "data", "more")
                           if key in event})
            return event

        exchange("call", "success", goal="(X=a; X=b; X=c)", limit=1)
        exchange("next", "success")
        exchange("next", "success")

        prompt = exchange("call", "prompt", goal="(read(X), X=ok)")
        fields = {"input": "ok."}
        correlated = "prompt_ref" in prompt
        if correlated:
            fields["prompt_ref"] = prompt["prompt_ref"]
        exchange("respond", "responded", **fields)
        exchange("poll", "success")
    return events, correlated


EXPECTED = [
    {"type": "success", "data": [{"X": "a"}], "more": True},
    {"type": "success", "data": [{"X": "b"}], "more": True},
    {"type": "success", "data": [{"X": "c"}], "more": False},
    {"type": "prompt", "data": "|:"},
    {"type": "responded"},
    {"type": "success", "data": [{"X": "ok"}], "more": False},
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swi", default="http://127.0.0.1:8091")
    parser.add_argument("--eclipse", default="http://127.0.0.1:8090")
    args = parser.parse_args()

    runs = {}
    for name, base in (("SWI-Prolog", args.swi), ("ECLiPSe", args.eclipse)):
        # The SWI node can tie ownership to an anonymous visitor cookie.
        opener = build_opener(HTTPCookieProcessor(CookieJar()))
        try:
            events, correlated = transcript(base.rstrip("/"),
                                            partial(post, open_url=opener.open))
        except (OSError, RuntimeError, ValueError, KeyError) as error:
            raise SystemExit(f"{name} at {base}: {error}") from None
        runs[name] = events
        reference = "includes prompt_ref" if correlated else "no prompt_ref field"
        print(f"{name} at {base} ({reference})\n{json.dumps(events, indent=2)}")

    try:
        expect(runs["SWI-Prolog"], EXPECTED)
        expect(runs["ECLiPSe"], EXPECTED)
    except RuntimeError as error:
        raise SystemExit(f"Transcript mismatch: {error}") from None
    print("Both nodes passed the same paging and prompt exchange.")


if __name__ == "__main__":
    main()
