:- module(node_profile_policy, [
    node_profile_mode/1,
    normalize_profile/2,
    min_profile/3,
    endpoint_profile_ceiling/2,
    profile_allows_route/2,
    effective_profile_for_route/2,
    profile_check_route/1,
    profile_check_goal/2,
    profile_check_spawn_options/2,
    profile_check_source_text/3,
    profile_check_source_options/3
]).

/** <module> Node Profile Policy

Explicit profile ceilings for node routes and submitted Web Prolog code.
*/

:- op(800, xfx, !).
:- op(200, xfx, @).
:- op(1000, xfy, if).

:- use_module(library(error)).
:- use_module(library(settings)).

:- use_module(goal_walker, [walk_goal/2]).
:- use_module(node_builtin_policy, [
    builtin_goal_policy/3,
    builtin_route_family/2,
    builtin_source_option_policy/2,
    builtin_family_enabled/2
]).
:- use_module(node_client, [text_to_string/2]).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(source_loader, [source_options/3]).

:- setting(profile, atom, workbench, 'Node profile: workbench, relation, isobase, isotope, or actor').


%!  node_profile_mode(-Profile) is det.
%
%   Effective node profile. Supported values are `workbench`, `relation`,
%   `isobase`, `isotope`, and `actor`. Historical aliases `stateless` and
%   `session` are normalized.
node_profile_mode(Profile) :-
    (   current_node_value(profile, Profile1)
    ->  Profile0 = Profile1
    ;   setting(profile, Profile0)
    ),
    normalize_profile(Profile0, Profile).


%!  normalize_profile(+Profile0, -Profile) is det.
normalize_profile(stateless, isobase) :- !.
normalize_profile(session, isotope) :- !.
normalize_profile(Profile, Profile) :-
    valid_profile(Profile),
    !.
normalize_profile(Profile, _) :-
    throw(error(domain_error(node_profile, Profile),
                context(node_profile_policy:normalize_profile/2,
                        'profile must be workbench, relation, isobase, isotope, actor, stateless, or session'))).


valid_profile(workbench).
valid_profile(relation).
valid_profile(isobase).
valid_profile(isotope).
valid_profile(actor).

profile_rank(relation, 0).
profile_rank(isobase, 1).
profile_rank(isotope, 2).
profile_rank(actor, 3).
profile_rank(workbench, 3).

profile_at_least(Profile0, Required0) :-
    normalize_profile(Profile0, Profile),
    normalize_profile(Required0, Required),
    profile_rank(Profile, ProfileRank),
    profile_rank(Required, RequiredRank),
    ProfileRank >= RequiredRank.


%!  min_profile(+ProfileA, +ProfileB, -MinProfile) is det.
%
%   Lower of two profile ceilings. This is used for node/endpoint composition,
%   not for principal-specific profile narrowing.
min_profile(ProfileA0, ProfileB0, MinProfile) :-
    normalize_profile(ProfileA0, ProfileA),
    normalize_profile(ProfileB0, ProfileB),
    profile_rank(ProfileA, RankA),
    profile_rank(ProfileB, RankB),
    (   RankA =< RankB
    ->  MinProfile = ProfileA
    ;   MinProfile = ProfileB
    ).


%!  endpoint_profile_ceiling(+RouteId, -Profile) is det.
endpoint_profile_ceiling(call, isobase).
endpoint_profile_ceiling(toplevel_spawn, isotope).
endpoint_profile_ceiling(toplevel_call, isotope).
endpoint_profile_ceiling(toplevel_next, isotope).
endpoint_profile_ceiling(toplevel_poll, isotope).
endpoint_profile_ceiling(toplevel_stop, isotope).
endpoint_profile_ceiling(toplevel_abort, isotope).
endpoint_profile_ceiling(toplevel_respond, isotope).
endpoint_profile_ceiling(ws, actor).


%!  profile_allows_route(+Profile, +RouteId) is semidet.
profile_allows_route(Profile, RouteId) :-
    Profile == relation,
    !,
    RouteId == call.
profile_allows_route(Profile, RouteId) :-
    endpoint_profile_ceiling(RouteId, RequiredProfile),
    profile_at_least(Profile, RequiredProfile).


%!  effective_profile_for_route(+RouteId, -EffectiveProfile) is det.
effective_profile_for_route(RouteId, EffectiveProfile) :-
    node_profile_mode(NodeProfile),
    endpoint_profile_ceiling(RouteId, EndpointProfile),
    min_profile(NodeProfile, EndpointProfile, EffectiveProfile).


%!  profile_check_route(+RouteId) is det.
profile_check_route(RouteId) :-
    node_profile_mode(NodeProfile),
    effective_profile_for_route(RouteId, EffectiveProfile),
    (   profile_allows_route(NodeProfile, RouteId)
    ->  true
    ;   throw(error(profile_violation(NodeProfile, route(RouteId)),
                    context(node_profile_policy:profile_check_route/1,
                            'route is not available in the current node profile')))
    ),
    (   builtin_route_family(RouteId, Family),
        \+ builtin_family_enabled(EffectiveProfile, Family)
    ->  throw(error(profile_violation(NodeProfile, route(RouteId)),
                    context(node_profile_policy:profile_check_route/1,
                            'web API family is not offered for this route in the current node profile')))
    ;   true
    ).


%!  profile_check_goal(+Profile, +QualifiedGoal) is det.
profile_check_goal(Profile0, QualifiedGoal) :-
    normalize_profile(Profile0, Profile),
    must_be(callable, QualifiedGoal),
    profile_check_goal_1(Profile, QualifiedGoal).


%!  profile_check_spawn_options(+Profile, +Options) is det.
%
%   Profile policy currently treats spawn options as transport details except
%   for source-loading options, which are validated separately.
profile_check_spawn_options(_Profile, Options) :-
    var(Options),
    !.
profile_check_spawn_options(_Profile, Options) :-
    must_be(list, Options).


%!  profile_check_source_text(+Profile, +GoalModule, +SourceText) is det.
profile_check_source_text(Profile0, _GoalModule, SourceText0) :-
    normalize_profile(Profile0, Profile),
    text_to_string(SourceText0, SourceText),
    (   SourceText == ""
    ->  true
    ;   setup_call_cleanup(
            open_string(SourceText, Stream),
            profile_check_source_terms(Profile, Stream),
            close(Stream)
        )
    ).


%!  profile_check_source_options(+Profile, +GoalModule, +Options) is det.
profile_check_source_options(Profile0, GoalModule, Options) :-
    normalize_profile(Profile0, Profile),
    must_be(list, Options),
    source_options(Options, GoalModule, SourceOptions),
    maplist(profile_check_source_option(Profile, GoalModule), SourceOptions).


profile_check_source_option(Profile, GoalModule, load_text(SourceText)) :-
    !,
    ensure_source_option_family(Profile, load_text(SourceText)),
    profile_check_source_text(Profile, GoalModule, SourceText).
profile_check_source_option(relation, _GoalModule, load_uri(URI)) :-
    !,
    throw(error(profile_violation(relation, option(load_uri(URI))),
                context(node_profile_policy:profile_check_source_options/3,
                        'load_uri/1 is not available in the RELATION profile'))).
profile_check_source_option(Profile, _GoalModule, load_uri(URI)) :-
    normalize_profile(Profile, NormalizedProfile),
    NormalizedProfile \== relation,
    ensure_source_option_family(Profile, load_uri(URI)),
    !.
profile_check_source_option(Profile, _GoalModule, load_list(Terms)) :-
    !,
    ensure_source_option_family(Profile, load_list(Terms)).
profile_check_source_option(Profile, _GoalModule, load_predicates(PIs)) :-
    !,
    ensure_source_option_family(Profile, load_predicates(PIs)).
profile_check_source_option(_, _, _).


ensure_source_option_family(Profile0, SourceOption) :-
    normalize_profile(Profile0, Profile),
    (   Profile == relation
    ->  true
    ;   builtin_source_option_policy(SourceOption, Family),
        \+ builtin_family_enabled(Profile, Family)
    ->  throw(error(profile_violation(Profile, option(SourceOption)),
                    context(node_profile_policy:profile_check_source_options/3,
                            'built-in predicate family is not offered in the current profile')))
    ;   true
    ).


profile_check_goal_1(Profile, Goal) :-
    walk_goal(profile_check_step(Profile), Goal).

profile_check_step(Profile, Goal) :-
    (   Goal = (QM:Inner),
        atom(QM)
    ->  % Qualified goal — check the module, then recurse into Inner
        profile_check_qualified_goal(Profile, QM, Inner),
        profile_check_goal_1(Profile, Inner)
    ;   % Unqualified goal — dispatch on goal functor
        (   profile_check_step_(Goal, Profile)
        ->  true
        ;   ensure_goal_profile(Profile, Goal)
        )
    ).

%!  profile_check_step_(+Goal, +Profile) is semidet.
%
%   Handle known goal forms that need special profile checking beyond
%   the default ensure_goal_profile. Goal is first for first-argument
%   indexing. No catch-all — fails for plain goals, falling back to
%   ensure_goal_profile in the caller.

profile_check_step_(receive(Clauses), Profile) :-
    ensure_goal_profile(Profile, receive(Clauses)),
    profile_check_receive_clauses(Profile, Clauses).
profile_check_step_(receive(Clauses, Options), Profile) :-
    ensure_goal_profile(Profile, receive(Clauses, Options)),
    profile_check_receive_clauses(Profile, Clauses),
    profile_check_receive_options(Profile, Options).
profile_check_step_(spawn(Goal), Profile) :-
    ensure_goal_profile(Profile, spawn(Goal)),
    profile_check_goal_1(Profile, Goal).
profile_check_step_(spawn(Goal, Pid), Profile) :-
    ensure_goal_profile(Profile, spawn(Goal, Pid)),
    profile_check_goal_1(Profile, Goal).
profile_check_step_(spawn(Goal, Pid, Options), Profile) :-
    ensure_goal_profile(Profile, spawn(Goal, Pid, Options)),
    profile_check_goal_1(Profile, Goal),
    profile_check_nested_spawn_source_options(Profile, actor, Options).
profile_check_step_(toplevel_spawn(Pid), Profile) :-
    ensure_goal_profile(Profile, toplevel_spawn(Pid)).
profile_check_step_(toplevel_spawn(Pid, Options), Profile) :-
    ensure_goal_profile(Profile, toplevel_spawn(Pid, Options)),
    profile_check_source_options(Profile, actor, Options).
profile_check_step_(toplevel_call(Pid, Goal), Profile) :-
    ensure_goal_profile(Profile, toplevel_call(Pid, Goal)),
    profile_check_goal_1(Profile, Goal).
profile_check_step_(toplevel_call(Pid, Goal, Options), Profile) :-
    ensure_goal_profile(Profile, toplevel_call(Pid, Goal, Options)),
    profile_check_goal_1(Profile, Goal),
    profile_check_toplevel_options(Profile, Options).
profile_check_step_(toplevel_next(Pid), Profile) :-
    ensure_goal_profile(Profile, toplevel_next(Pid)).
profile_check_step_(toplevel_next(Pid, Options), Profile) :-
    ensure_goal_profile(Profile, toplevel_next(Pid, Options)),
    profile_check_toplevel_options(Profile, Options).
profile_check_step_(toplevel_stop(Pid), Profile) :-
    ensure_goal_profile(Profile, toplevel_stop(Pid)).
profile_check_step_(toplevel_halt(Pid, Reply), Profile) :-
    ensure_goal_profile(Profile, toplevel_halt(Pid, Reply)).
profile_check_step_(toplevel_abort(Pid), Profile) :-
    ensure_goal_profile(Profile, toplevel_abort(Pid)).
profile_check_step_(parallel(Goals), Profile) :-
    ensure_goal_profile(Profile, parallel(Goals)),
    profile_check_parallel_goals(Profile, Goals).
profile_check_step_(supervisor_spawn(ChildSpecs, Pid), Profile) :-
    ensure_goal_profile(Profile, supervisor_spawn(ChildSpecs, Pid)),
    profile_check_supervisor_child_specs(Profile, ChildSpecs).
profile_check_step_(supervisor_spawn(ChildSpecs, Pid, Options), Profile) :-
    ensure_goal_profile(Profile, supervisor_spawn(ChildSpecs, Pid, Options)),
    profile_check_supervisor_child_specs(Profile, ChildSpecs).
profile_check_step_(supervisor_spawn_child(Sup, ChildSpec, Reply), Profile) :-
    ensure_goal_profile(Profile, supervisor_spawn_child(Sup, ChildSpec, Reply)),
    profile_check_supervisor_child_spec(Profile, ChildSpec).

profile_check_parallel_goals(Profile, Goals) :-
    is_list(Goals),
    !,
    maplist(profile_check_goal_1(Profile), Goals).
profile_check_parallel_goals(_, _).

profile_check_supervisor_child_specs(Profile, ChildSpecs) :-
    is_list(ChildSpecs),
    !,
    maplist(profile_check_supervisor_child_spec(Profile), ChildSpecs).
profile_check_supervisor_child_specs(_, _).

profile_check_supervisor_child_spec(Profile, child(_Id, Options)) :-
    is_list(Options),
    !,
    profile_check_supervisor_child_options(Profile, Options).
profile_check_supervisor_child_spec(_, _).

profile_check_supervisor_child_options(Profile, Options) :-
    forall(member(Option, Options),
           profile_check_supervisor_child_option(Profile, Option)).

profile_check_supervisor_child_option(Profile, start(server(Pred, _ServerOptions))) :-
    !,
    ensure_goal_profile(Profile, server_spawn(Pred, _, _Pid)).
profile_check_supervisor_child_option(Profile, start(Goal)) :-
    !,
    profile_check_goal_1(Profile, Goal).
profile_check_supervisor_child_option(_, _).

profile_check_nested_spawn_source_options(_Profile, _GoalModule, Options) :-
    var(Options),
    !.
profile_check_nested_spawn_source_options(Profile, GoalModule, Options) :-
    must_be(list, Options),
    (   has_deferred_nested_source_option(Options)
    ->  true
    ;   profile_check_source_options(Profile, GoalModule, Options)
    ).

has_deferred_nested_source_option(Options) :-
    member(Option, Options),
    deferred_nested_source_option(Option),
    !.

%!  deferred_nested_source_option(+Option) is semidet.
%
%   True when a nested spawn option must not be materialized during
%   profile source checking.  load_predicates/1 is always deferred
%   because the predicates it references may not yet exist in the
%   GoalModule at check time (chicken-and-egg).  Other source-like
%   options are deferred only when non-ground (content not yet known).
deferred_nested_source_option(load_predicates(_)) :- !.
deferred_nested_source_option(Option) :-
    source_option_like(Option),
    \+ ground(Option).

source_option_like(load_text(_)).
source_option_like(load_list(_)).
source_option_like(load_predicates(_)).
source_option_like(load_uri(_)).


profile_check_qualified_goal(Profile, actor, Goal) :-
    !,
    ensure_public_actor_goal(Goal),
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, toplevel_actor, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, statechart_actor, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, statechart_runtime, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, node, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, server_actor, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, supervisor_actor, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(Profile, parallel, Goal) :-
    !,
    ensure_goal_profile(Profile, Goal).
profile_check_qualified_goal(_, _, _).

ensure_public_actor_goal(Goal) :-
    callable(Goal),
    functor(Goal, Name, Arity),
    functor(Head, Name, Arity),
    predicate_property(actor:Head, exported),
    !.
ensure_public_actor_goal(Goal) :-
    throw(error(profile_violation(actor, goal(actor:Goal)),
                context(node_profile_policy:profile_check_goal/2,
                        'non-exported actor predicates are not available to clients'))).


ensure_goal_profile(Profile, Goal) :-
    (   goal_required_profile(Goal, RequiredProfile),
        \+ profile_at_least(Profile, RequiredProfile)
    ->  throw(error(profile_violation(Profile, goal(Goal)),
                    context(node_profile_policy:profile_check_goal/2,
                            'goal is not available in the current profile')))
    ;   builtin_goal_policy(Goal, Family, _RequiredProfile),
        \+ builtin_family_enabled(Profile, Family)
    ->  throw(error(profile_violation(Profile, goal(Goal)),
                    context(node_profile_policy:profile_check_goal/2,
                            'built-in predicate family is not offered in the current profile')))
    ;   true
    ).


goal_required_profile(Goal, RequiredProfile) :-
    builtin_goal_policy(Goal, _Family, RequiredProfile).


% Dynamic database modification requires persistent session state.
goal_required_profile(assert(_), isotope).
goal_required_profile(assert(_, _), isotope).
goal_required_profile(asserta(_), isotope).
goal_required_profile(asserta(_, _), isotope).
goal_required_profile(assertz(_), isotope).
goal_required_profile(assertz(_, _), isotope).
goal_required_profile(retract(_), isotope).
goal_required_profile(retractall(_), isotope).
goal_required_profile(abolish(_), isotope).
goal_required_profile(abolish(_, _), isotope).
goal_required_profile(nb_setval(_, _), isotope).
goal_required_profile(b_setval(_, _), isotope).
goal_required_profile(flag(_, _, _), isotope).

% Output predicates are side effects not available in pure relational queries.
goal_required_profile(write(_), isotope).
goal_required_profile(write(_, _), isotope).
goal_required_profile(writeln(_), isotope).
goal_required_profile(writeln(_, _), isotope).
goal_required_profile(write_term(_, _), isotope).
goal_required_profile(write_term(_, _, _), isotope).
goal_required_profile(write_canonical(_), isotope).
goal_required_profile(write_canonical(_, _), isotope).
goal_required_profile(writeq(_), isotope).
goal_required_profile(writeq(_, _), isotope).
goal_required_profile(print(_), isotope).
goal_required_profile(print(_, _), isotope).
goal_required_profile(nl, isotope).
goal_required_profile(nl(_), isotope).
goal_required_profile(time(_), isotope).
goal_required_profile(put_char(_), isotope).
goal_required_profile(put_char(_, _), isotope).
goal_required_profile(format(_), isotope).
goal_required_profile(format(_, _), isotope).
goal_required_profile(format(_, _, _), isotope).
goal_required_profile(with_output_to(_, _), isotope).
goal_required_profile(flush_output, isotope).
goal_required_profile(flush_output(_), isotope).

goal_required_profile(read(_), isotope).
goal_required_profile(read(_, _), isotope).
goal_required_profile(read_term(_, _), isotope).
goal_required_profile(read_term(_, _, _), isotope).


profile_check_source_terms(Profile, Stream) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  true
    ;   profile_check_source_term(Profile, Term),
        profile_check_source_terms(Profile, Stream)
    ).


profile_check_source_term(Profile, (:- Directive)) :-
    !,
    (   callable(Directive)
    ->  profile_check_goal(Profile, Directive)
    ;   true
    ).
profile_check_source_term(Profile, (Head :- Body)) :-
    !,
    profile_check_source_head(Head),
    profile_check_goal(Profile, Body).
profile_check_source_term(Profile, Rule) :-
    Rule = (_Head --> _Body),
    !,
    dcg_translate_rule(Rule, Expanded),
    profile_check_expanded_source_term(Profile, Expanded).
profile_check_source_term(_Profile, Fact) :-
    profile_check_source_head(Fact).


profile_check_source_head(Head) :-
    (   callable(Head)
    ->  true
    ;   throw(error(type_error(callable, Head),
                    context(node_profile_policy:profile_check_source_text/3,
                            'source term must be a fact or rule')))
    ).


profile_check_expanded_source_term(_, []) :-
    !.
profile_check_expanded_source_term(Profile, [Term|Terms]) :-
    !,
    profile_check_expanded_source_term(Profile, Term),
    profile_check_expanded_source_term(Profile, Terms).
profile_check_expanded_source_term(Profile, Term) :-
    profile_check_source_term(Profile, Term).


profile_check_toplevel_options(Profile, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           profile_check_toplevel_option(Profile, Option)).
profile_check_toplevel_options(_, _).


profile_check_toplevel_option(Profile, load_text(SourceText)) :-
    !,
    profile_check_source_text(Profile, actor, SourceText).
profile_check_toplevel_option(Profile, load_list(Terms)) :-
    !,
    profile_check_source_options(Profile, actor, [load_list(Terms)]).
profile_check_toplevel_option(Profile, load_predicates(PIs)) :-
    !,
    profile_check_source_options(Profile, actor, [load_predicates(PIs)]).
profile_check_toplevel_option(Profile, load_uri(URI)) :-
    !,
    profile_check_source_options(Profile, actor, [load_uri(URI)]).
profile_check_toplevel_option(_, _).


profile_check_receive_options(Profile, Options) :-
    is_list(Options),
    !,
    forall(member(Option, Options),
           profile_check_receive_option(Profile, Option)).
profile_check_receive_options(_, _).


profile_check_receive_option(Profile, on_timeout(Goal)) :-
    !,
    profile_check_goal(Profile, Goal).
profile_check_receive_option(_, _).


profile_check_receive_clauses(Profile, Module:{Clauses}) :-
    atom(Module),
    !,
    profile_check_receive_clauses(Profile, Clauses).
profile_check_receive_clauses(Profile, Clauses) :-
    profile_check_receive_clauses_1(Profile, Clauses).


profile_check_receive_clauses_1(Profile, (Clause ; Clauses)) :-
    !,
    profile_check_receive_clauses_1(Profile, Clause),
    profile_check_receive_clauses_1(Profile, Clauses).
profile_check_receive_clauses_1(Profile, (Head -> Body)) :-
    !,
    profile_check_receive_head(Profile, Head),
    profile_check_goal(Profile, Body).
profile_check_receive_clauses_1(_, _).


profile_check_receive_head(Profile, if(_Pattern, Guard)) :-
    !,
    profile_check_goal(Profile, Guard).
profile_check_receive_head(_, _).
