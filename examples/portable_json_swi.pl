:- module(portable_json_swi, [
    portable_json_chars/2, portable_json_value/1, portable_json_object/1,
    portable_json_get/3, portable_json_from_dict/2,
    portable_json_from_classic/2, portable_json_to_classic/2
]).
:- include('portable_json.pl').

% Host-only adapters. Native strings, dicts and the distinct atom '[]' never
% cross a node boundary; every text value/key becomes string(Codes).
portable_json_from_dict(Native, JSON) :- pj_from_native(dict, Native, JSON).
portable_json_from_classic(Native, JSON) :- pj_from_native(classic, Native, JSON).
pj_from_native(Mode, Native, JSON) :-
    ( acyclic_term(Native), pj_native_value(Mode,Native,JSON), portable_json_value(JSON) -> true
    ; pj_conversion_context(Mode,Context),
      throw(error(domain_error(json_native_value,Native),Context)) ).
pj_conversion_context(dict,portable_json_from_dict/2).
pj_conversion_context(classic,portable_json_from_classic/2).
pj_native_value(_, Native, _) :- var(Native), !, fail.
pj_native_value(_, Native, json(Pairs)) :- is_dict(Native), !,
    dict_pairs(Native,_,NativePairs), pj_dict_pairs(NativePairs,Pairs).
pj_native_value(classic,json(Pairs),json(Portable)) :- !,pj_classic_pairs(Pairs,Portable).
pj_native_value(_, '@'(B), '@'(B)) :- nonvar(B), memberchk(B,[true,false,null]), !.
pj_native_value(dict,B,'@'(B)) :- memberchk(B,[true,false,null]), !.
pj_native_value(_, Native, string(Codes)) :- string(Native), !, string_codes(Native,Codes).
pj_native_value(_, Native, string(Codes)) :- atom(Native), !, atom_codes(Native,Codes).
pj_native_value(_, Native, Native) :- number(Native), !.
pj_native_value(Mode,Values,Portable) :- is_list(Values),pj_native_values(Mode,Values,Portable).
pj_native_values(_,[],[]).
pj_native_values(M,[V|Vs],[P|Ps]) :- pj_native_value(M,V,P),pj_native_values(M,Vs,Ps).
pj_dict_pairs([],[]).
pj_dict_pairs([K-V|Pairs],[string(Codes)=P|Ps]) :-
    pj_native_key(K,Codes),pj_native_value(dict,V,P),pj_dict_pairs(Pairs,Ps).
pj_native_key(Key,Codes) :- atom(Key), !, atom_codes(Key,Codes).
pj_native_key(Key,Codes) :- integer(Key), number_codes(Key,Codes).
pj_classic_pairs([],[]).
pj_classic_pairs([K=V|Pairs],[string(Codes)=P|Ps]) :-
    atom(K),atom_codes(K,Codes),pj_native_value(classic,V,P),pj_classic_pairs(Pairs,Ps).

portable_json_to_classic(JSON, Classic) :-
    portable_json_value(JSON), pj_classic_value(JSON,Classic).
pj_classic_value(json(Pairs),json(Classic)) :- !,pj_to_classic_pairs(Pairs,Classic).
pj_classic_value(string(Codes),Atom) :- !,atom_codes(Atom,Codes).
pj_classic_value('@'(B),'@'(B)) :- !.
pj_classic_value(N,N) :- number(N),!.
pj_classic_value([],[]).
pj_classic_value([V|Vs],[C|Cs]) :- pj_classic_value(V,C),pj_classic_value(Vs,Cs).
pj_to_classic_pairs([],[]).
pj_to_classic_pairs([string(Codes)=V|Pairs],[K=C|Cs]) :-
    atom_codes(K,Codes),pj_classic_value(V,C),pj_to_classic_pairs(Pairs,Cs).
