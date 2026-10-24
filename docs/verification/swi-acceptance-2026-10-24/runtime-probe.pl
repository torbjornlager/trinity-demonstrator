:- module(runtime_acceptance_probe,[run/0]).
:- use_module(library(pcre)).
:- use_module(library(sgml)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/websocket)).
:- use_module(library(prolog_pack)).
run :-
 current_prolog_flag(version_data,V),current_prolog_flag(home,Home),
 absolute_file_name(library(pcre),PCRE,[file_type(prolog),access(read)]),
 absolute_file_name(library(sgml),SGML,[file_type(prolog),access(read)]),
 format('version(~q).~nhome(~q).~npcre(~q).~nsgml(~q).~n',[V,Home,PCRE,SGML]),
 sub_atom(Home,_,_,_,'/install/'),sub_atom(PCRE,_,_,_,'/install/'),sub_atom(SGML,_,_,_,'/install/'),
 re_matchsub('(?<word>.+)','räksmörgås',D,[]),get_dict(word,D,"räksmörgås"),
 setup_call_cleanup(open_string('<statechart><state id="s"/></statechart>',S),load_structure(S,[element(statechart,[],[element(state,[id=s],[])])],[dialect(xml)]),close(S)),
 (catch(use_module(library(ssl)),E,true)->format('ssl_probe(~q).~n',[E]);writeln(ssl_probe_failed)),
 writeln(installed_runtime_probe_passed).
