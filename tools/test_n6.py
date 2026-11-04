#!/usr/bin/env python3
"""Owner-authenticated black-box checks for the localhost N6 pilot."""
import argparse
import base64
import json
import http.cookiejar
import re
from pathlib import Path
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, Request, build_opener, urlopen

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', default='http://localhost:3057')
    parser.add_argument('--credentials', type=Path, default=ROOT / '.trinity/n6-access.txt')
    parser.add_argument('--resolve-ip', help='override only the N6 DNS lookup while preserving TLS verification')
    parser.add_argument('--hub-url', default='http://localhost:3058')
    args = parser.parse_args()
    if args.url != 'https://n6.elfenbenstornet.se' and urlsplit(args.url).hostname not in ('localhost', '127.0.0.1'):
        parser.error('test target must be localhost or the approved HTTPS N6 hostname')
    if args.resolve_ip:
        import socket, ipaddress
        ipaddress.ip_address(args.resolve_ip)
        resolve = socket.getaddrinfo
        hostname = urlsplit(args.url).hostname
        socket.getaddrinfo = lambda host, *a, **k: resolve(args.resolve_ip if host == hostname else host, *a, **k)
    fields = dict(line.split(': ', 1) for line in args.credentials.read_text().splitlines() if ': ' in line)
    authorization = 'Basic ' + base64.b64encode(('owner:' + fields['Password']).encode()).decode()

    def request(path, authenticated=True, headers=None):
        values = {'Authorization': authorization} if authenticated else {}
        values.update(headers or {})
        try:
            with urlopen(Request(args.url + path, headers=values), timeout=15) as response:
                return response.status, response.headers, response.read()
        except HTTPError as response:
            return response.code, response.headers, response.read()

    def query(goal, **options):
        code, _, body = request('/call?' + urlencode(dict(goal=goal, format='json', **options)))
        assert code == 200, (code, body)
        return json.loads(body)

    def success(goal, **options):
        response = query(goal, **options)
        assert response['type'] == 'success', response
        return response

    status, _, body = request('/demonstrator', False)
    assert status == 200 and b'N6 owner login' in body and b'WEB_PROLOG_HOST' not in body
    status, headers, _ = request('/call?goal=true', False)
    assert status == 401 and headers['WWW-Authenticate'].startswith('Basic ')
    assert request('/call?goal=true', False, {'X-Web-Prolog-User': 'owner',
                                           'X-Web-Prolog-Capabilities': 'admin'})[0] == 401
    assert request('/call?goal=true', headers={'Origin': 'http://unrelated.example'})[0] == 403
    wrong_host = request('/call?goal=true', headers={'Host': 'unrelated.example'})
    assert wrong_host[0] in (403, 404, 421) or wrong_host[0] == 200 and wrong_host[2] == b''
    assert request('/call?goal=true', headers={'Sec-Fetch-Site': 'cross-site'})[0] == 403
    for path in ('/ws', '/admin/config', '/admin/tokens', '/vendor/../call?goal=true'):
        assert request(path)[0] in (400, 404), path
    print('Owner login, forged-header rejection, browser boundary and excluded APIs: passed')

    owner_cookie = '__Host-n6_owner' if args.url.startswith('https:') else 'n6_owner'
    login_cookie = '__Secure-n6_login' if args.url.startswith('https:') else 'n6_login'
    cookies = http.cookiejar.CookieJar()
    browser = build_opener(HTTPCookieProcessor(cookies))
    with browser.open(args.url + '/login', timeout=15) as response:
        csrf = re.search(r'name="csrf"[^>]*value="([^"]+)"', response.read().decode())[1]
    form = urlencode({'username': 'owner', 'password': fields['Password'], 'csrf': csrf}).encode()
    with browser.open(Request(args.url + '/login', data=form,
                              headers={'Origin': args.url}), timeout=15) as response:
        assert b'WEB_PROLOG_HOST' in response.read()
    session = next(cookie for cookie in cookies if cookie.name == owner_cookie)
    if args.url.startswith('https:'):
        assert session.secure and next(c for c in cookies if c.name == login_cookie).secure
    assert 'HttpOnly' in session._rest and session._rest['SameSite'] == 'Strict'
    with browser.open(args.url + '/call?goal=true&format=json', timeout=15) as response:
        assert json.load(response)['type'] == 'success'
    assert request('/call?goal=true', False, {'Cookie': owner_cookie + '=forged'})[0] == 401
    assert request('/call?goal=true', False, {'Cookie': f'{owner_cookie}={session.value}',
                                           'Origin': 'https://unrelated.example'})[0] == 403
    assert request('/call?goal=true', False, {'Cookie': f'{owner_cookie}={session.value}',
                                           'Origin': 'null', 'Sec-Fetch-Site': 'same-origin'})[0] == 403
    with browser.open(args.url + '/login', timeout=15) as response:
        csrf = re.search(r'name="csrf"[^>]*value="([^"]+)"', response.read().decode())[1]
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None
    login_client = build_opener(HTTPCookieProcessor(cookies), NoRedirect())
    for token, expected in [('forged', 403), (csrf, 303)]:
        data = urlencode({'username': 'owner', 'password': fields['Password'], 'csrf': token}).encode()
        attempt = Request(args.url + '/login', data=data,
                          headers={'Origin': 'null', 'Sec-Fetch-Site': 'same-origin'})
        try:
            with login_client.open(attempt, timeout=15) as response:
                assert response.status == expected
        except HTTPError as response:
            assert response.code == expected
    print('Browser login, protected session cookie, cookie tampering and cross-origin rejection: passed')

    info = json.loads(request('/node_info')[2])
    assert info['profile'] == 'isobase' and info['auth'] == 'private' and info['principal_execution']
    assert not json.loads(request('/node_info', False)[2])['principal_execution']
    assert json.loads(request('/version')[2])['gprolog'] == '1.6.0'
    source = request('/')[2]
    assert b'deployment_node(n6)' in source and b'ancestor_descendant' in source
    html = request('/demonstrator')[2]
    assert b'window.WEB_PROLOG_HOST=' in html and b'"runtime": "gprolog"' in html
    assert request('/vendor/trinity-host.js')[0] == 200
    assert request('/editor_frame?id=editor&mode=none')[0] == 200
    assert request('/isobase-profile-tutorial')[0] == 200
    assert json.loads(request('/examples_index')[2])['actors']
    print('GNU identity, ISOBASE metadata, curated shared DB and browser assets: passed')

    first = success('member(X,[a,b,c])', limit=2)
    assert first['more'] and first['data'] == [{'X': 'a'}, {'X': 'b'}], first
    last = success('member(X,[a,b,c])', offset=2, limit=2)
    assert not last['more'] and last['data'] == [{'X': 'c'}], last
    assert len(success('human(X)')['data']) == 3
    assert success('deployment_node(X)')['data'] == [{'X': 'n6'}]
    assert len(success('mortal(X)', src_text='mortal(X):-human(X).')['data']) == 3
    success('large_source_probe', src_text='%' + 'source comment ' * 5000 + '\nlarge_source_probe.')
    assert query("open('/etc/passwd',read,S)")['type'] == 'error'
    assert query("rpc('http://169.254.169.254',true)")['type'] == 'error'
    print('Paging, source transfer, shared predicates, sandbox and outbound denial: passed')

    success("rpc('https://n1.elfenbenstornet.se',human(X),[limit(1)])")
    success("promise('https://n1.elfenbenstornet.se',human(X),R),yield(R,success([_|_],_))")
    success("rpc('https://n5.elfenbenstornet.se',human(X),[limit(1)])")
    print('GNU → SWI RPC/promise/yield and GNU → Trealla RPC: passed')
    started = time.monotonic()
    timeout = query('spin', src_text='spin:-spin.', timeout='0.1')
    assert timeout['type'] == 'error' and time.monotonic() - started < 5, timeout
    success('X=after_timeout')
    print('Execution deadline and subsequent worker recovery: passed')
    for goal, expected in [('node_profile(n6,P)', 'isobase'), ('node_auth(n6,A)', 'private'),
                           ('node_status(n6,S)', 'up')]:
        with urlopen(args.hub_url + '/call?' + urlencode({'goal': goal, 'format': 'json'}), timeout=10) as response:
            result = json.load(response)
        assert result['type'] == 'success' and expected in str(result['data']), result
    print('Discovery Hub harvests N6 profile, private access and live status: passed')


if __name__ == '__main__':
    main()
