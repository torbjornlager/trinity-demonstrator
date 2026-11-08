#!/usr/bin/env python3
"""Test the N7 HTTPS route with OAuth2 Proxy and a local GitHub API fixture."""
import argparse
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


def check_https(origin, ca, shell=False, *, shell_absent=False, actor_core=None):
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
    expect(info, {"self_url": origin, "implementation": "ECLiPSe CLP", "profile": "isotope",
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
    # Some macOS Python builds ignore SSL_CERT_FILE when loading default roots.
    trust_fixture_ca = """
import functools, runpy, ssl, sys
sys.argv.pop(0)
ssl.create_default_context = functools.partial(ssl.create_default_context, cafile=sys.argv.pop(0))
runner = sys.argv[0]
sys.path.insert(0, runner.rsplit('/', 1)[0])
runpy.run_path(runner, run_name='__main__')
"""
    result = subprocess.run([sys.executable, "-c", trust_fixture_ca, str(ca), str(runner.resolve()),
                             "--ws-url", endpoint.replace("https:", "wss:", 1),
                             "--advertised-profile", "actor", "--origin", origin,
                             "--header", "Cookie: " + cookie, "--candidate", "n7-owner-preview",
                             "--report", str(ca.parent / "actor-core.json")])
    expect(result.returncode, 0)


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="trinity-eclipse-n7:local")
    parser.add_argument("--shell", action="store_true", help="also exercise the packaged full demonstrator")
    parser.add_argument("--actor-core", type=Path, metavar="RUNNER", help="run ACTOR core through owner HTTPS")
    args = parser.parse_args()
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
        adapter = subprocess.Popen(
            [sys.executable, str(ROOT / "experiments/eclipse-clp/isotope_http.py"),
             "--pilot-image", args.image, "--port", str(adapter_port), "--private-origin", origin,
             "--owner", EMAIL, "--proxy-token-file", str(token_file), *shell_args], stdout=log, stderr=log,
        )

        def stop_adapter():
            if adapter.poll() is None:
                adapter.send_signal(signal.SIGTERM)
                adapter.wait(timeout=12)

        stack.callback(stop_adapter)
        wait_for(lambda: "Private proxy origin" in Path(log.name).read_text())
        override = scratch / "fixture.yaml"
        override.write_text(f"""services:
  oauth2_n7:
    environment:
      OAUTH2_PROXY_LOGIN_URL: http://127.0.0.1:{provider_port}/authorize
      OAUTH2_PROXY_REDEEM_URL: http://host.docker.internal:{provider_port}/token
      OAUTH2_PROXY_VALIDATE_URL: http://host.docker.internal:{provider_port}/
""")
        env = {**os.environ, "N7_ORIGIN": origin, "N7_HTTPS_PORT": str(https_port),
               "N7_HTTP_UPSTREAM": f"host.docker.internal:{adapter_port}", "N7_TLS_DIRECTIVE": "tls internal",
               "OAUTH2_PROXY_GITHUB_USERS": OWNER, "WP_N5_OWNER": EMAIL, "N7_PROXY_TOKEN": token,
               "N7_OAUTH2_CLIENT_ID": "n7-local-client", "N7_OAUTH2_CLIENT_SECRET": token_hex(16),
               "N7_OAUTH2_COOKIE_SECRET": token_urlsafe(32)}
        compose = ["docker", "compose", "-p", f"n7-test-{token_hex(4)}", "--env-file", "/dev/null",
                   "-f", str(ROOT / "Deployment/compose.eclipse-n7-https.yaml"), "-f", str(override)]
        stack.callback(subprocess.run, compose + ["down", "-v", "--rmi", "local"], env=env, stdout=subprocess.DEVNULL)
        subprocess.run(compose + ["up", "-d"], env=env, check=True)
        ca = scratch / "ca.crt"
        wait_for(lambda: subprocess.run(compose + ["cp", "n7_https:/data/caddy/pki/authorities/local/root.crt", str(ca)],
                                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)

        def tls_ready():
            try:
                with urlopen(origin + "/oauth2/auth", context=ssl.create_default_context(cafile=str(ca)), timeout=1):
                    return True
            except HTTPError as error:
                return error.code == 401
            except (OSError, URLError):
                return False

        try:
            wait_for(tls_ready)
            check_https(origin, ca, shell=args.shell, actor_core=args.actor_core)
        except Exception:
            subprocess.run(compose + ["logs", "--tail", "25"], env=env)
            print(Path(log.name).read_text()[-3000:])
            raise


if __name__ == "__main__":
    main()
