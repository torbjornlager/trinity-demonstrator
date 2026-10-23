#!/usr/bin/env python3
"""Rehearse native/asset separation without moving the checkout or live nodes.

Requires a fresh --work-dir; writes evidence to --report-dir and uses the named SWI.
Tests T0/T2, native and external integration selections of T1/T3/T4, legacy
colocated-path compatibility, partition coverage and the ordinary full T4.
No engine installation, git mutation, deployment or live-node operation.
"""
from pathlib import Path
import argparse,hashlib,json,os,shutil,signal,subprocess,time

ROOT=Path(__file__).resolve().parents[1]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def partition_audit_goal(path):
    # Compare loaded declaration IDs with the actual union of selector outputs.
    # This checks exhaustive, disjoint coverage without inspecting test bodies.
    return ("use_module(library(http/json)),tier_test_units(U),"
        "findall(A-N,(member(A,U),plunit:current_test(A,N,_,_,_)),All),"
        "findall(A-N,(member(C,[native,integration,legacy_layout]),"
        "test_partition:partition_test_specs(U,C,P),member(A:Ns,P),member(N,Ns)),Covered),"
        "msort(All,Expected),msort(Covered,Actual),assertion(Expected==Actual),"
        "findall(_{unit:A,test:N,class:C},(member(A,U),plunit:current_test(A,N,_,_,_),test_partition:test_class(A,N,C)),Rows),"
        "findall(_{class:C,spec:S,count:Count},(member(C,[native,integration,legacy_layout]),"
        "test_partition:partition_test_specs(U,C,P),findall(N,(member(_:Ns,P),member(N,Ns)),Keys),"
        "length(Keys,Count),term_string(P,S)),Sets),"
        "setup_call_cleanup(open("+repr(str(path))+",write,F),"
        "json_write_dict(F,_{exhaustive_disjoint:true,tests:Rows,selections:Sets},[width(0)]),close(F))")

def headless_package_goal(native,smoke):
    # A globally installed pack must not accidentally satisfy the loader probe.
    checks=[]
    for index,(module,relative) in enumerate([
        ('node','prolog/web_prolog/node.pl'),
        ('actors','prolog/web_prolog/actors.pl'),
        ('isolation','prolog/web_prolog/isolation.pl'),
        ('sxml_schema','prolog/web_prolog/wasm/sxml_schema.pl')]):
        checks.append(f"module_property({module},file(F{index})),assertion(same_file(F{index},{str(native/relative)!r}))")
    return ','.join(checks)+f",consult({str(smoke)!r}),probe"

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swipl',required=True,type=Path)
    parser.add_argument('--work-dir',required=True,type=Path)
    parser.add_argument('--report-dir',required=True,type=Path)
    args=parser.parse_args();exe=args.swipl.resolve();work=args.work_dir.resolve();out=args.report_dir.resolve()
    if work.exists():raise SystemExit('Use a fresh work directory; existing snapshots are preserved.')
    if not exe.is_file():raise SystemExit('SWI executable does not exist')
    out.mkdir(parents=True,exist_ok=True);work.mkdir(parents=True)
    native=work/'native';assets=work/'demonstrator-assets';foreign=work/'foreign-cwd'
    native.mkdir();assets.mkdir();foreign.mkdir()
    manifest=[]
    def copy(relative,destination,role):
        src=ROOT/relative;dst=destination/relative
        if src.is_dir():
            files=sorted(p for p in src.rglob('*') if p.is_file() and p.name!='.DS_Store' and '__pycache__' not in p.parts)
            for p in files:copy(str(p.relative_to(ROOT)),destination,role)
        else:
            dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
            manifest.append(dict(tree=destination.name,path=relative,role=role,sha256=sha(dst)))
    for name in ['pack.pl','load.pl','LICENSE','README.md','prolog/web_prolog.pl','tests/tiers','tests/test_statecharts']:
        copy(name,native,'native package or native test support')
    for file in sorted((ROOT/'prolog/web_prolog').iterdir()):
        if file.is_file() and file.suffix in ['.pl','.dtd','.md']:copy(str(file.relative_to(ROOT)),native,'native runtime')
    copy('prolog/web_prolog/wasm/sxml_schema.pl',native,'shared SXML schema required by native parser')
    copy('tools/test.sh',native,'test driver')
    for name in ['web','img','examples','prolog/web_prolog/wasm']:
        copy(name,assets,'demonstrator/browser assets')
    for name in ['Deployment/shared_db_n3.pl','Deployment/shared_db_n5.pl']:
        copy(name,assets,'existing integration-test data, not deployment startup')
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    assert not any((native/name).exists() for name in ['web','img','examples','.git'])
    assert sorted(p.name for p in (native/'prolog/web_prolog/wasm').iterdir())==['sxml_schema.pl']
    assert not any(p.is_symlink() for p in native.rglob('*'))
    provenance=dict(source=str(ROOT),revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),native=str(native),assets=str(assets),engine=str(exe),engine_sha256=sha(exe),manifest_sha256=sha(out/'manifest.json'))
    (out/'layout.json').write_text(json.dumps(provenance,indent=2)+'\n')
    env=dict(os.environ)
    for key in ['WP_ASSET_ROOT','WP_WASM_SOURCE_DIR','WP_LIFECYCLE_DIAGNOSTICS','WP_LIFECYCLE_LOG','WP_SPAWN_TEST_DIAGNOSTICS','WP_SPAWN_TEST_LOG']:env.pop(key,None)
    results=[]
    def run(label,file,goal,cwd=native,external=False,timeout=180,absolute=False):
        cmd=[str(exe),'-q','-s',str(file if absolute else cwd/file),'-g',goal,'-t','halt']
        child_env=dict(env)
        if external:child_env.update(WP_ASSET_ROOT=str(assets),WP_WASM_SOURCE_DIR=str(assets/'prolog/web_prolog/wasm'))
        t=time.monotonic();print('START',label,flush=True)
        with (out/(label+'.log')).open('w') as log:
            proc=subprocess.Popen(cmd,cwd=cwd,env=child_env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:rc=proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait();rc='external_timeout'
        results.append(dict(label=label,command=cmd,cwd=str(cwd),external_assets=external,exit_code=rc,seconds=round(time.monotonic()-t,3)))
        (out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('DONE',label,rc,flush=True)
        return rc
    # Standalone package load and same-origin HTTP API, from a foreign cwd.
    smoke=work/'headless-smoke.pl'
    smoke.write_text(""":- use_module(library(socket)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(http/thread_httpd)).
probe :- tcp_socket(S),tcp_bind(S,Port),tcp_close_socket(S),
    setup_call_cleanup(node(Port,[profile(actor),auth(open)]),
        (format(atom(URL),'http://localhost:~w/healthz',[Port]),
         http_get(URL,Health,[json_object(dict)]),assertion(Health.status==\"ok\"),
         format(atom(Call),'http://localhost:~w/call?goal=true&format=json',[Port]),
         http_get(Call,Answer,[json_object(dict)]),assertion(Answer.type==\"success\"),
         format('headless_api(~q,~q).~n',[Health,Answer])),http_stop_server(Port,[])).
""")
    smoke_goal=headless_package_goal(native,smoke)
    run('headless-api',native/'load.pl',smoke_goal,cwd=foreign,absolute=True)
    for tier in [0,2]:run(f'T{tier}-native',Path(f'tests/tiers/t{tier}_'+('actors' if tier==0 else 'toplevel')+'.pl'),'run_tier')
    for tier,file in [(1,'t1_isolation.pl'),(3,'t3_behaviours.pl'),(4,'t4_node.pl')]:
        rel=Path('tests/tiers')/file
        # Audit actual loaded declarations and all three selector sets.
        audit=out/f'T{tier}-partition.json'
        goal=partition_audit_goal(audit)
        run(f'T{tier}-partition-audit',rel,goal)
        run(f'T{tier}-native',rel,'run_native')
        run(f'T{tier}-integration',rel,'run_integration',external=True)
    # These assertions intentionally require the original colocated files.
    run('T4-legacy-layout',Path('tests/tiers/t4_node.pl'),'run_legacy_layout',cwd=ROOT)
    run('T4-original-full',Path('tests/tiers/t4_node.pl'),'run_tier',cwd=ROOT)
    # No copied native source differs from its original; no assets appeared.
    assert all(sha(native/m['path'])==sha(ROOT/m['path']) for m in manifest if m['tree']=='native')
    assert not any((native/name).exists() for name in ['web','img','examples'])
    (out/'final-layout.json').write_text(json.dumps(dict(native_sources_unchanged=True,no_frontend_directories=True,native_wasm_files=sorted(p.name for p in (native/'prolog/web_prolog/wasm').iterdir())),indent=2)+'\n')
    return 0 if all(r['exit_code']==0 for r in results) else 1

if __name__=='__main__':raise SystemExit(main())
