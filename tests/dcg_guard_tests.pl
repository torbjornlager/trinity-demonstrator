:- ['../load.pl'].
:- use_module(library(plunit)).
:- begin_tests(dcg_guards).

test(inline_terminals) :-
    control_guard:rewrite_goal(user,phrase([a,b],L),Safe),
    call(Safe), assertion(L == [a,b]).
test(variable_grammar) :-
    control_guard:rewrite_goal(user,phrase(G,L),Safe),
    G=([a],{X=b},[X]),call(Safe),assertion(L == [a,b]).
test(alternatives) :-
    control_guard:rewrite_goal(user,phrase(([a];[b]),L),Safe),
    findall(L,Safe,Answers),assertion(Answers == [[a],[b]]).
test(empty_embedded_goal) :-
    control_guard:rewrite_goal(user,phrase({},L),Safe),
    call(Safe),assertion(L == []).
test(restore_source) :-
    Original=phrase((G,{X=a},[X]),L,R),
    control_guard:rewrite_goal(user,Original,Safe),
    control_guard:restore_goal(user,Safe,Restored),
    assertion(Original == Restored),var(G),var(L),var(R).
test(unbound_grammar,[throws(error(instantiation_error,_))]) :-
    control_guard:rewrite_goal(user,phrase(_,[]),Safe),call(Safe).
:- end_tests(dcg_guards).
