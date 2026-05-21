:- module(node_ws, [
    current_ws_actor_infos/1,
    admin_terminate_ws_actor/1,
    admin_terminate_ws_actor/2,
    prepare_inherited_ws_actor_spawn/3,
    commit_inherited_ws_actor_spawn/2,
    abort_inherited_ws_actor_spawn/1
]).

/** <module> WebSocket Actor Profile

Full actor capabilities for browser clients over WebSocket.

A browser connects to `/ws`, and can spawn toplevel actors and bare actors
on the server.  Actor messages (success, failure, error, output, prompt,
down, ...) are relayed back as JSON events.

Architecture per connection:

  - WS Reader Thread  — reads JSON commands, dispatches to ws_action_* handlers
  - WS Relay Thread   — reads from per-connection Queue, serializes via
                         answer_to_json/2, sends over WebSocket
  - Per-connection Queue — actor messages accumulate here
*/

:- op(800, xfx, !).
:- op(200, xfx, @).

:- use_module(library(http/websocket)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(apply)).
:- use_module(library(option)).

:- use_module(actor, [
    spawn/3,
    send/2,
    exit/2,
    respond/2,
    make_id/1,
    actor_module/2,
    op(200, xfx, @)
]).
:- use_module(toplevel_actor, [
    toplevel_spawn/2,
    toplevel_call/3,
    toplevel_next/2,
    toplevel_stop/1,
    toplevel_abort/1
]).
:- use_module(node_response, [answer_to_json/2]).
:- use_module(node_log, [
    request_client_meta/3,
    log_event/1,
    start_activity/3,
    finish_activity/3,
    finish_activity/4
]).
:- use_module(node_session, [
    rewrite_isotope_goal/2,
    load_text_into_session/2,
    remember_isotope_session_profile/2,
    remember_isotope_session_namespace/2,
    set_isotope_session_trace/2,
    cleanup_isotope_session/1,
    with_isotope_session_public_execution_profile/2
]).
:- use_module(node_call_context, [parse_call_context/9]).
:- use_module(node_auth, [
    ws_principal/2,
    principal_id/2,
    principal_from_id/2,
    principal_has_capability/2,
    require_route_access/2,
    require_ws_command_access/2,
    require_source_text_access/2,
    require_source_options_access/2
]).
:- use_module(node_client, [text_to_string/2]).
:- use_module(node_profile_policy, [profile_check_route/1, effective_profile_for_route/2]).
:- use_module(node_limits, [
    reserve_ws_actor_capacity/2,
    commit_ws_actor_capacity/2,
    forget_ws_actor_owner/1,
    release_capacity_reservation/1
]).
:- use_module(node_input_limits, [
    check_term_text_size/2,
    check_source_text_size/2,
    check_ws_frame_size/1
]).
:- use_module(node_rate_limits, [enforce_ws_command_rate_limit/2]).
:- use_module(node_runtime_state, [
    node_request_port/2,
    current_node_value/2,
    with_node_request_context/2,
    with_node_port_context/2
]).
:- use_module(node_execution_context, [
    with_public_execution_profile/2,
    with_public_execution_namespace/2,
    current_public_execution_namespace/1
]).
:- use_module(pid_utils, [
    canonical_pid/2,
    local_node_url/1,
    parse_transport_pid_or_throw/4
]).
:- use_module(node_sandbox, [
    sandbox_check_goal/2,
    sandbox_check_goal_in_module/3,
    sandbox_check_source_options/3,
    sandbox_prepare_source_options/4,
    sandbox_check_goal_with_options/4
]).
:- use_module(dollar_expansion, [
    expand_dollar_vars/3,
    capture_answer_bindings/1,
    session_bindings/2
]).

:- http_handler(root(ws), ws_handler, [spawn([]), id(ws)]).


                /*******************************
                *       CONNECTION STATE       *
                *******************************/

%   ws_actor(Queue, Pid) — track actors spawned on this connection.
:- dynamic ws_actor/2.
:- dynamic ws_actor_owner/2.
:- dynamic ws_actor_kind/2.
:- dynamic ws_connection_meta/2.


                /*******************************
                *         ENTRY POINT          *
                *******************************/

%!  ws_handler(+Request) is det.
%
%   HTTP handler that upgrades to WebSocket and starts reader + relay.
ws_handler(Request) :-
    node_request_port(Request, NodePort),
    with_node_request_context(
        Request,
        catch((   profile_check_route(ws),
                  ws_principal(Request, Principal),
                  require_route_access(Principal, ws)
              ),
              Error,
              true)
    ),
    (   var(Error)
    ->  request_client_meta(Request, Principal, ClientMeta),
        http_upgrade_to_websocket(
            ws_main(NodePort, Principal, ClientMeta),
            [],
            Request
        )
    ;   ws_profile_error_reply(Error)
    ).

%!  ws_main(+NodePort, +Principal, +ClientMeta, +WebSocket) is det.
%
%   Per-connection main: create queue, start relay, run reader loop.
ws_main(NodePort, Principal, ClientMeta, WebSocket) :-
    with_node_port_context(
        NodePort,
        (
            message_queue_create(Queue),
            make_id(NamespaceId),
            Namespace = ws_client(NamespaceId),
            put_dict(_{connection_id:NamespaceId}, ClientMeta, ConnectionMeta),
            assertz(ws_connection_meta(Queue, ConnectionMeta)),
            ignore(catch(start_activity(ws_connection, NamespaceId,
                                        ConnectionMeta), _, true)),
            thread_create(ws_relay_loop(NodePort, WebSocket, Queue), RelayThread, [
                detached(false)
            ]),
            catch(
                with_public_execution_namespace(
                    Namespace,
                    ws_read_loop(WebSocket, Queue, Principal, ConnectionMeta)
                ),
                _,
                true
            ),
            ws_cleanup(Queue, RelayThread, ConnectionMeta)
        )
    ).


                /*******************************
                *         RELAY THREAD         *
                *******************************/

%!  ws_relay_loop(+NodePort, +WebSocket, +Queue) is det.
%
%   Read actor messages from Queue, convert to JSON, send over WebSocket.
%   Terminates on '$ws_close' sentinel.
ws_relay_loop(NodePort, WebSocket, Queue) :-
    with_node_port_context(NodePort, ws_relay_loop_1(NodePort, WebSocket, Queue)).

ws_relay_loop_1(NodePort, WebSocket, Queue) :-
    catch(
        thread_get_message(Queue, Message),
        _,
        (Message = '$ws_close')
    ),
    (   Message == '$ws_close'
    ->  true
    ;   catch(capture_answer_bindings(Message), _, true),
        ws_note_message(Message),
        catch(
            ws_relay_message(WebSocket, Message),
            _,
            true
        ),
        ws_relay_loop_1(NodePort, WebSocket, Queue)
    ).

%!  ws_relay_message(+WebSocket, +Message) is det.
%
%   Convert one actor message to JSON and send.  Normalizes 3-arg down/3
%   messages to 2-arg down/2 for the external protocol.  Also normalizes
%   any compound Pid (e.g. RemoteId@NodeURL) in the resulting JSON dict to
%   a string so that atom_json_dict/3 can serialize it.
ws_relay_message(WebSocket, down(_, Pid, Reason)) :-
    !,
    ws_relay_message(WebSocket, down(Pid, Reason)).
ws_relay_message(WebSocket, Message) :-
    answer_to_json(Message, JSON),
    atom_json_dict(Text, JSON, []),
    ws_send(WebSocket, text(Text)).


                /*******************************
                *        READER THREAD         *
                *******************************/

%!  ws_read_loop(+WebSocket, +Queue, +Principal, +ConnectionMeta) is det.
%
%   Read JSON commands from the browser and dispatch.
ws_read_loop(WebSocket, Queue, Principal, ConnectionMeta) :-
    ws_receive(WebSocket, Frame, []),
    (   Frame.opcode == close
    ->  true
    ;   Frame.opcode == text
    ->  catch(
            (   check_ws_frame_size(Frame.data),
                atom_json_dict(Frame.data, Dict, []),
                ws_dispatch(Dict, Queue, Principal, ConnectionMeta)
            ),
            Error,
            ws_send_error(Queue, Error)
        ),
        ws_read_loop(WebSocket, Queue, Principal, ConnectionMeta)
    ;   ws_read_loop(WebSocket, Queue, Principal, ConnectionMeta)
    ).


                /*******************************
                *          DISPATCH            *
                *******************************/

%!  ws_dispatch(+Dict, +Queue, +Principal, +ConnectionMeta) is det.
%
%   Route a JSON command dict to the appropriate action handler.
ws_dispatch(Dict, Queue, Principal, ConnectionMeta) :-
    get_time(StartedAt),
    catch(
        (
            get_dict(command, Dict, Command0),
            atom_string(Command, Command0),
            enforce_ws_command_rate_limit(Principal, Command),
            ws_action(Command, Dict, Queue, Principal),
            get_time(FinishedAt),
            DurationMs is max(0, round((FinishedAt - StartedAt) * 1000)),
            ignore(
                catch(
                    log_ws_command_result(ConnectionMeta, Dict, Command,
                                          success, DurationMs, _{}),
                    _,
                    true
                )
            )
        ),
        Error,
        (
            get_time(FinishedAt),
            DurationMs is max(0, round((FinishedAt - StartedAt) * 1000)),
            ignore(
                catch(
                    log_ws_command_error(ConnectionMeta, Dict, Error,
                                         DurationMs),
                    _,
                    true
                )
            ),
            throw(Error)
        )
    ).

%!  ws_action(+Command, +Dict, +Queue, +Principal) is det.

ws_action(toplevel_spawn, Dict, Queue, Principal) :-
    ws_action_toplevel_spawn(Dict, Queue, Principal).
ws_action(toplevel_call, Dict, Queue, Principal) :-
    ws_action_toplevel_call(Dict, Queue, Principal).
ws_action(toplevel_next, Dict, Queue, Principal) :-
    ws_action_toplevel_next(Dict, Queue, Principal).
ws_action(toplevel_stop, Dict, Queue, Principal) :-
    ws_action_toplevel_stop(Dict, Queue, Principal).
ws_action(toplevel_abort, Dict, Queue, Principal) :-
    ws_action_toplevel_abort(Dict, Queue, Principal).
ws_action(set_trace, Dict, Queue, Principal) :-
    ws_action_set_trace(Dict, Queue, Principal).
ws_action(set_statechart_trace, Dict, Queue, Principal) :-
    ws_action_set_trace(Dict, Queue, Principal).
ws_action(toplevel_respond, Dict, Queue, Principal) :-
    ws_action_toplevel_respond(Dict, Queue, Principal).
ws_action(spawn, Dict, Queue, Principal) :-
    ws_action_spawn(Dict, Queue, Principal).
ws_action(send, Dict, Queue, Principal) :-
    ws_action_send(Dict, Queue, Principal).
ws_action(exit, Dict, Queue, Principal) :-
    ws_action_exit(Dict, Queue, Principal).


                /*******************************
                *      TOPLEVEL ACTIONS        *
                *******************************/

%!  ws_action_toplevel_spawn(+Dict, +Queue, +Principal) is det.
%
%   Spawn a new toplevel actor targeting the connection queue.
ws_action_toplevel_spawn(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_spawn),
    effective_profile_for_route(ws, EffectiveProfile),
    ws_parse_spawn_options(Dict, UserOptions),
    ws_get_spawn_trace_enabled(Dict, TraceEnabled),
    require_source_options_access(Principal, UserOptions),
    sandbox_prepare_source_options(EffectiveProfile, node_ws,
                                   UserOptions, PreparedOptions),
    ws_get_load_text_or(Dict, load_text, '', LoadText0),
    require_source_text_access(Principal, LoadText0),
    text_to_string(LoadText0, LoadText),
    reserve_ws_actor_capacity(Principal, Reservation),
    catch(
        (
            ws_build_toplevel_options(Queue, PreparedOptions, SpawnOptions),
            with_public_execution_profile(
                EffectiveProfile,
                toplevel_spawn(Pid, SpawnOptions)
            ),
            remember_isotope_session_profile(Pid, EffectiveProfile),
            (   current_public_execution_namespace(Namespace)
            ->  remember_isotope_session_namespace(Pid, Namespace)
            ;   true
            ),
            set_isotope_session_trace(Pid, TraceEnabled),
            assertz(ws_actor(Queue, Pid)),
            remember_ws_actor_metadata(Pid, Queue, Principal, session),
            commit_ws_actor_capacity(Reservation, Pid),
            catch(load_text_into_session(Pid, LoadText), LoadError, true),
            (   var(LoadError)
            ->  thread_send_message(Queue, spawned(Pid))
            ;   catch(toplevel_abort(Pid), _, true),
                thread_send_message(Queue, error(Pid, load_text_error(LoadError)))
            )
        ),
        Error,
        (
            release_capacity_reservation(Reservation),
            throw(Error)
        )
    ).

%!  ws_action_toplevel_call(+Dict, +Queue, +Principal) is det.
%
%   Submit a goal to an existing toplevel actor.
ws_action_toplevel_call(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_call),
    effective_profile_for_route(ws, EffectiveProfile),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    ws_get_term_string(Dict, goal, GoalAtom0),
    session_bindings(Pid, Bindings),
    expand_dollar_vars(GoalAtom0, Bindings, GoalAtom),
    ws_get_term_string_or(Dict, template, GoalAtom, TemplateAtom0),
    ws_get_int_or(Dict, limit, 10 000 000 000, Limit),
    ws_get_int_or(Dict, offset, 0, Offset),
    ws_get_atom_or(Dict, once, false, Once0),
    ws_get_load_text_or(Dict, load_text, '', LoadText0),
    require_source_text_access(Principal, LoadText0),
    ws_get_atom_or(Dict, format, json, Format),
    parse_call_context(GoalAtom, TemplateAtom0, Format, Once0, none,
                       Goal, Template, Once, _RequestedTimeout),
    rewrite_isotope_goal(Goal, RewrittenGoal),
    text_to_string(LoadText0, LoadText),
    catch(load_text_into_session(Pid, LoadText), LoadError, true),
    (   var(LoadError)
    ->  actor_module(Pid, Module),
        sandbox_check_goal_in_module(EffectiveProfile, Module, RewrittenGoal),
        with_isotope_session_public_execution_profile(
            Pid,
            toplevel_call(Pid, RewrittenGoal, [
                template(Template),
                offset(Offset),
                limit(Limit),
                once(Once),
                target(Queue)
            ])
        )
    ;
        thread_send_message(Queue, error(Pid, load_text_error(LoadError)))
    ).

%!  ws_action_toplevel_next(+Dict, +Queue, +Principal) is det.
ws_action_toplevel_next(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_next),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    ws_get_int_or(Dict, limit, 10 000 000 000, Limit),
    with_isotope_session_public_execution_profile(
        Pid,
        toplevel_next(Pid, [
            limit(Limit),
            target(Queue)
        ])
    ).

%!  ws_action_toplevel_stop(+Dict, +Queue, +Principal) is det.
ws_action_toplevel_stop(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_stop),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    toplevel_stop(Pid),
    thread_send_message(Queue, stop(Pid)).

%!  ws_action_toplevel_abort(+Dict, +Queue, +Principal) is det.
ws_action_toplevel_abort(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_abort),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    toplevel_abort(Pid),
    thread_send_message(Queue, abort(Pid)).

%!  ws_action_set_trace(+Dict, +Queue, +Principal) is det.
%
%   Update the per-session trace flag for this client-owned toplevel.
ws_action_set_trace(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_call),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    ws_get_set_trace_enabled(Dict, Enabled),
    set_isotope_session_trace(Pid, Enabled),
    thread_send_message(Queue, responded(Pid)).

%!  ws_action_toplevel_respond(+Dict, +Queue, +Principal) is det.
ws_action_toplevel_respond(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_respond),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    ws_get_term_string(Dict, input, InputString),
    ws_read_term(input, InputString, Input),
    with_isotope_session_public_execution_profile(Pid, respond(Pid, Input)),
    thread_send_message(Queue, responded(Pid)).


                /*******************************
                *       BARE ACTOR ACTIONS     *
                *******************************/

%!  ws_action_spawn(+Dict, +Queue, +Principal) is det.
%
%   Spawn a bare actor with its goal, targeting the connection queue.
ws_action_spawn(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, spawn),
    effective_profile_for_route(ws, EffectiveProfile),
    ws_get_term_string(Dict, goal, GoalAtom0),
    atom_string(GoalAtom, GoalAtom0),
    ws_read_term(goal, GoalAtom, Goal),
    rewrite_isotope_goal(Goal, RewrittenGoal),
    ws_parse_spawn_options(Dict, UserOptions),
    require_source_options_access(Principal, UserOptions),
    sandbox_prepare_source_options(EffectiveProfile, node_ws,
                                   UserOptions, PreparedOptions),
    sandbox_check_goal_with_options(EffectiveProfile, node_ws,
                                    RewrittenGoal, PreparedOptions),
    reserve_ws_actor_capacity(Principal, Reservation),
    catch(
        (
            ws_build_bare_options(Queue, PreparedOptions, BareOptions),
            with_public_execution_profile(
                EffectiveProfile,
                spawn(RewrittenGoal, Pid, BareOptions)
            ),
            assertz(ws_actor(Queue, Pid)),
            remember_ws_actor_metadata(Pid, Queue, Principal, actor),
            commit_ws_actor_capacity(Reservation, Pid),
            thread_send_message(Queue, spawned(Pid))
        ),
        Error,
        (
            release_capacity_reservation(Reservation),
            throw(Error)
        )
    ).

%!  ws_action_send(+Dict, +Queue, +Principal) is det.
%
%   Send an arbitrary message to a WebSocket-owned actor by pid or to an
%   owner-published named service.
ws_action_send(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, send),
    ws_get_pid(Dict, Pid),
    ws_require_send_target(Queue, Principal, Pid),
    ws_get_term_string(Dict, message, MsgString),
    ws_read_term(message, MsgString, Message),
    send(Pid, Message).

%!  ws_action_exit(+Dict, +Queue, +Principal) is det.
%
%   Exit an actor by pid with an explicit reason.
ws_action_exit(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, exit),
    ws_get_pid(Dict, Pid),
    ws_require_owned_actor(Queue, Principal, Pid),
    ws_get_term_string_or(Dict, reason, "kill", ReasonString),
    (   catch(ws_read_term(reason, ReasonString, Reason), _, fail)
    ->  true
    ;   Reason = kill
    ),
    exit(Pid, Reason).


                /*******************************
                *       SPAWN HELPERS          *
                *******************************/

%!  ws_parse_spawn_options(+Dict, -Options:list) is det.
ws_parse_spawn_options(Dict, Options) :-
    (   get_dict(options, Dict, OptionsValue)
    ->  ws_parse_options_value(OptionsValue, Options)
    ;   Options = []
    ).

ws_parse_options_value(Options, Options) :-
    is_list(Options),
    !.
ws_parse_options_value(Value, Options) :-
    atom_string(Atom, Value),
    ws_read_term(options, Atom, Options),
    must_be(list, Options).

%!  ws_build_toplevel_options(+Queue, +UserOptions, -SpawnOptions) is det.
%
%   Build spawn options for a WebSocket toplevel: session mode, target queue,
%   and no link. Shared DB and actor I/O are provided by the actor module
%   import/setup path.
ws_build_toplevel_options(Queue, UserOptions, SpawnOptions) :-
    make_id(Ref),
    exclude(ws_reserved_option, UserOptions, FilteredOptions),
    SpawnOptions = [
        session(true),
        target(Queue),
        link(false),
        monitor_target(Queue),
        monitor_ref(Ref)
        | FilteredOptions
    ].

%!  ws_build_bare_options(+Queue, +UserOptions, -SpawnOptions) is det.
ws_build_bare_options(Queue, UserOptions, SpawnOptions) :-
    make_id(Ref),
    exclude(ws_reserved_option, UserOptions, FilteredOptions),
    SpawnOptions = [
        target(Queue),
        link(false),
        monitor_target(Queue),
        monitor_ref(Ref)
        | FilteredOptions
    ].

ws_reserved_option(session(_)).
ws_reserved_option(target(_)).
ws_reserved_option(link(_)).


                /*******************************
                *        MONITOR SETUP         *
                *******************************/
                /*******************************
                *           CLEANUP            *
                *******************************/

%!  ws_cleanup(+Queue, +RelayThread, +ConnectionMeta) is det.
%
%   Tear down all state for a closed WebSocket connection.
ws_cleanup(Queue, RelayThread, ConnectionMeta) :-
    forall(
        retract(ws_actor(Queue, Pid)),
        ws_kill_actor(Pid)
    ),
    catch(thread_send_message(Queue, '$ws_close'), _, true),
    catch(thread_join(RelayThread, _), _, true),
    retractall(ws_connection_meta(Queue, _)),
    (   get_dict(connection_id, ConnectionMeta, ConnectionId)
    ->  ignore(catch(finish_activity(ws_connection, ConnectionId, disconnect),
                     _, true))
    ;   true
    ),
    catch(message_queue_destroy(Queue), _, true).

ws_require_owned_session(Queue, Principal, Pid) :-
    ws_require_owned_resource(Queue, Principal, Pid, session,
                              node_ws:ws_require_owned_session/3,
                              'pid is not owned by this WebSocket connection').

ws_require_owned_actor(Queue, Principal, Pid) :-
    ws_require_owned_resource(Queue, Principal, Pid, actor,
                              node_ws:ws_require_owned_actor/3,
                              'pid is not owned by this WebSocket connection').

ws_require_send_target(_Queue, _Principal, Name) :-
    atom(Name),
    ws_published_service_name(Name),
    !.
ws_require_send_target(_Queue, _Principal, Name) :-
    atom(Name),
    actor:whereis(Name, Pid),
    Pid \== undefined,
    !.
ws_require_send_target(Queue, Principal, Pid) :-
    ws_require_owned_actor(Queue, Principal, Pid).

ws_require_owned_resource(_Queue, Principal, _Pid, _Kind, _Context, _Message) :-
    principal_has_capability(Principal, internal_transport),
    !.
ws_require_owned_resource(Queue, _Principal, Pid, _Kind, _Context, _Message) :-
    ws_owned_actor(Queue, Pid),
    !.
ws_require_owned_resource(_Queue, Principal, Pid0, Kind, Context, Message) :-
    principal_id(Principal, PrincipalId),
    (   catch(canonical_pid(Pid0, Pid), _, fail)
    ->  true
    ;   Pid = Pid0
    ),
    ws_owned_resource_term(Kind, Pid, Resource),
    throw(error(authorization_error(PrincipalId, Resource),
                context(Context, Message))).

ws_owned_resource_term(session, Pid, session(Pid)).
ws_owned_resource_term(actor, Pid, actor(Pid)).

ws_published_service_name(Name) :-
    atom(Name),
    current_node_value(shared_db_module, SharedModule),
    current_predicate(SharedModule:service/2),
    call(SharedModule:service(Name, _)).

ws_owned_actor(Queue, Pid) :-
    ws_actor(Queue, OwnedPid0),
    (   catch(canonical_pid(OwnedPid0, OwnedPid), _, fail),
        catch(canonical_pid(Pid, CanonicalPid), _, fail)
    ->  OwnedPid =@= CanonicalPid
    ;   OwnedPid0 =@= Pid
    ),
    !.

ws_kill_actor(Pid) :-
    retractall(actor:monitor(_, Pid, _)),
    ignore(catch(finish_activity(ws_actor, Pid, connection_closed), _, true)),
    forget_ws_actor_metadata(Pid),
    forget_ws_actor_owner(Pid),
    cleanup_isotope_session(Pid),
    catch(actor:exit(Pid, kill), _, true).

ws_note_message(down(_, Pid, Reason)) :-
    !,
    ignore(catch(finish_activity(ws_actor, Pid, Reason), _, true)),
    forget_ws_actor_metadata(Pid),
    forget_ws_actor_owner(Pid).
ws_note_message(down(Pid, Reason)) :-
    !,
    ignore(catch(finish_activity(ws_actor, Pid, Reason), _, true)),
    forget_ws_actor_metadata(Pid),
    forget_ws_actor_owner(Pid).
ws_note_message(_).


%!  current_ws_actor_infos(-Infos) is det.
%
%   Enumerate active WebSocket-owned actors for the current node.
current_ws_actor_infos(Infos) :-
    findall(
        json{
            pid:PidString,
            owner:OwnerId,
            kind:Kind
        },
        current_ws_actor_info(PidString, OwnerId, Kind),
        Infos0
    ),
    sort(Infos0, Infos).


%!  prepare_inherited_ws_actor_spawn(+ParentPid, +Options, -Context) is det.
%
%   If ParentPid is a WebSocket-owned actor/session, reserve capacity for a
%   nested child spawn so in-language spawn/3 uses the same WS ownership and
%   limit accounting as direct /ws spawn commands.
prepare_inherited_ws_actor_spawn(ParentPid0, Options, Context) :-
    (   ws_inherited_spawn_parent(ParentPid0, Queue, Principal),
        ws_child_kind(Options, Kind)
    ->  reserve_ws_actor_capacity(Principal, Reservation),
        Context = inherited_ws_actor(Queue, Principal, Reservation, Kind)
    ;   Context = none
    ).


%!  commit_inherited_ws_actor_spawn(+Context, +Pid) is det.
commit_inherited_ws_actor_spawn(none, _Pid) :-
    !.
commit_inherited_ws_actor_spawn(inherited_ws_actor(Queue, Principal,
                                                   Reservation, Kind),
                                Pid) :-
    assertz(ws_actor(Queue, Pid)),
    remember_ws_actor_metadata(Pid, Queue, Principal, Kind),
    commit_ws_actor_capacity(Reservation, Pid).


%!  abort_inherited_ws_actor_spawn(+Context) is det.
abort_inherited_ws_actor_spawn(none) :-
    !.
abort_inherited_ws_actor_spawn(inherited_ws_actor(_, _, Reservation, _)) :-
    release_capacity_reservation(Reservation).


%!  admin_terminate_ws_actor(+Pid) is det.
%
%   Force-stop a WebSocket-owned actor or toplevel session.
admin_terminate_ws_actor(Pid) :-
    admin_terminate_ws_actor(Pid, kill).

%!  admin_terminate_ws_actor(+Pid, +Reason) is det.
%
%   Force-stop a WebSocket-owned actor or toplevel session and preserve the
%   client monitor path so open connections observe the termination.
admin_terminate_ws_actor(Pid, Reason) :-
    (   ws_actor_queues(Pid, Queues),
        Queues \== []
    ->  ws_forget_actor_registry(Pid),
        ws_pid_key(Pid, CanonicalPid),
        notify_ws_actor_termination(Queues, CanonicalPid, Reason),
        ignore(catch(finish_activity(ws_actor, CanonicalPid, Reason,
                                     _{admin_terminated:true}),
                     _, true)),
        forget_ws_actor_metadata(Pid),
        forget_ws_actor_owner(Pid),
        cleanup_isotope_session(Pid),
        catch(actor:exit(Pid, Reason), _, true)
    ;   throw(error(existence_error(ws_actor, Pid),
                    context(node_ws:admin_terminate_ws_actor/1,
                            'unknown or expired WebSocket actor pid')))
    ).


                /*******************************
                *        ERROR HELPERS         *
                *******************************/

%!  ws_send_error(+Queue, +Error) is det.
%
%   Send a protocol-level error to the browser.
ws_send_error(Queue, Error) :-
    thread_send_message(Queue, error(Error)).


ws_actor_activity_meta(Queue, Pid0, PrincipalId0, Kind, ActivityMeta) :-
    value_text(Pid0, Pid),
    value_text(PrincipalId0, PrincipalId),
    (   ws_connection_meta(Queue, ConnectionMeta0)
    ->  put_dict(_{pid:Pid, kind:Kind}, ConnectionMeta0, ActivityMeta)
    ;   format(string(ClientId), 'principal:~w', [PrincipalId]),
        ActivityMeta = _{
            principal:PrincipalId,
            client_id:ClientId,
            pid:Pid,
            kind:Kind
        }
    ).


log_ws_command_result(ConnectionMeta, Dict, Command0, _Status, DurationMs,
                      Extra) :-
    value_text(Command0, Command),
    ws_command_context(Dict, Command, CommandContext),
    format(string(Summary), 'ws ~w success', [Command]),
    put_dict(_{
        event_type:"request",
        transport:"ws",
        route:"ws",
        action:Command,
        status:"success",
        duration_ms:DurationMs,
        summary:Summary
    }, ConnectionMeta, Event0),
    put_dict(CommandContext, Event0, Event1),
    put_dict(Extra, Event1, Event),
    log_event(Event).


log_ws_command_error(ConnectionMeta, Dict, Error, DurationMs) :-
    (   get_dict(command, Dict, Command0)
    ->  value_text(Command0, Command)
    ;   Command = "unknown"
    ),
    ws_command_context(Dict, Command, CommandContext),
    ws_error_status(Error, Status),
    ws_error_kind_text(Error, ErrorKind),
    format(string(Summary), 'ws ~w ~w (~w)', [Command, Status, ErrorKind]),
    put_dict(_{
        event_type:"request",
        transport:"ws",
        route:"ws",
        action:Command,
        status:Status,
        error_kind:ErrorKind,
        duration_ms:DurationMs,
        summary:Summary
    }, ConnectionMeta, Event0),
    put_dict(CommandContext, Event0, Event),
    log_event(Event).


ws_command_context(Dict, _Command, Context) :-
    ws_command_context_pid(Dict, _{}, Context0),
    ws_command_context_hash(Dict, goal, goal_hash, Context0, Context1),
    ws_command_context_hash(Dict, message, message_hash, Context1, Context2),
    ws_command_context_hash(Dict, input, input_hash, Context2, Context3),
    ws_command_context_size(Dict, load_text, load_text_chars, Context3, Context4),
    ws_command_context_size(Dict, input, input_chars, Context4, Context5),
    ws_command_context_options(Dict, Context5, Context).


ws_command_context_pid(Dict, Context0, Context) :-
    (   get_dict(pid, Dict, Pid0)
    ->  value_text(Pid0, Pid),
        put_dict(_{pid:Pid}, Context0, Context)
    ;   Context = Context0
    ).


ws_command_context_hash(Dict, Field, Key, Context0, Context) :-
    (   get_dict(Field, Dict, Value0)
    ->  text_hash_string(Value0, Hash),
        put_dict(Key, Context0, Hash, Context)
    ;   Context = Context0
    ).


ws_command_context_size(Dict, Field, Key, Context0, Context) :-
    (   get_dict(Field, Dict, Value0)
    ->  text_size(Value0, Size),
        put_dict(Key, Context0, Size, Context)
    ;   Context = Context0
    ).


ws_command_context_options(Dict, Context0, Context) :-
    (   get_dict(options, Dict, Options0)
    ->  options_context_value(Options0, OptionsCount),
        put_dict(_{options_count:OptionsCount}, Context0, Context)
    ;   Context = Context0
    ).


options_context_value(Options0, OptionsCount) :-
    is_list(Options0),
    !,
    length(Options0, OptionsCount).
options_context_value(Options0, OptionsCount) :-
    text_size(Options0, OptionsCount).


remember_ws_actor_metadata(Pid0, Queue, Principal, Kind) :-
    principal_id(Principal, PrincipalId),
    ws_pid_key(Pid0, Pid),
    retractall(ws_actor_owner(Pid, _)),
    retractall(ws_actor_kind(Pid, _)),
    assertz(ws_actor_owner(Pid, PrincipalId)),
    assertz(ws_actor_kind(Pid, Kind)),
    ws_actor_activity_meta(Queue, Pid, PrincipalId, Kind, ActivityMeta),
    ignore(catch(start_activity(ws_actor, Pid, ActivityMeta), _, true)).


forget_ws_actor_metadata(Pid0) :-
    ws_pid_key(Pid0, Pid),
    retractall(ws_actor_owner(Pid, _)),
    retractall(ws_actor_kind(Pid, _)).


current_ws_actor_info(PidString, OwnerId, Kind) :-
    ws_actor(_Queue, Pid0),
    ws_pid_key(Pid0, Pid),
    ws_pid_local(Pid),
    pid_string(Pid, PidString),
    ws_actor_owner_or_default(Pid, OwnerId),
    ws_actor_kind_or_default(Pid, Kind).


ws_actor_owner_or_default(Pid, OwnerId) :-
    (   ws_actor_owner(Pid, OwnerId0)
    ->  OwnerId = OwnerId0
    ;   OwnerId = anonymous
    ).


ws_inherited_spawn_parent(ParentPid0, Queue, Principal) :-
    ws_actor(Queue, OwnedPid),
    same_ws_pid(ParentPid0, OwnedPid),
    ws_pid_key(OwnedPid, ParentPid),
    ws_actor_owner_or_default(ParentPid, OwnerId),
    principal_from_id(OwnerId, Principal),
    !.


ws_child_kind(Options, session) :-
    option(session(true), Options),
    !.
ws_child_kind(_, actor).


ws_actor_kind_or_default(Pid, Kind) :-
    (   ws_actor_kind(Pid, Kind0)
    ->  Kind = Kind0
    ;   Kind = actor
    ).


ws_known_actor(Pid0) :-
    ws_actor(_Queue, OwnedPid),
    same_ws_pid(Pid0, OwnedPid),
    !.

ws_actor_queues(Pid0, Queues) :-
    findall(
        Queue,
        (
            ws_actor(Queue, OwnedPid),
            same_ws_pid(Pid0, OwnedPid)
        ),
        Queues
    ).

notify_ws_actor_termination([], _Pid, _Reason).
notify_ws_actor_termination([Queue|Queues], Pid, Reason) :-
    retractall(actor:monitor(Queue, Pid, _)),
    catch(thread_send_message(Queue, down(Pid, Reason)), _, true),
    notify_ws_actor_termination(Queues, Pid, Reason).


ws_forget_actor_registry(Pid0) :-
    (   ws_actor(Queue, OwnedPid),
        same_ws_pid(Pid0, OwnedPid),
        retract(ws_actor(Queue, OwnedPid)),
        fail
    ;   true
    ).


same_ws_pid(Pid0, Pid1) :-
    ws_pid_key(Pid0, Left),
    ws_pid_key(Pid1, Right),
    Left =@= Right.


ws_pid_key(Pid0, Pid) :-
    (   catch(canonical_pid(Pid0, CanonicalPid), _, fail)
    ->  Pid = CanonicalPid
    ;   Pid = Pid0
    ).


ws_pid_local(Pid0) :-
    nonvar(Pid0),
    Pid0 =.. ['@', Pid, Node],
    integer(Pid),
    local_node_url(Node),
    !.
ws_pid_local(Pid) :-
    integer(Pid).


pid_string(Pid, PidString) :-
    term_string(Pid, PidString).


ws_profile_error_reply(Error) :-
    answer_to_json(error(Error), JSON),
    reply_json_dict(JSON, [status(403)]).


ws_error_status(error(authorization_error(_, _), _), "denied") :-
    !.
ws_error_status(error(profile_violation(_, _), _), "denied") :-
    !.
ws_error_status(error(rate_limit_exceeded(_, _, _, _), _), "limited") :-
    !.
ws_error_status(error(resource_limit_exceeded(_, _, _), _), "limited") :-
    !.
ws_error_status(error(timeout, _), "timeout") :-
    !.
ws_error_status(timeout, "timeout") :-
    !.
ws_error_status(_, "error").


ws_error_kind_text(error(Term, _), ErrorKind) :-
    !,
    ws_error_term_kind_text(Term, ErrorKind).
ws_error_kind_text(Term, ErrorKind) :-
    ws_error_term_kind_text(Term, ErrorKind).


ws_error_term_kind_text(Term, ErrorKind) :-
    compound(Term),
    !,
    compound_name_arity(Term, Name, _),
    value_text(Name, ErrorKind).
ws_error_term_kind_text(Term, ErrorKind) :-
    value_text(Term, ErrorKind).


text_hash_string(Text0, HashText) :-
    value_text(Text0, Text),
    term_hash(Text, Hash),
    format(string(HashText), '~16r', [Hash]).


text_size(Text0, Size) :-
    value_text(Text0, Text),
    string_length(Text, Size).


value_text(Value0, Value) :-
    (   string(Value0)
    ->  Value = Value0
    ;   atom(Value0)
    ->  atom_string(Value0, Value)
    ;   term_string(Value0, Value)
    ).


                /*******************************
                *       DICT ACCESSORS         *
                *******************************/

ws_get_pid(Dict, Pid) :-
    get_dict(pid, Dict, Pid0),
    parse_transport_pid_or_throw(Pid0, node_ws:ws_get_pid/2,
                                 'pid must be an integer, atom name, or Id@Node term', Pid).

ws_get_string(Dict, Key, Value) :-
    get_dict(Key, Dict, Value0),
    atom_string(Value, Value0).

ws_get_string_or(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0)
    ->  atom_string(Value, Value0)
    ;   Value = Default
    ).

ws_get_term_string(Dict, Key, Value) :-
    ws_get_string(Dict, Key, Value).

ws_get_term_string_or(Dict, Key, Default, Value) :-
    ws_get_string_or(Dict, Key, Default, Value).

ws_get_load_text_or(Dict, Key, Default, Value) :-
    ws_get_string_or(Dict, Key, Default, Value),
    check_source_text_size(Key, Value).

ws_get_int_or(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0),
        (   integer(Value0)
        ->  Value = Value0
        ;   atom_string(A, Value0),
            atom_number(A, Value),
            integer(Value)
        )
    ->  true
    ;   Value = Default
    ).

ws_get_atom_or(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value0)
    ->  atom_string(Value, Value0)
    ;   Value = Default
    ).

ws_get_trace_enabled(Dict, Key, Enabled) :-
    ws_get_atom_or(Dict, Key, false, Enabled0),
    ws_parse_enabled_atom(Enabled0, Enabled).

%!  ws_get_spawn_trace_enabled(+Dict, -Enabled) is det.
%
%   Read the spawn-time statechart trace flag.  Prefer the new key
%   `statechart_trace`; fall back to the legacy `trace` key during
%   transition.
ws_get_spawn_trace_enabled(Dict, Enabled) :-
    (   get_dict(statechart_trace, Dict, Raw)
    ->  ws_parse_enabled_atom(Raw, Enabled)
    ;   get_dict(trace, Dict, Raw)
    ->  ws_parse_enabled_atom(Raw, Enabled)
    ;   Enabled = false
    ).

%!  ws_get_set_trace_enabled(+Dict, -Enabled) is det.
%
%   Read the runtime statechart trace flag for `set_statechart_trace`
%   (formerly `set_trace`).  Prefer the new key `statechart_trace`; fall
%   back to the legacy `enabled` key.
ws_get_set_trace_enabled(Dict, Enabled) :-
    (   get_dict(statechart_trace, Dict, Raw)
    ->  ws_parse_enabled_atom(Raw, Enabled)
    ;   get_dict(enabled, Dict, Raw)
    ->  ws_parse_enabled_atom(Raw, Enabled)
    ;   Enabled = false
    ).

ws_parse_enabled_atom(true, true) :-
    !.
ws_parse_enabled_atom(false, false) :-
    !.
ws_parse_enabled_atom(@(true), true) :-
    !.
ws_parse_enabled_atom(@(false), false) :-
    !.
ws_parse_enabled_atom('true', true) :-
    !.
ws_parse_enabled_atom('false', false) :-
    !.
ws_parse_enabled_atom(Value0, Enabled) :-
    atom(Value0),
    !,
    atom_string(Value0, ValueString),
    string_lower(ValueString, Lower),
    ws_parse_enabled_atom(Lower, Enabled).
ws_parse_enabled_atom(Value0, Enabled) :-
    string(Value0),
    !,
    string_lower(Value0, Lower),
    atom_string(LowerAtom, Lower),
    ws_parse_enabled_atom(LowerAtom, Enabled).
ws_parse_enabled_atom(Value, _) :-
    throw(error(domain_error(boolean, Value),
                context(node_ws:ws_parse_enabled_atom/2,
                        'enabled must be true or false'))).

%!  ws_read_term(+Field, +Text, -Term) is det.
%
%   Parse websocket payload terms using node_ws operators such as @/2
%   and !/2.  The size check is enforced here so that every call site
%   is protected regardless of how the text was obtained.
ws_read_term(Field, Text, Term) :-
    check_term_text_size(Field, Text),
    read_term_from_atom(Text, Term, [module(node_ws)]).
