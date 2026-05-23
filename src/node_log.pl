:- module(node_log, [
    clear_log_scope/1,
    request_client_meta/3,
    log_event/1,
    start_activity/3,
    finish_activity/3,
    finish_activity/4,
    current_activity_info/3,
    current_activity_infos/2,
    current_node_log_runtime/1
]).

/** <module> Per-node Logging and Activity Summaries

Retained structured event log plus lightweight live activity tracking for
node-owner/admin observability.
*/

:- use_module(library(aggregate)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(library(settings)).

:- use_module(node_auth, [principal_id/2]).
:- use_module(node_runtime_state, [current_node_port/1, current_node_value/2]).
:- use_module(pid_utils, [canonical_pid/2]).

:- setting(log_capacity, integer, 500,
           'Maximum retained per-node log events').
:- setting(log_retention_seconds, integer, 86400,
           'Maximum age in seconds for retained per-node log events').
:- setting(log_recent_event_limit, integer, 40,
           'Maximum recent log events returned through admin runtime').

:- dynamic node_log_event/3.
:- dynamic node_log_seq/2.
:- dynamic node_log_activity/4.


%!  clear_log_scope(+Scope) is det.
%
%   Drop retained events and live activity state for Scope.
clear_log_scope(Scope) :-
    with_mutex(
        node_log,
        (
            retractall(node_log_event(Scope, _, _)),
            retractall(node_log_seq(Scope, _)),
            retractall(node_log_activity(Scope, _, _, _))
        )
    ).


%!  request_client_meta(+Request, +Principal, -Meta) is det.
%
%   Derive stable logging metadata for one HTTP request / WS upgrade request.
request_client_meta(Request, Principal, json{
    principal:PrincipalId,
    client_id:ClientId,
    peer:Peer,
    user_agent:UserAgent
}) :-
    principal_id(Principal, PrincipalId0),
    value_text(PrincipalId0, PrincipalId),
    request_peer(Request, Peer),
    request_user_agent(Request, UserAgent),
    request_client_id(PrincipalId, Peer, UserAgent, ClientId).


%!  log_event(+Event) is det.
%
%   Append one structured event to the current node's retained event log.
log_event(Event0) :-
    must_be(dict, Event0),
    log_scope(Scope),
    with_mutex(
        node_log,
        append_log_event_locked(Scope, Event0)
    ).


%!  start_activity(+Kind, +Key, +Meta) is det.
%
%   Remember a live activity and emit a matching start event.
start_activity(Kind, Key0, Meta0) :-
    must_be(atom, Kind),
    must_be(dict, Meta0),
    activity_key(Kind, Key0, Key, KeyText),
    log_scope(Scope),
    event_clock(Now, At),
    normalize_activity_meta(Meta0, Meta1),
    put_dict(_{
        key:KeyText,
        started_ts:Now,
        started_at:At
    }, Meta1, Activity),
    activity_start_event(Kind, Activity, Event),
    with_mutex(
        node_log,
        (
            retractall(node_log_activity(Scope, Kind, Key, _)),
            assertz(node_log_activity(Scope, Kind, Key, Activity)),
            append_log_event_locked(Scope, Event)
        )
    ).


%!  finish_activity(+Kind, +Key, +Reason) is det.
finish_activity(Kind, Key0, Reason) :-
    finish_activity(Kind, Key0, Reason, _{}).

%!  finish_activity(+Kind, +Key, +Reason, +Extra) is det.
%
%   End a remembered activity when present and emit a matching end event.
finish_activity(Kind, Key0, Reason0, Extra0) :-
    must_be(atom, Kind),
    must_be(dict, Extra0),
    activity_key(Kind, Key0, Key, _KeyText),
    value_text(Reason0, Reason),
    normalize_event_fields(Extra0, Extra),
    log_scope(Scope),
    with_mutex(
        node_log,
        finish_activity_locked(Scope, Kind, Key, Reason, Extra)
    ).


%!  current_activity_info(+Kind, +Key, -Info) is semidet.
%
%   Return current live activity info for Kind/Key if present.
current_activity_info(Kind, Key0, Info) :-
    must_be(atom, Kind),
    activity_key(Kind, Key0, Key, KeyText),
    log_scope(Scope),
    with_mutex(
        node_log,
        (
            prune_scope_locked(Scope),
            node_log_activity(Scope, Kind, Key, Activity),
            activity_info_dict(Kind, KeyText, Activity, Info)
        )
    ).


%!  current_activity_infos(+Kind, -Infos) is det.
%
%   Enumerate current live activities of Kind for the current node.
current_activity_infos(Kind, Infos) :-
    must_be(atom, Kind),
    log_scope(Scope),
    with_mutex(
        node_log,
        current_activity_infos_locked(Scope, Kind, Infos)
    ).


%!  current_node_log_runtime(-JSON) is det.
%
%   Summarize the retained log plus current live activities for admin runtime.
current_node_log_runtime(json{
    ws_connections:WSConnections,
    activity_summary:ActivitySummary,
    principal_activity:PrincipalActivity,
    recent_events:RecentEvents
}) :-
    log_scope(Scope),
    with_mutex(
        node_log,
        (
            prune_scope_locked(Scope),
            current_activity_infos_locked(Scope, ws_connection, WSConnections),
            current_activity_summary_locked(Scope, ActivitySummary),
            current_principal_activity_locked(Scope, PrincipalActivity),
            current_recent_events_locked(Scope, RecentEvents)
        )
    ).


append_log_event_locked(Scope, Event0) :-
    prune_scope_locked(Scope),
    next_log_seq_locked(Scope, Seq),
    event_clock(Now, At),
    normalize_event_fields(Event0, Event1),
    put_dict(Event1, _{
        seq:Seq,
        ts:Now,
        at:At,
        event_type:"event",
        status:"info"
    }, Event),
    assertz(node_log_event(Scope, Seq, Event)),
    enforce_capacity_locked(Scope).


finish_activity_locked(Scope, Kind, Key, Reason, Extra) :-
    (   retract(node_log_activity(Scope, Kind, Key, Activity))
    ->  event_clock(Now, At),
        get_dict(started_ts, Activity, StartedTS),
        DurationMs is max(0, round((Now - StartedTS) * 1000)),
        activity_end_event(Kind, Activity, Reason, DurationMs, At, Extra, Event),
        append_log_event_locked(Scope, Event)
    ;   true
    ).


current_activity_infos_locked(Scope, Kind, Infos) :-
    prune_scope_locked(Scope),
    findall(
        Info,
        current_activity_info_locked(Scope, Kind, Info),
        Infos
    ).


current_activity_info_locked(Scope, Kind, Info) :-
    node_log_activity(Scope, Kind, Key, Activity),
    activity_key_text(Kind, Key, KeyText),
    activity_info_dict(Kind, KeyText, Activity, Info).


current_activity_summary_locked(Scope, json{
    retention_seconds:RetentionSeconds,
    retained_events:RetainedEvents,
    oldest_event_at:OldestEventAt,
    newest_event_at:NewestEventAt,
    active_principals:ActivePrincipalCount,
    active_clients:ActiveClientCount,
    active_sessions:ActiveSessionCount,
    active_ws_connections:ActiveWSConnectionCount,
    active_ws_actors:ActiveWSActorCount,
    recent_principals:RecentPrincipalCount,
    recent_errors:RecentErrorCount
}) :-
    current_log_retention_seconds(RetentionSeconds),
    aggregate_all(count, node_log_event(Scope, _, _), RetainedEvents),
    earliest_event_at(Scope, OldestEventAt),
    latest_event_at(Scope, NewestEventAt),
    distinct_active_values(Scope, principal, ActivePrincipals),
    length(ActivePrincipals, ActivePrincipalCount),
    distinct_active_values(Scope, client_id, ActiveClients),
    length(ActiveClients, ActiveClientCount),
    active_activity_count(Scope, isotope_session, ActiveSessionCount),
    active_activity_count(Scope, ws_connection, ActiveWSConnectionCount),
    active_activity_count(Scope, ws_actor, ActiveWSActorCount),
    distinct_recent_principals(Scope, RecentPrincipals),
    length(RecentPrincipals, RecentPrincipalCount),
    recent_error_count(Scope, RecentErrorCount).


current_principal_activity_locked(Scope, PrincipalActivity) :-
    principal_activity_ids(Scope, PrincipalIds),
    findall(
        Info,
        (
            member(PrincipalId, PrincipalIds),
            principal_activity_info(Scope, PrincipalId, Info)
        ),
        PrincipalActivity
    ).


current_recent_events_locked(Scope, RecentEvents) :-
    current_log_recent_event_limit(Limit),
    findall(Event, node_log_event(Scope, _, Event), Events0),
    reverse(Events0, Events1),
    take_prefix(Limit, Events1, Events),
    maplist(public_event_dict, Events, RecentEvents).


principal_activity_ids(Scope, PrincipalIds) :-
    findall(
        PrincipalId,
        principal_activity_id(Scope, PrincipalId),
        PrincipalIds0
    ),
    sort(PrincipalIds0, PrincipalIds).


principal_activity_id(Scope, PrincipalId) :-
    node_log_activity(Scope, _, _, Activity),
    get_dict(principal, Activity, PrincipalId),
    PrincipalId \== "".
principal_activity_id(Scope, PrincipalId) :-
    node_log_event(Scope, _, Event),
    get_dict(principal, Event, PrincipalId),
    PrincipalId \== "".


principal_activity_info(Scope, PrincipalId, json{
    principal:PrincipalId,
    active_sessions:ActiveSessions,
    active_session_seconds:ActiveSessionSeconds,
    recent_session_seconds:RecentSessionSeconds,
    active_ws_connections:ActiveWSConnections,
    active_ws_connection_seconds:ActiveWSConnectionSeconds,
    recent_ws_connection_seconds:RecentWSConnectionSeconds,
    active_ws_actors:ActiveWSActors,
    active_ws_actor_seconds:ActiveWSActorSeconds,
    recent_requests:RecentRequests,
    recent_errors:RecentErrors,
    recent_last_seen:LastSeenAt
}) :-
    active_activity_principal_count(Scope, isotope_session, PrincipalId, ActiveSessions),
    active_activity_principal_seconds(Scope, isotope_session, PrincipalId, ActiveSessionSeconds),
    completed_activity_principal_seconds(Scope, isotope_session, PrincipalId, CompletedSessionSeconds),
    RecentSessionSeconds is round(ActiveSessionSeconds + CompletedSessionSeconds),
    active_activity_principal_count(Scope, ws_connection, PrincipalId, ActiveWSConnections),
    active_activity_principal_seconds(Scope, ws_connection, PrincipalId, ActiveWSConnectionSeconds),
    completed_activity_principal_seconds(Scope, ws_connection, PrincipalId, CompletedWSConnectionSeconds),
    RecentWSConnectionSeconds is round(ActiveWSConnectionSeconds + CompletedWSConnectionSeconds),
    active_activity_principal_count(Scope, ws_actor, PrincipalId, ActiveWSActors),
    active_activity_principal_seconds(Scope, ws_actor, PrincipalId, ActiveWSActorSeconds),
    aggregate_all(
        count,
        (
            node_log_event(Scope, _, Event),
            event_request_for_principal(Event, PrincipalId)
        ),
        RecentRequests
    ),
    aggregate_all(
        count,
        (
            node_log_event(Scope, _, Event),
            event_error_for_principal(Event, PrincipalId)
        ),
        RecentErrors
    ),
    principal_last_seen_at(Scope, PrincipalId, LastSeenAt).


principal_last_seen_at(Scope, PrincipalId, LastSeenAt) :-
    findall(
        Ts-At,
        principal_seen_time(Scope, PrincipalId, Ts, At),
        Seen0
    ),
    keysort(Seen0, Seen1),
    reverse(Seen1, [_-LastSeenAt|_]),
    !.
principal_last_seen_at(_, _, "").


principal_seen_time(Scope, PrincipalId, Ts, At) :-
    node_log_event(Scope, _, Event),
    get_dict(principal, Event, PrincipalId),
    get_dict(ts, Event, Ts),
    get_dict(at, Event, At).
principal_seen_time(Scope, PrincipalId, Ts, At) :-
    node_log_activity(Scope, _, _, Activity),
    get_dict(principal, Activity, PrincipalId),
    get_dict(started_ts, Activity, Ts),
    get_dict(started_at, Activity, At).


event_request_for_principal(Event, PrincipalId) :-
    get_dict(principal, Event, PrincipalId),
    get_dict(event_type, Event, "request").


event_error_for_principal(Event, PrincipalId) :-
    get_dict(principal, Event, PrincipalId),
    event_error_like(Event).


event_error_like(Event) :-
    get_dict(status, Event, Status),
    memberchk(Status, ["error", "denied", "limited", "timeout"]).


distinct_recent_principals(Scope, Principals) :-
    findall(
        PrincipalId,
        (
            node_log_event(Scope, _, Event),
            get_dict(principal, Event, PrincipalId),
            PrincipalId \== ""
        ),
        Principals0
    ),
    sort(Principals0, Principals).


distinct_active_values(Scope, Field, Values) :-
    findall(
        Value,
        (
            node_log_activity(Scope, _, _, Activity),
            get_dict(Field, Activity, Value),
            Value \== ""
        ),
        Values0
    ),
    sort(Values0, Values).


recent_error_count(Scope, Count) :-
    aggregate_all(
        count,
        (
            node_log_event(Scope, _, Event),
            event_error_like(Event)
        ),
        Count
    ).


active_activity_count(Scope, Kind, Count) :-
    aggregate_all(count, node_log_activity(Scope, Kind, _, _), Count).


active_activity_principal_count(Scope, Kind, PrincipalId, Count) :-
    aggregate_all(
        count,
        (
            node_log_activity(Scope, Kind, _, Activity),
            get_dict(principal, Activity, PrincipalId)
        ),
        Count
    ).


active_activity_principal_seconds(Scope, Kind, PrincipalId, Seconds) :-
    findall(
        ActivitySeconds,
        (
            node_log_activity(Scope, Kind, _, Activity),
            get_dict(principal, Activity, PrincipalId),
            activity_elapsed_seconds(Activity, ActivitySeconds)
        ),
        SecondsList
    ),
    sum_list(SecondsList, Seconds0),
    Seconds is round(Seconds0).


completed_activity_principal_seconds(Scope, Kind, PrincipalId, Seconds) :-
    value_text(Kind, KindText),
    findall(
        DurationSeconds,
        (
            node_log_event(Scope, _, Event),
            get_dict(event_type, Event, "activity_end"),
            get_dict(resource_kind, Event, ResourceKind),
            ResourceKind == KindText,
            get_dict(principal, Event, PrincipalId),
            get_dict(duration_ms, Event, DurationMs),
            DurationSeconds is DurationMs / 1000
        ),
        SecondsList
    ),
    sum_list(SecondsList, Seconds).


activity_elapsed_seconds(Activity, Seconds) :-
    get_dict(started_ts, Activity, StartedTS),
    get_time(Now),
    Seconds is max(0, round(Now - StartedTS)).


earliest_event_at(Scope, At) :-
    node_log_event(Scope, _, Event),
    get_dict(at, Event, At),
    !.
earliest_event_at(_, "").


latest_event_at(Scope, At) :-
    findall(Seq-EventAt,
            (
                node_log_event(Scope, Seq, Event),
                get_dict(at, Event, EventAt)
            ),
            Events0),
    keysort(Events0, Events1),
    reverse(Events1, [_-At|_]),
    !.
latest_event_at(_, "").


take_prefix(Limit, List, Prefix) :-
    take_prefix_1(Limit, List, Prefix).


take_prefix_1(Limit, _List, []) :-
    Limit =< 0,
    !.
take_prefix_1(_Limit, [], []) :-
    !.
take_prefix_1(Limit, [Item|Rest], [Item|Prefix]) :-
    NextLimit is Limit - 1,
    take_prefix_1(NextLimit, Rest, Prefix).


activity_info_dict(Kind, KeyText, Activity0, Info) :-
    drop_key(started_ts, Activity0, Activity1),
    activity_elapsed_seconds(Activity0, ActiveSeconds),
    put_dict(_{
        resource_kind:Kind,
        key:KeyText,
        active_seconds:ActiveSeconds
    }, Activity1, Info).


public_event_dict(Event0, Event) :-
    drop_key(ts, Event0, Event).


activity_start_event(Kind, Activity, Event) :-
    activity_subject_text(Kind, Subject),
    activity_summary_value(Activity, SummaryValue),
    format(string(Summary), '~w started: ~w', [Subject, SummaryValue]),
    put_dict(_{
        event_type:"activity_start",
        action:"start",
        status:"started",
        resource_kind:Kind,
        summary:Summary
    }, Activity, Event).


activity_end_event(Kind, Activity, Reason, DurationMs, At, Extra, Event) :-
    activity_subject_text(Kind, Subject),
    activity_summary_value(Activity, SummaryValue),
    format(string(Summary), '~w ended: ~w', [Subject, SummaryValue]),
    End0 = _{
        event_type:"activity_end",
        action:"end",
        status:"ended",
        resource_kind:Kind,
        ended_at:At,
        duration_ms:DurationMs,
        reason:Reason,
        summary:Summary
    },
    put_dict(Activity, End0, End1),
    put_dict(Extra, End1, Event).


activity_subject_text(isotope_session, "HTTP session").
activity_subject_text(ws_connection, "WebSocket connection").
activity_subject_text(ws_actor, "WebSocket actor").
activity_subject_text(Kind, Subject) :-
    value_text(Kind, Subject).


activity_summary_value(Activity, SummaryValue) :-
    (   get_dict(pid, Activity, Pid)
    ->  SummaryValue = Pid
    ;   get_dict(connection_id, Activity, ConnectionId)
    ->  SummaryValue = ConnectionId
    ;   get_dict(client_id, Activity, ClientId)
    ->  SummaryValue = ClientId
    ;   SummaryValue = "activity"
    ).


normalize_activity_meta(Meta0, Meta) :-
    put_dict(Meta0, _{
        principal:"anonymous",
        client_id:"",
        peer:"",
        user_agent:""
    }, Meta1),
    normalize_event_fields(Meta1, Meta).


normalize_event_fields(Dict0, Dict) :-
    TextFields = [
        principal,
        client_id,
        peer,
        user_agent,
        transport,
        route,
        action,
        status,
        resource_kind,
        pid,
        connection_id,
        error_kind,
        summary,
        reason
    ],
    foldl(normalize_text_field, TextFields, Dict0, Dict).


normalize_text_field(Key, Dict0, Dict) :-
    (   get_dict(Key, Dict0, Value0)
    ->  value_text(Value0, Value),
        put_dict(Key, Dict0, Value, Dict)
    ;   Dict = Dict0
    ).


value_text(Value0, Value) :-
    (   string(Value0)
    ->  Value = Value0
    ;   atom(Value0)
    ->  atom_string(Value0, Value)
    ;   number(Value0)
    ->  term_string(Value0, Value)
    ;   term_string(Value0, Value)
    ).


request_peer(Request, Peer) :-
    (   memberchk(x_forwarded_for(Peer0), Request)
    ->  value_text(Peer0, Peer)
    ;   memberchk('x-forwarded-for'(Peer1), Request)
    ->  value_text(Peer1, Peer)
    ;   memberchk(peer(PeerTerm), Request)
    ->  peer_term_text(PeerTerm, Peer)
    ;   Peer = ""
    ).


request_user_agent(Request, UserAgent) :-
    (   memberchk(user_agent(UserAgent0), Request)
    ->  value_text(UserAgent0, UserAgent)
    ;   memberchk('user-agent'(UserAgent1), Request)
    ->  value_text(UserAgent1, UserAgent)
    ;   UserAgent = ""
    ).


request_client_id("anonymous", Peer, UserAgent, ClientId) :-
    !,
    term_hash(Peer-UserAgent, Hash),
    format(string(ClientId), 'anon:~16r', [Hash]).
request_client_id(PrincipalId, _, _, ClientId) :-
    format(string(ClientId), 'principal:~w', [PrincipalId]).


peer_term_text(ip(A, B, C, D), Peer) :-
    !,
    format(string(Peer), '~w.~w.~w.~w', [A, B, C, D]).
peer_term_text(ip(A, B, C, D, Port), Peer) :-
    !,
    format(string(Peer), '~w.~w.~w.~w:~w', [A, B, C, D, Port]).
peer_term_text(PeerTerm, Peer) :-
    value_text(PeerTerm, Peer).


activity_key(Kind, Key0, Key, KeyText) :-
    pid_activity_kind(Kind),
    !,
    (   catch(canonical_pid(Key0, Key1), _, fail)
    ->  Key = Key1
    ;   Key = Key0
    ),
    value_text(Key, KeyText).
activity_key(_, Key0, Key, KeyText) :-
    value_text(Key0, KeyText),
    Key = KeyText.


activity_key_text(Kind, Key, KeyText) :-
    activity_key(Kind, Key, _NormalizedKey, KeyText).


pid_activity_kind(isotope_session).
pid_activity_kind(ws_actor).


log_scope(Scope) :-
    (   current_node_port(Port)
    ->  Scope = node_port(Port)
    ;   Scope = global
    ).


prune_scope_locked(Scope) :-
    current_log_retention_seconds(RetentionSeconds),
    get_time(Now),
    Cutoff is Now - RetentionSeconds,
    forget_expired_events_locked(Scope, Cutoff),
    enforce_capacity_locked(Scope).


forget_expired_events_locked(Scope, Cutoff) :-
    (   node_log_event(Scope, Seq, Event),
        get_dict(ts, Event, Ts),
        Ts < Cutoff,
        retract(node_log_event(Scope, Seq, Event)),
        fail
    ;   true
    ).


enforce_capacity_locked(Scope) :-
    current_log_capacity(Capacity),
    findall(Seq, node_log_event(Scope, Seq, _), SeqList),
    length(SeqList, Count),
    Excess is Count - Capacity,
    (   Excess > 0
    ->  sort(SeqList, SortedSeqs),
        take_prefix(Excess, SortedSeqs, DropSeqs),
        forall(
            member(Seq, DropSeqs),
            retractall(node_log_event(Scope, Seq, _))
        )
    ;   true
    ).


next_log_seq_locked(Scope, Seq) :-
    (   retract(node_log_seq(Scope, Seq0))
    ->  Seq is Seq0 + 1
    ;   Seq = 1
    ),
    assertz(node_log_seq(Scope, Seq)).


event_clock(Now, At) :-
    get_time(Now),
    format_time(string(At), '%FT%TZ', Now).


current_log_capacity(Capacity) :-
    (   current_node_value(log_capacity, Capacity0)
    ->  Capacity = Capacity0
    ;   setting(log_capacity, Capacity)
    ).


current_log_retention_seconds(RetentionSeconds) :-
    (   current_node_value(log_retention_seconds, Retention0)
    ->  RetentionSeconds = Retention0
    ;   setting(log_retention_seconds, RetentionSeconds)
    ).


current_log_recent_event_limit(Limit) :-
    (   current_node_value(log_recent_event_limit, Limit0)
    ->  Limit = Limit0
    ;   setting(log_recent_event_limit, Limit)
    ).


drop_key(Key, Dict0, Dict) :-
    (   del_dict(Key, Dict0, _, Dict)
    ->  true
    ;   Dict = Dict0
    ).
