#!/usr/bin/env python3
"""Owner-only localhost presenter for the unmodified GNU ISOBASE listener.

The node still owns execution, source validation, query admission and paging.
This adapter owns browser login, the explicit proxy trust boundary, metadata,
and read-only demonstrator assets. It is not a multi-user/public gateway.
"""
import base64
from contextlib import closing
import hashlib
import hmac
import http.client
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import threading
import time
from urllib.parse import parse_qs, unquote, urlsplit

PUBLIC_EXECUTION = os.environ.get('N6_PUBLIC_EXECUTION') == 'yes'
VISITOR_COOKIE = '__Host-n6_visitor' if os.environ.get('N6_PUBLIC_URL', '').startswith('https:') else 'n6_visitor'
PUBLIC_URL = os.environ.get('N6_PUBLIC_URL', 'http://localhost:3057').rstrip('/')
ASSET_URL = os.environ.get('N6_ASSET_URL', 'http://n6_assets:3051')
HUB_URL = os.environ.get('N6_HUB_URL', 'http://localhost:3058/discovery-hub')
HTTPS_OWNER = PUBLIC_URL == 'https://n6.elfenbenstornet.se'
OWNER_COOKIE = '__Host-n6_owner' if HTTPS_OWNER else 'n6_owner'
LOGIN_COOKIE = '__Secure-n6_login' if HTTPS_OWNER else 'n6_login'
COOKIE_SECURE = '; Secure' if HTTPS_OWNER else ''
ROOT = Path('/app/n6')
PROVIDES = ['ancestor_descendant/2', 'parent_child/2', 'mother_child/2',
            'father_child/2', 'list_price/2', 'price/2', 'human/1', 'deployment_node/1']
ASSET_PATHS = {
    '/demonstrator', '/portal', '/manual', '/editor_frame', '/examples_index',
    '/tutorial', '/swi-wasm-tutorial', '/isobase-profile-tutorial',
    '/isobase-api-tutorial', '/isotope-profile-tutorial', '/isotope-api-tutorial',
    '/actor-profile-tutorial', '/actor-api-tutorial', '/statechart-behaviour-tutorial',
    '/jev-sxml-tutorial', '/swipl-bundle.js', '/swi_wasm_actor_worker.js', '/sxml-0.2.dtd'}
LOGIN = '''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>N6 owner login</title>
<style>body{font:16px system-ui;background:#f5f5f5;color:#1f2937;margin:0;padding:48px 20px}
main{max-width:360px;margin:8vh auto;padding:28px;background:white;border:1px solid #d4d4d4}
h1{color:darkgreen;font-size:26px}label{display:block;margin:18px 0 6px}
input{box-sizing:border-box;width:100%;font:inherit;padding:8px;border:1px solid #aaa}
button{font:inherit;background:darkgreen;color:white;border:0;padding:10px 18px;margin-top:24px}
</style><main><h1>N6 owner login</h1><p>GNU Prolog · ISOBASE · Owner preview</p>
<form method="post" action="/login"><input name="csrf" type="hidden" value="CSRF_TOKEN">
<label for="username">Username</label>
<input id="username" name="username" autocomplete="username" required value="owner">
<label for="password">Password</label><input id="password" name="password" type="password"
autocomplete="current-password" required><button type="submit">Sign in</button></form></main></html>'''


def owner_authorized(value, encoded_hash):
    try:
        scheme, encoded = value.split(' ', 1)
        if scheme.lower() != 'basic':
            return False
        username, password = base64.b64decode(encoded, validate=True).decode().split(':', 1)
        kind, rounds, salt, digest = encoded_hash.split(':')
        if kind != 'pbkdf2_sha256' or not hmac.compare_digest(username, 'owner'):
            return False
        calculated = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), int(rounds))
        return hmac.compare_digest(calculated.hex(), digest)
    except (ValueError, UnicodeError, TypeError):
        return False


def host_config():
    nodes = [dict(url=f'https://n{n}.elfenbenstornet.se',
                  runtime='swi' if n < 5 else 'trealla') for n in range(1, 6)]
    nodes.append(dict(url=PUBLIC_URL, runtime='gprolog'))
    return dict(remoteNodes=nodes, discoveryHubUrl=HUB_URL,
                ownerLogin=not PUBLIC_EXECUTION, interactionLogging=False)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, controller, owner_hash, token):
        super().__init__(address, Handler)
        self.controller, self.owner_hash, self.token = controller, owner_hash, token
        self.session_key = secrets.token_bytes(32)
        self.capacity = threading.BoundedSemaphore(16)

    def session(self, purpose='owner', lifetime=28800):
        value = str(int(time.time()) + lifetime) + ':' + secrets.token_hex(16)
        signature = hmac.new(self.session_key, (purpose + ':' + value).encode(), 'sha256').hexdigest()
        return value + ':' + signature

    def valid_session(self, value, purpose='owner'):
        try:
            expiry, nonce, signature = value.split(':')
            expected = hmac.new(self.session_key, (purpose + ':' + expiry + ':' + nonce).encode(), 'sha256').hexdigest()
            return int(expiry) > time.time() and hmac.compare_digest(signature, expected)
        except (ValueError, TypeError):
            return False

    def authorized(self, headers):
        if PUBLIC_EXECUTION:
            return True
        if owner_authorized(headers.get('Authorization', ''), self.owner_hash):
            return True
        try:
            cookie = SimpleCookie(headers.get('Cookie', ''))
            return self.valid_session(cookie[OWNER_COOKIE].value)
        except (ValueError, KeyError, CookieError):
            return False

    def visitor_context(self, headers):
        capability = headers.get('X-Web-Prolog-Query-Owner')
        if capability is not None:
            if len(capability) != 64 or any(c not in '0123456789abcdef' for c in capability):
                raise ValueError('invalid_query_owner')
            return 'capability:' + capability, None
        cookies = SimpleCookie(headers.get('Cookie', ''))
        value = cookies[VISITOR_COOKIE].value if VISITOR_COOKIE in cookies else ''
        if self.valid_session(value, 'visitor'):
            return 'visitor:' + value, None
        value = self.session('visitor', 86400)
        cookie = VISITOR_COOKIE + '=' + value + '; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax' + COOKIE_SECURE
        return 'visitor:' + value, cookie

    def query_owner(self, headers):
        # Native ownership is derived here, never trusted from public identity
        # headers. A CLI capability or a browser's verified login session forms
        # its own namespace; the one shared Basic credential is one owner.
        capability = headers.get('X-Web-Prolog-Query-Owner')
        if capability is not None:
            if len(capability) != 64 or any(c not in '0123456789abcdef' for c in capability):
                raise ValueError('invalid_query_owner')
            scope = 'capability:' + capability
        else:
            cookie = SimpleCookie(headers.get('Cookie', ''))
            session = cookie[OWNER_COOKIE].value if OWNER_COOKIE in cookie else ''
            scope = 'session:' + session if self.valid_session(session) else 'basic-owner'
        return hmac.new(self.session_key, ('query-owner:' + scope).encode(), 'sha256').hexdigest()

    def query_budget(self, headers, peer, trusted_proxy=False):
        # HTTPS ingress lives on a private network and Caddy overwrites this
        # address. Direct local clients are charged to the actual socket peer.
        address = headers.get('X-Real-IP', peer) if trusted_proxy else peer
        address = str(ipaddress.ip_address(address))
        return hmac.new(self.session_key, ('query-budget:' + address).encode(), 'sha256').hexdigest()

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(15)
        return connection, address

    def process_request(self, request, address):
        if not self.capacity.acquire(blocking=False):
            try:
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n'
                                b'Retry-After: 5\r\nContent-Length: 0\r\n\r\n')
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.capacity.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.capacity.release()


class Handler(BaseHTTPRequestHandler):
    server_version = 'TrinityN6'

    def handle_one_request(self):
        # Match the GNU transport's 256 KiB envelope instead of imposing the
        # stdlib's smaller 64 KiB request-line limit on submitted source.
        try:
            self.raw_requestline = self.rfile.readline(262145)
            if len(self.raw_requestline) > 262144:
                self.requestline = self.request_version = self.command = ''
                self.send_error(414)
                return
            if not self.raw_requestline:
                self.close_connection = True
                return
            if not self.parse_request():
                return
            method = getattr(self, 'do_' + self.command, None)
            if method is None:
                self.send_error(501)
                return
            method()
            self.wfile.flush()
        except TimeoutError:
            self.close_connection = True

    def log_message(self, format, *args):
        # Goals/source and Authorization headers never enter access logs.
        pass

    def reply(self, status, body, content_type='application/json', headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Connection', 'close')
        if getattr(self, 'response_cookie', None):
            self.send_header('Set-Cookie', self.response_cookie)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        try:
            self.get()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except (OSError, http.client.HTTPException):
            self.reply(502, {'error': 'n6_upstream_unavailable'})

    def browser_boundary(self, opaque_login=False, navigation=False):
        for key in ('Host', 'Authorization', 'Origin', 'Content-Length', 'Sec-Fetch-Site', 'Cookie', 'X-Web-Prolog-Query-Owner', 'X-Real-IP'):
            if len(self.headers.get_all(key, [])) > 1:
                return False
        host = self.headers.get('Host', '').lower()
        allowed = {urlsplit(PUBLIC_URL).netloc.lower(), 'localhost:3057', '127.0.0.1:3057', 'wp_n6:3060'}
        origin = self.headers.get('Origin')
        site = self.headers.get('Sec-Fetch-Site', 'none')
        scheme = 'https' if HTTPS_OWNER and host == urlsplit(PUBLIC_URL).netloc else 'http'
        same_origin = origin is not None and origin.lower() == scheme + '://' + host
        # Some embedded browsers submit forms with an opaque Origin. Only
        # login may use this path, and it additionally requires the signed,
        # purpose-separated hidden token AND the matching HttpOnly cookie.
        opaque = opaque_login and origin == 'null' and site == 'same-origin'
        public_rpc = (PUBLIC_EXECUTION and urlsplit(self.path).path == '/call'
            and len(self.headers.get('X-Web-Prolog-Query-Owner', '')) == 64
            and all(c in '0123456789abcdef' for c in self.headers.get('X-Web-Prolog-Query-Owner', '')))
        document_navigation = (navigation and self.command == 'GET'
            and self.headers.get('Sec-Fetch-Mode') == 'navigate'
            and self.headers.get('Sec-Fetch-Dest') == 'document'
            and origin is None)
        return (host in allowed and (origin is None or same_origin or opaque or public_rpc)
                and (site in ('same-origin', 'none') or site == 'same-site' and same_origin
                     or document_navigation or public_rpc))

    def login_page(self, status=200, incorrect=False):
        token = self.server.session('login', 600)
        html = LOGIN.replace('CSRF_TOKEN', token)
        if incorrect:
            html = html.replace('<form ', '<p>Incorrect username or password.</p><form ', 1)
        return self.reply(status, html, 'text/html; charset=UTF-8', {
            'Set-Cookie': LOGIN_COOKIE + '=' + token + '; Path=/login; Max-Age=600; HttpOnly; SameSite=Strict' + COOKIE_SECURE})

    def do_POST(self):
        if PUBLIC_EXECUTION:
            return self.reply(405, {'error': 'get_required'})
        if self.path != '/login':
            return self.reply(405, {'error': 'get_required'})
        if not self.browser_boundary(opaque_login=True) or self.headers.get('Transfer-Encoding'):
            return self.reply(403, {'error': 'invalid_browser_request'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096 or self.headers.get_content_type() != 'application/x-www-form-urlencoded':
                return self.reply(400, {'error': 'invalid_login_request'})
            fields = parse_qs(self.rfile.read(length).decode(), strict_parsing=True)
            if set(fields) != {'username', 'password', 'csrf'} or any(len(v) != 1 for v in fields.values()):
                return self.reply(400, {'error': 'invalid_login_request'})
            cookie = SimpleCookie(self.headers.get('Cookie', ''))
            supplied = fields['csrf'][0]
            if (not self.server.valid_session(supplied, 'login') or LOGIN_COOKIE not in cookie
                    or not hmac.compare_digest(cookie[LOGIN_COOKIE].value, supplied)):
                return self.reply(403, {'error': 'invalid_login_token'})
            value = base64.b64encode((fields['username'][0] + ':' + fields['password'][0]).encode()).decode()
            if not owner_authorized('Basic ' + value, self.server.owner_hash):
                return self.login_page(401, incorrect=True)
            return self.reply(303, '', 'text/plain', {
                'Location': '/demonstrator',
                'Set-Cookie': OWNER_COOKIE + '=' + self.server.session()
                              + '; Path=/; Max-Age=28800; HttpOnly; SameSite=Strict' + COOKIE_SECURE})
        except (ValueError, UnicodeError, CookieError):
            return self.reply(400, {'error': 'invalid_login_request'})

    def get(self):
        path = urlsplit(self.path)
        if path.scheme or path.netloc or path.fragment or not self.path.startswith('/'):
            return self.reply(400, {'error': 'invalid_request_target'})
        if any(segment in ('.', '..') for segment in unquote(path.path).split('/')):
            return self.reply(400, {'error': 'invalid_path'})
        for key in ('Host', 'Authorization', 'Origin', 'Content-Length', 'Sec-Fetch-Site'):
            if len(self.headers.get_all(key, [])) > 1:
                return self.reply(400, {'error': 'duplicate_security_header'})
        if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Length', '0') != '0':
            return self.reply(400, {'error': 'get_body_not_supported'})
        if path.path in ('/healthz', '/readyz'):
            ok = self.server.controller.poll() is None
            return self.reply(200 if ok else 503, {'status': 'ok' if ok else 'unavailable'})
        authorized = self.server.authorized(self.headers)
        self.response_cookie = None
        self.public_identity = None
        if PUBLIC_EXECUTION and path.path not in ('/version', '/portal', '/portal/'):
            try:
                self.public_identity, self.response_cookie = self.server.visitor_context(self.headers)
            except (ValueError, CookieError):
                return self.reply(400, {'error': 'invalid_query_owner'})
        # Discovery can inspect non-sensitive metadata without a query credential.
        if path.path == '/node_info':
            return self.reply(200, dict(self_url=PUBLIC_URL, profile='isobase', auth='open' if PUBLIC_EXECUTION else 'private',
                                       self_contained=True, provides=PROVIDES, services=[],
                                       principal_id=('anon:visitor:' + hashlib.sha256(self.public_identity.encode()).hexdigest()) if PUBLIC_EXECUTION else ('owner' if authorized else 'anonymous'),
                                       principal_execution=authorized, tutorial_sections=['all']))
        if path.path == '/version':
            pins = json.loads(Path('/usr/share/doc/gprolog/runtime-pins.json').read_text())
            return self.reply(200, dict(web_prolog='gprolog-port', gprolog=pins['engine']['version']))
        if path.path in ('/portal', '/portal/'):
            return self.reply(308, '', 'text/plain', {'Location': '/demonstrator' + ('?' + path.query if path.query else '')})
        if not self.browser_boundary(navigation=path.path in ('/demonstrator', '/login', '/')):
            return self.reply(403, {'error': 'invalid_browser_request'})
        if path.path == '/login':
            if PUBLIC_EXECUTION:
                return self.reply(303, '', 'text/plain', {'Location': '/demonstrator'})
            return self.login_page()
        if not authorized:
            if path.path in ('/demonstrator', '/portal', '/'):
                return self.reply(303, '', 'text/plain', {'Location': '/login'})
            return self.reply(401, {'error': 'owner_authentication_required'}, headers={
                'WWW-Authenticate': 'Basic realm="Trinity N6 owner", charset="UTF-8"'})
        if path.path == '/':
            return self.reply(200, (ROOT / 'shared_db.pl').read_bytes(), 'text/plain; charset=UTF-8')
        if path.path == '/call':
            try:
                query_owner = (hmac.new(self.server.session_key, self.public_identity.encode(), 'sha256').hexdigest()
                               if PUBLIC_EXECUTION else self.server.query_owner(self.headers))
                query_budget = self.server.query_budget(self.headers, self.client_address[0], HTTPS_OWNER)
            except (ValueError, CookieError):
                return self.reply(400, {'error': 'invalid_query_owner'})
            # The validated outer request is translated to the native local
            # Host/Origin/auth contract. No caller header is trusted upstream.
            return self.proxy('http://127.0.0.1:8081', self.path, {
                'Host': '127.0.0.1:8081', 'Authorization': 'Bearer ' + self.server.token,
                'X-Web-Prolog-Query-Owner': query_owner,
                'X-Web-Prolog-Query-Budget': query_budget})
        asset_path = '/img/spider-agent.png' if path.path == '/favicon.ico' else self.path
        if path.path in ASSET_PATHS or path.path == '/favicon.ico' or path.path.startswith(
                ('/vendor/', '/img/', '/examples/', '/statecharts/', '/wasm/')):
            return self.proxy(ASSET_URL, asset_path, {}, path.path in ('/demonstrator', '/portal'))
        return self.reply(404, {'error': 'not_found'})

    def proxy(self, base, path, headers, bootstrap=False):
        target = urlsplit(base)
        with closing(http.client.HTTPConnection(target.hostname, target.port, timeout=30)) as connection:
            connection.request('GET', path, headers=headers)
            response = connection.getresponse()
            if bootstrap and response.status == 200:
                html = response.read().decode()
                marker = '<script src="/vendor/trinity-host.js"></script>'
                config = json.dumps(host_config()).replace('<', '\\u003c')
                html = html.replace(marker, '<script>window.WEB_PROLOG_HOST=' + config + ';</script>\n' + marker, 1)
                return self.reply(200, html, 'text/html; charset=UTF-8')
            self.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Cache-Control', 'ETag', 'Last-Modified'):
                value = response.getheader(key)
                if value is not None:
                    self.send_header(key, value)
            self.send_header('Connection', 'close')
            if getattr(self, 'response_cookie', None):
                self.send_header('Set-Cookie', self.response_cookie)
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            while chunk := response.read(65536):
                self.wfile.write(chunk)
            self.close_connection = True


def main():
    public = urlsplit(PUBLIC_URL)
    local = (public.scheme == 'http' and public.hostname in ('localhost', '127.0.0.1') and public.port == 3057
             and not (public.path or public.query or public.fragment or public.username or public.password))
    network_owner = HTTPS_OWNER and os.environ.get('N6_OWNER_NETWORK_PILOT') == 'yes'
    if not (local or network_owner):
        raise SystemExit('N6 requires localhost or the explicitly enabled owner-only HTTPS pilot')
    owner_hash = os.environ.pop('N6_OWNER_PASSWORD_HASH', '')
    fields = owner_hash.split(':')
    if not PUBLIC_EXECUTION and (len(fields) != 4 or fields[0] != 'pbkdf2_sha256' or int(fields[1]) < 200000):
        raise SystemExit('N6 requires an owner password hash; use tools/setup_n6.py')
    if os.environ.get('N6_CONTAINMENT') == 'yes':
        from n6_contained import serve
        return serve(Server, ROOT, owner_hash)
    if PUBLIC_EXECUTION:
        raise SystemExit('Public execution requires verified Linux containment')
    temporary = Path('/tmp/n6')
    temporary.mkdir(mode=0o700, exist_ok=True)
    if temporary.is_symlink():
        raise SystemExit('N6 temporary directory must not be a symlink')
    token = secrets.token_hex(32)
    token_file = temporary / 'controller.token'
    token_file.write_text(token + '\n')
    token_file.chmod(0o600)
    # Only operator-approved public peers can be called. Pins are resolved
    # once at startup and retained for this node lifetime.
    import socket
    policy = temporary / 'outbound.policy'
    entries = []
    for number in range(1, 6):
        hostname = f'n{number}.elfenbenstornet.se'
        address = socket.getaddrinfo(hostname, 443, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        entries.append(f'https {hostname} 443 {address}\n')
    policy.write_text(''.join(entries))
    policy.chmod(0o600)
    controller = subprocess.Popen([
        '/app/isobase/isobase-node', '--port', '8081', '--auth-token-file', str(token_file),
        '--shared-db', str(ROOT / 'shared_db.pl'), '--outbound-policy', str(policy),
        '--max-queries', '8', '--max-owner-queries', '4', '--max-budget-queries', '6',
        '--require-query-owner', '1', '--require-query-budget', '1',
        '--time-ms', '2000', '--idle-ms', '300000',
        '--memory-mb', '256', '--total-memory-mb', '512'],
        stdout=subprocess.PIPE, text=True)
    try:
        announcement = controller.stdout.readline()
        if not announcement or json.loads(announcement).get('port') != 8081:
            raise RuntimeError('GNU node failed to start')
        server = Server(('0.0.0.0', 3060), controller, owner_hash, token)
        stopped = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stopped.set())
        signal.signal(signal.SIGINT, lambda *_: stopped.set())
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print('Owner-only N6 presenter ready; GNU execution remains on loopback.', flush=True)
        while not stopped.wait(0.5):
            if controller.poll() is not None:
                raise RuntimeError('GNU controller exited')
        server.shutdown()
        server.server_close()
    finally:
        controller.terminate()
        try:
            controller.wait(timeout=10)
        except subprocess.TimeoutExpired:
            controller.kill()
            controller.wait()


if __name__ == '__main__':
    main()
