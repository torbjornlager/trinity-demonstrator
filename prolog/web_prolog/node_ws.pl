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

:- use_module(actor_api, [
    spawn/3,
    send/2,
    exit/2,
    monitor/2,
    demonitor/1,
    respond/2,
    make_id/1,
    actor_module/2,
    op(200, xfx, @)
]).
:- use_module(toplevel_actors, [
    toplevel_spawn/2,
    toplevel_call/3,
    toplevel_next/2,
    toplevel_stop/1,
    toplevel_abort/1,
    toplevel_halt/2
]).
:- use_module(node_response, [answer_to_json/2]).
:- use_module(node_ip_policy, [ip_access_denied/1]).
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
:- use_module(rpc, [text_to_string/2]).
:- use_module(source_utils, [normalize_load_uri_allowed_origins/2]).
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
    with_node_port_context/2,
    current_node_maintenance/1
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
:- dynamic ws_browser_connection/2.
:- dynamic ws_browser_monitor/3.

:- multifile actors:hook_send/2.
:- multifile actors:hook_stop/1.


                /*******************************
                *         ENTRY POINT          *
                *******************************/

%!  ws_handler(+Request) is det.
%
%   HTTP handler that upgrades to WebSocket and starts reader + relay.
ws_handler(Request) :-
    node_request_port(Request, NodePort),
    %  Refuse a barred client IP (block/allowlist) before anything else.
    (   ip_access_denied(Request)
    ->  reply_json_dict(json{type:"error", error:"forbidden"}, [status(403)])
    %  Refuse new ACTOR connections while draining (existing
    %  connections continue); the upgrade is declined with 503.
    ;   with_node_request_context(Request, current_node_maintenance(true))
    ->  reply_json_dict(json{type:"error",
                             error:"node draining; not accepting new connections"},
                        [status(503)])
    ;   ws_handler_open(Request, NodePort)
    ).

ws_handler_open(Request, NodePort) :-
    with_node_request_context(
        Request,
        catch((   profile_check_route(ws),
                  ws_require_allowed_origin(Request),
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


%!  ws_require_allowed_origin(+Request) is det.
%
%   Validate the WebSocket handshake Origin header against the
%   node's configured allowlist (and same-origin against the
%   request's Host).  Browsers do not apply CORS to WebSocket
%   upgrade requests, so the receiving server is responsible for
%   restricting which web pages may open a connection to /ws --
%   without this check, any page on the web can drive this node's
%   full actor surface from a visitor's browser.
%
%   Policy:
%
%     - No Origin header present: accept.  Native (non-browser)
%       clients -- including the cross-node WebSocket reader in
%       actor.pl -- do not set Origin, and locking them out is not
%       the intent of this check.
%     - Origin matches the request's Host (same-origin): accept.
%       This is the typical browser case where a portal hosted at
%       n3.example.com opens wss://n3.example.com/ws.
%     - Origin appears in the node's `ws_allowed_origins` startup
%       option (a list of "scheme://host[:port]" entries): accept.
%       Use this to allow specific cross-origin browser clients.
%     - Otherwise: reject with a permission_error.
ws_require_allowed_origin(Request) :-
    (   ws_request_origin_value(Request, Origin)
    ->  (   ws_origin_allowed(Origin, Request)
        ->  true
        ;   throw(error(permission_error(open, websocket_origin, Origin),
                        context(node_ws:ws_require_allowed_origin/1,
                                'WebSocket Origin not allowed')))
        )
    ;   true
    ).

ws_request_origin_value(Request, Origin) :-
    memberchk(origin(Origin0), Request),
    text_to_string(Origin0, Origin1),
    normalize_space(string(Origin2), Origin1),
    Origin2 \== "",
    Origin = Origin2.

ws_origin_allowed(Origin, _Request) :-
    catch(current_node_value(ws_allowed_origins, Allowed), _, fail),
    is_list(Allowed),
    member(AllowedEntry, Allowed),
    normalize_origin_text(AllowedEntry, AllowedNorm),
    normalize_origin_text(Origin, OriginNorm),
    AllowedNorm == OriginNorm,
    !.
ws_origin_allowed(Origin, Request) :-
    %  Same-origin fallback against the Host header.  Accepts both
    %  bare "host:port" and "scheme://host[:port]" Host values.
    ws_request_host_origin(Request, HostOrigin),
    normalize_origin_text(Origin, OriginNorm),
    normalize_origin_text(HostOrigin, HostNorm),
    OriginNorm == HostNorm,
    !.

ws_request_host_origin(Request, HostOrigin) :-
    memberchk(host(HostValue), Request),
    text_to_string(HostValue, HostString),
    (   host_string_has_scheme(HostString)
    ->  HostOrigin = HostString
    ;   ws_request_scheme(Request, Scheme),
        %  SWI's HTTP layer splits "Host: example.com:3060" into
        %  separate host(example.com) and port(3060) request fields,
        %  so the port must be re-attached or a browser's
        %  "http://example.com:3060" Origin can never compare equal
        %  (the demonstrator rejects same-origin browsers on any
        %  non-default port because of this; see DEVIATIONS.md).
        (   sub_string(HostString, _, _, _, ":")
        ->  format(string(HostOrigin), "~w://~w", [Scheme, HostString])
        ;   memberchk(port(Port), Request)
        ->  format(string(HostOrigin), "~w://~w:~w", [Scheme, HostString, Port])
        ;   format(string(HostOrigin), "~w://~w", [Scheme, HostString])
        )
    ).

%!  host_string_has_scheme(+HostString) is semidet.
%
%   True when HostString already begins with an http:// or https://
%   prefix.  Anchored to position 0 so a Host header like
%   `evil.com://attacker.com` is NOT mistaken for a fully-qualified
%   origin -- only a real scheme prefix at the start of the string
%   counts.  Case-insensitive per RFC 3986 scheme rules.
host_string_has_scheme(HostString) :-
    string_lower(HostString, Lower),
    (   sub_string(Lower, 0, 7, _, "http://")
    ;   sub_string(Lower, 0, 8, _, "https://")
    ),
    !.

%!  ws_request_scheme(+Request, -Scheme) is det.
%
%   Resolve the wire scheme of the request, in priority order:
%
%     1. `X-Forwarded-Proto` header set by the upstream reverse proxy
%        (the typical Caddy-fronted production path).
%     2. The HTTP connection's own `protocol(https)` if the node
%        terminates TLS directly.
%     3. Fall back to `"http"`.
%
%   The fallback makes the computed same-origin host_origin start with
%   `http://`, which will not match a browser's `https://` Origin.  If
%   the node ever serves browsers over TLS without an upstream that
%   sets X-Forwarded-Proto, the missing protocol/2 entry in the request
%   would otherwise silently drop same-origin connections.
ws_request_scheme(Request, Scheme) :-
    memberchk(x_forwarded_proto(Proto), Request),
    !,
    text_to_string(Proto, Scheme).
ws_request_scheme(Request, "https") :-
    memberchk(protocol(https), Request),
    !.
ws_request_scheme(_, "http").

normalize_origin_text(Value0, Norm) :-
    text_to_string(Value0, S1),
    normalize_space(string(S2), S1),
    (   catch(normalize_load_uri_allowed_origins([S2], [Normalized]), _, fail)
    ->  text_to_string(Normalized, Norm)
    ;   string_lower(S2, S3),
        %  Strip a trailing slash so "https://host" == "https://host/".
        (   string_concat(S4, "/", S3)
        ->  Norm = S4
        ;   Norm = S3
        )
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
            assertz(ws_browser_connection(NamespaceId, Queue)),
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
%   Convert one actor message to JSON and send.  Compound Pids
%   (e.g. RemoteId@NodeURL) in the resulting JSON dict are normalized
%   to a string so that atom_json_dict/3 can serialize them.
%
%   Note: down/3 was previously downgraded to down/2 here for the
%   external protocol.  That stripped the monitor Ref the manual
%   documents (manual.html:210/231), so the conversion was removed --
%   down/3 now passes through and is serialized by answer_to_json/2 in
%   node_response.pl with a `ref` field included.
ws_relay_message(WebSocket, Message) :-
    answer_to_json(Message, JSON),
    atom_json_dict(Text, JSON, []),
    ws_send(WebSocket, text(Text)).

%  A browser-owned actor is a connection-scoped virtual recipient.  It is
%  deliberately not a normal local pid: only the matching WebSocket relay
%  can deliver to it, and no browser can name a recipient on another
%  connection.
ws_relay_message(WebSocket, browser_message(BrowserPid, Message)) :-
    term_string(BrowserPid, BrowserPidText),
    term_string(Message, MessageText),
    atom_json_dict(Text, json{
        type:"actor_message",
        target:BrowserPidText,
        message:MessageText
    }, []),
    ws_send(WebSocket, text(Text)).

ws_relay_message(WebSocket, transport_welcome(Version)) :-
    atom_json_dict(Text, json{
        type:"transport_welcome",
        protocol:"web_prolog_browser_actor",
        version:Version
    }, []),
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
ws_action(transport_hello, Dict, Queue, _Principal) :-
    ws_action_transport_hello(Dict, Queue).
ws_action(toplevel_call, Dict, Queue, Principal) :-
    ws_action_toplevel_call(Dict, Queue, Principal).
ws_action(toplevel_next, Dict, Queue, Principal) :-
    ws_action_toplevel_next(Dict, Queue, Principal).
ws_action(toplevel_stop, Dict, Queue, Principal) :-
    ws_action_toplevel_stop(Dict, Queue, Principal).
ws_action(toplevel_halt, Dict, Queue, Principal) :-
    ws_action_toplevel_halt(Dict, Queue, Principal).
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
ws_action(monitor, Dict, Queue, Principal) :-
    ws_action_monitor(Dict, Queue, Principal).
ws_action(demonitor, Dict, Queue, Principal) :-
    ws_action_demonitor(Dict, Queue, Principal).
ws_action(exit, Dict, Queue, Principal) :-
    ws_action_exit(Dict, Queue, Principal).


                /*******************************
                *      TOPLEVEL ACTIONS        *
                *******************************/

%!  ws_action_transport_hello(+Dict, +Queue) is det.
%
%   Additive browser transport version negotiation.  Existing node clients
%   may omit it; browser runtimes use it before relying on v1-only features.
ws_action_transport_hello(Dict, Queue) :-
    ws_get_int_or(Dict, version, 1, Version),
    (   Version =:= 1
    ->  thread_send_message(Queue, transport_welcome(1))
    ;   throw(error(domain_error(browser_actor_transport_version, Version),
                    context(node_ws:ws_action_transport_hello/2,
                            'supported browser actor transport version is 1')))
    ).

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
            ;   %  The session never reached the client: tear it down
                %  fully (toplevel_abort/1 only interrupts the current
                %  goal and would leak the idle actor, its ws_actor/2 row,
                %  metadata, committed capacity, and isotope state).
                catch(ws_discard_failed_session(Pid), _, true),
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
    strip_module(RewrittenGoal, _GoalCaller, PlainGoal),
    text_to_string(LoadText0, LoadText),
    catch(load_text_into_session(Pid, LoadText), LoadError, true),
    (   var(LoadError)
    ->  actor_module(Pid, Module),
        % The session's private actor module imports the node shared DB.
        % Validate and execute the unqualified goal there; a resolved
        % user: predicate is an import artefact, not client authority to
        % invoke arbitrary modules.
        sandbox_check_goal_in_module(EffectiveProfile, Module, PlainGoal),
        with_isotope_session_public_execution_profile(
            Pid,
            toplevel_call(Pid, PlainGoal, [
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

%!  ws_action_toplevel_halt(+Dict, +Queue, +Principal) is det.
%
%   Halt an idle local toplevel session and send a `halted(Pid, Reply)`
%   event back over the connection.  Used to terminate cross-node
%   toplevel_halt/2 calls: the remote-side proxy on the calling node
%   sends a {command:toplevel_halt, pid} JSON command, this handler
%   delivers '$halt'(Self) to the local toplevel, waits for its
%   reply(_) message, then thread_send_message(Queue, halted(Pid, Reply)).
%   The relay serializes that as {type:halted, pid, reply} which the
%   calling node routes to its waiting remote_request_halt/3 caller.
ws_action_toplevel_halt(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, toplevel_halt),
    ws_get_pid(Dict, Pid),
    ws_require_owned_session(Queue, Principal, Pid),
    toplevel_halt(Pid, Reply),
    thread_send_message(Queue, halted(Pid, Reply)).

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
    ws_shared_actor_goal(RewrittenGoal, GoalModule, PlainGoal, SpawnGoal),
    ws_parse_spawn_options(Dict, UserOptions),
    require_source_options_access(Principal, UserOptions),
    % A bare WebSocket spawn runs in a private actor module.  Import the
    % node's own shared database as its start-goal module: advertised actor
    % predicates must not accidentally resolve through node_ws or user.
    sandbox_prepare_source_options(EffectiveProfile, GoalModule,
                                   UserOptions, PreparedOptions),
    sandbox_check_goal_with_options(EffectiveProfile, GoalModule,
                                    PlainGoal, PreparedOptions),
    reserve_ws_actor_capacity(Principal, Reservation),
    catch(
        (
            ws_build_bare_options(Queue, PreparedOptions, BareOptions),
            with_public_execution_profile(
                EffectiveProfile,
                spawn(SpawnGoal, Pid, BareOptions)
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

ws_shared_actor_goal(Goal0, GoalModule, PlainGoal, SpawnGoal) :-
    strip_module(Goal0, _Caller, PlainGoal),
    current_node_value(shared_db_module, GoalModule),
    SpawnGoal = GoalModule:PlainGoal.

%!  ws_action_send(+Dict, +Queue, +Principal) is det.
%
%   Send an arbitrary message to a WebSocket-owned actor by pid or to an
%   owner-published named service.
ws_action_send(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, send),
    ws_get_pid(Dict, Pid),
    ws_require_send_target(Queue, Principal, Pid),
    ws_get_term_string(Dict, message, MsgString),
    ws_read_term(message, MsgString, Message0),
    ws_rewrite_browser_sender(Dict, Queue, Message0, Message),
    send(Pid, Message).

ws_rewrite_browser_sender(Dict, Queue, Message0, Message) :-
    (   get_dict(browser_from, Dict, BrowserFrom0)
    ->  value_text(BrowserFrom0, BrowserFromText),
        atom_string(BrowserFromAtom, BrowserFromText),
        ws_read_term(browser_from, BrowserFromAtom, BrowserPid),
        browser_local_pid(BrowserPid),
        ws_browser_virtual_pid(Queue, BrowserPid, VirtualPid),
        replace_browser_sender_argument(BrowserPid, VirtualPid, Message0, Message)
    ;   Message = Message0
    ).

browser_local_pid(main).
browser_local_pid(worker_actor(Id)) :-
    integer(Id),
    Id > 0.

ws_browser_virtual_pid(Queue, BrowserPid, browser_actor(ConnectionId, BrowserPid)) :-
    ws_connection_meta(Queue, ConnectionMeta),
    get_dict(connection_id, ConnectionMeta, ConnectionId).

%!  replace_browser_sender_argument(+BrowserPid, +VirtualPid,
%!                                  +Message0, -Message) is det.
%
%   `browser_from` identifies a reply recipient, not arbitrary message
%   data.  Rewrite only a matching first argument, the established actor
%   reply-pid convention.  A recursive whole-term replacement would turn an
%   unrelated atom `main` in message data into a virtual pid.
replace_browser_sender_argument(BrowserPid, VirtualPid, Message0, Message) :-
    compound(Message0),
    compound_name_arguments(Message0, Name, [First0|Rest]),
    First0 == BrowserPid,
    !,
    compound_name_arguments(Message, Name, [VirtualPid|Rest]).
replace_browser_sender_argument(_BrowserPid, _VirtualPid, Message, Message).

actors:hook_send(browser_actor(ConnectionId, BrowserPid), Message) :-
    ws_browser_connection(ConnectionId, Queue),
    thread_send_message(Queue, browser_message(BrowserPid, Message)).

actors:hook_stop(Pid0) :-
    canonical_pid(Pid0, Pid),
    forall(retract(ws_browser_monitor(Queue, Pid, Ref)),
           (   ( actors:exit_reason(Pid0, Reason) -> true ; Reason = true ),
               thread_send_message(Queue, down(Ref, Pid, Reason))
           )).

%!  ws_action_monitor(+Dict, +Queue, +Principal) is det.
%
%   A browser monitor is represented by the connection queue itself.  The
%   actor core already sends down/3 to queue watchers on termination, and the
%   regular relay serializes that event back to this WebSocket.
ws_action_monitor(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, monitor),
    ws_get_pid(Dict, Pid),
    ws_require_owned_resource(Queue, Principal, Pid, actor,
                              node_ws:ws_action_monitor/3,
                              'pid is not owned by this WebSocket connection'),
    ws_get_term_string(Dict, ref, RefText),
    ws_read_term(ref, RefText, Ref),
    canonical_pid(Pid, CanonPid),
    assertz(ws_browser_monitor(Queue, CanonPid, Ref)).

ws_action_demonitor(Dict, Queue, Principal) :-
    require_ws_command_access(Principal, demonitor),
    ws_get_term_string(Dict, ref, RefText),
    ws_read_term(ref, RefText, Ref),
    retractall(ws_browser_monitor(Queue, _, Ref)).

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
%   Build spawn options for a WebSocket-dispatched toplevel: target
%   queue and no link.  `session/1` is NOT injected; the caller's
%   session value is preserved if supplied, and otherwise falls
%   through to toplevel_spawn/2's documented default of `false`
%   (manual.html:408).  Earlier versions hardcoded `session(true)`
%   here, silently turning every WS-routed spawn -- including
%   cross-node ones routed via /ws -- into a long-lived session
%   regardless of the caller's intent.
%
%   Shared DB and actor I/O are provided by the actor module
%   import/setup path.
ws_build_toplevel_options(Queue, UserOptions, SpawnOptions) :-
    make_id(Ref),
    exclude(ws_reserved_option, UserOptions, FilteredOptions),
    SpawnOptions = [
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

%  session/1 is intentionally NOT reserved: the user's explicit value
%  must survive into SpawnOptions so that toplevel_spawn/2 can honour
%  the documented default of `false`.  target/1 and link/1 stay
%  reserved because the WS dispatcher owns those (the queue is the
%  caller's reply channel; link is fixed false because the WS layer
%  uses its own monitor for cleanup).
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
    retractall(ws_browser_connection(_, Queue)),
    retractall(ws_browser_monitor(Queue, _, _)),
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
    actors:whereis(Name, Pid),
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
    retractall(actors:monitor(_, Pid, _)),
    ignore(catch(finish_activity(ws_actor, Pid, connection_closed), _, true)),
    forget_ws_actor_metadata(Pid),
    forget_ws_actor_owner(Pid),
    cleanup_isotope_session(Pid),
    catch(actors:exit(Pid, kill), _, true).

%!  ws_discard_failed_session(+Pid) is det.
%
%   Tear down a toplevel session whose *initial* load_text failed, before
%   it was ever handed to the client.  Reverses every side effect of the
%   spawn — the registry row, metadata, owner/committed capacity, the
%   remembered isotope-session state, any cleanup monitor, and the actor
%   thread itself — so a failed spawn leaks nothing.  Idempotent.
ws_discard_failed_session(Pid) :-
    retractall(actors:monitor(_, Pid, _)),
    ws_forget_actor_registry(Pid),
    forget_ws_actor_metadata(Pid),
    forget_ws_actor_owner(Pid),
    cleanup_isotope_session(Pid),
    catch(actors:exit(Pid, kill), _, true).

%  Canonical 3-arity down/3 (manual.html:210/231).  The 2-arity clause
%  that used to live below has been removed -- all internal producers
%  now emit down/3.
ws_note_message(down(_Ref, Pid, Reason)) :-
    !,
    ignore(catch(finish_activity(ws_actor, Pid, Reason), _, true)),
    ws_forget_actor_registry(Pid),
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
%
%   Note: also installs a monitor from Pid back to the WS Queue so that
%   when this actor exits (for ANY reason, including in-language spawns
%   like remote_actor_proxy/3 and remote_toplevel_proxy/3 that do not
%   themselves pass monitor_target), stop/2 in actor.pl sends a down/3
%   to the Queue.  That down event is what triggers ws_note_message and
%   ws_forget_actor_registry to retract this Pid's ws_actor/2 row.
%   Without this monitor, the row leaks and /admin/runtime keeps
%   listing the actor after its thread is gone (concretely observed
%   for cross-node toplevel_halt where the local proxy on the calling
%   node exits cleanly but its ws_actor record is never reaped).
commit_inherited_ws_actor_spawn(none, _Pid) :-
    !.
commit_inherited_ws_actor_spawn(inherited_ws_actor(Queue, Principal,
                                                   Reservation, Kind),
                                Pid) :-
    assertz(ws_actor(Queue, Pid)),
    remember_ws_actor_metadata(Pid, Queue, Principal, Kind),
    commit_ws_actor_capacity(Reservation, Pid),
    %  Install a WS-layer cleanup monitor; Pid itself is the sentinel
    %  Ref (same convention as monitor(true) -- see manual.html:210).
    assertz(actors:monitor(Queue, Pid, Pid)).


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
        catch(actors:exit(Pid, Reason), _, true)
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
    retractall(actors:monitor(Queue, Pid, _)),
    %  Use the canonical 3-arity down(Ref, Pid, Reason) form
    %  (manual.html:210).  No specific monitor Ref applies here -- this
    %  is the WS layer fabricating a "your actor died" notification at
    %  teardown time -- so we follow the monitor(true) convention from
    %  manual.html:210 and use the Pid itself as the sentinel Ref.
    catch(thread_send_message(Queue, down(Pid, Pid, Reason)), _, true),
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
