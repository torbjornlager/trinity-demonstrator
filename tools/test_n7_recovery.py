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

from n7_recovery import adapter_command, docker, load_image, verify
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    bundle = parser.parse_args().bundle.resolve()
    manifest = verify(bundle)
    load_image(bundle, manifest)
    image = docker("image", "inspect", "--format", "{{.Id}}", manifest["edge_image"]).decode().strip()
    expect(image, manifest["edge_image_id"])

    with ExitStack() as stack:
        work = Path(stack.enter_context(TemporaryDirectory(prefix="n7-recovery-")))
        fixture_port = serve(stack, EdgeFixture)
        github_port = serve(stack, GitHubFixture)
        http_port, https_port, adapter_port = [free_port() for _ in range(3)]
        origin = f"https://localhost:{https_port}"
        network = "n7-recovery-" + token_hex(4)
        docker("network", "create", network)
        stack.callback(docker, "network", "rm", network)
        layout = work / "layout"
        layout.mkdir()
        for name in ("Caddyfile", "Caddyfile.rollback"):
            (layout / name).write_text(localize((bundle / name).read_text(), fixture_port))
        shutil.copyfile(bundle / "n7.Caddyfile", layout / "n7.Caddyfile")
        shutil.copytree(bundle / "assets", layout / "assets")
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
    image: {manifest['edge_image']}
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

        log = stack.enter_context((work / "adapter.log").open("w+"))
        # Map the single allowed peer to the disposable fixture, as with the OAuth origin.
        peer = f"http://127.0.0.1:{fixture_port}"
        adapter = subprocess.Popen(adapter_command(bundle, manifest, adapter_port, EMAIL, token_file,
                                                   origin=origin, peers=[peer]), stdout=log, stderr=log)

        def stop_adapter():
            if adapter.poll() is None:
                adapter.send_signal(signal.SIGTERM)
                adapter.wait(timeout=12)

        stack.callback(stop_adapter)
        wait_for(lambda: "Private proxy origin" in Path(log.name).read_text())
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
        check_https(origin, ca)
        check_existing_nodes()
        for node in range(7):
            assets = layout / "assets/n7-catalog-v1" / ("n6" if node == 6 else "shared") / "web"
            for path, relative in (("/demonstrator", "demonstrator.html"),
                                   ("/vendor/trinity-host.js?v=n7-catalog-v1", "vendor/trinity-host.js")):
                body, headers = edge_request(http_port, node, path)
                expect(body, (assets / relative).read_bytes())
                if node == 6:
                    expect(headers["set-cookie"], "n6_fixture=admitted")
                    expect(headers["cache-control"], "no-store")
        expect(edge_request(http_port, 0, "/discovery-hub")[0],
               (layout / "assets/n7-discovery-v1/discovery-hub.html").read_bytes())
        command = [*active, "exec", "-T", "caddy", "curl", "-fsS", "http://127.0.0.1:8087/node_info"]
        metadata = json.loads(subprocess.check_output(command, env=env))
        expect((metadata["implementation"], metadata["auth"]), ("ECLiPSe CLP", "private"))

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

        compose(base, "up", "-d", "--no-deps", "--force-recreate", "caddy")
        compose(base, "stop", "oauth2_n7")
        stop_adapter()
        wait_for(lambda: compose(base, "exec", "-T", "caddy", "curl", "-fsS",
                                 "-H", "Host: n0.elfenbenstornet.se",
                                 "http://localhost:18080/call", check=False).returncode == 0)
        check_existing_nodes()
        expect(edge_request(http_port, 0, "/discovery-hub")[0],
               b"upstream n0.elfenbenstornet.se /discovery-hub")
        for node in range(7):
            expect(edge_request(http_port, node, "/demonstrator")[0],
                   f"upstream n{node}.elfenbenstornet.se /demonstrator".encode())
        try:
            urlopen(origin + "/node_info", context=tls, timeout=2).close()
        except URLError:
            pass
        else:
            raise AssertionError("N7 remained reachable after rollback")
        print("Rollback restored N0–N6 fixture routes and retired the N7 pilot")


if __name__ == "__main__":
    main()
