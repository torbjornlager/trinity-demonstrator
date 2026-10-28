#!/usr/bin/env python3
"""Build a static demonstrator tree. No node, upload, credentials or live files are changed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import quote, urlsplit
from setup_swi import check, DEFAULT

ROOT=Path(__file__).resolve().parents[1]
PAGES=[p.name for p in sorted((ROOT/'web').glob('*.html')) if p.name not in ('admin.html','discovery-hub.html')]
ROUTES={name[:-5]:name for name in PAGES}
ROUTES.update(portal='index.html',demonstrator='index.html',manual='manual.html',editor_frame='editor_frame.html')

def prefix_path(value):
    if not re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*',value) or any(x in ('.','..') for x in value.split('/')):
        raise ValueError('prefix must be / or a path such as /releases/preview/')
    return value

def node_url(value):
    if value is None:return None
    u=urlsplit(value)
    if u.scheme not in ('http','https') or not u.netloc or u.username or u.password or u.query or u.fragment:
        raise ValueError('node URL must use HTTP(S), without credentials, query or fragment')
    return value.rstrip('/')+'/'

def rewrite_assets(text,prefix):
    # Only known UI routes and file trees move. Protocol paths (/call, /ws,
    # /admin etc.) remain execution-service paths. This also preserves examples
    # of protocol URLs in tutorial prose.
    pattern=r'''(?P<quote>["'])(?P<path>/(?:vendor/|img/|examples/|wasm/)[^"']*|/(?:'''+ '|'.join(re.escape(x) for x in sorted(ROUTES,key=len,reverse=True))+r'''|swi_wasm_actor_worker\.js|swipl-bundle\.js|favicon\.ico)(?=[?\#"']))'''
    def replace(m):
        path=m['path'];stem=re.split(r'[?#]',path,1)[0]
        target=ROUTES.get(stem[1:],stem[1:])
        if stem=='/favicon.ico':target='img/spider-agent.png'
        if stem=='/img/spider-prolog-1024-dark-transparent.png':target='img/spider-prolog-1024-inverted.png'
        return m['quote']+prefix+target+path[len(stem):]
    return re.sub(pattern,replace,text)

def page(text,prefix,config):
    text=rewrite_assets(text,prefix)
    text=text.replace('normalized.pathname = '+json.dumps(prefix+'index.html'), 'normalized.pathname = \"/demonstrator\"')
    bootstrap='<script>window.WEB_PROLOG_HOST='+json.dumps(config,separators=(',',':')).replace('<','\\u003c')+';</script>\n'
    # All documents share one asset origin so their editor/tutorial bridges keep
    # the existing same-origin checks. The remote node may have another origin.
    if 'src="'+prefix+'vendor/trinity-host.js"' not in text:
        bootstrap+='<script src="'+prefix+'vendor/trinity-host.js"></script>\n'
    text=text.replace('<head>','<head>\n'+bootstrap,1)
    def scripts(m):
        script=m[0]
        if 'src=' in script.split('>',1)[0]:return script
        # Live raw-API labs in tutorial/example documents use the configured
        # service too. Do not rewrite displayed <pre> code samples.
        script=script.replace('return protocol + "//" + window.location.host + "/ws";', 'return TrinityHost.websocket();')
        script=script.replace('new WebSocket(scheme+"//"+location.host+"/ws")','new WebSocket(TrinityHost.websocket())')
        script=script.replace('new URL(path, window.location.origin)','new URL(TrinityHost.endpoint(path))')
        script=script.replace('fetch("/node_info",', 'fetch(TrinityHost.endpoint("/node_info"),')
        script=script.replace('        fetch(TrinityHost.endpoint("/node_info"),','        if (!TrinityHost.nodeBase) return;\n        fetch(TrinityHost.endpoint("/node_info"),')
        return script
    return re.sub(r'<script\b[^>]*>[\s\S]*?</script>',scripts,text)

def inventory(directory):
    return {p.relative_to(directory).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file() and p!=directory/'manifest.json'}

def verify(directory):
    directory=Path(directory).resolve();m=json.loads((directory/'manifest.json').read_text())
    for p in directory.rglob('*'):
        if p.is_symlink():raise ValueError('static distribution must not contain symlinks')
    if inventory(directory)!=m['files']:raise ValueError('static distribution file inventory or hashes differ')
    return m

def build(output,prefix='/',node=None,allow_dirty=False):
    prefix=prefix_path(prefix);node=node_url(node)
    revision=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
    dirty=bool(subprocess.check_output(['git','-C',str(ROOT),'status','--porcelain'],text=True).strip())
    if dirty and not allow_dirty:raise ValueError('release builds require clean source; --allow-dirty marks a development preview')
    state=check(Path(os.environ.get('WP_NATIVE_STATE',str(DEFAULT))))
    output=Path(output).resolve();output.mkdir(parents=True,exist_ok=False)
    config=dict(mode='static',assetBase=prefix,nodeUrl=node)
    for name in PAGES:
        text=page((ROOT/'web'/name).read_text(),prefix,config)
        (output/name).write_text(text)
    shutil.copy2(output/'demonstrator.html',output/'index.html')
    for name,source in [('vendor',ROOT/'web/vendor'),('img',ROOT/'img'),('examples',ROOT/'examples')]:
        shutil.copytree(source,output/name,ignore=lambda directory,names:[n for n in names if n.startswith('.') or n=='__pycache__'])
    for name in ['swi_wasm_actor_worker.js','swipl-bundle.js']:
        shutil.copy2(ROOT/'web'/name,output/name)
    shutil.copytree(Path(state['wasm_root']),output/'wasm')
    # The assembly manifest contains local source paths and is not a browser input.
    (output/'wasm/manifest.json').unlink()
    for css in (output/'vendor').rglob('*.css'):
        text=css.read_text()
        text=re.sub(r'url\(\s*([\"\']?)/(vendor/|img/)',
                    lambda m:'url('+m[1]+prefix+m[2],text)
        css.write_text(text)
    for p in (output/'examples/APIs').glob('*.html'):p.write_text(page(p.read_text(),prefix,config))
    index={}
    for kind,folder in [('actors','actors'),('statecharts','statecharts')]:
        index[kind]=[dict(name=p.name,url=prefix+'examples/'+folder+'/'+quote(p.name),kind='prolog' if kind=='actors' else 'statechart')
                     for p in sorted((output/'examples'/folder).iterdir()) if p.is_file() and not p.name.startswith('.') and not (kind=='statecharts' and p.name=='game.xml')]
    index['swi_wasm']=[]
    (output/'examples_index.json').write_text(json.dumps(index,indent=2)+'\n')
    shutil.copy2(ROOT/'LICENSE',output/'LICENSE')
    license_dir=output/'licenses';license_dir.mkdir()
    browser=Path(state['browser_package'])
    shutil.copy2(browser/'LICENSE',license_dir/'swi-wasm-node.txt')
    shutil.copy2(browser/'third_party/LICENSE.txt',license_dir/'swi-prolog.txt')
    m=dict(format=1,name='trinity-demonstrator',source=dict(revision=revision,dirty=dirty),host=config,
           browser=json.loads((ROOT/'dependencies/swi-wasm-node.json').read_text()),
           native_schema=json.loads((ROOT/'dependencies/swi-prolog-node.json').read_text()),files=inventory(output))
    (output/'manifest.json').write_text(json.dumps(m,indent=2,sort_keys=True)+'\n')
    verify(output)
    return m

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path);p.add_argument('--prefix',default='/');p.add_argument('--node-url');p.add_argument('--allow-dirty',action='store_true');p.add_argument('--verify',type=Path);a=p.parse_args()
    try:
        if a.verify:m=verify(a.verify)
        elif a.output:m=build(a.output,a.prefix,a.node_url,a.allow_dirty)
        else:p.error('--output or --verify is required')
        print(json.dumps(dict(source=m['source'],host=m['host'],files=len(m['files'])),indent=2))
    except (OSError,ValueError,KeyError) as e:p.exit(2,'static demonstrator: '+str(e)+'\n')
if __name__=='__main__':main()
