:- module(node_builtin_policy, [
    default_builtin_family_policy/1,
    current_builtin_family_policy/1,
    current_builtin_families_json/1,
    normalize_builtin_family_updates/2,
    builtin_goal_policy/3,
    builtin_route_family/2,
    builtin_source_option_policy/2,
    builtin_family_enabled/2
]).

/** <module> Web Prolog Family Policy

Metadata and runtime policy for the built-in predicate families and node API
families exposed by the admin UI. The family catalog drives both what the UI
renders and what the profile checker may allow or deny.
*/

:- use_module(library(error)).

:- use_module(node_runtime_state, [current_node_value/2]).


%!  default_builtin_family_policy(-Policy) is det.
default_builtin_family_policy(Policy) :-
    findall(Id-Profiles,
            builtin_family_default_pair(Id, Profiles),
            Pairs),
    dict_pairs(Policy, builtin_family_policy, Pairs).


%!  current_builtin_family_policy(-Policy) is det.
current_builtin_family_policy(Policy) :-
    (   current_node_value(builtin_family_policy, Policy0)
    ->  Policy = Policy0
    ;   default_builtin_family_policy(Policy)
    ).


%!  current_builtin_families_json(-Families) is det.
current_builtin_families_json(Families) :-
    current_builtin_family_policy(Policy),
    findall(json{
                id:IdString,
                label:Label,
                description:Description,
                predicates:Predicates,
                profiles:Profiles,
                default_profiles:DefaultProfiles
            },
            builtin_family_json(Policy, IdString, Label, Description,
                                Predicates, Profiles, DefaultProfiles),
            Families).


builtin_family_json(Policy, IdString, Label, Description, Predicates,
                    Profiles, DefaultProfiles) :-
    builtin_family_json_(Policy, IdString, Label, Description, Predicates,
                         Profiles, DefaultProfiles).

builtin_family_json_(Policy, IdString, Label, Description, Predicates,
                    json{
                        relation:Relation,
                        isobase:Isobase,
                        isotope:Isotope,
                        actor:Actor
                    },
                    json{
                        relation:DefaultRelation,
                        isobase:DefaultIsobase,
                        isotope:DefaultIsotope,
                        actor:DefaultActor
                    }) :-
    builtin_family_spec(Id, Label, Description, Predicates0, EnabledProfiles),
    compact_predicate_indicators(Predicates0, Predicates),
    atom_string(Id, IdString),
    builtin_family_profile_enabled(Policy, Id, relation, Relation),
    builtin_family_profile_enabled(Policy, Id, isobase, Isobase),
    builtin_family_profile_enabled(Policy, Id, isotope, Isotope),
    builtin_family_profile_enabled(Policy, Id, actor, Actor),
    bool_memberchk(relation, EnabledProfiles, DefaultRelation),
    bool_memberchk(isobase, EnabledProfiles, DefaultIsobase),
    bool_memberchk(isotope, EnabledProfiles, DefaultIsotope),
    bool_memberchk(actor, EnabledProfiles, DefaultActor).


compact_predicate_indicators([], []).
compact_predicate_indicators([Indicator0|Indicators0], [Indicator|Indicators]) :-
    (   predicate_indicator_name_arity(Indicator0, Name, Arity0)
    ->  collect_predicate_indicator_range(Indicators0, Name, Arity0,
                                          Arity, Indicators1),
        format_predicate_indicator_range(Name, Arity0, Arity, Indicator)
    ;   Indicator = Indicator0,
        Indicators1 = Indicators0
    ),
    compact_predicate_indicators(Indicators1, Indicators).

collect_predicate_indicator_range([Indicator0|Indicators0], Name, PreviousArity,
                                  Arity, Indicators) :-
    predicate_indicator_name_arity(Indicator0, Name, NextArity),
    NextArity =:= PreviousArity + 1,
    !,
    collect_predicate_indicator_range(Indicators0, Name, NextArity,
                                      Arity, Indicators).
collect_predicate_indicator_range(Indicators, _Name, Arity, Arity, Indicators).

predicate_indicator_name_arity(Indicator0, Name, Arity) :-
    text_to_string(Indicator0, Indicator),
    split_string(Indicator, "/", "", [Name, ArityText]),
    Name \== "",
    catch(number_string(Arity, ArityText), _, fail),
    integer(Arity).

format_predicate_indicator_range(Name, Arity, Arity, Indicator) :-
    !,
    format(string(Indicator), '~w/~d', [Name, Arity]).
format_predicate_indicator_range(Name, FirstArity, LastArity, Indicator) :-
    format(string(Indicator), '~w/~d-~d', [Name, FirstArity, LastArity]).


%!  normalize_builtin_family_updates(+Value, -Policy) is det.
%
%   Accepts the admin-facing `builtin_families` JSON value and normalizes it to
%   the runtime `builtin_family_policy` dict. Missing families or profile keys
%   keep their existing/default values so small manual updates remain possible.
normalize_builtin_family_updates(Value, Policy) :-
    current_builtin_family_policy(Policy0),
    normalize_builtin_family_updates(Value, Policy0, Policy).

normalize_builtin_family_updates(Value, Policy0, Policy) :-
    must_be(list, Value),
    foldl(normalize_builtin_family_update, Value, Policy0, Policy).

normalize_builtin_family_update(Update0, Policy0, Policy) :-
    must_be(dict, Update0),
    get_dict(id, Update0, Id0),
    builtin_family_id(Id0, Id),
    normalize_builtin_family_profiles(Update0, Id, Policy0, Profiles),
    dict_pairs(Update, builtin_family_policy, [Id-Profiles]),
    put_dict(Update, Policy0, Policy).

normalize_builtin_family_profiles(Update0, Id, Policy0, Profiles) :-
    builtin_family_profiles(Policy0, Id, Profiles0),
    (   get_dict(profiles, Update0, ProfilesValue)
    ->  must_be(dict, ProfilesValue),
        normalize_builtin_family_profile_keys(ProfilesValue, Profiles0, Profiles)
    ;   normalize_builtin_family_profile_keys(Update0, Profiles0, Profiles)
    ).

normalize_builtin_family_profile_keys(Input, Profiles0, Profiles) :-
    normalize_builtin_family_profile_key(Input, relation, Profiles0, Profiles1),
    normalize_builtin_family_profile_key(Input, isobase, Profiles1, Profiles2),
    normalize_builtin_family_profile_key(Input, isotope, Profiles2, Profiles3),
    normalize_builtin_family_profile_key(Input, actor, Profiles3, Profiles).

normalize_builtin_family_profile_key(Input, Key, Profiles0, Profiles) :-
    (   get_dict(Key, Input, Value0)
    ->  normalize_builtin_family_boolean(Value0, Value),
        put_dict(Key, Profiles0, Value, Profiles)
    ;   Profiles = Profiles0
    ).

normalize_builtin_family_boolean(true, true) :- !.
normalize_builtin_family_boolean(false, false) :- !.
normalize_builtin_family_boolean("true", true) :- !.
normalize_builtin_family_boolean("false", false) :- !.
normalize_builtin_family_boolean('true', true) :- !.
normalize_builtin_family_boolean('false', false) :- !.
normalize_builtin_family_boolean(@(true), true) :- !.
normalize_builtin_family_boolean(@(false), false) :- !.
normalize_builtin_family_boolean(Value, _) :-
    throw(error(type_error(boolean, Value),
                context(node_builtin_policy:normalize_builtin_family_updates/2,
                        'family profile entries must be boolean values'))).


%!  builtin_goal_policy(+Goal, -Family, -RequiredProfile) is semidet.
builtin_goal_policy(self(_), actor_lifecycle, actor).
builtin_goal_policy(spawn(_), actor_lifecycle, actor).
builtin_goal_policy(spawn(_, _), actor_lifecycle, actor).
builtin_goal_policy(spawn(_, _, _), actor_lifecycle, actor).
builtin_goal_policy(actors(_), actor_lifecycle, actor).
builtin_goal_policy(exit(_), actor_lifecycle, actor).
builtin_goal_policy(exit(_, _), actor_lifecycle, actor).
builtin_goal_policy(cancel(_), actor_lifecycle, actor).

builtin_goal_policy(send(_, _), actor_messaging, actor).
builtin_goal_policy(send(_, _, _), actor_messaging, actor).
builtin_goal_policy(!(_, _), actor_messaging, actor).
builtin_goal_policy(receive(_), actor_messaging, actor).
builtin_goal_policy(receive(_, _), actor_messaging, actor).
builtin_goal_policy(monitor(_, _), actor_messaging, actor).
builtin_goal_policy(demonitor(_), actor_messaging, actor).
builtin_goal_policy(demonitor(_, _), actor_messaging, actor).
builtin_goal_policy(flush, actor_messaging, actor).

builtin_goal_policy(register(_, _), actor_naming, actor).
builtin_goal_policy(whereis(_, _), actor_naming, actor).
builtin_goal_policy(unregister(_), actor_naming, actor).

builtin_goal_policy(register_service(_, _), service_registry, actor).
builtin_goal_policy(whereis_service(_, _), service_registry, actor).
builtin_goal_policy(unregister_service(_), service_registry, actor).

builtin_goal_policy(listing, private_db, isotope).
builtin_goal_policy(listing(_), private_db, isotope).
builtin_goal_policy(assert(_), dynamic_db, isotope).
builtin_goal_policy(assert(_, _), dynamic_db, isotope).
builtin_goal_policy(asserta(_), dynamic_db, isotope).
builtin_goal_policy(asserta(_, _), dynamic_db, isotope).
builtin_goal_policy(assertz(_), dynamic_db, isotope).
builtin_goal_policy(assertz(_, _), dynamic_db, isotope).
builtin_goal_policy(retract(_), dynamic_db, isotope).
builtin_goal_policy(retractall(_), dynamic_db, isotope).
builtin_goal_policy(abolish(_), dynamic_db, isotope).
builtin_goal_policy(abolish(_, _), dynamic_db, isotope).

builtin_goal_policy(output(_), actor_io, isotope).
builtin_goal_policy(output(_, _), actor_io, isotope).
builtin_goal_policy(input(_, _), actor_io, isotope).
builtin_goal_policy(input(_, _, _), actor_io, isotope).
builtin_goal_policy(respond(_, _), actor_io, isotope).

builtin_goal_policy(toplevel_spawn(_), toplevel, actor).
builtin_goal_policy(toplevel_spawn(_, _), toplevel, actor).
builtin_goal_policy(toplevel_call(_, _), toplevel, actor).
builtin_goal_policy(toplevel_call(_, _, _), toplevel, actor).
builtin_goal_policy(toplevel_next(_), toplevel, actor).
builtin_goal_policy(toplevel_next(_, _), toplevel, actor).
builtin_goal_policy(toplevel_stop(_), toplevel, actor).
builtin_goal_policy(toplevel_abort(_), toplevel, actor).
builtin_goal_policy(toplevel_halt(_, _), toplevel, actor).

builtin_goal_policy(rpc(_, _), rpc, isobase).
builtin_goal_policy(rpc(_, _, _), rpc, isobase).
builtin_goal_policy(promise(_, _, _), rpc, isobase).
builtin_goal_policy(promise(_, _, _, _), rpc, isobase).
builtin_goal_policy(yield(_, _), rpc, isobase).
builtin_goal_policy(yield(_, _, _), rpc, isobase).

builtin_goal_policy(server_spawn(_, _, _), server, actor).
builtin_goal_policy(server_spawn(_, _, _, _), server, actor).
builtin_goal_policy(server_request(_, _, _), server, actor).
builtin_goal_policy(server_request(_, _, _, _), server, actor).
builtin_goal_policy(server_promise(_, _, _), server, actor).
builtin_goal_policy(server_promise(_, _, _, _), server, actor).
builtin_goal_policy(server_yield(_, _), server, actor).
builtin_goal_policy(server_yield(_, _, _), server, actor).
builtin_goal_policy(server_yield(_, _, _, _), server, actor).
builtin_goal_policy(server_upgrade(_, _), server, actor).
builtin_goal_policy(server_halt(_, _), server, actor).

builtin_goal_policy(supervisor_spawn(_, _), supervisor, actor).
builtin_goal_policy(supervisor_spawn(_, _, _), supervisor, actor).
builtin_goal_policy(supervisor_spawn_child(_, _, _), supervisor, actor).
builtin_goal_policy(supervisor_terminate_child(_, _, _), supervisor, actor).
builtin_goal_policy(supervisor_delete_child(_, _, _), supervisor, actor).
builtin_goal_policy(supervisor_respawn_child(_, _, _), supervisor, actor).
builtin_goal_policy(supervisor_which_children(_, _), supervisor, actor).
builtin_goal_policy(supervisor_count_children(_, _), supervisor, actor).
builtin_goal_policy(supervisor_halt(_), supervisor, actor).

builtin_goal_policy(statechart_spawn(_), statechart, actor).
builtin_goal_policy(statechart_halt(_, _), statechart, actor).
builtin_goal_policy(statechart_halt(_, _, _), statechart, actor).
builtin_goal_policy(statechart_spawn(_, _), statechart, actor).
builtin_goal_policy(raise(_), statechart, actor).

builtin_goal_policy(parallel(_), parallel, actor).

builtin_goal_policy(node(_), node_control, actor).
builtin_goal_policy(node(_, _), node_control, actor).

builtin_goal_policy(node_setting(_, _), node_info, relation).


builtin_route_family(call, stateless_api).
builtin_route_family(toplevel_spawn, semistateful_api).
builtin_route_family(toplevel_call, semistateful_api).
builtin_route_family(toplevel_next, semistateful_api).
builtin_route_family(toplevel_poll, semistateful_api).
builtin_route_family(toplevel_stop, semistateful_api).
builtin_route_family(toplevel_abort, semistateful_api).
builtin_route_family(toplevel_respond, semistateful_api).
builtin_route_family(ws, stateful_api).


builtin_source_option_policy(load_text(_), private_db).
builtin_source_option_policy(load_list(_), private_db).
builtin_source_option_policy(load_predicates(_), private_db).
builtin_source_option_policy(load_uri(_), private_db).


%!  builtin_family_enabled(+Profile, +Family) is semidet.
builtin_family_enabled(Profile0, Family) :-
    builtin_policy_profile(Profile0, Profile),
    current_builtin_family_policy(Policy),
    builtin_family_profile_enabled(Policy, Family, Profile, true).


builtin_policy_profile(workbench, actor) :- !.
builtin_policy_profile(stateless, isobase) :- !.
builtin_policy_profile(session, isotope) :- !.
builtin_policy_profile(Profile, Profile) :-
    builtin_family_profile(Profile).


builtin_family_profile(relation).
builtin_family_profile(isobase).
builtin_family_profile(isotope).
builtin_family_profile(actor).


builtin_family_default_pair(Id, Profiles) :-
    builtin_family_spec(Id, _Label, _Description, _Predicates, EnabledProfiles),
    builtin_family_profile_dict(EnabledProfiles, Profiles).

builtin_family_profiles(Policy, Id, Profiles) :-
    (   get_dict(Id, Policy, Profiles0)
    ->  Profiles = Profiles0
    ;   builtin_family_default_pair(Id, Profiles)
    ).

builtin_family_profile_enabled(Policy, Id, Profile, Enabled) :-
    builtin_family_profiles(Policy, Id, Profiles),
    get_dict(Profile, Profiles, Enabled).

builtin_family_profile_dict(EnabledProfiles, json{
    relation:Relation,
    isobase:Isobase,
    isotope:Isotope,
    actor:Actor
}) :-
    bool_memberchk(relation, EnabledProfiles, Relation),
    bool_memberchk(isobase, EnabledProfiles, Isobase),
    bool_memberchk(isotope, EnabledProfiles, Isotope),
    bool_memberchk(actor, EnabledProfiles, Actor).

bool_memberchk(Value, List, true) :-
    memberchk(Value, List),
    !.
bool_memberchk(_, _, false).

builtin_family_id(Id, Id) :-
    atom(Id),
    builtin_family_spec(Id, _Label, _Description, _Predicates, _Profiles),
    !.
builtin_family_id(Id0, Id) :-
    string(Id0),
    !,
    atom_string(Id, Id0),
    (   builtin_family_spec(Id, _Label, _Description, _Predicates, _Profiles)
    ->  true
    ;   throw(error(domain_error(builtin_family_id, Id0),
                    context(node_builtin_policy:normalize_builtin_family_updates/2,
                            'unknown family id')))
    ).
builtin_family_id(Id0, _Id) :-
    throw(error(domain_error(builtin_family_id, Id0),
                context(node_builtin_policy:normalize_builtin_family_updates/2,
                        'unknown family id'))).


builtin_family_spec(stateless_api,
                    "Stateless API",
                    "Offer the stateless HTTP query API.",
                    ["/call"],
                    [relation, isobase, isotope, actor]).
builtin_family_spec(semistateful_api,
                    "Semi-stateful API",
                    "Offer the semi-stateful HTTP toplevel API.",
                    ["/toplevel_spawn", "/toplevel_call", "/toplevel_next",
                     "/toplevel_poll", "/toplevel_stop", "/toplevel_abort",
                     "/toplevel_respond"],
                    [isotope, actor]).
builtin_family_spec(stateful_api,
                    "Stateful API",
                    "Offer the stateful WebSocket API.",
                    ["/ws"],
                    [actor]).
builtin_family_spec(actor_lifecycle,
                    "Actor lifecycle",
                    "Create, inspect, and terminate actors.",
                    ["self/1", "spawn/1", "spawn/2", "spawn/3",
                     "actors/1", "exit/1", "exit/2", "cancel/1"],
                    [actor]).
builtin_family_spec(actor_messaging,
                    "Actor messaging",
                    "Send messages, receive selectively, and monitor actor termination.",
                    ["send/2", "send/3", "!/2", "receive/1", "receive/2",
                     "monitor/2", "demonitor/1", "demonitor/2", "flush/0"],
                    [actor]).
builtin_family_spec(actor_naming,
                    "Actor naming",
                    "Register and resolve client-scoped actor names.",
                    ["register/2", "whereis/2", "unregister/1"],
                    [actor]).
builtin_family_spec(service_registry,
                    "Service registry",
                    "Publish and resolve owner-managed node services.",
                    ["register_service/2", "whereis_service/2", "unregister_service/1"],
                    [actor]).
builtin_family_spec(private_db,
                    "Private database",
                    "Load clauses into and inspect actor-local private databases.",
                    ["load_text/1", "load_list/1", "load_predicates/1", "load_uri/1",
                     "listing/0", "listing/1"],
                    [isobase, isotope, actor]).
builtin_family_spec(dynamic_db,
                    "Dynamic database",
                    "Mutate dynamic clauses in the current private database.",
                    ["assert/1", "assert/2", "asserta/1", "asserta/2",
                     "assertz/1", "assertz/2", "retract/1",
                     "retractall/1", "abolish/1", "abolish/2"],
                    [isotope, actor]).
builtin_family_spec(actor_io,
                    "Actor I/O",
                    "Route conversational output and prompts through the surrounding session.",
                    ["output/1", "output/2", "input/2", "input/3",
                     "respond/2"],
                    [isotope, actor]).
builtin_family_spec(toplevel,
                    "Toplevel sessions",
                    "Manage explicit toplevel actors and paged solution streams.",
                    ["toplevel_spawn/1", "toplevel_spawn/2", "toplevel_call/2",
                     "toplevel_call/3", "toplevel_next/1", "toplevel_next/2",
                     "toplevel_stop/1", "toplevel_abort/1", "toplevel_halt/2"],
                    [actor]).
builtin_family_spec(rpc,
                    "Remote queries",
                    "Call remote nodes through the sequential RPC interface.",
                    ["rpc/2", "rpc/3", "promise/3", "promise/4",
                     "yield/2", "yield/3"],
                    [isobase, isotope, actor]).
builtin_family_spec(server,
                    "Generic servers",
                    "Start request-response server actors and talk to them.",
                    ["server_spawn/3", "server_spawn/4", "server_request/3",
                     "server_request/4", "server_promise/3", "server_promise/4",
                     "server_yield/2", "server_yield/3", "server_yield/4",
                     "server_upgrade/2", "server_halt/2"],
                    [actor]).
builtin_family_spec(supervisor,
                    "Supervisors",
                    "Manage supervision trees and child specifications.",
                    ["supervisor_spawn/2", "supervisor_spawn/3",
                     "supervisor_spawn_child/3",
                     "supervisor_terminate_child/3",
                     "supervisor_delete_child/3",
                     "supervisor_respawn_child/3",
                     "supervisor_which_children/2",
                     "supervisor_count_children/2",
                     "supervisor_halt/1"],
                    [actor]).
builtin_family_spec(statechart,
                    "Statechart actors",
                    "Spawn, halt, and drive statechart-based actors.",
                    ["statechart_spawn/1", "statechart_spawn/2",
                     "statechart_halt/2-3",
                     "raise/1"],
                    [actor]).
builtin_family_spec(parallel,
                    "Parallel goals",
                    "Run independent goals concurrently via worker actors.",
                    ["parallel/1"],
                    [actor]).
builtin_family_spec(node_control,
                    "Node control",
                    "Start local Web Prolog nodes from Prolog code.",
                    ["node/1", "node/2"],
                    [actor]).
builtin_family_spec(node_info,
                    "Node introspection",
                    "Expose publicly readable runtime settings of the node.",
                    ["node_setting/2"],
                    [relation, isobase, isotope, actor]).
