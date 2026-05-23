:- module(node_admin, [
    node_admin_page/1,
    node_admin_config_page/1,
    node_admin_principals_page/1,
    node_admin_runtime_page/1,
    node_admin_reclaim_page/1
]).

/** <module> Admin HTTP API

Small admin surface for inspecting and updating per-node runtime config.
These updates are in-memory only for the running node; they are not persisted
as startup configuration across node restarts.
*/

:- use_module(library(http/http_client), [http_read_data/3]).
:- use_module(library(http/http_dispatch), [http_reply_file/3]).
:- use_module(library(http/http_json)).

:- use_module(node_auth, [
    auth_mode/1,
    normalize_auth_mode/2,
    request_principal/2,
    require_admin_access/1
]).
:- use_module(node_client, [text_to_string/2, normalize_timeout/2]).
:- use_module(node_limits, [
    normalize_max_inflight_calls/2,
    normalize_max_sessions_per_principal/2,
    normalize_max_ws_actors_per_principal/2,
    current_max_inflight_calls/1,
    current_max_sessions_per_principal/1,
    current_max_ws_actors_per_principal/1,
    current_limit_usage/1
]).
:- use_module(node_input_limits, [
    normalize_max_term_text_bytes/2,
    normalize_max_load_text_bytes/2,
    normalize_max_ws_frame_bytes/2,
    normalize_max_admin_json_bytes/2,
    current_max_term_text_bytes/1,
    current_max_load_text_bytes/1,
    current_max_ws_frame_bytes/1,
    current_max_admin_json_bytes/1,
    check_admin_json_size/1
]).
:- use_module(node_rate_limits, [
    normalize_rate_window_seconds/2,
    normalize_max_call_requests_per_window/2,
    normalize_max_session_spawns_per_window/2,
    normalize_max_ws_commands_per_window/2,
    current_rate_window_seconds/1,
    current_max_call_requests_per_window/1,
    current_max_session_spawns_per_window/1,
    current_max_ws_commands_per_window/1,
    clear_principal_rate_limit_buckets/1,
    current_rate_limit_usage/1
]).
:- use_module(node_principal_policy, [
    current_principal_policies/1,
    replace_current_principal_policies/1
]).
:- use_module(node_profile_policy, [node_profile_mode/1, normalize_profile/2]).
:- use_module(node_builtin_policy, [
    current_builtin_families_json/1,
    normalize_builtin_family_updates/2
]).
:- use_module(node_response, [answer_to_json/2]).
:- use_module(node_runtime_state, [
    with_node_request_context/2,
    current_node_value/2,
    current_node_url/1,
    update_current_node_runtime/1
]).
:- use_module(node_log, [
    request_client_meta/3,
    log_event/1,
    current_activity_info/3,
    current_node_log_runtime/1
]).
:- use_module(node_sandbox, [sandbox_mode/1, normalize_sandbox_mode/2]).
:- use_module(node_session, [
    current_isotope_session_infos/1,
    admin_terminate_isotope_session/1,
    admin_terminate_isotope_session/2
]).
:- use_module(node_ws, [
    current_ws_actor_infos/1,
    admin_terminate_ws_actor/1,
    admin_terminate_ws_actor/2
]).
:- use_module(pid_utils, [parse_pid_or_throw/4]).
:- use_module(library(settings)).


%!  node_admin_page(+Request) is det.
node_admin_page(Request) :-
    node_admin_file(File),
    http_reply_file(File, [unsafe(true)], Request).


%!  node_admin_config_page(+Request) is det.
node_admin_config_page(Request) :-
    with_node_request_context(
        Request,
        node_admin_reply(
            admin_config_response(Request)
        )
    ).


%!  node_admin_principals_page(+Request) is det.
node_admin_principals_page(Request) :-
    with_node_request_context(
        Request,
        node_admin_reply(
            admin_principals_response(Request)
        )
    ).


%!  node_admin_runtime_page(+Request) is det.
node_admin_runtime_page(Request) :-
    with_node_request_context(
        Request,
        node_admin_reply(
            admin_runtime_response(Request)
        )
    ).


%!  node_admin_reclaim_page(+Request) is det.
node_admin_reclaim_page(Request) :-
    with_node_request_context(
        Request,
        node_admin_reply(
            admin_reclaim_response(Request)
        )
    ).


node_admin_reply(Goal) :-
    catch(
        (   call(Goal, JSON),
            Status = 200
        ),
        Error,
        admin_error_reply(Error, Status, JSON)
    ),
    reply_json_dict(JSON, [status(Status)]).


admin_error_reply(Error, Status, JSON) :-
    answer_to_json(error(Error), JSON),
    admin_error_status(Error, Status).


admin_error_status(error(authorization_error(_, _), _), 403) :-
    !.
admin_error_status(error(profile_violation(_, _), _), 403) :-
    !.
admin_error_status(error(domain_error(_, _), _), 400) :-
    !.
admin_error_status(error(type_error(_, _), _), 400) :-
    !.
admin_error_status(error(syntax_error(_), _), 400) :-
    !.
admin_error_status(error(request_size_exceeded(_, _, _), _), 413) :-
    !.
admin_error_status(error(rate_limit_exceeded(_, _, _, _), _), 429) :-
    !.
admin_error_status(_, 500).


node_admin_file(File) :-
    module_property(node_admin, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../web/admin.html', File).


admin_config_response(Request, JSON) :-
    require_admin_principal(Request),
    request_method(Request, Method),
    (   Method == post
    ->  read_admin_json_dict(Request, Dict),
        update_admin_config(Dict, Updates),
        ignore(catch(log_admin_config_update(Request, Updates), _, true))
    ;   Method == get
    ->  true
    ;   throw(error(domain_error(http_method, Method),
                    context(node_admin:node_admin_config_page/1,
                            'admin config endpoint only supports GET and POST')))
    ),
    current_admin_config(JSON).


admin_principals_response(Request, JSON) :-
    require_admin_principal(Request),
    request_method(Request, Method),
    (   Method == post
    ->  read_admin_json_dict(Request, Dict),
        get_dict(principals, Dict, Principals0),
        replace_current_principal_policies(Principals0),
        ignore(catch(log_admin_principals_update(Request, Principals0),
                     _, true))
    ;   Method == get
    ->  true
    ;   throw(error(domain_error(http_method, Method),
                    context(node_admin:node_admin_principals_page/1,
                            'admin principals endpoint only supports GET and POST')))
    ),
    current_principal_policies(Principals),
    JSON = json{principals:Principals}.


admin_runtime_response(Request, JSON) :-
    require_admin_principal(Request),
    request_method(Request, Method),
    (   Method == get
    ->  current_admin_runtime(JSON)
    ;   throw(error(domain_error(http_method, Method),
                    context(node_admin:node_admin_runtime_page/1,
                            'admin runtime endpoint only supports GET')))
    ).


admin_reclaim_response(Request, JSON) :-
    require_admin_principal(Request),
    request_method(Request, Method),
    (   Method == post
    ->  read_admin_json_dict(Request, Dict),
        reclaim_admin_runtime(Dict, Audit),
        ignore(catch(log_admin_reclaim(Request, Audit), _, true)),
        current_admin_runtime(JSON)
    ;   throw(error(domain_error(http_method, Method),
                    context(node_admin:node_admin_reclaim_page/1,
                            'admin reclaim endpoint only supports POST')))
    ).


require_admin_principal(Request) :-
    require_admin_access(Request).


request_method(Request, Method) :-
    memberchk(method(Method), Request).


current_admin_config(json{
    self_url:SelfURL,
    profile:Profile,
    auth:Auth,
    sandbox:Sandbox,
    timeout:Timeout,
    cache_size:CacheSize,
    max_inflight_calls:MaxInflightCalls,
    max_sessions_per_principal:MaxSessionsPerPrincipal,
    max_ws_actors_per_principal:MaxWSActorsPerPrincipal,
    max_term_text_bytes:MaxTermTextBytes,
    max_load_text_bytes:MaxLoadTextBytes,
    max_ws_frame_bytes:MaxWSFrameBytes,
    max_admin_json_bytes:MaxAdminJSONBytes,
    rate_window_seconds:RateWindowSeconds,
    max_call_requests_per_window:MaxCallRequestsPerWindow,
    max_session_spawns_per_window:MaxSessionSpawnsPerWindow,
    max_ws_commands_per_window:MaxWSCommandsPerWindow,
    builtin_families:BuiltinFamilies
}) :-
    current_node_url(SelfURL),
    node_profile_mode(Profile),
    auth_mode(Auth),
    sandbox_mode(Sandbox),
    current_runtime_timeout(Timeout),
    current_runtime_cache_size(CacheSize),
    current_max_inflight_calls(MaxInflightCalls),
    current_max_sessions_per_principal(MaxSessionsPerPrincipal),
    current_max_ws_actors_per_principal(MaxWSActorsPerPrincipal),
    current_max_term_text_bytes(MaxTermTextBytes),
    current_max_load_text_bytes(MaxLoadTextBytes),
    current_max_ws_frame_bytes(MaxWSFrameBytes),
    current_max_admin_json_bytes(MaxAdminJSONBytes),
    current_rate_window_seconds(RateWindowSeconds),
    current_max_call_requests_per_window(MaxCallRequestsPerWindow),
    current_max_session_spawns_per_window(MaxSessionSpawnsPerWindow),
    current_max_ws_commands_per_window(MaxWSCommandsPerWindow),
    current_builtin_families_json(BuiltinFamilies).


current_admin_runtime(json{
    self_url:SelfURL,
    sessions:Sessions,
    ws_connections:WSConnections,
    ws_actors:WSActors,
    limit_usage:LimitUsage,
    rate_limits:RateUsage,
    activity_summary:ActivitySummary,
    principal_activity:PrincipalActivity,
    recent_events:RecentEvents
}) :-
    current_node_url(SelfURL),
    current_isotope_session_infos(Sessions0),
    augment_runtime_entries(isotope_session, Sessions0, Sessions),
    current_ws_actor_infos(WSActors0),
    augment_runtime_entries(ws_actor, WSActors0, WSActors),
    current_limit_usage(LimitUsage),
    current_rate_limit_usage(RateUsage),
    current_node_log_runtime(LogRuntime),
    get_dict(ws_connections, LogRuntime, WSConnections),
    get_dict(activity_summary, LogRuntime, ActivitySummary),
    get_dict(principal_activity, LogRuntime, PrincipalActivity),
    get_dict(recent_events, LogRuntime, RecentEvents).


update_admin_config(Dict, Updates) :-
    admin_config_updates(Dict, Updates),
    update_current_node_runtime(Updates),
    recycle_public_execution_sessions_if_needed(Updates).


recycle_public_execution_sessions_if_needed(Updates) :-
    public_execution_surface_changed(Updates),
    !,
    recycle_public_isotope_sessions(runtime_config_changed),
    recycle_public_ws_actors(runtime_config_changed).
recycle_public_execution_sessions_if_needed(_).


public_execution_surface_changed(Updates) :-
    (   get_dict(profile, Updates, _)
    ;   get_dict(auth, Updates, _)
    ;   get_dict(sandbox, Updates, _)
    ;   get_dict(builtin_family_policy, Updates, _)
    ).


recycle_public_isotope_sessions(Reason) :-
    current_isotope_session_infos(Sessions),
    forall(
        member(Session, Sessions),
        (
            get_dict(pid, Session, Pid),
            catch(admin_terminate_isotope_session(Pid, Reason), _, true)
        )
    ).


recycle_public_ws_actors(Reason) :-
    current_ws_actor_infos(Actors),
    forall(
        member(Actor, Actors),
        (
            get_dict(pid, Actor, Pid),
            catch(admin_terminate_ws_actor(Pid, Reason), _, true)
        )
    ).


admin_config_updates(Dict, Updates) :-
    findall(Key-Value, admin_config_update_pair(Dict, Key, Value), Pairs),
    dict_pairs(Updates, _, Pairs).


admin_config_update_pair(Dict, profile, Profile) :-
    get_dict(profile, Dict, Profile0),
    normalize_profile_value(Profile0, Profile).
admin_config_update_pair(Dict, auth, Auth) :-
    get_dict(auth, Dict, Auth0),
    normalize_auth_value(Auth0, Auth).
admin_config_update_pair(Dict, sandbox, Sandbox) :-
    get_dict(sandbox, Dict, Sandbox0),
    normalize_sandbox_value(Sandbox0, Sandbox).
admin_config_update_pair(Dict, timeout, Timeout) :-
    get_dict(timeout, Dict, Timeout0),
    normalize_timeout_value(Timeout0, Timeout).
admin_config_update_pair(Dict, cache_size, CacheSize) :-
    get_dict(cache_size, Dict, CacheSize0),
    normalize_cache_size_value(CacheSize0, CacheSize).
admin_config_update_pair(Dict, max_inflight_calls, MaxInflightCalls) :-
    get_dict(max_inflight_calls, Dict, MaxInflightCalls0),
    normalize_max_inflight_calls_value(MaxInflightCalls0, MaxInflightCalls).
admin_config_update_pair(Dict, max_sessions_per_principal,
                         MaxSessionsPerPrincipal) :-
    get_dict(max_sessions_per_principal, Dict, MaxSessionsPerPrincipal0),
    normalize_max_sessions_per_principal_value(MaxSessionsPerPrincipal0,
                                               MaxSessionsPerPrincipal).
admin_config_update_pair(Dict, max_ws_actors_per_principal,
                         MaxWSActorsPerPrincipal) :-
    get_dict(max_ws_actors_per_principal, Dict, MaxWSActorsPerPrincipal0),
    normalize_max_ws_actors_per_principal_value(
        MaxWSActorsPerPrincipal0,
        MaxWSActorsPerPrincipal
    ).
admin_config_update_pair(Dict, max_term_text_bytes, MaxTermTextBytes) :-
    get_dict(max_term_text_bytes, Dict, MaxTermTextBytes0),
    normalize_max_term_text_bytes_value(MaxTermTextBytes0, MaxTermTextBytes).
admin_config_update_pair(Dict, max_load_text_bytes, MaxLoadTextBytes) :-
    get_dict(max_load_text_bytes, Dict, MaxLoadTextBytes0),
    normalize_max_load_text_bytes_value(MaxLoadTextBytes0, MaxLoadTextBytes).
admin_config_update_pair(Dict, max_ws_frame_bytes, MaxWSFrameBytes) :-
    get_dict(max_ws_frame_bytes, Dict, MaxWSFrameBytes0),
    normalize_max_ws_frame_bytes_value(MaxWSFrameBytes0, MaxWSFrameBytes).
admin_config_update_pair(Dict, max_admin_json_bytes, MaxAdminJSONBytes) :-
    get_dict(max_admin_json_bytes, Dict, MaxAdminJSONBytes0),
    normalize_max_admin_json_bytes_value(MaxAdminJSONBytes0, MaxAdminJSONBytes).
admin_config_update_pair(Dict, rate_window_seconds, RateWindowSeconds) :-
    get_dict(rate_window_seconds, Dict, RateWindowSeconds0),
    normalize_rate_window_seconds_value(RateWindowSeconds0, RateWindowSeconds).
admin_config_update_pair(Dict, max_call_requests_per_window,
                         MaxCallRequestsPerWindow) :-
    get_dict(max_call_requests_per_window, Dict, MaxCallRequestsPerWindow0),
    normalize_max_call_requests_per_window_value(
        MaxCallRequestsPerWindow0,
        MaxCallRequestsPerWindow
    ).
admin_config_update_pair(Dict, max_session_spawns_per_window,
                         MaxSessionSpawnsPerWindow) :-
    get_dict(max_session_spawns_per_window, Dict, MaxSessionSpawnsPerWindow0),
    normalize_max_session_spawns_per_window_value(
        MaxSessionSpawnsPerWindow0,
        MaxSessionSpawnsPerWindow
    ).
admin_config_update_pair(Dict, max_ws_commands_per_window,
                         MaxWSCommandsPerWindow) :-
    get_dict(max_ws_commands_per_window, Dict, MaxWSCommandsPerWindow0),
    normalize_max_ws_commands_per_window_value(
        MaxWSCommandsPerWindow0,
        MaxWSCommandsPerWindow
    ).
admin_config_update_pair(Dict, builtin_family_policy, BuiltinFamilyPolicy) :-
    get_dict(builtin_families, Dict, BuiltinFamilies0),
    normalize_builtin_family_updates(BuiltinFamilies0, BuiltinFamilyPolicy).


normalize_profile_value(Profile0, Profile) :-
    text_lower_atom(Profile0, ProfileAtom),
    normalize_profile(ProfileAtom, Profile).


normalize_auth_value(Auth0, Auth) :-
    text_lower_atom(Auth0, AuthAtom),
    normalize_auth_mode(AuthAtom, Auth).


normalize_sandbox_value(Sandbox0, Sandbox) :-
    text_lower_atom(Sandbox0, SandboxAtom),
    normalize_sandbox_mode(SandboxAtom, Sandbox).


normalize_timeout_value(Timeout0, Timeout) :-
    text_to_number(Timeout0, TimeoutNumber),
    normalize_timeout(TimeoutNumber, Timeout).


normalize_cache_size_value(CacheSize0, CacheSize) :-
    text_to_number(CacheSize0, CacheSizeNumber),
    must_be(integer, CacheSizeNumber),
    (   CacheSizeNumber > 0
    ->  CacheSize = CacheSizeNumber
    ;   throw(error(domain_error(node_cache_size, CacheSizeNumber),
                    context(node_admin:node_admin_config_page/1,
                            'cache_size must be a positive integer')))
    ).


normalize_max_inflight_calls_value(MaxInflightCalls0, MaxInflightCalls) :-
    text_to_number(MaxInflightCalls0, MaxInflightCallsNumber),
    normalize_max_inflight_calls(MaxInflightCallsNumber, MaxInflightCalls).


normalize_max_sessions_per_principal_value(MaxSessionsPerPrincipal0,
                                           MaxSessionsPerPrincipal) :-
    text_to_number(MaxSessionsPerPrincipal0, MaxSessionsPerPrincipalNumber),
    normalize_max_sessions_per_principal(MaxSessionsPerPrincipalNumber,
                                         MaxSessionsPerPrincipal).


normalize_max_ws_actors_per_principal_value(MaxWSActorsPerPrincipal0,
                                            MaxWSActorsPerPrincipal) :-
    text_to_number(MaxWSActorsPerPrincipal0, MaxWSActorsPerPrincipalNumber),
    normalize_max_ws_actors_per_principal(MaxWSActorsPerPrincipalNumber,
                                          MaxWSActorsPerPrincipal).


normalize_max_term_text_bytes_value(MaxTermTextBytes0, MaxTermTextBytes) :-
    text_to_number(MaxTermTextBytes0, MaxTermTextBytesNumber),
    normalize_max_term_text_bytes(MaxTermTextBytesNumber, MaxTermTextBytes).


normalize_max_load_text_bytes_value(MaxLoadTextBytes0, MaxLoadTextBytes) :-
    text_to_number(MaxLoadTextBytes0, MaxLoadTextBytesNumber),
    normalize_max_load_text_bytes(MaxLoadTextBytesNumber, MaxLoadTextBytes).


normalize_max_ws_frame_bytes_value(MaxWSFrameBytes0, MaxWSFrameBytes) :-
    text_to_number(MaxWSFrameBytes0, MaxWSFrameBytesNumber),
    normalize_max_ws_frame_bytes(MaxWSFrameBytesNumber, MaxWSFrameBytes).


normalize_max_admin_json_bytes_value(MaxAdminJSONBytes0, MaxAdminJSONBytes) :-
    text_to_number(MaxAdminJSONBytes0, MaxAdminJSONBytesNumber),
    normalize_max_admin_json_bytes(MaxAdminJSONBytesNumber, MaxAdminJSONBytes).


normalize_rate_window_seconds_value(RateWindowSeconds0, RateWindowSeconds) :-
    text_to_number(RateWindowSeconds0, RateWindowSecondsNumber),
    normalize_rate_window_seconds(RateWindowSecondsNumber, RateWindowSeconds).


normalize_max_call_requests_per_window_value(MaxCallRequestsPerWindow0,
                                             MaxCallRequestsPerWindow) :-
    text_to_number(MaxCallRequestsPerWindow0, MaxCallRequestsPerWindowNumber),
    normalize_max_call_requests_per_window(MaxCallRequestsPerWindowNumber,
                                           MaxCallRequestsPerWindow).


normalize_max_session_spawns_per_window_value(MaxSessionSpawnsPerWindow0,
                                              MaxSessionSpawnsPerWindow) :-
    text_to_number(MaxSessionSpawnsPerWindow0,
                   MaxSessionSpawnsPerWindowNumber),
    normalize_max_session_spawns_per_window(
        MaxSessionSpawnsPerWindowNumber,
        MaxSessionSpawnsPerWindow
    ).


normalize_max_ws_commands_per_window_value(MaxWSCommandsPerWindow0,
                                           MaxWSCommandsPerWindow) :-
    text_to_number(MaxWSCommandsPerWindow0, MaxWSCommandsPerWindowNumber),
    normalize_max_ws_commands_per_window(MaxWSCommandsPerWindowNumber,
                                         MaxWSCommandsPerWindow).


text_lower_atom(Value0, Atom) :-
    text_to_string(Value0, Value1),
    string_lower(Value1, Lower),
    atom_string(Atom, Lower).


text_to_number(Value0, Number) :-
    (   number(Value0)
    ->  Number = Value0
    ;   text_to_string(Value0, Value),
        number_string(Number, Value)
    ).


read_admin_json_dict(Request, Dict) :-
    admin_json_body_string(Request, Body),
    atom_json_dict(Body, Dict, []).


admin_json_body_string(Request, Body) :-
    current_max_admin_json_bytes(Limit),
    (   memberchk(content_length(Length), Request),
        number(Length),
        Length > Limit
    ->  throw(error(request_size_exceeded(admin_json, Length, Limit),
                    context(node_admin:read_admin_json_dict/2,
                            'admin JSON body exceeded the configured size limit')))
    ;   true
    ),
    http_read_data(Request, Body, [to(string)]),
    check_admin_json_size(Body).


reclaim_admin_runtime(Dict, Audit) :-
    get_dict(action, Dict, Action0),
    text_lower_atom(Action0, Action),
    reclaim_admin_action(Action, Dict, Audit).


reclaim_admin_action(terminate_session, Dict, Audit) :-
    get_dict(pid, Dict, Pid0),
    parse_pid_or_throw(Pid0, node_admin:node_admin_reclaim_page/1,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    admin_terminate_isotope_session(Pid),
    Audit = _{action:"terminate_session", pid:Pid,
              target_kind:"isotope_session"}.
reclaim_admin_action(terminate_ws_actor, Dict, Audit) :-
    get_dict(pid, Dict, Pid0),
    parse_pid_or_throw(Pid0, node_admin:node_admin_reclaim_page/1,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    admin_terminate_ws_actor(Pid),
    Audit = _{action:"terminate_ws_actor", pid:Pid,
              target_kind:"ws_actor"}.
reclaim_admin_action(clear_principal_rate_limits, Dict, Audit) :-
    get_dict(principal, Dict, Principal0),
    text_to_string(Principal0, PrincipalId),
    clear_principal_rate_limit_buckets(PrincipalId),
    Audit = _{action:"clear_principal_rate_limits",
              target_principal:PrincipalId}.
reclaim_admin_action(Action, _Dict, _Audit) :-
    throw(error(domain_error(admin_reclaim_action, Action),
                context(node_admin:node_admin_reclaim_page/1,
                        'unknown admin reclaim action'))).


augment_runtime_entries(Kind, Infos0, Infos) :-
    maplist(augment_runtime_entry(Kind), Infos0, Infos).


augment_runtime_entry(Kind, Info0, Info) :-
    (   get_dict(pid, Info0, Pid0),
        current_activity_info(Kind, Pid0, ActivityInfo)
    ->  runtime_activity_overlay(ActivityInfo, Overlay),
        put_dict(Overlay, Info0, Info)
    ;   Info = Info0
    ).


runtime_activity_overlay(ActivityInfo, Overlay) :-
    runtime_activity_overlay_keys(
        [started_at, active_seconds, client_id, peer, user_agent, connection_id],
        ActivityInfo,
        _{},
        Overlay
    ).


runtime_activity_overlay_keys([], _Info, Overlay, Overlay).
runtime_activity_overlay_keys([Key|Keys], Info, Overlay0, Overlay) :-
    (   get_dict(Key, Info, Value)
    ->  put_dict(Key, Overlay0, Value, Overlay1)
    ;   Overlay1 = Overlay0
    ),
    runtime_activity_overlay_keys(Keys, Info, Overlay1, Overlay).


log_admin_config_update(Request, Updates) :-
    dict_pairs(Updates, _, Pairs),
    pairs_keys(Pairs, Keys0),
    maplist(value_text, Keys0, Keys),
    atomic_list_concat(Keys, ', ', KeysText),
    format(string(Summary), 'admin config updated: ~w', [KeysText]),
    log_admin_event(
        Request,
        "admin_config_update",
        _{status:"success", updated_keys:Keys, summary:Summary}
    ).


log_admin_principals_update(Request, Principals) :-
    length(Principals, PrincipalCount),
    format(string(Summary), 'admin principals updated: ~w entries',
           [PrincipalCount]),
    log_admin_event(
        Request,
        "admin_principals_update",
        _{status:"success", principal_count:PrincipalCount, summary:Summary}
    ).


log_admin_reclaim(Request, Audit0) :-
    must_be(dict, Audit0),
    get_dict(action, Audit0, Action0),
    value_text(Action0, Action),
    admin_reclaim_summary(Audit0, Summary),
    put_dict(_{status:"success", summary:Summary}, Audit0, Audit),
    log_admin_event(Request, Action, Audit).


admin_reclaim_summary(Audit, Summary) :-
    (   get_dict(pid, Audit, Pid)
    ->  format(string(Summary), 'admin reclaim ~w: ~w',
               [Audit.action, Pid])
    ;   get_dict(target_principal, Audit, PrincipalId)
    ->  format(string(Summary), 'admin reclaim ~w: ~w',
               [Audit.action, PrincipalId])
    ;   format(string(Summary), 'admin reclaim ~w', [Audit.action])
    ).


log_admin_event(Request, Action0, Fields0) :-
    request_principal(Request, Principal),
    request_client_meta(Request, Principal, ClientMeta),
    value_text(Action0, Action),
    put_dict(_{
        event_type:"admin",
        transport:"admin",
        route:"admin",
        action:Action
    }, ClientMeta, Event0),
    put_dict(Fields0, Event0, Event),
    ignore(catch(log_event(Event), _, true)).


current_runtime_timeout(Timeout) :-
    (   current_node_value(timeout, Timeout0)
    ->  Timeout = Timeout0
    ;   setting(node:timeout, Timeout)
    ).


current_runtime_cache_size(CacheSize) :-
    (   current_node_value(cache_size, CacheSize0)
    ->  CacheSize = CacheSize0
    ;   setting(node:cache_size, CacheSize)
    ).


value_text(Value0, Value) :-
    (   string(Value0)
    ->  Value = Value0
    ;   atom(Value0)
    ->  atom_string(Value0, Value)
    ;   term_string(Value0, Value)
    ).
