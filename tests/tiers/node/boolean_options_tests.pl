% Language Booleans are atoms; transport fields have their own decoding.
:- module(test_boolean_options, []).
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/actor_api.pl').
:- use_module('../../../prolog/web_prolog/rpc.pl', []).
:- use_module('../../../prolog/web_prolog/statechart_actor.pl').
:- use_module(library(plunit)).

boolean_goal(link,V,spawn(true,_,[link(V)])).
boolean_goal(monitor,V,spawn(true,_,[monitor(V)])).
boolean_goal(session,V,toplevel_spawn(_,[session(V)])).
boolean_goal(trace,V,statechart_spawn(_,[src_text('<invalid/>'),trace(V)])).
boolean_goal(rpc,V,rpc:rpc('http://invalid.example',true,[once(V)])).
boolean_goal(promise,V,rpc:promise('http://invalid.example',true,_,[once(V)])).

:- begin_tests(boolean_options).
test(language_substitutes_rejected,
     [forall((member(V,[1,0,-1,1.0,"true","false",'TRUE',[t,r,u,e],@(true)]),
              member(Kind,[link,monitor,session,trace,rpc,promise])))]) :-
    test_boolean_options:boolean_goal(Kind,V,Goal),
    catch(call(Goal),E,true),assertion(nonvar(E)),
    assertion((E=error(type_error(boolean,V),_);E=error(domain_error(boolean,V),_))).

test(trace_transport_decodes_text_and_json,
     [forall(member(Input-Expected,[true-true,false-false,"true"-true,"false"-false,
                                    'TRUE'-true,@(true)-true,@(false)-false]))]) :-
    node_isotope_options:parse_trace_value(Input,Trace),assertion(Trace==Expected),
    node_ws:ws_parse_enabled_atom(Input,WS),assertion(WS==Expected),
    node:parse_enabled_atom(Input,HTTP),assertion(HTTP==Expected).

test(trace_transport_rejects_numbers,
     [forall((member(V,[0,1,1.0,"bogus",bogus]),member(Module-Pred,[node_isotope_options-parse_trace_value,node_ws-ws_parse_enabled_atom,node-parse_enabled_atom])))]) :-
    Goal=..[Pred,V,_],catch(call(Module:Goal),E,true),
    assertion(nonvar(E)),assertion(E=error(domain_error(boolean,V),_)).
:- end_tests(boolean_options).
