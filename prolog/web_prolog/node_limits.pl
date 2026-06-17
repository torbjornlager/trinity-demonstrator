:- module(node_limits, [
    normalize_max_inflight_calls/2,
    normalize_max_sessions_per_principal/2,
    normalize_max_ws_actors_per_principal/2,
    current_max_inflight_calls/1,
    current_max_sessions_per_principal/1,
    current_max_ws_actors_per_principal/1,
    with_inflight_call_limit/2,
    reserve_isotope_session_capacity/2,
    commit_isotope_session_capacity/2,
    forget_isotope_session_owner/1,
    reserve_ws_actor_capacity/2,
    commit_ws_actor_capacity/2,
    forget_ws_actor_owner/1,
    clear_limit_scope/1,
    release_capacity_reservation/1,
    current_limit_usage/1
]).

/** <module> Node Resource Limits

Per-node, per-principal concurrency limits for stateless calls and spawned
resources. Limits are enforced independently of sandbox and authorization.
*/

:- use_module(library(aggregate)).
:- use_module(library(settings)).

:- use_module(actor_api, []).
:- use_module(node_auth, [principal_capabilities/2, principal_id/2]).
:- use_module(node_limit_helpers, [
    current_limit_value/4,
    normalize_positive_integer_limit/5
]).
:- use_module(pid_utils, [canonical_pid/2]).
:- use_module(node_runtime_state, [current_node_port/1]).

:- setting(max_inflight_calls, integer, 4,
           'Max concurrent /call requests per principal').
:- setting(max_sessions_per_principal, integer, 8,
           'Max active HTTP ISOTOPE sessions per principal').
:- setting(max_ws_actors_per_principal, integer, 16,
           'Max active WS-owned actors per principal').

:- dynamic principal_limit_reservation/5.
:- dynamic principal_limit_resource/4.

:- meta_predicate with_inflight_call_limit(+, 0).


%!  normalize_max_inflight_calls(+Value0, -Value) is det.
normalize_max_inflight_calls(Value0, Value) :-
    normalize_positive_integer_limit(max_inflight_calls, Value0, Value,
                                     node_limits:normalize_max_inflight_calls/2,
                                     'max_inflight_calls must be a positive integer').


%!  normalize_max_sessions_per_principal(+Value0, -Value) is det.
normalize_max_sessions_per_principal(Value0, Value) :-
    normalize_positive_integer_limit(max_sessions_per_principal, Value0, Value,
                                     node_limits:normalize_max_sessions_per_principal/2,
                                     'max_sessions_per_principal must be a positive integer').


%!  normalize_max_ws_actors_per_principal(+Value0, -Value) is det.
normalize_max_ws_actors_per_principal(Value0, Value) :-
    normalize_positive_integer_limit(max_ws_actors_per_principal, Value0, Value,
                                     node_limits:normalize_max_ws_actors_per_principal/2,
                                     'max_ws_actors_per_principal must be a positive integer').


%!  current_max_inflight_calls(-Limit) is det.
current_max_inflight_calls(Limit) :-
    current_limit_value(max_inflight_calls,
                        normalize_max_inflight_calls,
                        node_limits:max_inflight_calls,
                        Limit).


%!  current_max_sessions_per_principal(-Limit) is det.
current_max_sessions_per_principal(Limit) :-
    current_limit_value(max_sessions_per_principal,
                        normalize_max_sessions_per_principal,
                        node_limits:max_sessions_per_principal,
                        Limit).


%!  current_max_ws_actors_per_principal(-Limit) is det.
current_max_ws_actors_per_principal(Limit) :-
    current_limit_value(max_ws_actors_per_principal,
                        normalize_max_ws_actors_per_principal,
                        node_limits:max_ws_actors_per_principal,
                        Limit).


%!  with_inflight_call_limit(+Principal, :Goal) is det.
with_inflight_call_limit(Principal, Goal) :-
    reserve_capacity(Principal, inflight_call, Reservation),
    setup_call_cleanup(
        true,
        Goal,
        release_capacity_reservation(Reservation)
    ).


%!  reserve_isotope_session_capacity(+Principal, -Reservation) is det.
reserve_isotope_session_capacity(Principal, Reservation) :-
    reserve_capacity(Principal, isotope_session, Reservation).


%!  commit_isotope_session_capacity(+Reservation, +Pid) is det.
commit_isotope_session_capacity(Reservation, Pid) :-
    commit_reserved_capacity(Reservation, Pid).


%!  forget_isotope_session_owner(+Pid) is det.
forget_isotope_session_owner(Pid) :-
    forget_resource(isotope_session, Pid).


%!  reserve_ws_actor_capacity(+Principal, -Reservation) is det.
reserve_ws_actor_capacity(Principal, Reservation) :-
    reserve_capacity(Principal, ws_actor, Reservation).


%!  commit_ws_actor_capacity(+Reservation, +Pid) is det.
commit_ws_actor_capacity(Reservation, Pid) :-
    commit_reserved_capacity(Reservation, Pid).


%!  forget_ws_actor_owner(+Pid) is det.
forget_ws_actor_owner(Pid) :-
    forget_resource(ws_actor, Pid).


%!  release_capacity_reservation(+Reservation) is det.
release_capacity_reservation(none) :-
    !.
release_capacity_reservation(reservation(Scope, Kind, Token)) :-
    with_mutex(node_limits,
               retractall(principal_limit_reservation(Scope, Kind, _, Token, _))).


%!  clear_limit_scope(+Scope) is det.
%
%   Drop remembered reservations and owned resources for Scope. This is used
%   when a node starts on a port that may have been reused in the same SWI
%   process.
clear_limit_scope(Scope) :-
    with_mutex(
        node_limits,
        (
            retractall(principal_limit_reservation(Scope, _, _, _, _)),
            retractall(principal_limit_resource(Scope, _, _, _))
        )
    ).


%!  current_limit_usage(-Usage) is det.
%
%   Summarize current per-principal resource usage for the current node scope.
current_limit_usage(json{
    inflight_calls:InflightCalls,
    isotope_sessions:IsotopeSessions,
    ws_actors:WSActors
}) :-
    current_limit_usage_kind(inflight_call, InflightCalls),
    current_limit_usage_kind(isotope_session, IsotopeSessions),
    current_limit_usage_kind(ws_actor, WSActors).


reserve_capacity(Principal, _Kind, none) :-
    principal_limit_exempt(Principal),
    !.
reserve_capacity(Principal, Kind, reservation(Scope, Kind, Token)) :-
    principal_id(Principal, PrincipalId),
    limit_scope(Scope),
    limit_kind_spec(Kind, _SettingKey, Resource, LimitGetter, Context, Message),
    call(LimitGetter, Limit),
    with_mutex(node_limits,
               reserve_capacity_1(Scope, Kind, PrincipalId, Resource, Limit,
                                  Context, Message, Token)).


reserve_capacity_1(Scope, Kind, PrincipalId, Resource, Limit, Context, Message,
                   Token) :-
    sweep_stale_limit_entries(Scope, Kind),
    aggregate_all(count,
                  principal_limit_reservation(Scope, Kind, PrincipalId, _, _),
                  ReservationCount),
    aggregate_all(count,
                  principal_limit_resource(Scope, Kind, PrincipalId, _),
                  ResourceCount),
    Count is ReservationCount + ResourceCount,
    (   Count < Limit
    ->  next_limit_token(Token),
        current_limit_owner_thread(OwnerThreadId),
        assertz(principal_limit_reservation(Scope, Kind, PrincipalId, Token,
                                            OwnerThreadId))
    ;   throw(error(resource_limit_exceeded(PrincipalId, Resource, Limit),
                    context(Context, Message)))
    ).


commit_reserved_capacity(none, _Pid) :-
    !.
commit_reserved_capacity(reservation(Scope, Kind, Token), Pid) :-
    limit_pid_key(Pid, ResourcePid),
    with_mutex(
        node_limits,
        (   sweep_stale_limit_entries(Scope, Kind),
            retract(principal_limit_reservation(Scope, Kind, PrincipalId, Token, _))
        ->  retractall(principal_limit_resource(_, Kind, _, ResourcePid)),
            assertz(principal_limit_resource(Scope, Kind, PrincipalId, ResourcePid))
        ;   true
        )
    ).


forget_resource(Kind, Pid) :-
    with_mutex(node_limits,
               forget_resource_1(Kind, Pid)).


forget_resource_1(Kind, Pid0) :-
    (   matching_resource_pid(Kind, Pid0, StoredPid),
        retract(principal_limit_resource(_, Kind, _, StoredPid)),
        fail
    ;   true
    ).


matching_resource_pid(Kind, Pid0, StoredPid) :-
    principal_limit_resource(_, Kind, _, StoredPid),
    same_limit_pid(Pid0, StoredPid).


sweep_stale_limit_entries(Scope, Kind) :-
    forget_dead_limit_reservations(Scope, Kind),
    forget_dead_limit_resources(Scope, Kind).


forget_dead_limit_reservations(Scope, Kind) :-
    (   principal_limit_reservation(Scope, Kind, _, _, OwnerThreadId),
        stale_limit_owner_thread(OwnerThreadId),
        retract(principal_limit_reservation(Scope, Kind, _, _, OwnerThreadId)),
        fail
    ;   true
    ).


forget_dead_limit_resources(Scope, Kind) :-
    (   principal_limit_resource(Scope, Kind, _, StoredPid),
        stale_limit_resource_pid(StoredPid),
        retract(principal_limit_resource(Scope, Kind, _, StoredPid)),
        fail
    ;   true
    ).


current_limit_owner_thread(OwnerThreadId) :-
    thread_self(Thread),
    (   thread_property(Thread, id(OwnerThreadId))
    ->  true
    ;   OwnerThreadId = Thread
    ).


stale_limit_owner_thread(OwnerThreadId) :-
    \+ live_limit_thread(OwnerThreadId).


stale_limit_resource_pid(Pid) :-
    (   actors:resolve_thread(Pid, ThreadId)
    ->  \+ live_limit_thread(ThreadId)
    ;   true
    ).


live_limit_thread(main) :-
    !.
live_limit_thread(ThreadId) :-
    is_thread(ThreadId),
    thread_property(ThreadId, status(running)).


principal_limit_exempt(Principal) :-
    principal_capabilities(Principal, Capabilities),
    memberchk(internal_transport, Capabilities).


limit_scope(Scope) :-
    (   current_node_port(Port)
    ->  Scope = node_port(Port)
    ;   Scope = global
    ).


next_limit_token(Token) :-
    flag(node_limit_token, Token, Token + 1).


limit_pid_key(Pid0, Pid) :-
    (   catch(canonical_pid(Pid0, CanonicalPid), _, fail)
    ->  Pid = CanonicalPid
    ;   Pid = Pid0
    ).


same_limit_pid(Pid0, StoredPid0) :-
    limit_pid_key(Pid0, Pid),
    limit_pid_key(StoredPid0, StoredPid),
    Pid =@= StoredPid.


limit_kind_spec(inflight_call, max_inflight_calls, inflight_calls,
                current_max_inflight_calls,
                node_limits:with_inflight_call_limit/2,
                'principal exceeded the concurrent /call request limit').
limit_kind_spec(isotope_session, max_sessions_per_principal, isotope_sessions,
                current_max_sessions_per_principal,
                node_limits:reserve_isotope_session_capacity/2,
                'principal exceeded the active ISOTOPE session limit').
limit_kind_spec(ws_actor, max_ws_actors_per_principal, ws_actors,
                current_max_ws_actors_per_principal,
                node_limits:reserve_ws_actor_capacity/2,
                'principal exceeded the active WebSocket actor limit').


current_limit_usage_kind(Kind, Entries) :-
    limit_scope(Scope),
    limit_kind_spec(Kind, _SettingKey, _Resource, LimitGetter, _Context, _Message),
    call(LimitGetter, Limit),
    with_mutex(
        node_limits,
        current_limit_usage_kind_1(Scope, Kind, Limit, Entries)
    ).


current_limit_usage_kind_1(Scope, Kind, Limit, Entries) :-
    sweep_stale_limit_entries(Scope, Kind),
    (   setof(PrincipalId,
              current_limit_usage_principal(Scope, Kind, PrincipalId),
              PrincipalIds)
    ->  true
    ;   PrincipalIds = []
    ),
    findall(
        json{
            principal:PrincipalId,
            reservations:ReservationCount,
            resources:ResourceCount,
            limit:Limit
        },
        (
            member(PrincipalId, PrincipalIds),
            aggregate_all(
                count,
                principal_limit_reservation(Scope, Kind, PrincipalId, _, _),
                ReservationCount
            ),
            aggregate_all(
                count,
                principal_limit_resource(Scope, Kind, PrincipalId, _),
                ResourceCount
            )
        ),
        Entries
    ).


current_limit_usage_principal(Scope, Kind, PrincipalId) :-
    principal_limit_reservation(Scope, Kind, PrincipalId, _, _).
current_limit_usage_principal(Scope, Kind, PrincipalId) :-
    principal_limit_resource(Scope, Kind, PrincipalId, _).
