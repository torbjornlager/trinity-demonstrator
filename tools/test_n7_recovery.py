#!/usr/bin/env python3
"""Install a captured N7 bundle into an isolated edge, then roll it back."""
import argparse
from contextlib import ExitStack
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
from secrets import token_hex, token_urlsafe
import shutil
import signal
import ssl
import subprocess
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import urlopen
import venv

from n7_recovery import WS_REQUIREMENTS, adapter_command, docker, load_image, verify
from test_n7_https import EMAIL, OWNER, GitHubFixture, check_https, expect, free_port, wait_for


class EdgeFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers["Host"]
        if host.startswith("127.0.0.1:"):
            if any(name in self.headers for name in ("Cookie", "Authorization", "X-Web-Prolog-Proxy-Token")):
                self.send_error(403)
                return
            offset = parse_qs(urlsplit(self.path).query)["offset"][0]
            body = {"0": "success([v(a),v(b)],true).", "2": "success([v(c)],false)."}[offset]
        else:
            body = f"upstream {host} {self.path}"
        self.send_response(200)
        if host == "n6.elfenbenstornet.se":
            self.send_header("Set-Cookie", "n6_fixture=admitted")
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, *_):
        pass


def serve(stack, handler):
    server = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), handler))
    Thread(target=server.serve_forever, daemon=True).start()
    stack.callback(server.shutdown)
    return server.server_port


def localize(source, fixture_port):
    source = re.sub(r"(?m)^(n[0-6]\.elfenbenstornet\.se) \{", r"http://\1:18080 {", source)
    return re.sub(r"(reverse_proxy (?:@\w+ )?)(?:n0|wp_n[1-4]|n[56]_admission):\d+",
                  rf"\1host.docker.internal:{fixture_port}", source)


def edge_request(port, node, path):
    host = f"n{node}.elfenbenstornet.se"
    connection = HTTPConnection("127.0.0.1", port, timeout=4)
    try:
        connection.request("GET", path, headers={"Host": host})
        with connection.getresponse() as response:
            expect(response.status, 200)
            return response.read(), dict((k.lower(), v) for k, v in response.getheaders())
    finally:
        connection.close()


def stage_edge(bundle, layout, fixture_port):
    for name in ("Caddyfile", "Caddyfile.rollback"):
        (layout / name).write_text(localize((bundle / name).read_text(), fixture_port))
    shutil.copyfile(bundle / "n7.Caddyfile", layout / "n7.Caddyfile")
    shutil.copytree(bundle / "assets", layout / "assets", dirs_exist_ok=True)


def stage_shell(bundle, manifest, directory, origin):
    if "shell" not in manifest:
        return None
    shutil.copytree(bundle / "shell", directory)
    old_url = json.dumps(manifest["origin"] + "/").encode()
    new_url = json.dumps(origin + "/").encode()
    for page in directory.rglob("*.html"):
        original = page.read_bytes()
        local = original.replace(b'"nodeUrl":' + old_url, b'"nodeUrl":' + new_url)
        if local != original:
            page.write_bytes(local)
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    rollback = parser.add_mutually_exclusive_group()
    rollback.add_argument("--compact-rollback", type=Path, help="also restore an earlier compact-only N7 bundle")
    rollback.add_argument("--isotope-rollback", type=Path, help="also restore an earlier HTTP-only full shell")
    rollback.add_argument("--actor-rollback", type=Path, help="also restore the previous ACTOR shell without the workshop")
    parser.add_argument("--require-workshop", action="store_true", help="require and exercise the bundled workshop")
    parser.add_argument("--actor-core", type=Path, metavar="RUNNER", help="run ACTOR core through restored owner HTTPS")
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    manifest = verify(bundle)
    workshop_name = "n7-actor-workshop.html"
    has_workshop = "shell/" + workshop_name in manifest["files"]
    if args.require_workshop and not (manifest.get("actor_ws") and has_workshop):
        parser.error("--require-workshop requires a bundled WebSocket shell with the workshop page")
    rollback_bundle = args.compact_rollback or args.isotope_rollback or args.actor_rollback
    previous = verify(rollback_bundle) if rollback_bundle else None
    if previous is not None and ("shell" not in manifest
                                 or ("shell" in previous) != (args.compact_rollback is None)
                                 or previous.get("actor_ws", False) != bool(args.actor_rollback)
                                 or previous.get("profile", "isotope") != ("actor" if args.actor_rollback else "isotope")
                                 or previous["edge_image_id"] != manifest["edge_image_id"]):
        parser.error("Choose a rollback bundle with the requested profile and shell type and the same edge image")
    if args.actor_rollback and "shell/" + workshop_name in previous["files"]:
        parser.error("--actor-rollback requires an ACTOR bundle from before the workshop")
    if bool(args.actor_core) != bool(manifest.get("actor_ws") or args.actor_rollback):
        parser.error("WebSocket recovery requires --actor-core RUNNER")
    load_image(bundle, manifest)
    if previous is not None:
        load_image(rollback_bundle, previous)
    edge_image_id = manifest["edge_image_id"]
    image = docker("image", "inspect", "--format", "{{.Id}}", edge_image_id).decode().strip()
    expect(image, edge_image_id)

    with ExitStack() as stack:
        work = Path(stack.enter_context(TemporaryDirectory(prefix="n7-recovery-")))
        fixture_port = serve(stack, EdgeFixture)
        github_port = serve(stack, GitHubFixture)
        http_port, https_port, adapter_port = [free_port() for _ in range(3)]
        origin = f"https://localhost:{https_port}"
        network = "n7-recovery-" + token_hex(4)
        edge_image = network + ":edge"
        docker("image", "tag", edge_image_id, edge_image)
        stack.callback(docker, "image", "rm", edge_image)
        docker("network", "create", network)
        stack.callback(docker, "network", "rm", network)
        layout = work / "layout"
        layout.mkdir()
        stage_edge(bundle, layout, fixture_port)
        shell_assets = stage_shell(bundle, manifest, work / "shell", origin)
        def stage_python(source, release, directory):
            if not release.get("actor_ws"):
                return None
            venv.create(directory, with_pip=True)
            python = directory / "bin/python"
            subprocess.run([str(python), "-m", "pip", "install", "--no-index", "--no-deps",
                            "--find-links", str(source / "wheels"), "-r", str(source / WS_REQUIREMENTS)],
                           check=True)
            return python

        actor_python = stage_python(bundle, manifest, work / "venv")
        token = token_hex(32)
        token_file = work / "proxy-token"
        token_file.touch(mode=0o600)
        token_file.write_text(token)
        env = {**os.environ, "N7_RECOVERY_DIR": str(layout), "N7_EDGE_NETWORK": network,
               "N7_ORIGIN": origin, "N7_HTTPS_PORT": str(https_port),
               "N7_HTTP_UPSTREAM": f"host.docker.internal:{adapter_port}",
               "N7_EDGE_TLS_DIRECTIVE": "tls internal", "N7_DISCOVERY_HOST": f"localhost:{https_port}",
               "OAUTH2_PROXY_GITHUB_USERS": OWNER, "WP_N5_OWNER": EMAIL, "N7_PROXY_TOKEN": token,
               "N7_OAUTH2_CLIENT_ID": "n7-recovery-fixture", "N7_OAUTH2_CLIENT_SECRET": token_hex(16),
               "N7_OAUTH2_COOKIE_SECRET": token_urlsafe(32)}
        fixture = work / "fixture.yaml"
        fixture.write_text(f"""services:
  caddy:
    image: {edge_image}
    pull_policy: never
    ports:
      - 127.0.0.1:{http_port}:18080
      - 127.0.0.1:{https_port}:{https_port}
    volumes:
      - {layout}/Caddyfile.rollback:/etc/caddy/Caddyfile:ro
      - rehearsal_tls:/data
  oauth2_n7:
    networks: [default, peer]
    environment:
      OAUTH2_PROXY_LOGIN_URL: http://127.0.0.1:{github_port}/authorize
      OAUTH2_PROXY_REDEEM_URL: http://host.docker.internal:{github_port}/token
      OAUTH2_PROXY_VALIDATE_URL: http://host.docker.internal:{github_port}/
networks:
  peer:
    external: true
    name: {network}
volumes:
  rehearsal_tls:
""")
        base = ["docker", "compose", "-p", network, "--env-file", "/dev/null",
                "-f", str(bundle / "Deployment/compose.eclipse-n7-https.yaml"), "-f", str(fixture)]
        active = base + ["-f", str(bundle / "Deployment/compose.eclipse-n7-recovery.yaml")]

        def compose(flags, *cmd, check=True):
            return subprocess.run([*flags, *cmd], env=env, check=check,
                                  stdout=subprocess.DEVNULL)

        stack.callback(compose, active, "down", "-v", check=False)

        def check_existing_nodes():
            for node in range(7):
                host = f"n{node}.elfenbenstornet.se"
                expect(edge_request(http_port, node, "/call")[0], f"upstream {host} /call".encode())

        compose(base, "up", "-d", "--no-deps", "caddy")
        wait_for(lambda: compose(base, "exec", "-T", "caddy", "curl", "-fsS",
                                 "-H", "Host: n0.elfenbenstornet.se",
                                 "http://localhost:18080/call", check=False).returncode == 0)
        check_existing_nodes()
        expect(edge_request(http_port, 0, "/discovery-hub")[0],
               b"upstream n0.elfenbenstornet.se /discovery-hub")

        # Map the single allowed peer to the disposable fixture, as with the OAuth origin.
        peer = f"http://127.0.0.1:{fixture_port}"
        def stop_adapter(adapter):
            if adapter.poll() is None:
                adapter.send_signal(signal.SIGTERM)
                adapter.wait(timeout=12)

        def start_adapter(source, release, name, assets=None, python=None):
            log = stack.enter_context((work / name).open("w+"))
            command = adapter_command(source, release, adapter_port, EMAIL, token_file,
                                      origin=origin, peers=[peer], shell_assets=assets, python=python)
            adapter = subprocess.Popen(command, stdout=log, stderr=log)
            stack.callback(stop_adapter, adapter)
            wait_for(lambda: "Private proxy origin" in Path(log.name).read_text())
            return adapter

        adapter = start_adapter(bundle, manifest, "adapter.log", shell_assets, actor_python)
        compose(active, "up", "-d", "--no-deps", "oauth2_n7", "caddy")
        ca = work / "ca.crt"
        wait_for(lambda: compose(active, "cp", "caddy:/data/caddy/pki/authorities/local/root.crt",
                                 str(ca), check=False).returncode == 0)
        tls = ssl.create_default_context(cafile=str(ca))

        def https_ready():
            try:
                with urlopen(origin + "/oauth2/auth", context=tls, timeout=1):
                    return True
            except HTTPError as error:
                return error.code == 401
            except OSError:
                return False

        wait_for(https_ready)
        profile = manifest.get("profile", "isotope")
        check_https(origin, ca, shell=shell_assets is not None, actor_core=args.actor_core, profile=profile,
                    workshop=shell_assets / workshop_name if has_workshop else None, recovery=True)
        check_existing_nodes()
        for node in range(7):
            assets = layout / "assets/n7-catalog-v1" / ("n6" if node == 6 else "shared") / "web"
            for path, relative in (("/demonstrator", "demonstrator.html"),
                                   ("/vendor/trinity-host.js?v=n7-catalog-v1", "vendor/trinity-host.js")):
                body, headers = edge_request(http_port, node, path)
                expect(body, (assets / relative).read_bytes())
                if shell_assets is not None and relative == "demonstrator.html":
                    assert b'node.href = parsed.origin + "/n7-shell/";' in body
                if node == 6:
                    expect(headers["set-cookie"], "n6_fixture=admitted")
                    expect(headers["cache-control"], "no-store")
        hub = edge_request(http_port, 0, "/discovery-hub")[0]
        expect(hub, (layout / "assets/n7-discovery-v1/discovery-hub.html").read_bytes())
        if shell_assets is not None:
            assert b'r.id === "n7" ? "/n7-shell/"' in hub
        command = [*active, "exec", "-T", "caddy", "curl", "-fsS", "http://127.0.0.1:8087/node_info"]
        metadata = json.loads(subprocess.check_output(command, env=env))
        expect((metadata["implementation"], metadata["auth"], metadata["profile"]),
               ("ECLiPSe CLP", "private", profile))

        def query(target):
            args = urlencode({"goal": f"rpc('{target}',member(X,[a,b,c]),[limit(2)])", "format": "json"})
            headers = {"Host": f"localhost:{https_port}", "Origin": origin, "X-Web-Prolog-User": EMAIL,
                       "X-Web-Prolog-Proxy-Token": token}
            connection = HTTPConnection("127.0.0.1", adapter_port, timeout=4)
            try:
                connection.request("GET", "/call?" + args, headers=headers)
                with connection.getresponse() as response:
                    expect(response.status, 200)
                    return json.load(response)
            finally:
                connection.close()

        expect(query(peer)["data"], [{"X": "a"}, {"X": "b"}, {"X": "c"}])
        expect(query(peer.replace("127.0.0.1", "localhost"))["type"], "error")
        print("Recovered Hub, catalog, internal metadata, N6 admission headers and single-peer policy")

        if previous is not None:
            stop_adapter(adapter)
            previous_assets = stage_shell(rollback_bundle, previous, work / "rollback-shell", origin)
            previous_python = stage_python(rollback_bundle, previous, work / "rollback-venv")
            adapter = start_adapter(rollback_bundle, previous, "rollback.log", previous_assets, previous_python)
            stage_edge(rollback_bundle, layout, fixture_port)
            compose(active, "up", "-d", "--no-deps", "--force-recreate", "caddy")
            wait_for(https_ready)
            check_https(origin, ca, shell=previous_assets is not None,
                        shell_absent=previous_assets is None,
                        actor_core=args.actor_core if args.actor_rollback else None,
                        profile=previous.get("profile", "isotope"), ws_absent=not args.actor_rollback,
                        workshop_absent=True, recovery=True)
            check_existing_nodes()
            expect(edge_request(http_port, 0, "/discovery-hub")[0],
                   (rollback_bundle / "assets/n7-discovery-v1/discovery-hub.html").read_bytes())
            for node in range(7):
                variant = "n6" if node == 6 else "shared"
                expect(edge_request(http_port, node, "/demonstrator")[0],
                       (rollback_bundle / f"assets/n7-catalog-v1/{variant}/web/demonstrator.html").read_bytes())
            if args.actor_rollback:
                print("ACTOR rollback kept the owner gate and WebSocket support and retired the workshop")
            else:
                print("ISOTOPE rollback kept the owner gate and retired the WebSocket route")

        compose(base, "up", "-d", "--no-deps", "--force-recreate", "caddy")
        compose(base, "stop", "oauth2_n7")
        stop_adapter(adapter)
        wait_for(lambda: compose(base, "exec", "-T", "caddy", "curl", "-fsS",
                                 "-H", "Host: n0.elfenbenstornet.se",
                                 "http://localhost:18080/call", check=False).returncode == 0)
        check_existing_nodes()
        expect(edge_request(http_port, 0, "/discovery-hub")[0],
               b"upstream n0.elfenbenstornet.se /discovery-hub")
        for node in range(7):
            expect(edge_request(http_port, node, "/demonstrator")[0],
                   f"upstream n{node}.elfenbenstornet.se /demonstrator".encode())
        for path in ("/demonstrator", "/n7-shell/", "/n7-shell/n7-actor-workshop.html", "/ws"):
            try:
                urlopen(origin + path, context=tls, timeout=2).close()
            except HTTPError as error:
                raise AssertionError(f"N7 route still responded after rollback: {path}") from error
            except URLError:
                pass
            else:
                raise AssertionError(f"N7 route remained reachable after rollback: {path}")
        print("Rollback restored N0–N6 fixture routes and retired the N7 pilot")


if __name__ == "__main__":
    main()
