#!/usr/bin/env python3
"""Test the N7 HTTPS route with OAuth2 Proxy and a local GitHub API fixture."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
from secrets import token_hex, token_urlsafe
import signal
import socket
import ssl
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from time import monotonic, sleep
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, HTTPSHandler, Request, build_opener, urlopen

ROOT = Path(__file__).resolve().parents[1]
OWNER, EMAIL = "n7-test-owner", "owner@example.test"
OWNER_OTHER_EMAIL = "n7-owner-other-email"
CURL_FIXTURE_IMAGE = "curlimages/curl@sha256:a134550be58ab783810e613ae96fd253c38f7bdd16d9bf9be350700c7a29ac06"


def expect(actual, expected):
    if actual != expected:
        raise AssertionError(f"expected {expected!r}, got {actual!r}")


class GitHubFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/authorize":
            params = parse_qs(url.query)
            code = params.get("account", [OWNER])[0]
            self.send_response(302)
            self.send_header("Location", params["redirect_uri"][0] + "?" +
                             urlencode({"state": params["state"][0], "code": code}))
            self.end_headers()
        elif url.path in ("/user/orgs", "/user/teams"):
            self.reply([])
        elif url.path == "/user":
            account = self.headers["Authorization"].split()[-1]
            self.reply({"login": OWNER if account == OWNER_OTHER_EMAIL else account})
        elif url.path == "/user/emails":
            account = self.headers["Authorization"].split()[-1]
            email = "other@example.test" if account == OWNER_OTHER_EMAIL else EMAIL
            self.reply([{"email": email, "primary": True, "verified": True}])
        elif url.path == "/":
            self.reply({})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/token":
            self.send_error(404)
            return
        params = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        self.reply({"access_token": params["code"][0], "token_type": "bearer"})

    def reply(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def http(opener, url, *, body=None, headers=None, status=200):
    request = Request(url, data=body, headers=headers or {})
    try:
        response = opener.open(request, timeout=10)
    except HTTPError as error:
        response = error
    with response:
        expect(response.code, status)
        return response.headers, response.read()


def check_https(origin, ca, shell=False, *, shell_absent=False, actor_core=None,
                profile="isotope", unicode_literals=False):
    ssl_context = ssl.create_default_context(cafile=str(ca))

    def client(redirect=False):
        handlers = [HTTPSHandler(context=ssl_context), HTTPCookieProcessor(CookieJar())]
        return build_opener(*handlers) if redirect else build_opener(*handlers, NoRedirect())

    anonymous = client()
    spoof = {"X-Auth-Request-User": OWNER, "X-Auth-Request-Email": EMAIL,
             "X-Web-Prolog-User": EMAIL, "X-Web-Prolog-Proxy-Token": "forged"}
    hub = "https://n0.elfenbenstornet.se"
    headers, body = http(anonymous, origin + "/node_info", headers={"Origin": hub})
    expect(headers["Access-Control-Allow-Origin"], hub)
    info = json.loads(body)
    expect(bool(re.fullmatch(r"\d+\.\d+\.\d+", info.pop("version"))), True)
    if shell:
        expect(info.pop("http_session_options"), ["src_text", "prompt_correlation"])
    expect(info, {"self_url": origin, "implementation": "ECLiPSe CLP", "profile": profile,
                  "auth": "private", "services": [], "provides": []})
    http(anonymous, origin + "/node_info", body=b"{}", status=401)
    http(anonymous, origin + "/call?goal=true", headers=spoof, status=401)
    headers, _ = http(anonymous, origin + "/demonstrator", headers=spoof, status=302)
    expect(headers["Location"], "/oauth2/start?rd=/demonstrator")
    http(anonymous, origin + "/toplevel_spawn", body=b"{}", headers=spoof, status=401)
    if shell:
        headers, _ = http(anonymous, origin + "/n7-shell/", status=302)
        expect(headers["Location"], "/oauth2/start?rd=/n7-shell/")
        http(anonymous, origin + "/n7-shell/vendor/trinity-host.js", status=401)
        http(anonymous, origin + "/n7-shell/session.json", status=401)
    elif shell_absent:
        http(anonymous, origin + "/n7-shell/", status=401)

    wrong = client()
    headers, _ = http(wrong, origin + "/oauth2/start?rd=/demonstrator", status=302)
    headers, _ = http(wrong, headers["Location"] + "&account=n7-test-intruder", status=302)
    # OAuth2 Proxy 7.6 rejects a non-allowlisted GitHub user during session creation.
    headers, _ = http(wrong, headers["Location"], status=500)
    expect(any(value.startswith("__Host-n7_oauth=") for value in headers.get_all("Set-Cookie", [])), False)
    http(wrong, origin + "/toplevel_spawn", body=b"{}", status=401)
    http(wrong, origin + "/demonstrator", status=302)
    if shell:
        http(wrong, origin + "/n7-shell/", status=302)

    wrong_email = client()
    headers, _ = http(wrong_email, origin + "/oauth2/start?rd=/demonstrator", status=302)
    headers, _ = http(wrong_email, headers["Location"] + "&account=" + OWNER_OTHER_EMAIL, status=302)
    http(wrong_email, headers["Location"], status=302)
    http(wrong_email, origin + "/toplevel_spawn", body=b"{}", headers=spoof, status=403)
    http(wrong_email, origin + "/demonstrator", status=403)
    if shell:
        http(wrong_email, origin + "/n7-shell/", status=403)

    owner = client(redirect=True)
    _, body = http(owner, origin + "/demonstrator")
    expect(b"Start paging" in body and b"Send reply" in body, True)
    if actor_core is not None:
        check_actor_ws(origin, ca, actor_core, anonymous, wrong, wrong_email, owner, spoof)
    if shell:
        _, body = http(client(redirect=True), origin + "/n7-shell/")
        expect(b"WEB_PROLOG_HOST" in body and b"/n7-shell/editor_frame.html" in body, True)
        expect(b'"nodeUrl":' + json.dumps(origin + "/").encode() in body, True)
        http(owner, origin + "/n7-shell/vendor/trinity-host.js")
        http(owner, origin + "/n7-shell/%2e%2e/proxy-token", status=404)
        _, data = http(owner, origin + "/n7-shell/session.json")
        expect(json.loads(data), {"principal_id": "owner", "principal_execution": True})
    elif shell_absent:
        http(owner, origin + "/n7-shell/", status=404)
    query = urlencode({"goal": "fixture_value(X)", "format": "json",
                       "src_text": "fixture_value(owner)."})
    response_headers, data = http(owner, origin + "/call?" + query, headers={"Origin": origin})
    expect(response_headers.get_content_type(), "application/json")
    expect(json.loads(data), {"type": "success", "data": [{"X": "owner"}], "more": False})
    library_query = urlencode({
        "goal": "nth1(2,L,b,[a,c]),L==[a,b,c],countall(between(1,4,_),4),"
                "call_nth(between(1,4,Selected),3),"
                "maplist(add,[1,2],[3,4],Sums),Sums==[4,6],"
                "foldl(add,Sums,0,Total)",
        "src_text": "add(A,B,C) :- C is A+B.",
        "format": "json",
    })
    _, data = http(owner, origin + "/call?" + library_query, headers={"Origin": origin})
    library_result = json.loads(data)
    expect((library_result["type"], library_result["more"]), ("success", False))
    expect({key: library_result["data"][0][key] for key in ("Selected", "Total")},
           {"Selected": "3", "Total": "10"})
    if unicode_literals:
        query = urlencode({"goal": """fixture_chars(X), X == "aé€😀", X == [a,'é','€','😀'], "" == []""",
                           "format": "json", "src_text": 'fixture_chars("aé€😀").'})
        _, data = http(owner, origin + "/call?" + query, headers={"Origin": origin})
        expect(json.loads(data)["data"], [{"X": "[a, 'é', '€', '😀']"}])
    headers = {"Origin": origin, "Content-Type": "application/json"}
    spawn = {"options": "[session(true)]", "prompt_correlation": True}
    if shell:
        spawn["src_text"] = "shell_source(editor)."
    _, data = http(owner, origin + "/toplevel_spawn", headers=headers, body=json.dumps(spawn).encode())
    spawned = json.loads(data)
    expect(spawned["type"], "spawned")
    pid = spawned["pid"]

    def post(command, **params):
        _, data = http(owner, origin + "/toplevel_" + command,
                       headers={"Origin": origin, "Content-Type": "application/x-www-form-urlencoded"},
                       body=urlencode({"pid": pid, "format": "json", **params}).encode())
        return json.loads(data)

    try:
        expect(post("call", goal="sleep(0.01)")["type"], "success")
        if shell:
            expect(post("call", goal="shell_source(X)")["data"], [{"X": "editor"}])
        expect(post("call", goal="member(X,[a,b,c])", limit=1)["data"], [{"X": "a"}])
        expect(post("next")["data"], [{"X": "b"}])
        last = post("next")
        expect(last["data"], [{"X": "c"}])
        if last["more"]:
            expect(post("stop")["type"], "stop")
        prompt = post("call", goal="read(X)")
        expect(prompt["type"], "prompt")
        expect(post("respond", input="owner_reply.", prompt_ref=prompt["prompt_ref"])["type"], "responded")
        expect(post("poll")["data"], [{"X": "owner_reply"}])
        if unicode_literals:
            prompt = post("call", goal="""input("Réponse 😀",X), X == ['é','😀']""")
            expect((prompt["type"], prompt["data"]), ("prompt", "Réponse 😀"))
            reply = post("respond", input='"é😀".', prompt_ref=prompt["prompt_ref"])
            expect(reply["type"], "responded")
            expect(post("poll")["data"], [{"X": "['é', '😀']"}])
    finally:
        expect(post("halt")["type"], "halted")
    print("N7 HTTPS metadata, admission, stateless JSON with source, paging and prompt reply passed")


def check_actor_ws(origin, ca, runner, anonymous, wrong, wrong_email, owner, spoof):
    upgrade = {"Origin": origin, "Connection": "Upgrade", "Upgrade": "websocket",
               "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="}
    endpoint = origin + "/ws"
    http(anonymous, endpoint, headers={**upgrade, **spoof}, status=401)
    http(wrong, endpoint, headers=upgrade, status=401)
    http(wrong_email, endpoint, headers=upgrade, status=403)
    http(owner, endpoint, headers={**upgrade, "Origin": "https://other.example.test"}, status=404)
    http(owner, endpoint, headers={"Origin": origin}, status=400)
    request = Request(endpoint)
    next(handler.cookiejar for handler in owner.handlers
         if isinstance(handler, HTTPCookieProcessor)).add_cookie_header(request)
    cookie = request.get_header("Cookie")
    if not cookie:
        raise AssertionError("Expected a fixture owner session cookie")
    workshop_path = ca.parent / "workshop.html"
    try:
        with owner.open(origin + "/n7-shell/n7-actor-workshop.html", timeout=10) as response:
            workshop_path.write_bytes(response.read())
    except HTTPError as error:
        if error.code != 404:
            raise
    # Some macOS Python builds ignore SSL_CERT_FILE when loading default roots.
    trust_fixture_ca = """
import functools, html, re, runpy, ssl, sys
from pathlib import Path
sys.argv.pop(0)
ssl.create_default_context = functools.partial(ssl.create_default_context, cafile=sys.argv.pop(0))
workshop_path = Path(sys.argv.pop(0))
runner = sys.argv[0]
sys.path.insert(0, runner.rsplit('/', 1)[0])
suite = runpy.run_path(runner)
if suite['main']():
    sys.exit(1)

# The packaged shell opens a session without sending transport_hello.
def option(name):
    return sys.argv[sys.argv.index(name) + 1]

ws = suite['WebSocket'](option('--ws-url'), 5, origin=option('--origin'),
                        extra_headers=(option('--header'),))
try:
    ws.send_json(dict(command='toplevel_spawn', options='[session(true)]'))
    spawned = ws.recv_json()
    assert spawned['type'] == 'spawned', spawned
    pid = spawned['pid']
    ws.send_json(dict(command='toplevel_call', pid=pid, goal='format("shell output~n",[])'))
    output = ws.recv_json()
    assert (output['type'], output['data']) == ('output', 'shell output\\n'), output
    assert ws.recv_json()['type'] == 'success'

    def shell_call(goal):
        ws.send_json(dict(command='toplevel_call', pid=pid, goal=goal, options='[limit(1)]'))
        event = ws.recv_json()
        assert event['type'] == 'success' and event['more'] is False, (goal, event)
        assert len(event['data']) == 1, (goal, event)
        return event['data'][0]

    shell_call("make_ref(First),make_ref(Second),ground(First),ground(Second),"
               "(First == Second -> throw(reused_reference) ; true),"
               "self(Self),send(Self,First),receive({Reply if Reply == First -> true})")
    shell_call("maplist(=,[a],[a]),foldl(throw,[],state,Final),Final==state")
    child = shell_call("toplevel_spawn(Child,[session(true),monitor(true),src_list([p(a),p(b)])])")['Child']
    shell_call(f"toplevel_call({child},assert((p :- p))),receive({{success({child},_,false) -> true}})")

    def start_loop():
        shell_call(f"self(Shell),toplevel_call({child},(send(Shell,started),p)),receive({{started -> true}})")

    start_loop()
    shell_call(f"toplevel_abort({child}),receive({{abort({child}) -> true}})")
    shell_call(f"toplevel_call({child},p(X),[template(X),limit(1)]),"
               f"receive({{success({child},[a],true) -> true}}),toplevel_stop({child})")
    start_loop()
    assert shell_call(f"toplevel_halt({child},Reply)") == {'Reply': 'true'}
    shell_call(f"receive({{down({child},{child},true) -> true}}),actors(Actors),"
               f"(member({child},Actors) -> throw(child_still_running) ; true)")
    print('Nested toplevel abort, reuse, stop, halt, and spawn monitor passed')

    ws.send_json(dict(command='toplevel_halt', pid=pid))
    assert ws.recv_json()['type'] == 'halted'
finally:
    ws.close()
print('Shell WebSocket session and output passed without capability negotiation')

if not workshop_path.is_file():
    sys.exit(0)
workshop = workshop_path.read_text()

def block(id):
    return html.unescape(re.search(r'<pre id="' + id + r'">(.*?)</pre>', workshop, re.S)[1]).strip()

ws = suite['WebSocket'](option('--ws-url'), 5, origin=option('--origin'),
                        extra_headers=(option('--header'),))
try:
    ws.send_json(dict(command='toplevel_spawn', options='[session(true)]', src_text=block('workshop-source')))
    spawned = ws.recv_json()
    assert spawned['type'] == 'spawned', spawned
    pid = spawned['pid']

    def call(id):
        ws.send_json(dict(command='toplevel_call', pid=pid, goal=block(id)[3:-1], options='[limit(1)]'))

    def answer(**bindings):
        event = ws.recv_json()
        assert event['type'] == 'success' and event['more'] is False, event
        assert len(event['data']) == 1 and all(event['data'][0].get(k) == v for k, v in bindings.items()), event

    for id, bindings in [('start-counters', {}), ('add-red', {'Red': '3'}), ('add-red', {'Red': '6'}),
                         ('two-updates', {'Red': '8', 'Blue': '5'})]:
        call(id)
        answer(**bindings)
    call('prompt-red')
    prompt = ws.recv_json()
    assert (prompt['type'], prompt['data']) == ('prompt', 'Amount to add (an integer)'), prompt
    ws.send_json(dict(command='toplevel_respond', pid=pid, input='7.'))
    assert ws.recv_json()['type'] == 'responded'
    answer(Total='15')
    call('watch-exit')
    answer(Reason='workshop_done')
    call('stop-counters')
    answer()
    call('start-counters')
    answer()
    call('add-red')
    answer(Red='3')
    if 'id="register-ping"' in workshop:
        call('register-ping')
        answer(After='undefined')
        call('register-ping')
        answer(After='undefined')
        print('N7 ACTOR workshop named send, monitoring, and name reuse passed')
    ws.send_json(dict(command='toplevel_halt', pid=pid))
    assert ws.recv_json()['type'] == 'halted'
finally:
    ws.close()
print('N7 ACTOR workshop counters, prompts, and monitors passed')
"""
    result = subprocess.run([sys.executable, "-c", trust_fixture_ca, str(ca),
                             str(workshop_path), str(runner.resolve()),
                             "--ws-url", endpoint.replace("https:", "wss:", 1),
                             "--advertised-profile", "actor", "--origin", origin,
                             "--header", "Cookie: " + cookie, "--candidate", "n7-owner-preview",
                             "--report", str(ca.parent / "actor-core.json")])
    expect(result.returncode, 0)


def check_shared_database(origin, ca, assets):
    tls = ssl.create_default_context(cafile=str(ca))
    source = origin + "/n7-shell/shared-db.pl"
    anonymous = build_opener(HTTPSHandler(context=tls), NoRedirect())
    http(anonymous, source, status=401)
    owner = build_opener(HTTPSHandler(context=tls), HTTPCookieProcessor(CookieJar()))
    http(owner, origin + "/n7-shell/")
    headers, body = http(owner, source)
    expect(headers.get_content_type(), "text/plain")
    expect(body, (assets / "shared-db.pl").read_bytes())

    def query(goal, src_text=""):
        params = urlencode({"goal": goal, "src_text": src_text, "format": "json"})
        _, response = http(owner, origin + "/call?" + params, headers={"Origin": origin})
        result = json.loads(response)
        expect(result["type"], "success")
        return result["data"]

    expect(query("ancestor_descendant(mike,sally),human(plato),shared_fact(n4_shared_db),price(widget,X)"),
           [{"X": "100"}])
    expect(query("price(widget,X)", "price(widget,1)."), [{"X": "1"}])
    expect(query("price(widget,X)"), [{"X": "100"}])
    expect(query("linda_local_address(Address),linda_out(n7_db_probe(ok)),linda_inp(n7_db_probe(X))"),
           [{"Address": "linda", "X": "ok"}])
    query("ping_pong_benchmark(3,T),T >= 0")
    print("N7 shared database source, private shadowing, actor benchmark and Linda passed")


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for(check):
    deadline = monotonic() + 20
    while monotonic() < deadline:
        if check():
            return
        sleep(0.2)
    raise RuntimeError("N7 fixture did not start")


def check_stateless_cache(origin, ca):
    tls = ssl.create_default_context(cafile=str(ca))
    owner = build_opener(HTTPSHandler(context=tls), HTTPCookieProcessor(CookieJar()))
    http(owner, origin + "/demonstrator")

    def page(offset, limit, **overrides):
        fields = {"goal": "stamp(Stamp), member(X, [a,b,c,d])",
                  "src_text": "stamp(Stamp) :- make_ref(Stamp).",
                  "format": "json", "offset": offset, "limit": limit}
        fields.update(overrides)
        _, body = http(owner, origin + "/call?" + urlencode(fields), headers={"Origin": origin})
        return json.loads(body) if fields["format"] == "json" else body.decode()

    first = page(0, 1)
    stamp = first["data"][0]["Stamp"]
    expect(first, {"type": "success", "more": True, "data": [{"Stamp": stamp, "X": "a"}]})
    # Same goal and offset, different source. This request must miss the cache.
    changed = page(1, 2, src_text="stamp(changed).")
    expect(changed["data"], [{"Stamp": "changed", "X": x} for x in ("b", "c")])
    second = page(1, 2)
    expect(second, {"type": "success", "more": True,
                    "data": [{"Stamp": stamp, "X": x} for x in ("b", "c")]})
    last = page(3, 1)
    expect(last, {"type": "success", "more": False, "data": [{"Stamp": stamp, "X": "d"}]})
    expect(page(3, 1)["data"][0]["Stamp"] != stamp, True)

    term = page(0, 1, format="prolog", template="pair(Stamp,X)")
    match = re.fullmatch(r"success\(\[pair\((ref\(\d+\)|\d+),\s*a\)\],\s*true\)\.\s*", term)
    expect(match is not None, True)
    expect(re.sub(r"\s+", "", page(1, 3, format="prolog", template="pair(Stamp,X)")),
           "success([" + ",".join(f"pair({match[1]},{x})" for x in ("b", "c", "d")) + "],false).")

    goal = "member(X,[a,b]), (X == a -> true ; output(late))"
    expect(page(0, 1, goal=goal, src_text="")["more"], True)
    expect(page(1, 1, goal=goal, src_text=""), {"type": "error", "data": "stateless_output"})
    print("N7 stateless pages resumed without rerunning the query prefix in JSON and Prolog")


def check_stateless_admission(origin, ca, network, *, anonymous=False, prefix=""):
    tls = HTTPSHandler(context=ssl.create_default_context(cafile=str(ca)))
    client = build_opener(tls, NoRedirect())
    endpoint = origin + prefix
    quick = "true"
    slow = "forall(between(1,1000000000,_),true)"
    if anonymous:
        caller_headers = []
        _, data = http(client, endpoint + "/node_info")
        expect(json.loads(data)["auth"], "open")
        expect(json.loads(data)["self_url"], endpoint)
        for route in ("/", "/demonstrator", "/n7-shell/", "/ws", "/oauth2/start", "/toplevel_spawn"):
            http(client, endpoint + route, status=404)
        for route in ("/call?goal=true&format=json", "/node_info", "/toplevel_spawn"):
            http(client, endpoint + route, body=b"{}", status=404)
        http(client, endpoint + "/call?goal=true&format=json", headers={"Sec-Fetch-Site": "cross-site"}, status=403)
        _, answer = http(client, endpoint + "/call?goal=true&format=json")
        expect(json.loads(answer)["type"], "success")
        query = urlencode({"goal": "open('/etc/os-release',read,S)", "format": "json"})
        _, answer = http(client, endpoint + "/call?" + query)
        assert "permission_error(call, sandboxed" in json.loads(answer)["data"], answer
        if prefix:
            http(client, origin + "/n7-shell/", status=302)
            for route in ("/call?goal=true&format=json", "/ws", "/toplevel_spawn"):
                http(client, origin + route, status=401)
    else:
        jar = CookieJar()
        owner = build_opener(tls, HTTPCookieProcessor(jar))
        http(client, origin + "/call?goal=true&format=json",
             headers={"Origin": origin, "X-Web-Prolog-Client-IP": "192.0.2.1"}, status=401)
        _, data = http(owner, origin + "/oauth2/start?rd=/node_info")
        expect(json.loads(data)["auth"], "private")
        cookie = next(item for item in jar if item.name == "__Host-n7_oauth")
        caller_headers = [f"Cookie: {cookie.name}={cookie.value}", f"Origin: {origin}"]
    expect(json.loads(data)["request_isolation"], "container")
    port = urlsplit(origin).port
    ca.chmod(0o644)

    def worker_names():
        return subprocess.check_output(
            ["docker", "ps", "--filter", "name=^/trinity-n7-request-", "--format", "{{.Names}}"],
            text=True, timeout=3,
        ).splitlines()

    with ExitStack() as clients:
        containers = []
        for _ in range(2):
            name = "n7-admission-client-" + token_hex(4)
            subprocess.run(["docker", "run", "--rm", "-d", "--name", name, "--network", network,
                            "--entrypoint", "sleep", CURL_FIXTURE_IMAGE, "90"],
                           stdout=subprocess.DEVNULL, check=True, timeout=30)
            clients.callback(subprocess.run, ["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, timeout=5)
            subprocess.run(["docker", "cp", str(ca), name + ":/tmp/n7-ca.crt"], check=True)
            containers.append(name)
        first, second = containers

        def call(client, goal, spoof=None):
            headers = caller_headers.copy()
            if spoof:
                headers.extend([f"X-Web-Prolog-Client-IP: {spoof}", f"X-Forwarded-For: {spoof}"])
            output = subprocess.check_output(
                ["docker", "exec", "-i", client, "curl", "--silent", "--show-error", "--max-time", "10",
                 "--cacert", "/tmp/n7-ca.crt", "--connect-to", f"localhost:{port}:n7_https:{port}",
                 "--header", "@-", "--write-out", "\n%{http_code}:%header{retry-after}",
                 endpoint + "/call?" + urlencode({"format": "json", "goal": goal})],
                input="\n".join(headers) + "\n", text=True, timeout=12,
            )
            body, result = output.rsplit("\n", 1)
            status, retry_after = result.split(":", 1)
            return int(status), json.loads(body), retry_after

        baseline = set(worker_names())
        with ThreadPoolExecutor(max_workers=1) as pool:
            running = pool.submit(call, first, slow)

            def worker_started():
                if running.done():
                    raise AssertionError(f"Slow call ended before the isolation check: {running.result()}")
                return bool(set(worker_names()) - baseline)

            wait_for(worker_started)
            expect(call(first, quick, "192.0.2.10"),
                   (429, {"type": "error", "code": "client_capacity"}, "1"))
            expect(call(first, quick, "192.0.2.11"),
                   (429, {"type": "error", "code": "client_capacity"}, "1"))
            expect(call(second, quick, "192.0.2.10")[:2],
                   (200, {"type": "success", "data": [{}], "more": False}))
            expect(running.done(), False)
            status, body, _ = running.result(timeout=8)
            expect((status, body["type"]), (200, "error"))
            assert "time_limit_exceeded" in body["data"], body

        for _ in range(2):
            expect(call(first, quick)[0], 200)
        status, body, retry_after = call(first, quick, "192.0.2.12")
        expect((status, body), (429, {"type": "error", "code": "rate_limit"}))
        assert 1 <= int(retry_after) <= 60, retry_after
        expect(call(second, quick, "192.0.2.12")[0], 200)
    print("N7 HTTPS client fairness, spoof resistance, and rate limits passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="trinity-eclipse-n7:local")
    parser.add_argument("--shell", action="store_true", help="also exercise the packaged full demonstrator")
    parser.add_argument("--actor-core", type=Path, metavar="RUNNER", help="run ACTOR core through owner HTTPS")
    parser.add_argument("--advertise-actor", action="store_true", help="exercise ACTOR discovery metadata")
    parser.add_argument("--stateless-admission", action="store_true",
                        help="test the stateless preview with two HTTPS clients on the Docker network")
    parser.add_argument("--anonymous-staging", action="store_true",
                        help="test the anonymous staging site with two HTTPS clients on the Docker network")
    parser.add_argument("--anonymous-preview", action="store_true",
                        help="test the anonymous /preview routes on the owner HTTPS site")
    args = parser.parse_args()
    if args.advertise_actor and args.actor_core is None:
        parser.error("--advertise-actor requires --actor-core")
    anonymous = args.anonymous_staging or args.anonymous_preview
    stateless = args.stateless_admission or anonymous
    prefix = "/preview" if args.anonymous_preview else ""
    if stateless and (args.shell or args.actor_core is not None):
        parser.error("The stateless fixtures run separately from the shell and ACTOR fixtures")
    if sum((args.stateless_admission, args.anonymous_staging, args.anonymous_preview)) > 1:
        parser.error("Choose one stateless fixture")
    with ExitStack() as stack:
        scratch = Path(stack.enter_context(TemporaryDirectory(prefix="n7-https-")))
        provider = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), GitHubFixture))
        Thread(target=provider.serve_forever, daemon=True).start()
        stack.callback(provider.shutdown)
        provider_port = provider.server_port
        https_port, adapter_port = free_port(), free_port()
        origin = f"https://localhost:{https_port}"
        token = token_hex(32)
        token_file = scratch / "proxy-token"
        token_file.touch(mode=0o600)
        token_file.write_text(token)
        log = stack.enter_context((scratch / "adapter.log").open("w+"))
        shell_args = []
        if args.shell:
            assets = scratch / "shell"
            subprocess.run([sys.executable, str(ROOT / "tools/package_demonstrator.py"),
                            "--prefix", "/n7-shell/", "--node-url", origin, "--allow-dirty",
                            "--output", str(assets)], check=True)
            shell_args = ["--shell-assets", str(assets)]
        if args.actor_core is not None:
            shell_args.append("--actor-ws")
        if args.advertise_actor:
            shell_args.append("--advertise-actor")
        if stateless:
            shell_args.extend(["--stateless-whitelist", "--stateless-calls-per-minute", "3"])
        if anonymous:
            shell_args.append("--anonymous-stateless")
        if prefix:
            shell_args.extend(["--stateless-public-prefix", prefix])
        adapter = subprocess.Popen(
            [sys.executable, str(ROOT / "experiments/eclipse-clp/isotope_http.py"),
             "--pilot-image", args.image, "--port", str(adapter_port), "--private-origin", origin,
             "--owner", "n7-stateless-staging" if anonymous else EMAIL,
             "--proxy-token-file", str(token_file), *shell_args], stdout=log, stderr=log,
        )

        def stop_adapter():
            if adapter.poll() is None:
                adapter.send_signal(signal.SIGTERM)
                adapter.wait(timeout=12)

        stack.callback(stop_adapter)
        wait_for(lambda: "Private proxy origin" in Path(log.name).read_text())
        override = scratch / "fixture.yaml"
        fixture = f"""services:
  oauth2_n7:
    environment:
      OAUTH2_PROXY_LOGIN_URL: http://127.0.0.1:{provider_port}/authorize
      OAUTH2_PROXY_REDEEM_URL: http://host.docker.internal:{provider_port}/token
      OAUTH2_PROXY_VALIDATE_URL: http://host.docker.internal:{provider_port}/
"""
        env = {**os.environ, "N7_ORIGIN": origin, "N7_HTTPS_PORT": str(https_port),
               "N7_HTTP_UPSTREAM": f"host.docker.internal:{adapter_port}", "N7_TLS_DIRECTIVE": "tls internal",
               "OAUTH2_PROXY_GITHUB_USERS": OWNER, "WP_N5_OWNER": EMAIL, "N7_PROXY_TOKEN": token,
               "N7_OAUTH2_CLIENT_ID": "n7-local-client", "N7_OAUTH2_CLIENT_SECRET": token_hex(16),
               "N7_OAUTH2_COOKIE_SECRET": token_urlsafe(32)}
        if anonymous:
            fixture += "  n7_https:\n"
            if args.anonymous_staging:
                fixture += """    build:
      args:
        N7_CADDYFILE: Caddyfile.eclipse-n7-staging
"""
            fixture += f"""    environment:
      N7_STAGE_ORIGIN: {origin}
      N7_STAGE_TLS_DIRECTIVE: tls internal
      N7_STAGE_HTTP_UPSTREAM: host.docker.internal:{adapter_port}
      N7_STAGE_PROXY_TOKEN: {token}
"""
            if prefix:
                fixture += "      N7_PREVIEW_IMPORT: /etc/caddy/n7-preview.Caddyfile\n"
        override.write_text(fixture)
        project = f"n7-test-{token_hex(4)}"
        compose = ["docker", "compose", "-p", project, "--env-file", "/dev/null",
                   "-f", str(ROOT / "Deployment/compose.eclipse-n7-https.yaml"), "-f", str(override)]
        stack.callback(subprocess.run, compose + ["down", "-v", "--rmi", "local"], env=env, stdout=subprocess.DEVNULL)
        subprocess.run(compose + ["up", "-d"], env=env, check=True)
        ca = scratch / "ca.crt"
        wait_for(lambda: subprocess.run(compose + ["cp", "n7_https:/data/caddy/pki/authorities/local/root.crt", str(ca)],
                                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)

        def tls_ready():
            route, expected = (prefix + "/node_info", 200) if anonymous else ("/oauth2/auth", 401)
            try:
                with urlopen(origin + route, context=ssl.create_default_context(cafile=str(ca)), timeout=1) as response:
                    return response.status == expected
            except HTTPError as error:
                return error.code == expected
            except (OSError, URLError):
                return False

        try:
            wait_for(tls_ready)
            if stateless:
                if anonymous:
                    request = Request(f"http://127.0.0.1:{adapter_port}/call?goal=true&format=json",
                                      headers={"Host": urlsplit(origin).netloc,
                                               "X-Web-Prolog-Client-IP": "192.0.2.1",
                                               "X-Web-Prolog-User": "n7-stateless-staging"})
                    try:
                        with urlopen(request, timeout=3) as response:
                            raise AssertionError(f"Direct adapter request returned {response.status}")
                    except HTTPError as error:
                        expect(error.code, 403)
                check_stateless_admission(origin, ca, project + "_default", anonymous=anonymous, prefix=prefix)
                return
            check_https(origin, ca, shell=args.shell, actor_core=args.actor_core,
                        profile="actor" if args.advertise_actor else "isotope",
                        unicode_literals=True)
            check_stateless_cache(origin, ca)
            if args.shell:
                check_shared_database(origin, ca, assets)
        except Exception:
            subprocess.run(compose + ["logs", "--tail", "25"], env=env)
            print(Path(log.name).read_text()[-3000:])
            raise


if __name__ == "__main__":
    main()
