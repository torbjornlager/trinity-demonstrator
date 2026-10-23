from pathlib import Path
base=Path(__file__).with_name('run_checks.py').read_text()
setup=base.split("for label in ['LINT'")[0].replace("out/'results.json'", "out/'followup-results.json'")
exec(setup)
node_dir='/Users/torbjorn.lager/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin'
env['PATH']=node_dir+os.pathsep+env['PATH']
run('WASM-with-node',['bash','tools/test.sh','WASM'],source)
foreign=work/'foreign-cwd'
goal=f'''use_module(library(prolog_pack)),pack_attach('{native}',[]),use_module(library(web_prolog)),module_property(actors,file(F)),assertion(same_file(F,'{native}/prolog/web_prolog/actors.pl')),node_version:web_prolog_version(V),assertion(V=="0.2.0"),writeln(pack_attachment_verified)'''
run('pack-attachment-corrected',[exe,'-q','-g',goal,'-t','halt'],foreign)
smoke=work/'headless-smoke.pl'
smoke.write_text(f'''\n:- consult('{native}/load.pl').
:- use_module(library(socket)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(http/thread_httpd)).
probe :- module_property(node,file(F)),
    assertion(same_file(F,'{native}/prolog/web_prolog/node.pl')),
    tcp_socket(S),tcp_bind(S,Port),tcp_close_socket(S),
    setup_call_cleanup(node(Port,[profile(actor),auth(open)]),
        (format(atom(URL),'http://localhost:~w/healthz',[Port]),
         http_get(URL,Health,[json_object(dict)]),assertion(Health.status=="ok"),
         format(atom(Call),'http://localhost:~w/call?goal=true&format=json',[Port]),
         http_get(Call,Answer,[json_object(dict)]),assertion(Answer.type=="success"),
         format('headless_api(~q,~q).~n',[Health,Answer])),http_stop_server(Port,[])).
''')
run('headless-api',[exe,'-q','-s',str(smoke),'-g','probe','-t','halt'],foreign)
raise SystemExit(0 if all(r['exit_code']==0 for r in results) else 1)
