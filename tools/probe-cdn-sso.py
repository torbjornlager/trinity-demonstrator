#!/usr/bin/env python3
"""Read-only HTTPS/CORS readiness probe. Never imports browser cookies or follows SSO redirects."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def https_base(value, origin=False):
    u=urllib.parse.urlsplit(value)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment:
        raise ValueError('Use HTTPS URLs without credentials, query or fragment')
    if origin and u.path not in ('','/'):
        raise ValueError('UI origin must not include a path')
    return urllib.parse.urlunsplit((u.scheme,u.netloc,'' if origin else u.path.rstrip('/')+'/', '', ''))

def summarize_headers(headers):
    out={key:headers.get(name) for key,name in [
        ('allow_origin','Access-Control-Allow-Origin'),('allow_credentials','Access-Control-Allow-Credentials'),
        ('allow_methods','Access-Control-Allow-Methods'),('allow_headers','Access-Control-Allow-Headers'),
        ('vary','Vary'),('cache_control','Cache-Control'),('content_type','Content-Type')]}
    location=headers.get('Location')
    if location:
        u=urllib.parse.urlsplit(location)
        out['redirect']=dict(scheme=u.scheme,host=u.hostname,path=u.path) # Never query, userinfo or fragment.
    # Intentionally do not record Set-Cookie, identity headers or response bodies.
    return out

def probe(node,origin,timeout=6):
    opener=urllib.request.build_opener(NoRedirect)
    requests=[('signed_out_metadata','node_info','GET',{'Origin':origin}),
              ('version','version','GET',{'Origin':origin}),
              ('json_preflight','toplevel_spawn','OPTIONS',{'Origin':origin,'Access-Control-Request-Method':'POST','Access-Control-Request-Headers':'Content-Type'}),
              ('unlisted_origin','node_info','GET',{'Origin':'https://not-approved.invalid'})]
    rows=[]
    for name,path,method,headers in requests:
        url=urllib.parse.urljoin(node,path);row=dict(name=name,path='/'+path,method=method)
        try:
            try:response=opener.open(urllib.request.Request(url,method=method,headers=headers),timeout=timeout)
            except urllib.error.HTTPError as e:response=e
            with response:
                row.update(https_response_received=True,status=response.status,headers=summarize_headers(response.headers))
        except (OSError,urllib.error.URLError) as e:
            reason=getattr(e,'reason',e)
            row.update(https_response_received=False,error=type(reason).__name__,errno=getattr(reason,'errno',None))
        rows.append(row)
    def grant(row):
        h=row.get('headers',{})
        return h.get('allow_origin')==origin and str(h.get('allow_credentials','')).lower()=='true'
    metadata,version,preflight,denied=rows
    checks=dict(https_reachable=all(r['https_response_received'] for r in rows),
                signed_out_api_401=metadata.get('status')==401 and grant(metadata),
                readable_version=version.get('status') in (200,401) and grant(version),
                credentialed_json_preflight=preflight.get('status')==204 and grant(preflight) and 'POST' in str(preflight.get('headers',{}).get('allow_methods','')).upper() and 'content-type' in str(preflight.get('headers',{}).get('allow_headers','')).lower(),
                unlisted_origin_not_granted=denied.get('https_response_received',False) and not grant(denied) and denied.get('headers',{}).get('allow_origin') not in ('*','https://not-approved.invalid'))
    # A transport failure leaves CORS/auth checks unmeasured, not failed.
    for key,row in [('signed_out_api_401',metadata),('readable_version',version),('credentialed_json_preflight',preflight),('unlisted_origin_not_granted',denied)]:
        if not row['https_response_received']:checks[key]=None
    return dict(time=datetime.now(timezone.utc).isoformat(),node=node,ui_origin=origin,
                credentials_used=False,checks=checks,requests=rows,
                browser_sso_verified=False,ready_for_browser_verification=all(checks.values()))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--node-url',required=True);p.add_argument('--ui-origin',required=True);p.add_argument('--timeout',type=float,default=6);p.add_argument('--output',type=Path);a=p.parse_args()
    try:
        node=https_base(a.node_url);origin=https_base(a.ui_origin,True)
        if a.timeout<=0 or a.timeout>15:raise ValueError('timeout must be between 0 and 15 seconds')
        if a.output and a.output.exists():raise ValueError('output must be fresh')
        result=probe(node,origin,a.timeout);text=json.dumps(result,indent=2)+'\n'
        if a.output:a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(text)
        print(text,end='')
        return 0 if result['ready_for_browser_verification'] else 1
    except (OSError,ValueError) as e:p.exit(2,str(e)+'\n')
if __name__=='__main__':raise SystemExit(main())
