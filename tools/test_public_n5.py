#!/usr/bin/env python3
"""Exercise public N5 admission on a disposable loopback-published test node.

This test deliberately saturates connections and fills the Linda space. Never
point it at the live service. Normal tutorial/Linda tests should run first.
"""
import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='http://127.0.0.1:13060')
    parser.add_argument('--conformance-root', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'trinity-conformance')
    args = parser.parse_args()
    parsed = urlsplit(args.base_url)
    if parsed.scheme != 'http' or parsed.hostname not in {'127.0.0.1', 'localhost', '::1'}:
        parser.error('saturation tests require a disposable loopback HTTP endpoint')
    base = args.base_url.rstrip('/')
    ws_url = 'ws://' + parsed.netloc + '/ws'
    origin = 'https://n5.elfenbenstornet.se'
    sys.path.insert(0, str(args.conformance_root / 'runner'))
    from run import Candidate, Harness, WebSocket

    def request(path, ip='192.0.2.200', extra=None):
        headers = {'X-Real-IP': ip, **(extra or {})}
        try:
            with urlopen(Request(base + path, headers=headers), timeout=15) as response:
                return response.status, response.headers, response.read()
        except HTTPError as response:
            return response.code, response.headers, response.read()

    forged = {key: 'admin' for key in [
        'X-Web-Prolog-User', 'X-Web-Prolog-Principal', 'X-Authenticated-User',
        'X-Web-Prolog-Capabilities', 'X-Web-Prolog-Caps', 'X-Web-Prolog-Internal-Proxy']}
    code, _, body = request('/node_info', extra=forged)
    info = json.loads(body)
    assert code == 200 and info['auth'] == 'open' and info['principal_id'] == 'anonymous', info
    for path in ['/admin/runtime', '/admin/tokens', '/admin/maintenance']:
        assert request(path, extra=forged)[0] == 404, path
    for goal in ["open('/etc/passwd',read,S)", "shell(true)", "getenv('WP_ADMIN_TOKEN',V)"]:
        code, _, body = request('/call?' + urlencode({'goal': goal, 'format': 'json'}))
        assert b'permission_error' in body, (goal, code, body)
    code, _, body = request('/')
    assert code == 200 and b'linda_out' in body and b'service(linda' in body
    code, _, _ = request('/ws', extra={
        'Origin': 'https://unrelated.example', 'Upgrade': 'websocket',
        'Connection': 'Upgrade', 'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='})
    assert code == 403, code
    print('Anonymous execution, forged identity stripping, sandbox, admin exclusion and shared DB: passed')

    candidate = Candidate(ws_url, 'actor', 15, None, origin, False,
                          ('X-Real-IP: 192.0.2.201',))
    with Harness(candidate) as established:
        established.spawn_shell()
        # Guard against accidentally deploying the previously suggested
        # 10-second execution budget or a short proxy response timeout.
        established.call('sleep(11),X=long_query_completed', '[limit(1)]')
        result = established.recv_type('success', limit=64)
        assert 'long_query_completed' in str(result), result
        print('A query longer than 10 seconds still completes: passed')
        with ExitStack() as connections:
            sockets = []
            for n in range(31):
                # One IP has 16 slots; use two IPs to exercise the global cap.
                ip = f'192.0.2.{1 + n // 16}'
                ws = WebSocket(ws_url, 10, origin=origin, extra_headers=(f'X-Real-IP: {ip}',))
                connections.callback(ws.close)
                sockets.append(ws)
                if n == 15:
                    code, headers, body = request('/healthz', ip='192.0.2.1')
                    assert code == 429 and headers['Retry-After'] == '5' and b'busy' in body
            code, headers, body = request('/healthz', ip='192.0.2.100')
            assert code == 429 and headers['Retry-After'] == '5' and b'busy' in body
            established.call('X=still_running', '[limit(1)]')
            result = established.recv_type('success', limit=64)
            assert 'still_running' in str(result), result
            print('16 connections/IP and 32 globally; established query survives saturation: passed')
        established.halt()
    deadline = time.monotonic() + 10
    while request('/healthz')[0] != 200:
        if time.monotonic() > deadline:
            raise AssertionError('connection capacity was not reclaimed')
        time.sleep(0.05)
    print('Closing sessions reclaims connection capacity: passed')

    with Harness(candidate) as harness:
        harness.spawn_shell()

        def success(goal):
            harness.call(goal, '[limit(1)]')
            result = harness.recv_type('success', limit=64)
            assert result.get('more') is False, result

        # Rejection must leave the service alive and all stored data intact.
        success('forall(between(1,512,N),linda_out(public_capacity_test(N)))')
        success('catch(linda_out(public_capacity_test(513)),E,true),'
                'E=linda_error(tuple_space_full)')
        success('linda_rd(public_capacity_test(1)),linda_inp(public_capacity_test(1))')
        success('linda_out(public_capacity_test(513))')
        success('forall(between(2,513,N),linda_inp(public_capacity_test(N)))')
        success('length(T,4097),catch(linda_out(T),E,true),E=linda_error(tuple_too_large)')
        success('linda_out(after_capacity_test),linda_inp(after_capacity_test)')
        harness.halt()
    print('Linda tuple and term bounds, recovery and preserved data: passed')


if __name__ == '__main__':
    main()
