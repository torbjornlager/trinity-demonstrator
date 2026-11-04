#!/usr/bin/env python3
"""Public N6 functional and visitor-boundary smoke checks (no credentials)."""
import argparse,json,secrets,time,urllib.request,urllib.parse,urllib.error
p=argparse.ArgumentParser();p.add_argument('--url',default='https://n6.elfenbenstornet.se');p.add_argument('--host');a=p.parse_args()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args):return None
opener=urllib.request.build_opener(NoRedirect)
def request(path,headers=None):
    h=dict(headers or {})
    if a.host:h['Host']=a.host
    try:
        r=opener.open(urllib.request.Request(a.url+path,headers=h),timeout=10)
    except urllib.error.HTTPError as e:r=e
    with r:return r.status,r.headers,r.read()
def query(goal,cap=None,**options):
    status,headers,body=request('/call?'+urllib.parse.urlencode(dict(goal=goal,format='json',**options)),{'X-Web-Prolog-Query-Owner':cap} if cap else {})
    assert status==200,(status,body)
    return json.loads(body),headers
status,headers,body=request('/node_info');info=json.loads(body)
assert status==200 and info['auth']=='open' and info['principal_execution']
cookie=headers['Set-Cookie'].split(';')[0]
assert '__Host-n6_visitor=' in cookie and 'Secure' in headers['Set-Cookie'] and 'HttpOnly' in headers['Set-Cookie']
assert json.loads(request('/node_info',{'Cookie':cookie})[2])['principal_id']==info['principal_id']
assert json.loads(request('/node_info')[2])['principal_id']!=info['principal_id']
status,headers,_=request('/portal?goal=human(X)&node=N6');assert status in (301,308) and headers['Location']=='/demonstrator?goal=human(X)&node=N6'
assert request('/demonstrator',{'Sec-Fetch-Site':'same-site','Sec-Fetch-Mode':'navigate','Sec-Fetch-Dest':'document'})[0]==200
assert request('/call?goal=true',{'Sec-Fetch-Site':'cross-site','Origin':'https://unrelated.example'})[0]==403
assert request('/call?goal=true',{'X-Web-Prolog-Query-Owner':'forged'})[0]==400
for path in ['/admin/config','/ws','/tmp/n6/controller.token']:
    assert request(path)[0] in (403,404)
cap1,cap2=secrets.token_hex(32),secrets.token_hex(32)
for cap in (cap1,cap2):
    data,_=query('member(X,[a,b])',cap,limit=1);assert data['data']==[{'X':'a'}] and data['more']
for cap in (cap1,cap2):
    data,_=query('member(X,[a,b])',cap,limit=1,offset=1);assert data['data']==[{'X':'b'}] and not data['more']
for goal,options in [('foo(X)',{'src_text':'foo(a). foo(b).'}),('human(X)',{}),('ancestor_descendant(X,Y)',{})]:
    data,_=query(goal,cap1,**options);assert data['type']=='success' and data['data'],data
data,_=query('large_source_probe',cap1,src_text='%'+'source comment '*5000+'\nlarge_source_probe.')
assert data['type']=='success',data
started=time.monotonic()
data,_=query('spin',cap1,src_text='spin:-spin.',timeout='0.1')
assert data['type']=='error' and time.monotonic()-started<5,data
assert query('true',cap1)[0]['type']=='success'
for n in range(1,6):
    data,_=query(f"rpc('https://n{n}.elfenbenstornet.se',member(X,[a,b]))",cap1)
    assert data['type']=='success' and data['data']==[{'X':'a'},{'X':'b'}],(n,data)
for dest in ['http://169.254.169.254','http://127.0.0.1:8081','https://example.com','https://n1.elfenbenstornet.se:444','https://n6.elfenbenstornet.se']:
    data,_=query(f"rpc('{dest}',true)",cap1);assert data['type']=='error',data
print('PASS public N6: canonical navigation, anonymous cookies, capability continuations, source, shared DB, N1–N5 RPC and denied egress')
