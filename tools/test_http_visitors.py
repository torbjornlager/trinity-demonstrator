#!/usr/bin/env python3
"""Low-volume ownership checks against the deployed N1–N4 and private or public N6.

Aggressive admission/forgery tests live in disposable upstream fixtures. This
check uses fresh cookie jars and synthetic queries, and keeps N6 credentials out
of arguments, logs and public peers.
"""
import argparse
import base64
import http.cookiejar
import json
from pathlib import Path
import secrets
import subprocess
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPCookieProcessor, urlopen

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-n6',action='store_true')
    parser.add_argument('--n6-auth', choices=['public', 'private'], default='public',
                        help='expected deployed N6 access policy (default: public)')
    args=parser.parse_args()
    for number in range(1,5):
        base=f'https://n{number}.elfenbenstornet.se'
        clients=[]
        for _ in range(2):
            jar=http.cookiejar.CookieJar()
            clients.append((build_opener(HTTPCookieProcessor(jar)),jar))
        goal="get_time(T),member(X,[a,b,c,d]),Probe='"+secrets.token_hex(8)+"'"
        def page(client,offset):
            with client.open(base+'/call?'+urlencode(dict(goal=goal,offset=offset,limit=1,format='json')),timeout=12) as response:
                result=json.load(response)
            assert result['type']=='success',f'N{number}: query did not succeed'
            return result['data'][0]
        a=page(clients[0][0],0)
        b=page(clients[1][0],1)
        following=page(clients[0][0],1)
        assert a['T']==following['T']!=b['T'],f'N{number}: ownership failed'
        assert following['X']=='b'
        for client,jar in clients:
            cookie=next(c for c in jar if c.name=='__Host-wp_visitor')
            assert cookie.secure and not cookie.domain_specified and cookie.path=='/'
            assert 'httponly' in {k.lower() for k in cookie._rest}
            with client.open(base+'/node_info',timeout=12) as response:info=json.load(response)
            assert info['principal_execution'] and info['principal_id'].startswith('anon:visitor:')
        # Finish both queries rather than leaving test continuations resident.
        page(clients[0][0],2);page(clients[0][0],3)
        page(clients[1][0],2);page(clients[1][0],3)
        preflight=Request(base+'/call',method='OPTIONS',headers={
            'Origin':'https://n4.elfenbenstornet.se',
            'Access-Control-Request-Method':'GET',
            'Access-Control-Request-Headers':'X-Web-Prolog-Query-Owner'})
        with urlopen(preflight,timeout=10) as response:
            assert 'x-web-prolog-query-owner' in response.headers['Access-Control-Allow-Headers'].lower()
        print(f'N{number}: independent live paging, Secure host-only cookies and browser RPC preflight passed')
    if args.skip_n6:return
    fields=dict(line.split(': ',1) for line in (ROOT/'.trinity/n6-access.txt').read_text().splitlines() if ': ' in line)
    authorization='Basic '+base64.b64encode(('owner:'+fields['Password']).encode()).decode()
    owners=[secrets.token_hex(32),secrets.token_hex(32)]
    base='https://n6.elfenbenstornet.se'
    goal="between(1,5,X),Probe='"+secrets.token_hex(8)+"'"
    def native_children():
        code="""from pathlib import Path
import json
rows={}
for p in Path('/proc').iterdir():
 if p.name.isdigit():
  try:
   text=(p/'stat').read_text();rows[int(p.name)]=(int(text[text.rindex(')')+2:].split()[1]),(p/'comm').read_text().strip())
  except (FileNotFoundError,ProcessLookupError):pass
controllers={pid for pid,(_,name) in rows.items() if name=='isobase-node'}
print(json.dumps(sorted(pid for pid,(parent,_) in rows.items() if parent in controllers)))
"""
        return set(json.loads(subprocess.check_output(['docker','exec','trinity-n6-host-wp_n6-1','python3','-c',code],text=True)))
    def page(owner,offset,limit=1):
        headers={'Authorization':authorization,'X-Web-Prolog-Query-Owner':owner}
        with urlopen(Request(base+'/call?'+urlencode(dict(goal=goal,offset=offset,limit=limit,format='json')),headers=headers),timeout=12) as response:
            result=json.load(response)
        assert result['type']=='success','N6: ownership probe did not succeed'
    before=native_children();page(owners[0],0);a=native_children()-before
    assert len(a)==1,'N6: concurrent activity made the worker probe inconclusive'
    page(owners[1],1);both=native_children();b=both-before-a
    assert len(b)==1 and a<=both,'N6: separate owner did not retain an independent worker'
    page(owners[0],1)
    assert a|b<=native_children(),'N6: owner did not resume its retained worker'
    page(owners[0],2,100);page(owners[1],2,100)
    assert not (a|b)&native_children(),'N6: completed probe workers were retained'
    with urlopen(base+'/node_info',timeout=10) as response:info=json.load(response)
    if args.n6_auth == 'private':
        assert info['auth']=='private' and not info['principal_execution']
    else:
        assert info['auth']=='open' and info['principal_execution']
    print(f'N6: independent authenticated query capabilities and expected {args.n6_auth} access policy passed')


if __name__=='__main__':main()
