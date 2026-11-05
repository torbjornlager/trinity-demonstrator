"""Bounded egress for contained GNU workers; no ambient proxy or credentials."""
from collections import defaultdict
from http.server import BaseHTTPRequestHandler
import http.client
import hashlib
import hmac
import io
import ipaddress
import os
from pathlib import Path
import socket
import socketserver
import ssl
import stat
import struct
import threading
import time
from urllib.parse import parse_qs, quote, urlsplit

MAX_BODY = 1024 * 1024


HTTP_TOKEN = frozenset("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
PROXY_HEADERS = frozenset(('x-forwarded-for', 'x-real-ip', 'x-web-prolog-user',
    'x-web-prolog-principal', 'x-authenticated-user', 'x-web-prolog-capabilities',
    'x-web-prolog-caps', 'x-web-prolog-internal-proxy', 'x-web-prolog-query-budget'))


def request_headers(text, purpose, owner):
    """Validate worker fields independently of the language-side validator."""
    if len(text.encode('utf-8')) > 16384 or (text and purpose != 'rpc'):
        raise ValueError('invalid_request_headers')
    headers = {}
    if text and not text.endswith('\n'):
        raise ValueError('invalid_request_headers')
    for line in text.split('\n')[:-1]:
        if '\r' in line or ': ' not in line:
            raise ValueError('invalid_request_headers')
        name, value = line.split(': ', 1)
        if not name or any(c not in HTTP_TOKEN for c in name):
            raise ValueError('invalid_request_headers')
        if any((ord(c) < 32 and c != '\t') or ord(c) == 127 for c in value):
            raise ValueError('invalid_request_headers')
        key = name.lower()
        if key == 'host' or key.replace('_', '-') in PROXY_HEADERS:
            raise ValueError('reserved_proxy_header')
        if key == 'x-web-prolog-query-owner' and value != owner:
            raise ValueError('query_owner_mismatch')
        # http.client accepts bytes; use UTF-8 consistently with the clients.
        headers.setdefault(key, value.encode('utf-8'))
    return headers


class DeadlineReader(io.RawIOBase):
    def __init__(self, connection, deadline):
        self.connection, self.deadline = connection, deadline

    def readable(self):
        return True

    def readinto(self, buffer):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('egress deadline')
        self.connection.settimeout(remaining)
        return self.connection.recv_into(buffer)


class DeadlineSocket:
    def __init__(self, connection, deadline):
        self.connection, self.deadline = connection, deadline

    def __getattr__(self, name):
        return getattr(self.connection, name)

    def sendall(self, data):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError('egress deadline')
        self.connection.settimeout(remaining)
        self.connection.sendall(data)

    def makefile(self, mode):
        if mode != 'rb':
            raise ValueError('read-only response stream required')
        return io.BufferedReader(DeadlineReader(self.connection, self.deadline))


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self, hostname, address, timeout, context):
        super().__init__(hostname, 443, timeout=timeout, context=context)
        self.address, self.deadline = address, time.monotonic() + timeout

    def connect(self):
        raw = socket.create_connection((self.address, 443), self.timeout)
        try:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('egress deadline')
            raw.settimeout(remaining)
            secure = self._context.wrap_socket(raw, server_hostname=self.host)
            self.sock = DeadlineSocket(secure, self.deadline)
        except BaseException:
            raw.close()
            raise


class LocalRPCConnection(http.client.HTTPConnection):
    """One fixed controller listener, with the same absolute transport deadline."""
    def __init__(self, port, timeout):
        super().__init__('127.0.0.1', port, timeout=timeout)
        self.deadline = time.monotonic() + timeout

    def connect(self):
        raw = socket.create_connection(('127.0.0.1', self.port), self.timeout)
        self.sock = DeadlineSocket(raw, self.deadline)


class Broker(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, path, peers, leases, local_rpc=None):
        self.local_rpc = local_rpc
        self.peers, self.leases = dict(peers), Path(leases)
        self.context = ssl.create_default_context()
        self.lock = threading.Lock()
        self.active = defaultdict(int)
        self.total = 0
        self.window = -1
        self.counts = {}
        super().__init__(str(path), BrokerHandler)
        if not str(path).startswith('\0'):
            os.chmod(path, 0o666)

    def lease(self, uid):
        fd = os.open(self.leases / str(uid), os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_size != 130:
                raise ValueError('invalid_lease')
            values = os.read(fd, 131).decode('ascii').splitlines()
            if (len(values) != 2 or any(len(v) != 64 or any(c not in '0123456789abcdef' for c in v) for v in values)):
                raise ValueError('invalid_lease')
            return tuple(values)
        finally:
            os.close(fd)

    def group(self, uid):
        return self.lease(uid)[0]

    def process_request(self, connection, address):
        pid, uid, gid = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        try:
            if not 20000 <= uid <= 60000:
                raise ValueError('invalid_worker')
            group = self.group(uid)
        except (OSError, ValueError, UnicodeError):
            connection.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            self.shutdown_request(connection)
            return
        with self.lock:
            window = int(time.monotonic() // 60)
            if window != self.window:
                self.window, self.counts = window, {}
            keys = [('uid', uid), ('group', group), ('node', 0)]
            limits = [240, 1200, 4800]
            busy = self.total >= 128 or self.active.get(uid, 0) >= 16 or len(self.counts) > 8192
            busy |= any(self.counts.get(key, 0) >= limit for key, limit in zip(keys, limits))
            if not busy:
                for key in keys:
                    self.counts[key] = self.counts.get(key, 0) + 1
                self.total += 1
                self.active[uid] += 1
        if busy:
            connection.sendall(b'HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            self.shutdown_request(connection)
            return
        connection.settimeout(3)
        try:
            super().process_request(connection, (pid, uid, gid))
        except BaseException:
            with self.lock:
                self.total -= 1
                self.active[uid] -= 1
            raise

    def process_request_thread(self, connection, address):
        try:
            super().process_request_thread(connection, address)
        finally:
            with self.lock:
                self.total -= 1
                self.active[address[1]] -= 1
                if not self.active[address[1]]:
                    del self.active[address[1]]


class BrokerHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body=b''):
        self.send_response(code)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        try:
            if self.path != '/fetch' or self.headers.get('Transfer-Encoding'):
                return self.reply(400)
            for key in ('Content-Length', 'Content-Type', 'Host'):
                if len(self.headers.get_all(key, [])) != 1:
                    return self.reply(400)
            size = int(self.headers['Content-Length'])
            if not 0 < size <= MAX_BODY or self.headers.get_content_type() != 'application/x-www-form-urlencoded':
                return self.reply(400)
            raw = self.rfile.read(size)
            if len(raw) != size:
                return self.reply(400)
            fields = parse_qs(raw.decode('utf-8'), strict_parsing=True, errors='strict',
                              max_num_fields=5, keep_blank_values=True)
            required = {'url', 'purpose', 'query_owner', 'timeout_ms'}
            if set(fields) not in (required, required | {'headers'}) or any(len(v) != 1 for v in fields.values()):
                return self.reply(400)
            url, purpose, owner = (fields[k][0] for k in ('url', 'purpose', 'query_owner'))
            if len(url.encode()) > 262144 or any(ord(c) <= 32 or ord(c) == 127 for c in url):
                return self.reply(403)
            target = urlsplit(url)
            # localhost is a language node designator. This reserved route can
            # reach only /call on the configured controller, never arbitrary
            # loopback resources, source URLs or administration endpoints.
            local_rpc = getattr(self.server, 'local_rpc', None)
            local = (local_rpc is not None and purpose == 'rpc'
                     and target.scheme == 'http' and target.netloc == 'localhost'
                     and target.path == '/call' and not target.fragment)
            if (not local and (purpose not in ('rpc', 'source') or target.scheme != 'https'
                    or target.hostname not in self.server.peers or target.port not in (None, 443)
                    or target.username is not None or target.password is not None or target.fragment)):
                return self.reply(403)
            if owner and (len(owner) != 64 or any(c not in '0123456789abcdef' for c in owner)):
                return self.reply(400)
            timeout = min(2.0, max(.01, int(fields['timeout_ms'][0]) / 1000))
            path = quote(target.path or '/', safe="/%:@!$&'()*+,;=-._~")
            if target.query:
                path += '?' + quote(target.query, safe="=&%+/:?@!$'()*;,-._~")
            headers = {'connection': 'close', 'accept': 'text/plain'}
            headers.update(request_headers(fields.get('headers', [''])[0], purpose, owner))
            if owner and purpose == 'rpc':
                headers['x-web-prolog-query-owner'] = owner
            if local:
                if not owner:
                    return self.reply(403)
                # Credentials remain in the broker. Bind delegated execution to
                # the authenticated worker's lease budget, never supplied headers.
                group, context = self.server.lease(self.client_address[1])
                port, token = local_rpc
                # A worker-supplied nonce cannot address a different client's
                # cached continuation, including clients sharing an IP budget.
                headers['x-web-prolog-query-owner'] = hmac.new(
                    token.encode(), ('local-rpc:' + context + ':' + owner).encode(),
                    hashlib.sha256).hexdigest()
                headers['authorization'] = 'Bearer ' + token
                headers['x-web-prolog-query-budget'] = group
                connection = LocalRPCConnection(port, timeout)
            else:
                peer = self.server.peers[target.hostname]
                ipaddress.ip_address(peer)
                connection = PinnedHTTPS(target.hostname, peer, timeout, self.server.context)
            try:
                connection.request('GET', path, headers=headers)
                response = connection.getresponse()
                if response.status != 200:
                    return self.reply(403 if 300 <= response.status < 400 else 502)
                body = response.read(MAX_BODY + 1)
                if len(body) > MAX_BODY or b'\0' in body:
                    return self.reply(502)
                body.decode('utf-8')
            finally:
                connection.close()
            self.reply(200, body)
        except (TimeoutError, socket.timeout):
            self.reply(504)
        except (ValueError, UnicodeError):
            self.reply(400)
        except (OSError, http.client.HTTPException):
            try:
                self.reply(502)
            except OSError:
                pass
