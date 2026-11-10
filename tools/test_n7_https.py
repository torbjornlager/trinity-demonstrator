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
from urllib.parse import parse_qs, quote, urlencode, urlsplit
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
        elif url.path in ("/fixtures/chart.xml", "/fixtures/parent.xml",
                          "/fixtures/child.xml", "/fixtures/worker.pl"):
            body = {
                "/fixtures/chart.xml": b'<statechart version="0.2" initial="s"><state id="s"/></statechart>',
                "/fixtures/parent.xml": b"""
                    <statechart version="0.2" initial="s">
                      <datamodel>value(copied).</datamodel>
                      <state id="s">
                        <spawn type="actor" goal="worker" options="[src_uri('worker.pl'),node(localhost)]"/>
                        <spawn type="statechart" options="[src_uri('child.xml'),src_predicates([value/1]),trace(false)]"/>
                        <go on="output(_,Result)">output(Result)</go>
                      </state>
                    </statechart>""",
                "/fixtures/child.xml": b"""
                    <statechart version="0.2" initial="f">
                      <final id="f"><onentry>value(X),output(nested(X))</onentry></final>
                    </statechart>""",
                "/fixtures/worker.pl": b"worker :- output(fetched).",
            }[url.path]
            self.send_response(200)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
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
                profile="isotope", ws_absent=False, workshop=None, workshop_absent=False,
                unicode_literals=False, sxml_peer=None):
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
    if workshop_absent:
        http(owner, origin + "/n7-shell/n7-actor-workshop.html", status=404)
    if actor_core is not None:
        check_actor_ws(origin, ca, actor_core, anonymous, wrong, wrong_email, owner, spoof,
                       workshop=workshop, sxml_peer=sxml_peer)
    if ws_absent:
        http(anonymous, origin + "/ws", headers=websocket_headers(origin), status=401)
        http(owner, origin + "/ws", headers=websocket_headers(origin), status=404)
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
    expect(type(pid) is int and 1_000_000_000 <= pid <= 9_999_999_999, True)

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
        expect(re.fullmatch(r"[1-9][0-9]{9}", prompt["prompt_ref"]) is not None, True)
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
    if shell:
        sign_in_path = "/oauth2/sign_in?" + urlencode({"rd": "/n7-shell/"})
        logout_path = "/oauth2/sign_out?" + urlencode({"rd": sign_in_path})
        _, page = http(owner, origin + "/n7-shell/")
        expect(logout_path.encode() in page and b"Sign out of N7" in page, True)
        http(owner, origin + "/oauth2/auth", status=202)
        _, sign_in_page = http(owner, origin + logout_path)
        expect(b'name="rd" value="/n7-shell/"' in sign_in_page, True)
        http(owner, origin + "/oauth2/auth", status=401)
        http(owner, origin + "/n7-shell/session.json", status=401)
        print("N7 shell sign-out clears the owner session and returns to the sign-in page")
    print("N7 HTTPS metadata, admission, stateless JSON with source, paging and prompt reply passed")


def websocket_headers(origin):
    return {"Origin": origin, "Connection": "Upgrade", "Upgrade": "websocket",
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="}


def check_actor_ws(origin, ca, runner, anonymous, wrong, wrong_email, owner, spoof, *,
                   workshop=None, sxml_peer=None):
    upgrade = websocket_headers(origin)
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
    workshop_url = origin + "/n7-shell/n7-actor-workshop.html"
    workshop_path = ca.parent / "workshop.html"
    workshop_path.unlink(missing_ok=True)
    if workshop is not None:
        http(anonymous, workshop_url, headers=spoof, status=401)
        http(wrong, workshop_url, status=401)
        http(wrong_email, workshop_url, status=403)
    try:
        with owner.open(workshop_url, timeout=10) as response:
            body = response.read()
        if workshop is not None:
            expect(body == workshop.read_bytes(), True)
            print("N7 workshop matches the restored asset and requires the owner session")
        workshop_path.write_bytes(body)
    except HTTPError as error:
        if workshop is not None or error.code != 404:
            raise
    # Some macOS Python builds ignore SSL_CERT_FILE when loading default roots.
    trust_fixture_ca = """
import functools, html, json, re, runpy, ssl, sys
from pathlib import Path
sys.argv.pop(0)
ssl.create_default_context = functools.partial(ssl.create_default_context, cafile=sys.argv.pop(0))
workshop_path = Path(sys.argv.pop(0))
chart_uris, chart_peer = json.loads(sys.argv.pop(0))
service_request_path = Path(sys.argv.pop(0))
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
    assert type(pid) is int and 1000000000 <= pid <= 9999999999, spawned
    ws.send_json(dict(command='toplevel_call', pid=pid, goal='format("shell output~n",[])'))
    output = ws.recv_json()
    assert (output['type'], output['data']) == ('output', 'shell output\\n'), output
    assert ws.recv_json()['type'] == 'success'

    def shell_call(goal, output=None):
        ws.send_json(dict(command='toplevel_call', pid=pid, goal=goal, options='[limit(1)]'))
        event = ws.recv_json()
        while output is not None and event['type'] == 'output':
            output.append(event['data'])
            event = ws.recv_json()
        assert event['type'] == 'success' and event['more'] is False, (goal[:200], event)
        assert len(event['data']) == 1, (goal, event)
        return event['data'][0]

    bindings = shell_call("self(Self),findall(R,(between(1,8,_),make_ref(R),integer(R)),Refs),"
                          "Pair=[Self|Refs],"
                          "send(Self,Refs),receive({Reply if Reply == Refs -> true})")
    node = option('--origin')
    assert bindings['Self'] == f"{pid}@'{node}'", bindings
    assert bindings['Pair'] == f"[{pid}@'{node}'," + bindings['Refs'][1:], bindings
    refs = [int(ref) for ref in re.findall(r'\d+', bindings['Refs'])]
    assert len(refs) == 8 and len(set(refs + [pid])) == 9, bindings
    assert all(1000000000 <= ref <= 9999999999 for ref in refs), bindings
    assert max(refs) - min(refs) > len(refs) - 1, bindings
    ws.send_json(dict(command='toplevel_call', pid=pid,
                      goal='input(prompt_ref(123,question),A),input(second,B)'))
    first = ws.recv_json()
    assert (first['type'], first['data']) == ('prompt', 'prompt_ref(123,question)'), first
    first_ref = first['prompt_ref']
    ws.send_json(dict(command='toplevel_respond', pid=pid, prompt_ref=first_ref, input='one.'))
    assert ws.recv_json()['type'] == 'responded'
    second = ws.recv_json()
    assert second['type'] == 'prompt', second
    second_ref = second['prompt_ref']
    assert all(re.fullmatch(r'[1-9][0-9]{9}', ref) for ref in (first_ref, second_ref))
    assert len(set(refs + [pid, int(first_ref), int(second_ref)])) == 11
    for fields in ({'prompt_ref': first_ref}, {}, {'prompt_ref': int(second_ref)}):
        ws.send_json(dict(command='toplevel_respond', pid=pid, input='invalid.', **fields))
        rejected = ws.recv_json()
        assert (rejected['type'], rejected['code'], rejected['pid']) == ('error', 'invalid_prompt_ref', pid), rejected
    ws.send_json(dict(command='toplevel_respond', pid=pid, prompt_ref=second_ref, input='two.'))
    assert ws.recv_json()['type'] == 'responded'
    assert ws.recv_json()['data'] == [{'A': 'one', 'B': 'two'}]
    shell_call("maplist(=,[a],[a]),foldl(throw,[],state,Final),Final==state")
    child = shell_call("toplevel_spawn(Child,[session(true),monitor(true),src_list([p(a),p(b)])])")['Child']
    child_id, separator, child_node = child.partition('@')
    assert separator and child_node == f"'{node}'", child
    assert re.fullmatch(r'[1-9][0-9]{9}', child_id) and int(child_id) not in refs + [pid], child
    monitor = shell_call(f"monitor({child},Ref),demonitor(Ref)")['Ref']
    assert re.fullmatch(r'[1-9][0-9]{9}', monitor) and int(monitor) not in refs + [pid, int(child_id)], monitor
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

    if chart_uris:
        atom = suite['prolog_quote_atom']
        start = '<statechart version="0.2" initial="s">'
        end = '</statechart>'
        chart = start + '<state id="s"/></statechart>'
        shell_call(f'statechart_validate_text({atom(chart)},[])')
        shell_call(f'statechart_validate_text({json.dumps(chart)},[])')
        unicode_chart = (start + '<state id="s"><go on="X &lt; 3">'
                         '<![CDATA[output(é😀), output("<!DOCTYPE harmless>")]]>'
                         '</go></state>' + end)
        shell_call(f'statechart_validate_text({atom(unicode_chart)},[])')
        for uri in chart_uris:
            shell_call(f'statechart_validate({atom(uri)},[])')
        shell_call(f'statechart_validate({atom(node + "/n7-shell" + chart_uris[0])},[])')
        shell_call(f'statechart_validate({atom(chart_peer + "/fixtures/chart.xml")},[])')
        shell_call("catch(statechart_validate('/examples/statecharts/%2e%2e%2fsecret.xml',_),"
                   "error(rpc_error(_),_),Rejected=true),Rejected==true")
        shell_call("catch(statechart_validate('https://unapproved.invalid/chart.xml',_),"
                   "error(rpc_error(_),_),Rejected=true),Rejected==true")

        invalid = [
            (start + '<state id="s"></statechart>', 'malformed_xml'),
            ('<!DOCTYPE statechart SYSTEM "file:///etc/passwd">' + chart, 'forbidden_xml_declaration'),
            (start + '<state id="s" id="t"/>' + end, 'malformed_xml'),
            (start + '<state id="s"initial="t"><state id="t"/></state>' + end, 'malformed_xml'),
            (start + '<state id="s" alien="value"/>' + end, 'unknown_attribute'),
            (start + '<state id="s"><go to="absent"/></state>' + end, 'unknown_identifier'),
            (start + '<state id="s"/><state id="s"/>' + end, 'duplicate_identifier'),
            (start + '<state id="s"><go on="&unknown;"/></state>' + end, 'unknown_entity'),
            (start + '<state id="s"><go on="&#0;"/></state>' + end, 'malformed_xml'),
            (start + '<state id="s"><go to=""/></state>' + end, 'empty_transition_target'),
            (start + '<state id="s"><go after="-1"/></state>' + end, 'after_delay'),
            (start + '<state id="s"><go on="e" after="1"/></state>' + end, 'on_and_after'),
            (start + '<state id="s"><history id="h"><go/></history></state>' + end, 'history_default'),
            (start + '<state id="s"><go to="statechart_actor"/></state>' + end, 'unknown_identifier'),
            (start + '<state id="s">' * 129 + '</state>' * 129 + end, 'sxml_document_depth'),
        ]
        for text, detail in invalid:
            term = atom(text)
            diagnostics = shell_call(f'statechart_validate_text({term},Diagnostics)')['Diagnostics']
            assert detail in diagnostics, (detail, diagnostics)
            shell_call(f'actors(Before),catch(statechart_spawn(P,[src_text({term})]),_,Caught=true),'
                       'Caught==true,var(P),actors(After),sort(Before,Set),sort(After,Set)')
        bad_attribute = atom(next(text for text, detail in invalid if detail == 'unknown_attribute'))
        ws.send_json(dict(command='toplevel_call', pid=pid,
                          goal=f'statechart_spawn(P,[src_text({bad_attribute})])'))
        error = ws.recv_json()
        assert error['type'] == 'error' and 'unknown_attribute' in error['data'], error
        shell_call(f'statechart_spawn(P,[src_text({atom(chart)}),trace(false)]),statechart_halt(P,true)')
        invocation = start + '<state id="s"><spawn type="actor"/></state>' + end
        shell_call(f'actors(Before),catch(statechart_spawn(P,[src_text({atom(invocation)})]),'
                   'error(existence_error(attribute,goal),_),Rejected=true),'
                   'Rejected==true,var(P),actors(After),sort(Before,Set),sort(After,Set)')
        cycle = (start + '<state id="s" initial="a"><state id="a"/>'
                 '<history id="h"><go to="k"/></history>'
                 '<history id="k"><go to="h"/></history></state>' + end)
        shell_call(f'actors(Before),catch(statechart_spawn(P,[src_text({atom(cycle)})]),'
                   'error(domain_error(history_cycle,_),_),Rejected=true),'
                   'Rejected==true,var(P),actors(After),sort(Before,Set),sort(After,Set)')
        bad_goal = start + '<state id="s"><onentry>bad(</onentry></state>' + end
        shell_call(f'actors(Before),catch(statechart_spawn(P,[src_text({atom(bad_goal)})]),_,Rejected=true),'
                   'Rejected==true,var(P),actors(After),sort(Before,Set),sort(After,Set)')
        runtime = (start + '<datamodel>:- dynamic mark/1.</datamodel>'
                   '<state id="s"><onexit>in(s),assertz(mark(exit))</onexit>'
                   '<go on="run(To,X)" if="X=7" to="t">raise(deliver(To,X)),fail</go></state>'
                   '<state id="t"><onentry>in(t),assertz(mark(entry))</onentry>'
                   '<go to="u" if="mark(entry)">true</go></state>'
                   '<state id="u"><onexit>in(u),mark(exit),mark(entry),mark(error),'
                   ' mark(receiver(Receiver)),send(Receiver,stopped)</onexit>'
                   '<go on="deliver(To,X)">in(u),extra(Supplement),'
                   ' assertz(mark(receiver(To))),send(To,delivered(X,Supplement))</go>'
                   '<go on="error(failure(_))">assertz(mark(error))</go>'
                   '</state>' + end)
        shell_call(f'statechart_spawn(P,[src_text({atom(runtime)}),src_list([extra(supplement)]),'
                   'trace(false),monitor(true)]),self(Self),send(P,run(Self,7)),'
                   'receive({delivered(7,supplement)->true},[timeout(2),on_timeout(throw(no_delivery))]),'
                   'statechart_halt(P,true,2),receive({stopped->true},[timeout(2),on_timeout(throw(no_exit_action))]),'
                   'receive({down(P,P,true)->true},[timeout(2),on_timeout(throw(no_down))])')
        stalled = start + '<state id="s"><onentry>repeat,fail</onentry></state>' + end
        shell_call(f'statechart_spawn(P,[src_text({atom(stalled)}),trace(false)]),statechart_halt(P,killed,0.05)')
        shell_call("statechart_spawn(P,[src_uri('/examples/statecharts/20%20jev-deployment-assistant.xml'),"
                   "trace(false)]),self(Self),"
                   "send(P,observed(Self,one,deploy,observation(choice(request_deploy,[],1),score,noul,source))),"
                   "receive({demo_reply(one,report(_,_,state(idle),_,action(ask_confirmation),_))->true},"
                   "[timeout(2),on_timeout(throw(no_proposal))]),"
                   "send(P,observed(Self,two,yes,observation(choice(affirm,[],1),score,noul,source))),"
                   "receive({demo_reply(two,report(_,_,state(awaiting_confirmation),_,"
                   "action(simulate_deploy(proposal(one,deploy,_))),_))->true},"
                   "[timeout(2),on_timeout(throw(no_confirmation))]),statechart_halt(P,true,2)")
        def structured_chart(title, initial, body, steps):
            chart = f'<statechart version="0.2" initial="{initial}">' + body + end
            shell_call(f"self(Self),statechart_spawn(P,[src_text({atom(chart)}),trace(false)]),"
                       "send(P,watch(Self))," + steps + ",statechart_halt(P,true,2)")
            print('PASS', title)

        # Consume the next result, rather than selectively skipping results
        # that would reveal an incorrect action or event order.
        result_ids = iter(range(100))

        def check_result(expected):
            variable = 'R' + str(next(result_ids))
            return ("receive({chart_result(" + variable + ")->true},"
                    "[timeout(2),on_timeout(throw(missing_chart_result(" + expected + ")))]),"
                    + variable + "==" + expected)

        structured_chart('SXML history fallback, shallow and deep restore', 'away',
            '''
            <datamodel>:- dynamic watcher/1.
            report(X) :- watcher(To),send(To,chart_result(X)).</datamodel>
            <state id="away">
                <go on="watch(To)">assertz(watcher(To))</go>
                <go to="sh" on="shallow"/>
                <go to="dh" on="deep"/>
            </state>
            <state id="outer" initial="home">
                <history id="sh"><go to="inner"/></history>
                <history id="dh" type="deep"><go to="inner"/></history>
                <state id="home"/>
                <state id="inner" initial="a">
                    <state id="a"><onentry>report(a)</onentry><go on="step" to="b"/></state>
                    <state id="b"><onentry>report(b)</onentry></state>
                </state>
                <go to="away" on="leave"/>
            </state>
            ''',
            ','.join(["send(P,shallow)", check_result('a'), "send(P,step)", check_result('b'),
                      "send(P,leave)", "send(P,deep)", check_result('b'),
                      "send(P,leave)", "send(P,shallow)", check_result('a')]))

        structured_chart('SXML parallel conflict, multi-target entry and completion', 'idle',
            '''
            <datamodel>:- dynamic watcher/1.
            report(X) :- watcher(To),send(To,chart_result(X)).</datamodel>
            <state id="idle">
                <go on="watch(To)">assertz(watcher(To))</go>
                <go to="a1 b1" on="enter"/>
            </state>
            <parallel id="p">
                <state id="left" initial="a0">
                    <state id="a0"><onentry>report(unexpected_a0)</onentry></state>
                    <state id="a1"><onentry>report(a1)</onentry>
                        <go on="finish_left" to="af">report(left)</go>
                    </state>
                    <final id="af"/>
                </state>
                <state id="right" initial="b0">
                    <state id="b0"><onentry>report(unexpected_b0)</onentry></state>
                    <state id="b1"><onentry>report(b1)</onentry>
                        <go on="finish_right" to="bf">report(right)</go>
                    </state>
                    <final id="bf"/>
                </state>
                <go on="finish_left" to="idle">report(wrong_ancestor)</go>
                <go on="done(p)" to="idle">report(complete)</go>
                <go on="probe">in(af),in(b1),report(still_parallel)</go>
            </parallel>
            ''',
            ','.join(["send(P,enter)", check_result('a1'), check_result('b1'),
                      "send(P,finish_left)", check_result('left'),
                      "send(P,probe)", check_result('still_parallel'),
                      "send(P,finish_right)", check_result('right'), check_result('complete')]))

        structured_chart('SXML guarded deferral, self-reentry and FIFO replay', 's',
            '''
            <datamodel>:- dynamic watcher/1, attempts/1.
            report(X) :- watcher(To),send(To,chart_result(X)).
            postpone(X) :- integer(X),assertz(attempts(X)).</datamodel>
            <state id="s">
                <go on="watch(To)">assertz(watcher(To))</go>
                <defer on="work(X)" if="postpone(X)"/>
                <go on="work(now)">report(now)</go>
                <go on="again" to="s"/>
                <go on="check">findall(X,attempts(X),Xs),report(attempts(Xs))</go>
                <go on="ready" to="ready">raise(first)</go>
            </state>
            <state id="ready">
                <go on="first">report(first)</go>
                <go on="work(X)">report(X)</go>
            </state>
            ''',
            ','.join(["send(P,work(1))", "send(P,work(now))", "send(P,work(2))", "send(P,again)",
                      "send(P,check)", check_result('now'), check_result('attempts([1,2])'),
                      "send(P,ready)", "send(P,work(3))",
                      *(check_result(x) for x in ['first', '1', '2', '3'])]))

        structured_chart('SXML timers ignore stale firings after reentry', 'idle',
            '''
            <datamodel>:- dynamic watcher/1.
            report(X) :- watcher(To),send(To,chart_result(X)).</datamodel>
            <state id="idle">
                <go on="watch(To)" to="waiting">assertz(watcher(To))</go>
            </state>
            <state id="waiting">
                <onentry>report(waiting)</onentry>
                <go after="0.3">report(timer)</go>
                <go after="0.05" if="fail">report(unexpected_guard)</go>
                <go on="leave" if="report(leaving),receive({release->true})" to="away"/>
                <go on="probe">report(probe)</go>
                <go on="_">report(unexpected_event)</go>
            </state>
            <state id="away"><go on="back" to="waiting"/></state>
            ''',
            ','.join([check_result('waiting'), "send(P,leave)", check_result('leaving'),
                      "send(P,back)", "sleep(0.45)", "send(P,probe)", "send(P,release)",
                      check_result('waiting'), check_result('probe'), check_result('timer')]))

        lifecycle = (start + '<state id="s"><spawn type="actor" options="[link(false)]" '
                     'goal="worker"><![CDATA[worker :- '
                     'receive({ping(To) -> send(To,pong),receive({never -> true})}).]]></spawn>'
                     '<go on="spawned(C)">output(child(C))</go>'
                     '<go on="leave" to="away"/></state>'
                     '<state id="away"><go on="resume" to="s"/></state>' + end)
        wait = "[timeout(2),on_timeout(throw(invocation_timeout))]"
        shell_call(f"statechart_spawn(P,[src_text({atom(lifecycle)}),trace(false),monitor(true)]),"
                   f"receive({{output(P,child(A))->true}},{wait}),self(Self),send(A,ping(Self)),"
                   f"receive({{pong->true}},{wait}),monitor(A,MA),send(P,leave),"
                   f"receive({{down(A,MA,stop)->true}},{wait}),send(P,resume),"
                   f"receive({{output(P,child(B))->true}},{wait}),A\\==B,monitor(B,MB),exit(P,kill),"
                   f"receive({{down(P,P,kill)->true}},{wait}),receive({{down(B,MB,stop)->true}},{wait})")
        transient = (start + '<state id="s"><onentry>raise(skip)</onentry>'
                     '<spawn type="actor" goal="throw(should_not_start)" options="[monitor(true)]"/>'
                     '<go on="spawned(_)" to="wrong"/><go on="skip" to="settled"/></state>'
                     '<final id="settled"><onentry>output(settled)</onentry></final>'
                     '<final id="wrong"/>' + end)
        shell_call(f"statechart_spawn(P,[src_text({atom(transient)}),trace(false),monitor(true)]),"
                   f"receive({{output(P,settled)->true}},{wait}),receive({{down(P,P,true)->true}},{wait})")
        print('PASS SXML stable invocation, reentry and forced cleanup')

        timed = (start + '<state id="s">'
                 '<spawn type="toplevel" options="[time_limit(0.15),idle_limit(0.5),session(true),monitor(true)]"/>'
                 '<go on="spawned(C)">toplevel_call(C,(repeat,fail))</go>'
                 '<go on="error(C,error(resource_error(time),_))">output(timed_out),toplevel_call(C,true)</go>'
                 '<go on="success(_,[true],false)">output(recovered)</go>'
                 '<go on="down(_,_,true)" to="f"/></state><final id="f"/>' + end)
        shell_call(f"statechart_spawn(P,[src_text({atom(timed)}),trace(false),monitor(true)]),"
                   f"receive({{output(P,timed_out)->true}},{wait}),"
                   f"receive({{output(P,recovered)->true}},{wait}),receive({{down(P,P,true)->true}},{wait})")
        shell_call("toplevel_spawn(C,[session(true),time_limit(0.15)]),"
                   "toplevel_call(C,receive({never->true})),"
                   f"receive({{error(C,error(resource_error(time),_))->true}},{wait}),"
                   "toplevel_call(C,sleep(3)),"
                   f"receive({{error(C,error(resource_error(time),_))->true}},{wait}),"
                   "toplevel_halt(C,true)")
        print('PASS SXML toplevel query and idle limits')

        shell_call(f"statechart_spawn(P,[src_uri({atom(chart_peer + '/fixtures/parent.xml')}),"
                   "trace(false),monitor(true)]),"
                   f"receive({{output(P,fetched)->true;down(P,P,E)->throw(E)}},{wait}),"
                   f"receive({{output(P,nested(copied))->true;down(P,P,E)->throw(E)}},{wait}),"
                   "statechart_halt(P,true,2)")
        print('PASS SXML document-relative child sources and parent predicate copying')

        named = (start + '<state id="s"><spawn type="toplevel" options="[name(sxml_invoked),link(false)]"/>'
                 '<go on="spawned(C)">output(child(C))</go><go to="s" on="again"/></state>' + end)
        shell_call(f"statechart_spawn(P,[src_text({atom(named)}),trace(false)]),"
                   f"receive({{output(P,child(A))->true}},{wait}),whereis(sxml_invoked,A),send(P,again),"
                   f"receive({{output(P,child(B))->true}},{wait}),A\\==B,whereis(sxml_invoked,B),"
                   "statechart_halt(P,true,2),whereis(sxml_invoked,undefined)")
        rollback = (start + '<state id="s">'
                    '<spawn type="toplevel" options="[name(sxml_rollback),link(false)]"/>'
                    '<spawn type="toplevel" options="[name(sxml_rollback)]"/></state>' + end)
        shell_call(f"statechart_spawn(P,[src_text({atom(rollback)}),trace(false),monitor(true)]),"
                   f"receive({{down(P,P,exception(name_is_in_use(sxml_rollback)))->true}},{wait}),"
                   "once((between(1,100,_),(whereis(sxml_rollback,undefined)->true;sleep(0.01),fail)))")
        print('PASS SXML named child reentry and startup rollback')

        routed = (start + '<state id="s"><spawn type="actor" goal="worker" '
                  'options="[io_target(sxml_io)]">worker :- writeln(invoked_io).</spawn>'
                  '</state>' + end)
        shell_call(f"self(Self),setup_call_cleanup(register(sxml_io,Self),"
                   f"(statechart_spawn(P,[src_text({atom(routed)}),trace(false)]),"
                   f"receive({{terminal_io_output(_,Text)->true}},{wait}),atom_string(invoked_io,Prefix),substring(Text,Prefix,1),"
                   "statechart_halt(P,true,2)),unregister(sxml_io))")
        print('PASS SXML explicit invocation I/O target')

        service_request = json.dumps(service_request_path.read_text(encoding='utf-8'), ensure_ascii=False)
        output = []
        def await_notice(notice):
            while notice not in ''.join(''.join(output).split()):
                event = ws.recv_json()
                assert event['type'] == 'output', event
                output.append(event['data'])

        service = shell_call(f"statechart_spawn(P,[src_text({service_request}),trace(false),monitor(true)]),"
                             "make_ref(Key),send(P,start(Key,vpn))", output)
        chart_pid, key = int(service['P'].split('@', 1)[0]), int(service['Key'])
        await_notice("summary(1,[cost(10),service(vpn)])")
        shell_call(f"send({chart_pid},authenticated({key},alice,confirm(1,[cost(10),service(vpn)])))", output)
        await_notice("human_review(1,[cost(10),service(vpn)],conflicting)")
        shell_call(f"send({chart_pid},authenticated({key},reviewer,review(1,[cost(10),service(vpn)],approve)))", output)
        await_notice("terminal(1,succeeded(ticket_42))")
        shell_call(f"receive({{down({chart_pid},{chart_pid},true)->true}},{wait})", output)
        print('PASS SXML service request from the packaged editor source')

        document_manifest = Path(runner).parent.parent / 'cases/statechart-document-0.1.json'
        for case in json.loads(document_manifest.read_text())['cases']:
            shell_call(case['goal'])
            print('PASS', case['id'], case['title'])
        print(f'N7 SXML validation passed for {len(chart_uris)} bundled documents; flat and structured execution passed')

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
    ws.send_json(dict(command='toplevel_respond', pid=pid, prompt_ref=prompt['prompt_ref'], input='7.'))
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
    chart_uris = ["/examples/statecharts/" + quote(path.name)
                  for path in sorted((ROOT / "examples/statecharts").glob("*.xml"))] if sxml_peer else []
    result = subprocess.run([sys.executable, "-c", trust_fixture_ca, str(ca),
                             str(workshop_path), json.dumps([chart_uris, sxml_peer]),
                             str(ROOT / "examples/statecharts/18 service-request.xml"), str(runner.resolve()),
                             "--ws-url", endpoint.replace("https:", "wss:", 1),
                             "--advertised-profile", "actor", "--origin", origin,
                             "--header", "Cookie: " + cookie, "--candidate", "n7-owner-preview",
                             "--report", str(ca.parent / "actor-core.json")])
    expect(result.returncode, 0)


def check_sxml_reader(image):
    # A valid chart can still have the wrong Prolog meaning if the XML reader
    # collapses spaces or joins separate character-data chunks incorrectly.
    goal = r"""sxml_document:parse_sxml(
        "<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"><go on=\"msg(&apos;a   b&apos;,&#x1F600;)\"><![CDATA[write(é).]]></go></state></statechart>",
        [element(statechart, _, [element(state, _, [element(go, [on=Pattern], [Body])])])]),
        atom_string(Pattern, "msg('a   b',😀)"), Body == "write(é).", halt"""
    subprocess.run([
        "docker", "run", "--rm", "--network", "none",
        "--entrypoint", "/eclipse/lib/aarch64_linux/eclipse.exe", image,
        "-D", "/eclipse", "-b", "isotope_bridge.ecl", "-e", goal,
    ], check=True, timeout=20)


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


def check_stateless_admission(origin, ca, network, *, anonymous=False, prefix=""):
    tls = HTTPSHandler(context=ssl.create_default_context(cafile=str(ca)))
    client = build_opener(tls, NoRedirect())
    endpoint = origin + prefix
    quick = "true"
    slow = "sleep(60)"
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
        query = urlencode({"goal": "sleep(0.01)", "format": "json"})
        _, answer = http(client, endpoint + "/call?" + query)
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
    parser.add_argument("--sxml-documents", action="store_true", help="validate packaged SXML through the owner shell")
    parser.add_argument("--stateless-admission", action="store_true",
                        help="test the stateless preview with two HTTPS clients on the Docker network")
    parser.add_argument("--anonymous-staging", action="store_true",
                        help="test the anonymous staging site with two HTTPS clients on the Docker network")
    parser.add_argument("--anonymous-preview", action="store_true",
                        help="test the anonymous /preview routes on the owner HTTPS site")
    args = parser.parse_args()
    if args.sxml_documents and (not args.shell or args.actor_core is None):
        parser.error("--sxml-documents requires --shell and --actor-core")
    if args.sxml_documents:
        check_sxml_reader(args.image)
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
        chart_peer = f"http://127.0.0.1:{provider_port}" if args.sxml_documents else None
        if chart_peer:
            shell_args.extend(["--allow-peer", chart_peer])
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
                        unicode_literals=True, sxml_peer=chart_peer)
            check_stateless_cache(origin, ca)
            if args.shell:
                check_shared_database(origin, ca, assets)
        except Exception:
            subprocess.run(compose + ["logs", "--tail", "25"], env=env)
            print(Path(log.name).read_text()[-3000:])
            raise


if __name__ == "__main__":
    main()
