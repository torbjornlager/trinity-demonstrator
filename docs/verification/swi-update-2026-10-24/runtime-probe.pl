:- module(updated_runtime_probe,[run/0]).
:- use_module(library(pcre)).
:- use_module(library(sgml)).
:- use_module(library(ssl)).
:- use_module(library(crypto)).
:- use_module(library(http/thread_httpd)).
run :-
 current_prolog_flag(version_data,swi(10,1,18,[])),
 current_prolog_flag(home,Home),
 Expected='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-http-shutdown-2026-10-24/install/lib/swipl',
 same_file(Home,Expected),
 absolute_file_name(library(pcre),PCRE,[file_type(prolog),access(read)]),
 atom_concat(Expected,'/library/ext/pcre/pcre.pl',ExpectedPCRE),same_file(PCRE,ExpectedPCRE),
 absolute_file_name(library(sgml),SGML,[file_type(prolog),access(read)]),
 atom_concat(Expected,'/library/ext/sgml/sgml.pl',ExpectedSGML),same_file(SGML,ExpectedSGML),
 re_matchsub('(?<word>.+)','räksmörgås',D,[]),get_dict(word,D,"räksmörgås"),
 setup_call_cleanup(open_string('<statechart><state id="s"/></statechart>',S),
  load_structure(S,[element(statechart,[],[element(state,[id=s],[])])],[dialect(xml)]),close(S)),
 ssl_context(client,_,[]),crypto_data_hash('acceptance',Hash,[algorithm(sha256)]),
 Hash == c1514c6cdad166c18aa557dc1d780ba84c0e32df7633235385023eb429377e74,
 format('version(swi(10,1,18,[])).~nhome(~q).~npcre_unicode_ok.~nxml_ok.~nssl_context_ok.~ncrypto_ok.~n',[Home]).
