:- module(test_public_goal_guard, []).

:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/public_goal_guard.pl').
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module(library(apply)).
:- use_module(library(settings)).
:- use_module(library(plunit)).

:- meta_predicate guarded(0), meta_zero(0), meta_data(:), meta_large(8), meta_exist(^).

guarded(Goal) :-
    strip_module(Goal, Module, PlainGoal),
    setup_call_cleanup(
        (setting(node:sandbox, Saved), set_setting(node:sandbox, blacklist)),
        with_public_execution_profile(actor,
            (rewrite_goal_if_needed(Module, PlainGoal, Safe), call(Module:Safe))),
        set_setting(node:sandbox, Saved)).

meta_zero(Goal) :- call(Goal).
meta_data(Data) :- Data = _:_ .
meta_large(_).
meta_exist(_).
plus_one(X,Y) :- Y is X+1.
add(X,A,B) :- B is A+X.
choice(X) :- member(X,[a,b]).

:- begin_tests(public_goal_guard).

test(maplist_bindings, true(Y == [2,3])) :- guarded(maplist(plus_one,[1,2],Y)).
test(maplist_sharing) :- guarded(maplist(=(X),[a,Y])), assertion(X==a), assertion(Y==a).
test(maplist_backtracking, true(Answers == [[a,a],[a,b],[b,a],[b,b]])) :-
    findall(X,guarded((X=[_,_],maplist(choice,X))),Answers).
test(maplist_failure, [fail]) :- guarded(maplist(=(a),[a,b])).
test(foldl_context, true(Total==6)) :- guarded(foldl(add,[1,2,3],0,Total)).
test(explicit_caller_module, true(Y==[2,3])) :-
    context_module(Module),
    guarded(maplist(Module:plus_one,[1,2],Y)).
test(include_context, true(Selected==[a,a])) :- guarded(include(=(a),[a,b,a],Selected)).
test(callback_exception, [throws(callback_error)]) :- guarded(maplist(throw,[callback_error])).
test(runtime_closure, true(X==[a,a])) :- guarded((X=[_,_], P = =(a), maplist(P,X))).
test(empty_list_does_not_invoke_unbound_closure) :-
    guarded(maplist(P,[])), assertion(var(P)).
test(unbound_invoked_closure, [throws(error(instantiation_error,_))]) :-
    guarded(maplist(_P,[a])).
test(forbidden_callback, [throws(error(permission_error(call,sandboxed,_),_))]) :-
    guarded(maplist(nb_getval, [guard_probe], [_])).
test(nested_forbidden_callback, [throws(error(permission_error(call,sandboxed,_),_))]) :-
    guarded(maplist(maplist(nb_getval(guard_probe)), [[_]])).
test(qualified_forbidden_callback, [throws(error(permission_error(call,sandboxed,_),_))]) :-
    guarded(maplist(system:nb_getval(guard_probe), [_])).
test(zero_argument_meta_callback, [throws(error(permission_error(call,sandboxed,_),_))]) :-
    guarded(meta_zero(nb_getval(guard_probe,_))).
test(module_sensitive_data) :-
    public_goal_guard:rewrite_goal(test_public_goal_guard, meta_data(foo), Rewritten),
    assertion(Rewritten == meta_data(foo)).
test(unsupported_closure, [throws(error(domain_error(sandbox_closure_arity,8),_))]) :-
    guarded(meta_large(foo)).
test(unsupported_existential_meta, [throws(error(domain_error(sandbox_meta_argument,^),_))]) :-
    guarded(meta_exist(true)).
test(dcg_terminals, true(L==[a,b])) :- guarded(phrase([a,b],L)).
test(dcg_variable_and_braces, true(L==[a,b])) :-
    guarded((G=([a],{X=b},[X]),phrase(G,L))).
test(dcg_forbidden, [throws(error(permission_error(call,sandboxed,_),_))]) :-
    guarded(phrase({nb_getval(guard_probe,_)},[])).
test(restore_closure_identity) :-
    Original=maplist(=(X),[Y]),
    public_goal_guard:rewrite_goal(test_public_goal_guard,Original,Safe),
    public_goal_guard:restore_goal(test_public_goal_guard,Safe,Restored),
    assertion(Restored==Original), assertion(var(X)), assertion(var(Y)).
test(restore_zero_meta) :-
    Original=meta_zero(member(X,[a,b])),
    public_goal_guard:rewrite_goal(test_public_goal_guard,Original,Safe),
    public_goal_guard:restore_goal(test_public_goal_guard,Safe,Restored),
    assertion(Restored==Original), assertion(var(X)).
test(restore_dcg_identity) :-
    Original=phrase((G,{X=a},[X]),L,R),
    public_goal_guard:rewrite_goal(test_public_goal_guard,Original,Safe),
    public_goal_guard:restore_goal(test_public_goal_guard,Safe,Restored),
    assertion(Restored==Original), assertion(var(G)), assertion(var(L)), assertion(var(R)).
test(restore_unguarded_variables,
     [forall(member(Name,[maplist,meta_zero,phrase]))]) :-
    (Name==maplist -> Original=maplist(P,[]) ;
     Name==phrase -> Original=phrase(P,[]) ; Original=meta_zero(P)),
    public_goal_guard:restore_goal(test_public_goal_guard,Original,Restored),
    assertion(Restored==Original), assertion(var(P)).

:- end_tests(public_goal_guard).
