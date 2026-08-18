:- module(control_guard, [
    rewrite_goal/3,          % +Module, +Goal0, -Goal
    restore_goal/3,          % +Module, +Goal0, -Goal
    rewrite_source_text/3,   % +Module, +Source0, -Source
    rewrite_asserted_clause/3,% +Module, +Clause0, -Clause
    reserved_control/1,      % +Exception
    rethrow_reserved/1       % +Exception
]).

/** <module> Untrappable Web Prolog control transfers (layer 1)

Web Prolog uses Prolog exceptions for two runtime control transfers that are
not application exceptions:

  - an actor exit ultimately raises SWI-Prolog's `unwind(abort)`; and
  - PTCP abort and wall-time expiry raise reserved control atoms.

Native `catch/3` can intercept all three.  This module rewrites the Web Prolog
`catch/3` surface so cleanup still runs while application recovery is skipped
for a reserved control transfer.  Ordinary exceptions retain native catch
semantics, including catcher unification and recovery in the caller's module.

The rewriter also mediates `call/1-8` and dynamic assertion.  Consequently a
catch assembled at runtime, or asserted as part of a new clause, receives the
same protection as a catch present in loaded source.
*/

:- use_module(library(lists)).

%!  reserved_control(+Exception) is semidet.
%
%   True only for runtime control transfers which application recovery must
%   not consume.  SWI-Prolog permits catch/3 recovery to run for
%   `unwind(abort)`, but still unwinds the query afterwards; treating that
%   value as ordinary recovery would therefore be both misleading and able
%   to delay actor teardown indefinitely.

reserved_control('$abort_goal').
reserved_control('$ptcp_time_limit').
reserved_control(unwind(abort)).

rethrow_reserved(Error) :-
    (   reserved_control(Error)
    ->  throw(Error)
    ;   true
    ).


%!  rewrite_goal(+Module, +Goal0, -Goal) is det.
%
%   Rewrite catch, computed-call, and dynamic-clause boundaries recursively.

rewrite_goal(Module, Goal0, Goal) :-
    rewrite_goal_(Module, Goal0, Goal),
    !.
rewrite_goal(_, Goal, Goal).

rewrite_goal_(Module, Var, control_guard:'$call'(Module, Var)) :-
    var(Var).
rewrite_goal_(Module, (A0, B0), (A, B)) :-
    rewrite_goal(Module, A0, A),
    rewrite_goal(Module, B0, B).
rewrite_goal_(Module, (A0 ; B0), (A ; B)) :-
    rewrite_goal(Module, A0, A),
    rewrite_goal(Module, B0, B).
rewrite_goal_(Module, (A0 -> B0), (A -> B)) :-
    rewrite_goal(Module, A0, A),
    rewrite_goal(Module, B0, B).
rewrite_goal_(Module, (A0 *-> B0), (A *-> B)) :-
    rewrite_goal(Module, A0, A),
    rewrite_goal(Module, B0, B).
rewrite_goal_(_Module, QualifiedModule:Goal0, QualifiedModule:Goal) :-
    atom(QualifiedModule),
    rewrite_goal(QualifiedModule, Goal0, Goal).
rewrite_goal_(Module, catch(Goal0, Catcher, Recover0),
              control_guard:'$catch'(Module, Goal, Catcher, Recover)) :-
    rewrite_goal(Module, Goal0, Goal),
    rewrite_goal(Module, Recover0, Recover).
rewrite_goal_(Module, setup_call_cleanup(Setup0, Goal0, Cleanup0),
              setup_call_cleanup(Setup, Goal, Cleanup)) :-
    rewrite_goal(Module, Setup0, Setup),
    rewrite_goal(Module, Goal0, Goal),
    rewrite_goal(Module, Cleanup0, Cleanup).
rewrite_goal_(Module, setup_call_catcher_cleanup(Setup0, Goal0, Catcher, Cleanup0),
              setup_call_catcher_cleanup(Setup, Goal, Catcher, Cleanup)) :-
    rewrite_goal(Module, Setup0, Setup),
    rewrite_goal(Module, Goal0, Goal),
    rewrite_goal(Module, Cleanup0, Cleanup).
rewrite_goal_(Module, call_cleanup(Goal0, Cleanup0),
              call_cleanup(Goal, Cleanup)) :-
    rewrite_goal(Module, Goal0, Goal),
    rewrite_goal(Module, Cleanup0, Cleanup).
rewrite_goal_(Module, Vars^Goal0, Vars^Goal) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, \+ Goal0, \+ Goal) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, once(Goal0), once(Goal)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, ignore(Goal0), ignore(Goal)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, time(Goal0), time(Goal)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, forall(Generate0, Test0), forall(Generate, Test)) :-
    rewrite_goal(Module, Generate0, Generate),
    rewrite_goal(Module, Test0, Test).
rewrite_goal_(Module, receive(Clauses0),
              control_guard:'$receive'(Module, Clauses0)).
rewrite_goal_(Module, receive(Clauses0, Options0),
              control_guard:'$receive'(Module, Clauses0, Options0)).
rewrite_goal_(Module, call(Goal0), control_guard:'$call'(Module, Goal0)).
rewrite_goal_(Module, call(Goal0, A1),
              control_guard:'$call'(Module, Goal0, A1)).
rewrite_goal_(Module, call(Goal0, A1, A2),
              control_guard:'$call'(Module, Goal0, A1, A2)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3),
              control_guard:'$call'(Module, Goal0, A1, A2, A3)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4),
              control_guard:'$call'(Module, Goal0, A1, A2, A3, A4)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5),
              control_guard:'$call'(Module, Goal0, A1, A2, A3, A4, A5)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5, A6),
              control_guard:'$call'(Module, Goal0, A1, A2, A3, A4, A5, A6)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5, A6, A7),
              control_guard:'$call'(Module, Goal0, A1, A2, A3, A4, A5, A6, A7)).
rewrite_goal_(Module, findall(Template, Goal0, Bag),
              findall(Template, Goal, Bag)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, findnsols(Count, Template, Goal0, Bag),
              findnsols(Count, Template, Goal, Bag)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, findnsols(Count, Template, Goal0, Bag, Tail),
              findnsols(Count, Template, Goal, Bag, Tail)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, setof(Template, Goal0, Set),
              setof(Template, Goal, Set)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, bagof(Template, Goal0, Bag),
              bagof(Template, Goal, Bag)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, aggregate(Spec, Goal0, Result),
              aggregate(Spec, Goal, Result)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, aggregate(Spec, Template, Goal0, Result),
              aggregate(Spec, Template, Goal, Result)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, aggregate_all(Spec, Goal0, Result),
              aggregate_all(Spec, Goal, Result)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, aggregate_all(Spec, Template, Goal0, Result),
              aggregate_all(Spec, Template, Goal, Result)) :-
    rewrite_goal(Module, Goal0, Goal).
rewrite_goal_(Module, assert(Clause0),
              control_guard:'$assert'(Module, Clause0)).
rewrite_goal_(Module, assert(Clause0, Ref),
              control_guard:'$assert'(Module, Clause0, Ref)).
rewrite_goal_(Module, asserta(Clause0),
              control_guard:'$asserta'(Module, Clause0)).
rewrite_goal_(Module, asserta(Clause0, Ref),
              control_guard:'$asserta'(Module, Clause0, Ref)).
rewrite_goal_(Module, assertz(Clause0),
              control_guard:'$assertz'(Module, Clause0)).
rewrite_goal_(Module, assertz(Clause0, Ref),
              control_guard:'$assertz'(Module, Clause0, Ref)).
rewrite_goal_(Module, Goal0, Goal) :-
    callable(Goal0),
    functor(Goal0, Name, Arity),
    functor(Skeleton, Name, Arity),
    predicate_property(Module:Skeleton, meta_predicate(MetaSpec)),
    Goal0 =.. [Name|Args0],
    MetaSpec =.. [_|Modes],
    rewrite_meta_arguments(Modes, Module, Args0, Args),
    Goal =.. [Name|Args].


%  Protect closures passed through any loaded meta-predicate, not only the
%  built-ins listed above.  A positive integer in a meta declaration denotes
%  a closure that receives that many additional arguments.  Prefixing it with
%  '$call'(Module, Closure) preserves that arity while ensuring the fully
%  applied goal is rewritten at invocation time.  The // mode is the DCG
%  equivalent and receives two additional list arguments.

rewrite_meta_arguments([], _, [], []).
rewrite_meta_arguments([Mode|Modes], Module, [Arg0|Args0], [Arg|Args]) :-
    rewrite_meta_argument(Mode, Module, Arg0, Arg),
    rewrite_meta_arguments(Modes, Module, Args0, Args).

rewrite_meta_argument(0, Module, Goal0, Goal) :-
    !,
    rewrite_goal(Module, Goal0, Goal).
rewrite_meta_argument(Extra, Module, Closure,
                      control_guard:'$call'(Module, Closure)) :-
    integer(Extra),
    Extra > 0,
    !.
rewrite_meta_argument(//, Module, Closure,
                      control_guard:'$call'(Module, Closure)) :-
    !.
rewrite_meta_argument(_, _, Arg, Arg).


%!  restore_goal(+Module, +Goal0, -Goal) is det.
%
%   Reconstruct the user-level goal represented by a compiled, guarded goal.
%   This is the inverse boundary used by src_predicates/1: copied predicates
%   must be validated and rewritten afresh for their destination module.

restore_goal(Module, Goal0, Goal) :-
    restore_goal_(Module, Goal0, Goal),
    !.
restore_goal(_, Goal, Goal).

restore_goal_(Module, (A0, B0), (A, B)) :-
    restore_goal(Module, A0, A),
    restore_goal(Module, B0, B).
restore_goal_(Module, (A0 ; B0), (A ; B)) :-
    restore_goal(Module, A0, A),
    restore_goal(Module, B0, B).
restore_goal_(Module, (A0 -> B0), (A -> B)) :-
    restore_goal(Module, A0, A),
    restore_goal(Module, B0, B).
restore_goal_(Module, (A0 *-> B0), (A *-> B)) :-
    restore_goal(Module, A0, A),
    restore_goal(Module, B0, B).
restore_goal_(Module,
              control_guard:'$catch'(_StoredModule, Goal0, Catcher, Recover0),
              catch(Goal, Catcher, Recover)) :-
    restore_goal(Module, Goal0, Goal),
    restore_goal(Module, Recover0, Recover).
restore_goal_(Module, control_guard:'$receive'(_StoredModule, Clauses0),
              receive(Clauses)) :-
    restore_receive_clauses(Module, Clauses0, Clauses).
restore_goal_(Module,
              control_guard:'$receive'(_StoredModule, Clauses0, Options0),
              receive(Clauses, Options)) :-
    restore_receive_clauses(Module, Clauses0, Clauses),
    restore_receive_options(Module, Options0, Options).
restore_goal_(Module, Guarded, Goal) :-
    restore_call_goal(Module, Guarded, Goal).
restore_goal_(Module, Guarded, Goal) :-
    restore_assert_goal(Module, Guarded, Goal).
restore_goal_(_Module, QualifiedModule:Goal0, QualifiedModule:Goal) :-
    atom(QualifiedModule),
    restore_goal(QualifiedModule, Goal0, Goal).
restore_goal_(Module, catch(Goal0, Catcher, Recover0),
              catch(Goal, Catcher, Recover)) :-
    restore_goal(Module, Goal0, Goal),
    restore_goal(Module, Recover0, Recover).
restore_goal_(Module, setup_call_cleanup(Setup0, Goal0, Cleanup0),
              setup_call_cleanup(Setup, Goal, Cleanup)) :-
    restore_goal(Module, Setup0, Setup),
    restore_goal(Module, Goal0, Goal),
    restore_goal(Module, Cleanup0, Cleanup).
restore_goal_(Module, setup_call_catcher_cleanup(Setup0, Goal0, Catcher, Cleanup0),
              setup_call_catcher_cleanup(Setup, Goal, Catcher, Cleanup)) :-
    restore_goal(Module, Setup0, Setup),
    restore_goal(Module, Goal0, Goal),
    restore_goal(Module, Cleanup0, Cleanup).
restore_goal_(Module, call_cleanup(Goal0, Cleanup0),
              call_cleanup(Goal, Cleanup)) :-
    restore_goal(Module, Goal0, Goal),
    restore_goal(Module, Cleanup0, Cleanup).
restore_goal_(Module, Vars^Goal0, Vars^Goal) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, \+ Goal0, \+ Goal) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, once(Goal0), once(Goal)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, ignore(Goal0), ignore(Goal)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, time(Goal0), time(Goal)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, forall(Generate0, Test0), forall(Generate, Test)) :-
    restore_goal(Module, Generate0, Generate),
    restore_goal(Module, Test0, Test).
restore_goal_(Module, findall(Template, Goal0, Bag),
              findall(Template, Goal, Bag)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, findnsols(Count, Template, Goal0, Bag),
              findnsols(Count, Template, Goal, Bag)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, findnsols(Count, Template, Goal0, Bag, Tail),
              findnsols(Count, Template, Goal, Bag, Tail)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, setof(Template, Goal0, Set),
              setof(Template, Goal, Set)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, bagof(Template, Goal0, Bag),
              bagof(Template, Goal, Bag)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, aggregate(Spec, Goal0, Result),
              aggregate(Spec, Goal, Result)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, aggregate(Spec, Template, Goal0, Result),
              aggregate(Spec, Template, Goal, Result)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, aggregate_all(Spec, Goal0, Result),
              aggregate_all(Spec, Goal, Result)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, aggregate_all(Spec, Template, Goal0, Result),
              aggregate_all(Spec, Template, Goal, Result)) :-
    restore_goal(Module, Goal0, Goal).
restore_goal_(Module, Goal0, Goal) :-
    callable(Goal0),
    functor(Goal0, Name, Arity),
    functor(Skeleton, Name, Arity),
    predicate_property(Module:Skeleton, meta_predicate(MetaSpec)),
    Goal0 =.. [Name|Args0],
    MetaSpec =.. [_|Modes],
    restore_meta_arguments(Modes, Module, Args0, Args),
    Goal =.. [Name|Args].

restore_call_goal(Module, Guarded, Goal) :-
    Guarded = control_guard:Call,
    Call =.. ['$call', _StoredModule, Closure|ExtraArgs],
    restore_goal(Module, Closure, RestoredClosure),
    Goal =.. [call, RestoredClosure|ExtraArgs].

restore_assert_goal(Module, Guarded, Goal) :-
    Guarded = control_guard:Call,
    Call =.. [GuardName, _StoredModule, Clause0|Rest],
    control_assert_name(GuardName, Name),
    restore_asserted_clause_goal(Module, Clause0, Clause),
    Goal =.. [Name, Clause|Rest].

control_assert_name('$assert', assert).
control_assert_name('$asserta', asserta).
control_assert_name('$assertz', assertz).

restore_asserted_clause_goal(Module, (Head :- Body0), (Head :- Body)) :-
    !,
    restore_goal(Module, Body0, Body).
restore_asserted_clause_goal(_, Clause, Clause).

restore_meta_arguments([], _, [], []).
restore_meta_arguments([Mode|Modes], Module, [Arg0|Args0], [Arg|Args]) :-
    restore_meta_argument(Mode, Module, Arg0, Arg),
    restore_meta_arguments(Modes, Module, Args0, Args).

restore_meta_argument(0, Module, Goal0, Goal) :-
    !,
    restore_goal(Module, Goal0, Goal).
restore_meta_argument(Extra, _Module,
                      control_guard:'$call'(_StoredModule, Closure), Closure) :-
    (   integer(Extra), Extra > 0
    ;   Extra == (//)
    ),
    !.
restore_meta_argument(_, _, Arg, Arg).

restore_receive_clauses(_, Var, Var) :-
    var(Var),
    !.
restore_receive_clauses(Module, (Clause0 ; Clauses0),
                        (Clause ; Clauses)) :-
    !,
    restore_receive_clauses(Module, Clause0, Clause),
    restore_receive_clauses(Module, Clauses0, Clauses).
restore_receive_clauses(Module, (Head0 -> Body0), (Head -> Body)) :-
    !,
    restore_receive_head(Module, Head0, Head),
    restore_goal(Module, Body0, Body).
restore_receive_clauses(_, Clauses, Clauses).

restore_receive_head(_, Head, Head) :-
    var(Head),
    !.
restore_receive_head(Module, if(Pattern, Guard0), if(Pattern, Guard)) :-
    !,
    restore_goal(Module, Guard0, Guard).
restore_receive_head(_, Head, Head).

restore_receive_options(_, Var, Var) :-
    var(Var),
    !.
restore_receive_options(Module, Options0, Options) :-
    is_list(Options0),
    !,
    maplist(restore_receive_option(Module), Options0, Options).
restore_receive_options(_, Options, Options).

restore_receive_option(Module, on_timeout(Goal0), on_timeout(Goal)) :-
    !,
    restore_goal(Module, Goal0, Goal).
restore_receive_option(_, Option, Option).


%!  '$catch'(+Module, +Goal, +Catcher, +Recover) is nondet.
%
%   Native catch with a reserved-control filter in its recovery boundary.

'$catch'(Module, Goal, Catcher, Recover) :-
    catch(runtime_call(Module, Goal),
          Error,
          recover_or_rethrow(Module, Error, Catcher, Recover)).

recover_or_rethrow(_, Error, _, _) :-
    reserved_control(Error),
    !,
    throw(Error).
recover_or_rethrow(Module, Error, Catcher, Recover) :-
    (   Error = Catcher
    ->  runtime_call(Module, Recover)
    ;   throw(Error)
    ).


'$call'(Module, Goal0) :-
    runtime_execute(Module, Goal0).
'$call'(Module, Closure0, A1) :-
    runtime_execute_closure(Module, Closure0, [A1]).
'$call'(Module, Closure0, A1, A2) :-
    runtime_execute_closure(Module, Closure0, [A1, A2]).
'$call'(Module, Closure0, A1, A2, A3) :-
    runtime_execute_closure(Module, Closure0, [A1, A2, A3]).
'$call'(Module, Closure0, A1, A2, A3, A4) :-
    runtime_execute_closure(Module, Closure0, [A1, A2, A3, A4]).
'$call'(Module, Closure0, A1, A2, A3, A4, A5) :-
    runtime_execute_closure(Module, Closure0, [A1, A2, A3, A4, A5]).
'$call'(Module, Closure0, A1, A2, A3, A4, A5, A6) :-
    runtime_execute_closure(Module, Closure0, [A1, A2, A3, A4, A5, A6]).
'$call'(Module, Closure0, A1, A2, A3, A4, A5, A6, A7) :-
    runtime_execute_closure(Module, Closure0, [A1, A2, A3, A4, A5, A6, A7]).

'$receive'(Module, Clauses0) :-
    receive_module(Module, Clauses0, ReceiveModule, PlainClauses0),
    rewrite_receive_clauses(ReceiveModule, PlainClauses0, Clauses),
    actors:receive(ReceiveModule:{Clauses}).

'$receive'(Module, Clauses0, Options0) :-
    receive_module(Module, Clauses0, ReceiveModule, PlainClauses0),
    rewrite_receive_clauses(ReceiveModule, PlainClauses0, Clauses),
    rewrite_receive_options(ReceiveModule, Options0, Options),
    actors:receive(ReceiveModule:{Clauses}, Options).

receive_module(_, QualifiedModule:{Clauses}, QualifiedModule, Clauses) :-
    atom(QualifiedModule),
    !.
receive_module(Module, {Clauses}, Module, Clauses) :-
    !.
receive_module(Module, Clauses, Module, Clauses).

rewrite_receive_clauses(_, Var, Var) :-
    var(Var),
    !.
rewrite_receive_clauses(Module, (Clause0 ; Clauses0),
                        (Clause ; Clauses)) :-
    !,
    rewrite_receive_clauses(Module, Clause0, Clause),
    rewrite_receive_clauses(Module, Clauses0, Clauses).
rewrite_receive_clauses(Module, (Head0 -> Body0), (Head -> Body)) :-
    !,
    rewrite_receive_head(Module, Head0, Head),
    rewrite_goal(Module, Body0, Body).
rewrite_receive_clauses(_, Clauses, Clauses).

rewrite_receive_head(_, Head, Head) :-
    var(Head),
    !.
rewrite_receive_head(Module, if(Pattern, Guard0), if(Pattern, Guard)) :-
    !,
    rewrite_goal(Module, Guard0, Guard).
rewrite_receive_head(_, Head, Head).

rewrite_receive_options(_, Var, Var) :-
    var(Var),
    !.
rewrite_receive_options(Module, Options0, Options) :-
    is_list(Options0),
    !,
    maplist(rewrite_receive_option(Module), Options0, Options).
rewrite_receive_options(_, Options, Options).

rewrite_receive_option(Module, on_timeout(Goal0), on_timeout(Goal)) :-
    !,
    rewrite_goal(Module, Goal0, Goal).
rewrite_receive_option(_, Option, Option).

runtime_execute(Module, Goal0) :-
    rewrite_goal(Module, Goal0, Goal),
    runtime_call(Module, Goal).

runtime_execute_closure(Module, Closure0, ExtraArgs) :-
    build_applied_goal(Closure0, ExtraArgs, Goal0),
    runtime_execute(Module, Goal0).

runtime_call(_Module, QualifiedModule:Goal) :-
    atom(QualifiedModule),
    !,
    call(QualifiedModule:Goal).
runtime_call(Module, Goal) :-
    call(Module:Goal).

build_applied_goal(QualifiedModule:Closure0, ExtraArgs,
                   QualifiedModule:Goal) :-
    atom(QualifiedModule),
    !,
    build_plain_applied_goal(Closure0, ExtraArgs, Goal).
build_applied_goal(Closure0, ExtraArgs, Goal) :-
    build_plain_applied_goal(Closure0, ExtraArgs, Goal).

build_plain_applied_goal(Closure0, ExtraArgs, Goal) :-
    Closure0 =.. [Name|ClosureArgs],
    append(ClosureArgs, ExtraArgs, GoalArgs),
    Goal =.. [Name|GoalArgs].


'$assert'(Module, Clause0) :-
    runtime_assert(assert, Module, Clause0).
'$assert'(Module, Clause0, Ref) :-
    runtime_assert(assert, Module, Clause0, Ref).
'$asserta'(Module, Clause0) :-
    runtime_assert(asserta, Module, Clause0).
'$asserta'(Module, Clause0, Ref) :-
    runtime_assert(asserta, Module, Clause0, Ref).
'$assertz'(Module, Clause0) :-
    runtime_assert(assertz, Module, Clause0).
'$assertz'(Module, Clause0, Ref) :-
    runtime_assert(assertz, Module, Clause0, Ref).

runtime_assert(Functor, Module, Clause0) :-
    rewrite_asserted_clause(Module, Clause0, Clause),
    Goal =.. [Functor, Clause],
    call(Module:Goal).

runtime_assert(Functor, Module, Clause0, Ref) :-
    rewrite_asserted_clause(Module, Clause0, Clause),
    Goal =.. [Functor, Clause, Ref],
    call(Module:Goal).

rewrite_asserted_clause(Module, (Head :- Body0), (Head :- Body)) :-
    !,
    rewrite_goal(Module, Body0, Body).
rewrite_asserted_clause(_, Clause, Clause).


%!  rewrite_source_text(+Module, +Source0, -Source) is det.
%
%   Apply rewrite_goal/3 to directives and clause bodies before actor source
%   is compiled.  DCGs are expanded first so catches in their bodies are not
%   hidden behind the DCG notation.

rewrite_source_text(Module, Source0, Source) :-
    text_to_string(Source0, SourceText),
    setup_call_cleanup(
        open_string(SourceText, In),
        read_rewritten_terms(Module, In, Terms),
        close(In)
    ),
    with_output_to(string(Source),
                   forall(member(Term, Terms),
                          write_term(Term, [
                              quoted(true),
                              fullstop(true),
                              nl(true)
                          ]))).

read_rewritten_terms(Module, In, Terms) :-
    read_term(In, Term0, [module(Module)]),
    (   Term0 == end_of_file
    ->  Terms = []
    ;   rewrite_source_term(Module, Term0, RewrittenTerms),
        update_reader_operators(Module, Term0),
        read_rewritten_terms(Module, In, Rest),
        append(RewrittenTerms, Rest, Terms)
    ).

%  Source used to be compiled as a stream, so an op/3 directive affected the
%  parser before the following term was read.  Preserve that behavior while
%  materializing and rewriting the source.  The directive remains in the
%  emitted source and is executed normally by load_files/2 as well.
update_reader_operators(Module, (:- op(Priority, Type, Name))) :-
    !,
    Module:op(Priority, Type, Name).
update_reader_operators(_, _).

rewrite_source_term(Module, (:- Directive0), [(:- Directive)]) :-
    !,
    rewrite_goal(Module, Directive0, Directive).
rewrite_source_term(Module, (Head :- Body0), [(Head :- Body)]) :-
    !,
    rewrite_goal(Module, Body0, Body).
rewrite_source_term(Module, Rule0, Terms) :-
    Rule0 = (_Head --> _Body),
    !,
    dcg_translate_rule(Rule0, Expanded0),
    rewrite_expanded_terms(Module, Expanded0, Terms).
rewrite_source_term(_, Term, [Term]).

rewrite_expanded_terms(_, [], []) :-
    !.
rewrite_expanded_terms(Module, [Term0|Terms0], Terms) :-
    !,
    rewrite_source_term(Module, Term0, Rewritten0),
    rewrite_expanded_terms(Module, Terms0, Rewritten1),
    append(Rewritten0, Rewritten1, Terms).
rewrite_expanded_terms(Module, Term0, Terms) :-
    rewrite_source_term(Module, Term0, Terms).

text_to_string(Text, Text) :-
    string(Text),
    !.
text_to_string(Text, String) :-
    atom(Text),
    atom_string(Text, String).
