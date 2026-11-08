#!/usr/bin/env python3
"""Check owner-only admission against a running private ECLiPSe bridge."""

import argparse
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from contextlib import ExitStack
from http.client import HTTPConnection
import json
from pathlib import Path
from socket import create_connection
from time import sleep
from urllib.parse import urlencode, urlsplit

from isotope_http import DEMO_ROUTE
from probe_http_control import expect


def request(port, method, path, headers, *, body=b"", status=200):
    connection = HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        connection.putrequest(method, path, skip_host=True)
        for name, value in headers:
            connection.putheader(name, value)
        connection.putheader("Content-Length", str(len(body)))
        connection.endheaders(body)
        with connection.getresponse() as response:
            expect((path, response.status), (path, status))
            expect(response.getheader("Cache-Control"), "no-store")
            return response.read()
    finally:
        connection.close()


def probe(port, origin, owner, token):
    host = [("Host", urlsplit(origin).netloc)]
    from_origin = host + [("Origin", origin)]
    identity = ("X-Web-Prolog-User", owner)
    credential = ("X-Web-Prolog-Proxy-Token", token)
    trusted = from_origin + [identity, credential]
    query = "/call?" + urlencode({"goal": "X=private", "template": "X", "format": "prolog"})
    spawn = b'{"options":"[session(true)]","prompt_correlation":true}'
    json_headers = [("Content-Type", "application/json")]

    request(port, "GET", DEMO_ROUTE, host, status=403)
    request(port, "GET", DEMO_ROUTE, host + [identity, credential])
    request(port, "GET", query, from_origin + [identity], status=403)
    request(port, "GET", query, from_origin + [credential], status=403)
    request(port, "GET", query, trusted + [credential], status=403)
    request(port, "GET", query, host + [identity, credential], status=403)
    request(port, "GET", query, host + [identity, credential, ("Sec-Fetch-Site", "cross-site")], status=403)
    request(port, "GET", query, trusted + [("Sec-Fetch-Site", "same-site")], status=403)
    request(port, "GET", query, trusted + [("Origin", "https://foreign.example")], status=404)
    request(port, "GET", query, [("Host", f"127.0.0.1:{port}")] + trusted[1:], status=404)

    request(port, "POST", "/toplevel_spawn", from_origin + [identity] + json_headers, body=spawn, status=403)
    request(port, "POST", "/toplevel_spawn",
            from_origin + [(identity[0], "someone-else"), credential] + json_headers, body=spawn, status=403)
    request(port, "POST", "/toplevel_spawn",
            from_origin + [identity, (credential[0], "0" * 64)] + json_headers, body=spawn, status=403)
    request(port, "POST", "/actor_probe", trusted + json_headers, body=b"{}", status=404)

    browser = host + [identity, credential, ("Sec-Fetch-Site", "same-origin")]
    expect(request(port, "GET", query, browser).strip(), b"success([private], false).")
    event = json.loads(request(port, "POST", "/toplevel_spawn", trusted + json_headers, body=spawn))
    expect(event["type"], "spawned")
    fields = {"pid": event["pid"], "format": "json"}
    form = trusted + [("Content-Type", "application/x-www-form-urlencoded")]

    def post(command, **params):
        body = urlencode({**fields, **params}).encode()
        return json.loads(request(port, "POST", f"/toplevel_{command}", form, body=body))

    try:
        prompt = post("call", goal="read(X)")
        expect(prompt["type"], "prompt")
        replay = {**fields, "input": "intruder.", "prompt_ref": prompt["prompt_ref"]}
        request(port, "POST", "/toplevel_respond", from_origin + [identity, form[-1]],
                body=urlencode(replay).encode(), status=403)
        expect(post("respond", input="owner_reply.", prompt_ref=prompt["prompt_ref"])["type"], "responded")
        expect(post("poll")["data"], [{"X": "owner_reply"}])
    finally:
        expect(post("halt")["type"], "halted")


def probe_pilot_limits(port, origin, owner, token):
    trusted = [("Host", urlsplit(origin).netloc), ("Origin", origin),
               ("X-Web-Prolog-User", owner), ("X-Web-Prolog-Proxy-Token", token)]

    def spawn(status=200):
        return json.loads(request(port, "POST", "/toplevel_spawn",
                                  trusted + [("Content-Type", "application/json")],
                                  body=b'{"options":"[session(true)]"}', status=status))

    def post(command, pid, status=200, **fields):
        body = urlencode({"pid": pid, "format": "json", **fields}).encode()
        return json.loads(request(port, "POST", f"/toplevel_{command}",
                                  trusted + [("Content-Type", "application/x-www-form-urlencoded")],
                                  body=body, status=status))

    with ExitStack() as sessions:
        for _ in range(4):
            event = spawn()
            expect(event["type"], "spawned")
            sessions.callback(post, "halt", event["pid"])
        expect(spawn(429)["code"], "capacity")

    # Exceed the container's lifetime task cap in total, while keeping
    # one session live at a time. Retired relays must release their threads.
    for _ in range(80):
        event = spawn()
        expect(event["type"], "spawned")
        expect(post("halt", event["pid"])["type"], "halted")

    pid = spawn()["pid"]
    expect(post("call", pid, goal="repeat, fail")["type"], "error")
    expect(post("call", pid, status=404, goal="true")["code"], "session_lost")

    pid = spawn()["pid"]
    prompt = post("call", pid, goal="read(X), repeat, fail")
    expect(prompt["type"], "prompt")
    expect(post("respond", pid, input="resume.", prompt_ref=prompt["prompt_ref"])["type"], "responded")
    # The pilot must stop the resumed goal even if the client never polls.
    sleep(11)
    expect(post("poll", pid, status=404)["code"], "session_lost")

    looping = "/call?" + urlencode({"goal": "repeat, fail", "template": "ok", "format": "prolog"})
    with ThreadPoolExecutor(max_workers=2) as clients:
        requests = [clients.submit(request, port, "GET", looping, trusted) for _ in range(2)]
        for pending in requests:
            try:
                answer = pending.result(timeout=0.15)
            except FutureTimeout:
                continue
            raise RuntimeError(f"looping query returned before the capacity check: {answer!r}")
        request(port, "GET", looping, trusted, status=429)
        for pending in requests:
            expect(pending.result().strip(), b"error(time_limit_exceeded).")
    expect(request(port, "GET", "/call?goal=true&template=ready&format=prolog", trusted).strip(),
           b"success([ready], false).")

    with ExitStack() as sockets:
        for _ in range(16):
            connection = sockets.enter_context(create_connection(("127.0.0.1", port), timeout=2))
            connection.sendall(b"GET / HTTP/1.0\r\n")
        request(port, "GET", DEMO_ROUTE, trusted, status=503)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--private-origin", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--proxy-token-file", type=Path, required=True)
    parser.add_argument("--pilot-limits", action="store_true")
    args = parser.parse_args()
    token = args.proxy_token_file.read_text().strip()
    probe(args.port, args.private_origin, args.owner, token)
    print("ECLiPSe private admission and owner prompt probe passed")
    if args.pilot_limits:
        probe_pilot_limits(args.port, args.private_origin, args.owner, token)
        print("ECLiPSe N7 pilot capacity and timeout probe passed")


if __name__ == "__main__":
    main()
