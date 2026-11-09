#!/usr/bin/env python3
"""Exercise the N7 stateless allowlist using an isolated packaged engine."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from http.client import HTTPConnection
import json
from pathlib import Path
from secrets import token_hex
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlencode

from test_n7_https import ROOT, expect, free_port, wait_for


def check(port, token):
    origin = f"https://127.0.0.1:{port}"
    owner = {"Origin": origin, "X-Web-Prolog-User": "test-owner", "X-Web-Prolog-Proxy-Token": token}

    def request(route, headers=owner, method="GET", *, client_ip="192.0.2.1"):
        conn = HTTPConnection("127.0.0.1", port, timeout=7)
        try:
            if client_ip is not None:
                headers = {**headers, "X-Web-Prolog-Client-IP": client_ip}
            conn.request(method, route, headers=headers)
            with conn.getresponse() as response:
                if response.status == 429:
                    expect(response.getheader("Retry-After"), "1")
                return response.status, response.read()
        finally:
            conn.close()

    def ready():
        with suppress(OSError):
            return request("/node_info", {})[0] == 200
        return False

    wait_for(ready)
    info = json.loads(request("/node_info", {})[1])
    expect((info["auth"], info["profile"], info["sandbox"], info["execution_policy"]),
           ("private", "isobase", "whitelist", "stateless_preview"))
    expect(info["request_isolation"], "container")
    expect(request("/call?goal=true&format=json", {})[0], 403)
    expect(request("/call?goal=true&format=json", {**owner, "X-Web-Prolog-User": "other"})[0], 403)
    expect(request("/call?goal=true&format=json", {**owner, "Origin": "https://other.test"})[0], 404)
    for invalid_ip in (None, "192.0.2.1, 192.0.2.2", "fe80::1%eth0"):
        expect(request("/call?goal=true&format=json", client_ip=invalid_ip)[0], 400)
    for route in ("/ws", "/demonstrator", "/n7-shell/"):
        expect(request(route)[0], 404)
    expect(request("/toplevel_spawn", method="POST")[0], 404)

    def query(goal, **options):
        status, body = request("/call?" + urlencode({"format": "json", "goal": goal, **options}))
        expect(status, 200)
        return body

    page = json.loads(query("between(1,4,X)", offset=1, limit=2))
    expect(page, {"type": "success", "data": [{"X": "2"}, {"X": "3"}], "more": True})
    expect(json.loads(query("findall(X,call(member(X,[a,b])),[a,b]), countall(between(1,3,_),3)"))["type"],
           "success")
    expect(json.loads(query("X=open('/etc/os-release',read,stream)"))["type"], "success")
    expect(query("member(X,[a,b])", format="prolog", template="X", limit=1).strip(), b"success([a], true).")

    for goal in (
        "open('/etc/os-release',read,S),close(S)",
        "sepia_kernel:open('/etc/os-release',read,S)",
        "true@sepia_kernel",
        "G=open('/etc/os-release',read,S),call(G)",
        "once(findall(X,(member(X,[a]),open('/etc/os-release',read,S)),Rows))",
        "forall(member(X,[a]),call(shell(X)))",
        "X is eval(E)",
        "spawn(true)",
        "rpc(localhost,true)",
        "assertz(p(a))",
        "halt",
    ):
        response = json.loads(query(goal))
        assert response["type"] == "error" and "permission_error(call, sandboxed" in response["data"], (goal, response)
    assert b"permission_error(call, sandboxed" in query("halt", format="prolog", template="x")
    assert b"permission_error(load, sandboxed" in query("true", src_text="p(a).")
    assert b"stateless_preview_offset" in query("true", offset=1001)
    assert b"cyclic_term" in query("X=f(X)")
    check_isolation(request)


def check_isolation(request):
    def workers(*options):
        names = subprocess.check_output(
            ["docker", "ps", *options, "--filter", "name=^/trinity-n7-request-", "--format", "{{.Names}}"],
            text=True, timeout=3,
        )
        return set(names.splitlines())

    baseline = workers("-a")
    quick = "/call?goal=true&format=json"
    slow = "/call?" + urlencode({
        "goal": "forall(between(1,1000000000,_),true)",
        "format": "json",
    })
    with ThreadPoolExecutor(max_workers=2) as pool:
        stalled = pool.submit(request, slow)
        wait_for(lambda: len(workers() - baseline) == 1)
        paused, = workers() - baseline
        subprocess.run(["docker", "pause", paused], check=True, stdout=subprocess.DEVNULL, timeout=3)
        try:
            status, body = request(quick, client_ip="::ffff:192.0.2.1")
            expect(status, 429)
            expect(json.loads(body)["code"], "client_capacity")
            expect(request(quick, client_ip="192.0.2.2")[0], 200)
            expect(workers("-a") - baseline, {paused})
            running = pool.submit(request, slow, client_ip="192.0.2.2")
            wait_for(lambda: len(workers() - baseline) == 2)
            for _ in range(3):
                status, body = request(quick, client_ip="192.0.2.3")
                expect(status, 429)
                expect(json.loads(body)["code"], "capacity")
            expect(request("/node_info", {})[0], 200)

            status, body = running.result(timeout=7)
            expect(status, 200)
            assert b"time_limit_exceeded" in body, body
            expect(stalled.result(timeout=8)[0], 504)
            expect(workers("-a") - baseline, set())
            expect(request(quick)[0], 200)
        finally:
            # Clean up a paused fixture even if an assertion fails.
            if paused in workers("-a"):
                subprocess.run(["docker", "rm", "-f", paused], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    with TemporaryDirectory(prefix="n7-whitelist-") as directory:
        token = token_hex(32)
        token_file = Path(directory) / "token"
        token_file.write_text(token)
        port = free_port()
        with subprocess.Popen([
            sys.executable, str(ROOT / "experiments/eclipse-clp/isotope_http.py"),
            "--pilot-image", args.image, "--port", str(port), "--stateless-whitelist",
            "--private-origin", f"https://127.0.0.1:{port}", "--owner", "test-owner",
            "--proxy-token-file", str(token_file),
        ], stdout=subprocess.DEVNULL) as adapter:
            try:
                check(port, token)
            finally:
                if adapter.poll() is None:
                    adapter.terminate()
                adapter.wait(timeout=12)
    print("N7 stateless whitelist, request isolation, overload, and worker recovery checks passed")


if __name__ == "__main__":
    main()
