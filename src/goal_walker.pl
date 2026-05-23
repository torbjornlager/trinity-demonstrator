:- module(goal_walker, [walk_goal/2]).

:- meta_predicate walk_goal(1, +).

/** <module> Goal Structure Walker

Shared structural recursion over Prolog goal terms. Decomposes compound
control-flow forms (conjunction, disjunction, if-then, catch,
setup_call_cleanup, call/1-8, findall, setof, bagof, aggregate, etc.)
and calls a user-supplied callback for every non-structural sub-goal.

The callback is responsible for handling:

  - qualified goals (`Module:Goal`),
  - domain-specific special forms (e.g. `receive`, `spawn`),
  - leaf goals.
*/


%!  walk_goal(:Callback, +Goal) is det.
%
%   Structurally recurse over Goal. For every sub-goal that is not a
%   known compound control form, call `call(Callback, SubGoal)`.
%   Variable goals succeed silently.

walk_goal(_, Goal) :-
    var(Goal),
    !.
walk_goal(CB, Goal) :-
    (   walk_structural_goal_(Goal)
    ->  walk_compound_(Goal, CB)
    ;   call(CB, Goal)
    ).

%!  walk_structural_goal_(+Goal) is semidet.
%
%   True when Goal is a known structural control-flow form that should
%   be decomposed by walk_compound_/2. This keeps compound detection
%   independent from callback success so leaf failures still propagate.

walk_structural_goal_((_, _)).
walk_structural_goal_((_ ; _)).
walk_structural_goal_((_ -> _)).
walk_structural_goal_((_ *-> _)).
walk_structural_goal_(catch(_, _, _)).
walk_structural_goal_(setup_call_cleanup(_, _, _)).
walk_structural_goal_(setup_call_catcher_cleanup(_, _, _, _)).
walk_structural_goal_(call_cleanup(_, _)).
walk_structural_goal_(_^_).
walk_structural_goal_(\+ _).
walk_structural_goal_(once(_)).
walk_structural_goal_(ignore(_)).
walk_structural_goal_(forall(_, _)).
walk_structural_goal_(call(_)).
walk_structural_goal_(call(_, _)).
walk_structural_goal_(call(_, _, _)).
walk_structural_goal_(call(_, _, _, _)).
walk_structural_goal_(call(_, _, _, _, _)).
walk_structural_goal_(call(_, _, _, _, _, _)).
walk_structural_goal_(call(_, _, _, _, _, _, _)).
walk_structural_goal_(call(_, _, _, _, _, _, _, _)).
walk_structural_goal_(findall(_, _, _)).
walk_structural_goal_(findnsols(_, _, _, _)).
walk_structural_goal_(findnsols(_, _, _, _, _)).
walk_structural_goal_(setof(_, _, _)).
walk_structural_goal_(bagof(_, _, _)).
walk_structural_goal_(aggregate(_, _, _)).
walk_structural_goal_(aggregate(_, _, _, _)).
walk_structural_goal_(aggregate_all(_, _, _)).
walk_structural_goal_(aggregate_all(_, _, _, _)).

%!  walk_compound_(+Goal, +Callback) is semidet.
%
%   Decompose known compound control-flow forms. Called only after
%   walk_structural_goal_/1 has matched a recognized structural form.
%   Goal is the first argument for first-argument indexing.

walk_compound_((A, B), CB) :-
    walk_goal(CB, A),
    walk_goal(CB, B).
walk_compound_((A ; B), CB) :-
    walk_goal(CB, A),
    walk_goal(CB, B).
walk_compound_((A -> B), CB) :-
    walk_goal(CB, A),
    walk_goal(CB, B).
walk_compound_((A *-> B), CB) :-
    walk_goal(CB, A),
    walk_goal(CB, B).
walk_compound_(catch(Goal, _Error, Recover), CB) :-
    walk_goal(CB, Goal),
    walk_goal(CB, Recover).
walk_compound_(setup_call_cleanup(Setup, Goal, Cleanup), CB) :-
    walk_goal(CB, Setup),
    walk_goal(CB, Goal),
    walk_goal(CB, Cleanup).
walk_compound_(setup_call_catcher_cleanup(Setup, Goal, _Catcher, Cleanup), CB) :-
    walk_goal(CB, Setup),
    walk_goal(CB, Goal),
    walk_goal(CB, Cleanup).
walk_compound_(call_cleanup(Goal, Cleanup), CB) :-
    walk_goal(CB, Goal),
    walk_goal(CB, Cleanup).
walk_compound_(_Vars^Goal, CB) :-
    walk_goal(CB, Goal).
walk_compound_(\+ Goal, CB) :-
    walk_goal(CB, Goal).
walk_compound_(once(Goal), CB) :-
    walk_goal(CB, Goal).
walk_compound_(ignore(Goal), CB) :-
    walk_goal(CB, Goal).
walk_compound_(forall(Generate, Test), CB) :-
    walk_goal(CB, Generate),
    walk_goal(CB, Test).
walk_compound_(call(Goal), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _, _, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _, _, _, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(call(Goal, _, _, _, _, _, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(findall(_, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(findnsols(_, _, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(findnsols(_, _, Goal, _, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(setof(_, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(bagof(_, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(aggregate(_, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(aggregate(_, _, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(aggregate_all(_, Goal, _), CB) :-
    walk_goal(CB, Goal).
walk_compound_(aggregate_all(_, _, Goal, _), CB) :-
    walk_goal(CB, Goal).
