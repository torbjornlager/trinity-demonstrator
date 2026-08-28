:- module(public_goal_guard, [
    blacklist_guard_active/0,
    rewrite_goal_if_needed/3,
    rewrite_source_text_if_needed/3,
    rewrite_source_text/3,
    restore_goal/3
]).

/** <module> Public Blacklist Goal Rewriting

Runtime/load-time rewriting that inserts guarded execution wrappers around
opaque meta-call positions for public blacklist sandbox mode.
*/

:- use_module(library(lists)).
:- use_module(node_execution_context, [current_public_execution_profile/1]).
:- use_module(control_guard, []).


%!  blacklist_guard_active is semidet.
blacklist_guard_active :-
    current_public_execution_profile(_),
    current_predicate(node_sandbox:sandbox_mode/1),
    node_sandbox:sandbox_mode(Mode),
    Mode == blacklist.


%!  rewrite_goal_if_needed(+Module, +Goal0, -Goal) is det.
rewrite_goal_if_needed(Module, Goal0, Goal) :-
    (   blacklist_guard_active
    ->  rewrite_goal(Module, Goal0, Goal)
    ;   Goal = Goal0
    ).


%!  rewrite_source_text_if_needed(+Module, +SourceIn, -SourceOut) is det.
rewrite_source_text_if_needed(Module, SourceIn, SourceOut) :-
    text_to_string_(SourceIn, Source0),
    (   Source0 == ""
    ->  SourceOut = Source0
    ;   blacklist_guard_active
    ->  rewrite_source_text(Module, Source0, SourceOut)
    ;   SourceOut = Source0
    ).


%!  rewrite_source_text(+Module, +SourceIn, -SourceOut) is det.
rewrite_source_text(Module, SourceIn, SourceOut) :-
    text_to_string_(SourceIn, Source),
    setup_call_cleanup(
        open_string(Source, In),
        read_rewritten_terms(Module, In, Terms),
        close(In)
    ),
    with_output_to(string(SourceOut),
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
        read_rewritten_terms(Module, In, Rest),
        append(RewrittenTerms, Rest, Terms)
    ).


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
    rewrite_source_term(Module, Term0, RewrittenTerms0),
    rewrite_expanded_terms(Module, Terms0, RewrittenTerms1),
    append(RewrittenTerms0, RewrittenTerms1, Terms).
rewrite_expanded_terms(Module, Term0, Terms) :-
    rewrite_source_term(Module, Term0, Terms).


rewrite_goal(Module, Goal0, Goal) :-
    rewrite_goal_(Module, Goal0, Goal),
    !.
rewrite_goal(_, Goal, Goal).


rewrite_goal_(Module, Var, public_goal_guard:'$sandbox_call'(Module, Var)) :-
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
rewrite_goal_(Module, catch(Goal0, Catcher, Recover0),
              catch(Goal, Catcher, Recover)) :-
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
rewrite_goal_(Module, call(Goal0),
              public_goal_guard:'$sandbox_call'(Module, Goal0)).
rewrite_goal_(Module, call(Goal0, A1),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1)).
rewrite_goal_(Module, call(Goal0, A1, A2),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2, A3)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2, A3, A4)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5, A6),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5, A6)).
rewrite_goal_(Module, call(Goal0, A1, A2, A3, A4, A5, A6, A7),
              public_goal_guard:'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5, A6, A7)).
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
              public_goal_guard:'$sandbox_assert'(Module, Clause0)).
rewrite_goal_(Module, assert(Clause0, Ref),
              public_goal_guard:'$sandbox_assert'(Module, Clause0, Ref)).
rewrite_goal_(Module, asserta(Clause0),
              public_goal_guard:'$sandbox_asserta'(Module, Clause0)).
rewrite_goal_(Module, asserta(Clause0, Ref),
              public_goal_guard:'$sandbox_asserta'(Module, Clause0, Ref)).
rewrite_goal_(Module, assertz(Clause0),
              public_goal_guard:'$sandbox_assertz'(Module, Clause0)).
rewrite_goal_(Module, assertz(Clause0, Ref),
              public_goal_guard:'$sandbox_assertz'(Module, Clause0, Ref)).


%!  restore_goal(+Module, +Goal0, -Goal) is det.
%
%   Inverse of the blacklist guard rewrite for src_predicates/1 source
%   reconstruction.  The reconstructed goal crosses the sandbox and rewrite
%   boundaries again in the destination actor.

restore_goal(Module, Goal0, Goal) :-
    restore_goal_(Module, Goal0, Goal),
    !.
restore_goal(_, Goal, Goal).

restore_goal_(_, Var, Var) :-
    var(Var),
    !.
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
restore_goal_(Module, Guarded, Goal) :-
    restore_sandbox_call(Module, Guarded, Goal).
restore_goal_(Module, Guarded, Goal) :-
    restore_sandbox_assert(Module, Guarded, Goal).
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

restore_sandbox_call(Module, Guarded, Goal) :-
    Guarded = public_goal_guard:Call,
    Call =.. ['$sandbox_call', _StoredModule, Closure|ExtraArgs],
    restore_goal(Module, Closure, RestoredClosure),
    Goal =.. [call, RestoredClosure|ExtraArgs].

restore_sandbox_assert(Module, Guarded, Goal) :-
    Guarded = public_goal_guard:Call,
    Call =.. [GuardName, _StoredModule, Clause0|Rest],
    sandbox_assert_name(GuardName, Name),
    restore_asserted_clause(Module, Clause0, Clause),
    Goal =.. [Name, Clause|Rest].

sandbox_assert_name('$sandbox_assert', assert).
sandbox_assert_name('$sandbox_asserta', asserta).
sandbox_assert_name('$sandbox_assertz', assertz).

restore_asserted_clause(Module, (Head :- Body0), (Head :- Body)) :-
    !,
    restore_goal(Module, Body0, Body).
restore_asserted_clause(_, Clause, Clause).

restore_meta_arguments([], _, [], []).
restore_meta_arguments([Mode|Modes], Module, [Arg0|Args0], [Arg|Args]) :-
    restore_meta_argument(Mode, Module, Arg0, Arg),
    restore_meta_arguments(Modes, Module, Args0, Args).

restore_meta_argument(0, Module, Goal0, Goal) :-
    !,
    restore_goal(Module, Goal0, Goal).
restore_meta_argument(Extra, _Module,
                      public_goal_guard:'$sandbox_call'(_StoredModule, Closure),
                      Closure) :-
    (   integer(Extra), Extra > 0
    ;   Extra == (//)
    ),
    !.
restore_meta_argument(_, _, Arg, Arg).


'$sandbox_call'(Module, Goal0) :-
    runtime_execute_goal(Module, Goal0).
'$sandbox_call'(Module, Goal0, A1) :-
    runtime_execute_closure(Module, Goal0, [A1]).
'$sandbox_call'(Module, Goal0, A1, A2) :-
    runtime_execute_closure(Module, Goal0, [A1, A2]).
'$sandbox_call'(Module, Goal0, A1, A2, A3) :-
    runtime_execute_closure(Module, Goal0, [A1, A2, A3]).
'$sandbox_call'(Module, Goal0, A1, A2, A3, A4) :-
    runtime_execute_closure(Module, Goal0, [A1, A2, A3, A4]).
'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5) :-
    runtime_execute_closure(Module, Goal0, [A1, A2, A3, A4, A5]).
'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5, A6) :-
    runtime_execute_closure(Module, Goal0, [A1, A2, A3, A4, A5, A6]).
'$sandbox_call'(Module, Goal0, A1, A2, A3, A4, A5, A6, A7) :-
    runtime_execute_closure(Module, Goal0, [A1, A2, A3, A4, A5, A6, A7]).


'$sandbox_assert'(Module, Clause0) :-
    runtime_assert_clause(assert, Module, Clause0).
'$sandbox_assert'(Module, Clause0, Ref) :-
    runtime_assert_clause(assert, Module, Clause0, Ref).
'$sandbox_asserta'(Module, Clause0) :-
    runtime_assert_clause(asserta, Module, Clause0).
'$sandbox_asserta'(Module, Clause0, Ref) :-
    runtime_assert_clause(asserta, Module, Clause0, Ref).
'$sandbox_assertz'(Module, Clause0) :-
    runtime_assert_clause(assertz, Module, Clause0).
'$sandbox_assertz'(Module, Clause0, Ref) :-
    runtime_assert_clause(assertz, Module, Clause0, Ref).


runtime_execute_goal(Module, Goal0) :-
    (   blacklist_guard_profile(Profile)
    ->  runtime_sandbox_check(Profile, Module, Goal0),
        rewrite_goal(Module, Goal0, GuardedGoal0)
    ;   GuardedGoal0 = Goal0
    ),
    control_guard:rewrite_goal(Module, GuardedGoal0, GuardedGoal),
    runtime_call_goal(Module, GuardedGoal).


runtime_execute_closure(Module, Closure0, ExtraArgs) :-
    build_applied_goal(Closure0, ExtraArgs, Goal0),
    runtime_execute_goal(Module, Goal0).


runtime_assert_clause(Functor, Module, Clause0) :-
    (   blacklist_guard_profile(Profile)
    ->  runtime_sandbox_check_dynamic_clause(Profile, Module, Clause0),
        rewrite_asserted_clause(Module, Clause0, GuardedClause0)
    ;   GuardedClause0 = Clause0
    ),
    control_guard:rewrite_asserted_clause(Module, GuardedClause0,
                                          GuardedClause),
    runtime_call_assert(Functor, Module, GuardedClause).


runtime_assert_clause(Functor, Module, Clause0, Ref) :-
    (   blacklist_guard_profile(Profile)
    ->  runtime_sandbox_check_dynamic_clause(Profile, Module, Clause0),
        rewrite_asserted_clause(Module, Clause0, GuardedClause0)
    ;   GuardedClause0 = Clause0
    ),
    control_guard:rewrite_asserted_clause(Module, GuardedClause0,
                                          GuardedClause),
    runtime_call_assert(Functor, Module, GuardedClause, Ref).


blacklist_guard_profile(Profile) :-
    blacklist_guard_active,
    current_public_execution_profile(Profile).


runtime_sandbox_check(Profile, Module, Goal0) :-
    (   Goal0 = (QM:Inner),
        atom(QM)
    ->  node_sandbox:sandbox_check_goal(Profile, QM:Inner)
    ;   node_sandbox:sandbox_check_goal_in_module(Profile, Module, Goal0)
    ).


runtime_sandbox_check_dynamic_clause(Profile, Module, Clause0) :-
    node_sandbox:sandbox_check_dynamic_clause(Profile, Module, Clause0).


runtime_call_goal(Module, Goal0) :-
    (   Goal0 = (QM:Inner),
        atom(QM)
    ->  call(QM:Inner)
    ;   call(Module:Goal0)
    ).


runtime_call_assert(Functor, Module, Clause) :-
    Goal =.. [Functor, Clause],
    call(Module:Goal).


runtime_call_assert(Functor, Module, Clause, Ref) :-
    Goal =.. [Functor, Clause, Ref],
    call(Module:Goal).


rewrite_asserted_clause(Module, (Head :- Body0), (Head :- Body)) :-
    !,
    rewrite_goal(Module, Body0, Body).
rewrite_asserted_clause(_, Clause, Clause).


build_applied_goal((QM:Closure0), ExtraArgs, QM:Goal) :-
    atom(QM),
    !,
    build_plain_applied_goal(Closure0, ExtraArgs, Goal).
build_applied_goal(Closure0, ExtraArgs, Goal) :-
    build_plain_applied_goal(Closure0, ExtraArgs, Goal).


build_plain_applied_goal(Closure0, ExtraArgs, Goal) :-
    Closure0 =.. [Name|ClosureArgs],
    append(ClosureArgs, ExtraArgs, GoalArgs),
    Goal =.. [Name|GoalArgs].


text_to_string_(Text, String) :-
    string(Text),
    !,
    String = Text.
text_to_string_(Text, String) :-
    atom(Text),
    !,
    atom_string(Text, String).
