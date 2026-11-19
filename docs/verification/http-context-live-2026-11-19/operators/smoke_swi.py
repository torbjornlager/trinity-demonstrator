import json, subprocess, sys, time
from pathlib import Path
from urllib.request import urlopen
from urllib.parse import urlencode

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
CONF=Path('/Users/lager/trinity-conformance')
ROWS=[]

def record(label, **values):
    ROWS.append(dict(label=label, **values))
    (HERE/'smoke/live-results.json').write_text(json.dumps(ROWS,indent=2)+'\n')
    print(label, values, flush=True)

def command(label, args):
    with (HERE/'logs'/('smoke-'+label+'.log')).open('w') as log:
        result=subprocess.run(list(map(str,args)),cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=240)
    record(label,exit_code=result.returncode)
    if result.returncode: raise RuntimeError('Smoke failed: '+label)

def query(node, goal, **kwargs):
    q=dict(goal=goal,format='json',limit=20,**kwargs)
    with urlopen('https://'+node+'.elfenbenstornet.se/call?'+urlencode(q),timeout=10) as response:
        return json.load(response)

def run():
    command('http-visitors',['python3','tools/test_http_visitors.py','--skip-n6'])
    for node,profile in [('n1','isobase'),('n2','isotope')]:
        label=node+'-isobase-http'
        command(label,['python3',CONF/'runner/baseline.py','--manifest',CONF/'cases/isobase-http-0.1.json',
                       '--url','https://'+node+'.elfenbenstornet.se','--candidate',node,'--profile',profile,
                       '--timeout','10','--report',HERE/'smoke'/f'{label}.json'])
    nested=query('n2','mortal(X)',template='X')
    assert nested['type']=='success' and {row['X'] for row in nested['data']}=={'socrates','plato','aristotle'},nested
    record('n2-private-n4-rpc',status='pass')
    registry=query('n0','node_card(N,Status,P,A,V,T)')
    assert registry['type']=='success',registry
    up={row['N'] for row in registry['data'] if row['Status']=='up'}
    assert {'n0','n1','n2','n3','n4'}<=up,registry
    record('n0-discovery',status='pass',nodes_up=sorted(up))
    for node in ['n3','n4']:
        ws='wss://'+node+'.elfenbenstornet.se/ws'
        command(node+'-actor-core',['python3',CONF/'runner/run.py','--ws-url',ws,'--origin','https://'+node+'.elfenbenstornet.se',
                '--candidate',node,'--timeout','12','--session-interval','1.5','--report',HERE/'smoke'/f'{node}-actor-core.json'])
        for suite in ['creation-validation','receive-callback-context','links-monitors','uri-atoms','local-naming']:
            label=node+'-'+suite
            command(label,['python3',CONF/'runner/baseline.py','--manifest',CONF/'cases'/f'{suite}-0.1.json',
                    '--url',ws,'--candidate',node,'--profile','actor','--timeout','12','--session-interval','1.5',
                    '--report',HERE/'smoke'/f'{label}.json'])
        command(node+'-linda',['python3','tools/test_linda_service.py','--ws-url',ws,'--origin','https://'+node+'.elfenbenstornet.se'])
    cross_engine()
    command('n3-to-n4-actor-interop',['python3',CONF/'runner/baseline.py','--manifest',CONF/'cases/interop-actor-0.1.json',
            '--url','wss://n3.elfenbenstornet.se/ws','--peer','https://n4.elfenbenstornet.se','--candidate','n3-to-n4',
            '--profile','actor','--timeout','12','--session-interval','1.5','--report',HERE/'smoke/n3-to-n4-actor-interop.json'])

def cross_engine():
    # Exercise unchanged consumers through their private execution maps to the upgraded SWI peers.
    sys.path.insert(0,str(CONF/'runner'))
    from run import Candidate, Harness
    for node in ['n5','n7']:
        candidate=Candidate('wss://'+node+'.elfenbenstornet.se/ws','actor',15,None,
                            'https://'+node+'.elfenbenstornet.se',False,())
        with Harness(candidate) as h:
            h.spawn_shell()
            for label,goal in [
                ('n1-source', 'rpc(\'https://n1.elfenbenstornet.se\',double(21,R),[src_text("double(X,Y) :- Y is X*2.")]),R=42'),
                ('n2-n4-rpc', "findall(X,rpc('https://n2.elfenbenstornet.se',mortal(X)),Xs),sort(Xs,[aristotle,plato,socrates])")]:
                h.call(goal,'[limit(1)]')
                result=h.recv_type('success',limit=64)
                assert result.get('more') is False,result
                record(node+'-'+label,status='pass')
            h.halt()

if __name__=='__main__':run()
