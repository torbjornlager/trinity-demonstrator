:- module(node_rate_limits, [
    normalize_rate_window_seconds/2,
    normalize_max_call_requests_per_window/2,
    normalize_max_session_spawns_per_window/2,
    normalize_max_ws_commands_per_window/2,
    current_rate_window_seconds/1,
    current_max_call_requests_per_window/1,
    current_max_session_spawns_per_window/1,
    current_max_ws_commands_per_window/1,
    clear_rate_limit_scope/1,
    clear_principal_rate_limit_buckets/1,
    current_rate_limit_usage/1,
    enforce_call_request_rate_limit/1,
    enforce_session_spawn_rate_limit/1,
    enforce_ws_command_rate_limit/2
]).

/** <module> Node Request Rate Limits

Per-node, per-principal fixed-window rate limits for public execution
surfaces. These limits are orthogonal to authorization, profiles, and
sandboxing.
*/

:- use_module(library(settings)).

:- use_module(node_auth, [principal_has_capability/2, principal_id/2]).
:- use_module(node_limit_helpers, [
    current_limit_value/4,
    normalize_positive_integer_limit/5
]).
:- use_module(node_runtime_state, [current_node_port/1]).

:- setting(rate_window_seconds, integer, 60,
           'Fixed window size in seconds for request rate limits').
:- setting(max_call_requests_per_window, integer, 500,
           'Max /call requests per principal and rate window').
:- setting(max_session_spawns_per_window, integer, 100,
           'Max /toplevel_spawn requests per principal and rate window').
:- setting(max_ws_commands_per_window, integer, 1000,
           'Max WebSocket commands per principal and rate window').

:- dynamic principal_rate_bucket/5.
:- dynamic rate_scope_window/2.


%!  normalize_rate_window_seconds(+Value0, -Value) is det.
normalize_rate_window_seconds(Value0, Value) :-
    normalize_positive_integer_limit(rate_window_seconds, Value0, Value,
                                     node_rate_limits:normalize_rate_window_seconds/2,
                                     'rate_window_seconds must be a positive integer').


%!  normalize_max_call_requests_per_window(+Value0, -Value) is det.
normalize_max_call_requests_per_window(Value0, Value) :-
    normalize_positive_integer_limit(max_call_requests_per_window, Value0, Value,
                                     node_rate_limits:normalize_max_call_requests_per_window/2,
                                     'max_call_requests_per_window must be a positive integer').


%!  normalize_max_session_spawns_per_window(+Value0, -Value) is det.
normalize_max_session_spawns_per_window(Value0, Value) :-
    normalize_positive_integer_limit(max_session_spawns_per_window, Value0, Value,
                                     node_rate_limits:normalize_max_session_spawns_per_window/2,
                                     'max_session_spawns_per_window must be a positive integer').


%!  normalize_max_ws_commands_per_window(+Value0, -Value) is det.
normalize_max_ws_commands_per_window(Value0, Value) :-
    normalize_positive_integer_limit(max_ws_commands_per_window, Value0, Value,
                                     node_rate_limits:normalize_max_ws_commands_per_window/2,
                                     'max_ws_commands_per_window must be a positive integer').


%!  current_rate_window_seconds(-Seconds) is det.
current_rate_window_seconds(Seconds) :-
    current_limit_value(rate_window_seconds,
                        normalize_rate_window_seconds,
                        node_rate_limits:rate_window_seconds,
                        Seconds).


%!  current_max_call_requests_per_window(-Limit) is det.
current_max_call_requests_per_window(Limit) :-
    current_limit_value(max_call_requests_per_window,
                        normalize_max_call_requests_per_window,
                        node_rate_limits:max_call_requests_per_window,
                        Limit).


%!  current_max_session_spawns_per_window(-Limit) is det.
current_max_session_spawns_per_window(Limit) :-
    current_limit_value(max_session_spawns_per_window,
                        normalize_max_session_spawns_per_window,
                        node_rate_limits:max_session_spawns_per_window,
                        Limit).


%!  current_max_ws_commands_per_window(-Limit) is det.
current_max_ws_commands_per_window(Limit) :-
    current_limit_value(max_ws_commands_per_window,
                        normalize_max_ws_commands_per_window,
                        node_rate_limits:max_ws_commands_per_window,
                        Limit).


%!  clear_rate_limit_scope(+Scope) is det.
%
%   Drop all remembered buckets for Scope. This is used when a node is started
%   on a port that may have been reused inside the same SWI process.
clear_rate_limit_scope(Scope) :-
    retractall(principal_rate_bucket(Scope, _, _, _, _)),
    retractall(rate_scope_window(Scope, _)).


%!  clear_principal_rate_limit_buckets(+PrincipalId) is det.
%
%   Drop all remembered rate-limit counters for PrincipalId in the current
%   node scope.
clear_principal_rate_limit_buckets(PrincipalId) :-
    rate_scope(Scope),
    with_mutex(
        node_rate_limits,
        retractall(principal_rate_bucket(Scope, _, PrincipalId, _, _))
    ).


%!  current_rate_limit_usage(-Usage) is det.
%
%   Summarize current fixed-window counters for the current node scope.
current_rate_limit_usage(json{
    window_seconds:WindowSeconds,
    call_requests:CallRequests,
    session_spawns:SessionSpawns,
    ws_commands:WSCommands
}) :-
    current_rate_window_seconds(WindowSeconds),
    current_rate_limit_usage_kind(call_request, CallRequests),
    current_rate_limit_usage_kind(session_spawn_request, SessionSpawns),
    current_rate_limit_usage_kind(ws_command, WSCommands).


%!  enforce_call_request_rate_limit(+Principal) is det.
enforce_call_request_rate_limit(Principal) :-
    enforce_rate_limit(Principal, call_request).


%!  enforce_session_spawn_rate_limit(+Principal) is det.
enforce_session_spawn_rate_limit(Principal) :-
    enforce_rate_limit(Principal, session_spawn_request).


%!  enforce_ws_command_rate_limit(+Principal, +_Command) is det.
enforce_ws_command_rate_limit(Principal, _Command) :-
    enforce_rate_limit(Principal, ws_command).


enforce_rate_limit(Principal, _Kind) :-
    principal_rate_limit_exempt(Principal),
    !.
enforce_rate_limit(Principal, Kind) :-
    principal_id(Principal, PrincipalId),
    rate_scope(Scope),
    current_rate_window_seconds(WindowSeconds),
    rate_bucket_id(WindowSeconds, WindowId),
    rate_kind_spec(Kind, Resource, LimitGetter, Context, Message),
    call(LimitGetter, Limit),
    with_mutex(
        node_rate_limits,
        enforce_rate_limit_1(Scope, Kind, PrincipalId, Resource,
                             Limit, WindowSeconds, WindowId, Context, Message)
    ).


enforce_rate_limit_1(Scope, Kind, PrincipalId, Resource, Limit, WindowSeconds,
                     WindowId, Context, Message) :-
    sweep_scope_rate_buckets(Scope, WindowId),
    forget_stale_rate_buckets(Scope, Kind, PrincipalId, WindowId),
    (   retract(principal_rate_bucket(Scope, Kind, PrincipalId, WindowId, Count0))
    ->  true
    ;   Count0 = 0
    ),
    Count is Count0 + 1,
    (   Count =< Limit
    ->  assertz(principal_rate_bucket(Scope, Kind, PrincipalId, WindowId, Count))
    ;   assertz(principal_rate_bucket(Scope, Kind, PrincipalId, WindowId, Count0)),
        throw(error(rate_limit_exceeded(PrincipalId, Resource, Limit, WindowSeconds),
                    context(Context, Message)))
    ).


forget_stale_rate_buckets(Scope, Kind, PrincipalId, WindowId) :-
    (   principal_rate_bucket(Scope, Kind, PrincipalId, OtherWindowId, _),
        OtherWindowId =\= WindowId,
        retract(principal_rate_bucket(Scope, Kind, PrincipalId, OtherWindowId, _)),
        fail
    ;   true
    ).


sweep_scope_rate_buckets(Scope, WindowId) :-
    (   rate_scope_window(Scope, WindowId)
    ->  true
    ;   retractall(rate_scope_window(Scope, _)),
        forget_scope_rate_buckets(Scope, WindowId),
        assertz(rate_scope_window(Scope, WindowId))
    ).


forget_scope_rate_buckets(Scope, WindowId) :-
    (   principal_rate_bucket(Scope, _, _, OtherWindowId, _),
        OtherWindowId =\= WindowId,
        retract(principal_rate_bucket(Scope, _, _, OtherWindowId, _)),
        fail
    ;   true
    ).


principal_rate_limit_exempt(Principal) :-
    principal_has_capability(Principal, admin),
    !.
principal_rate_limit_exempt(Principal) :-
    principal_has_capability(Principal, internal_transport).


rate_scope(Scope) :-
    (   current_node_port(Port)
    ->  Scope = node_port(Port)
    ;   Scope = global
    ).


rate_bucket_id(WindowSeconds, WindowId) :-
    get_time(Now),
    WindowId is floor(Now / WindowSeconds).


rate_kind_spec(call_request, call_requests,
               current_max_call_requests_per_window,
               node_rate_limits:enforce_call_request_rate_limit/1,
               'principal exceeded the /call rate limit').
rate_kind_spec(session_spawn_request, session_spawns,
               current_max_session_spawns_per_window,
               node_rate_limits:enforce_session_spawn_rate_limit/1,
               'principal exceeded the /toplevel_spawn rate limit').
rate_kind_spec(ws_command, ws_commands,
               current_max_ws_commands_per_window,
               node_rate_limits:enforce_ws_command_rate_limit/2,
               'principal exceeded the WebSocket command rate limit').


current_rate_limit_usage_kind(Kind, Entries) :-
    rate_scope(Scope),
    current_rate_window_seconds(WindowSeconds),
    rate_bucket_id(WindowSeconds, WindowId),
    rate_kind_spec(Kind, _Resource, LimitGetter, _Context, _Message),
    call(LimitGetter, Limit),
    with_mutex(
        node_rate_limits,
        current_rate_limit_usage_kind_1(Scope, Kind, WindowId, Limit, Entries)
    ).


current_rate_limit_usage_kind_1(Scope, Kind, WindowId, Limit, Entries) :-
    sweep_scope_rate_buckets(Scope, WindowId),
    findall(
        json{
            principal:PrincipalId,
            count:Count,
            limit:Limit,
            window_id:WindowId
        },
        principal_rate_bucket(Scope, Kind, PrincipalId, WindowId, Count),
        Entries0
    ),
    predsort(principal_json_compare, Entries0, Entries).


principal_json_compare(Order, Left, Right) :-
    compare(Order, Left.principal, Right.principal).
