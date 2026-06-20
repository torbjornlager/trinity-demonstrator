:- module(node,  
   [ rpc/2,                  % +URI, :Goal
     rpc/3,                  % +URI, :Goal, +Options
     promise/3,              % +URI, :Goal, -Reference
     promise/4,              % +URI, :Goal, -Reference, +Options
     yield/2,                % +Reference, ?Message
     yield/3,                % +Reference, ?Message, +Options
     node/1,                 % +Port
     node/2                  % +Port, +Options
   ]).

/** <module> Web Prolog Node Controller

This module is the HTTP-facing controller for the PoC node.

It implements three closely related layers:

  1.  Client-side helpers (`rpc/2-3`, `promise/3-4`, `yield/2-3`) for calling
      another node over the stateless `/call` API.
  2.  Stateless node endpoints (ISOBASE behavior) via `/call`.
  3.  Semi-stateful session endpoints (ISOTOPE behavior) built on top of
      toplevel actors and per-session message queues.

Design notes:

  - The stateless `/call` endpoint can cache continuation state between
    requests using `(Goal, Template, LoadText, Once, Offset)` keys.
  - ISOTOPE endpoints keep explicit session state keyed by `Pid` and route all
    asynchronous actor events through a dedicated message queue.
  - JSON is the default format; Prolog term format is also supported for easy
    manual testing and backwards compatibility.
*/

        
                 /*******************************
                 *        NODE DEPENDENCIES      *
                 *******************************/    
                 
:- use_module(actor_api).
:- use_module(node_glue).
:- use_module(actor_io_support, [actor_io_prelude_text/1]).
:- use_module(toplevel_actors).
:- use_module(statechart_actor, []).
:- use_module(library(modules)).
:- use_module(rpc, [
    rpc/2,
    rpc/3,
    promise/3,
    promise/4,
    yield/2,
    yield/3,
    text_to_string/2,
    normalize_requested_timeout/2,
    normalize_timeout/2
]).
:- use_module(node_call_context, [
    http_parse_call_request/10,
    parse_call_context/9
]).
:- use_module(node_startup_options, [
    node_options/24
]).
:- use_module(node_version, [node_version_info/1]).
:- use_module(node_metrics, [node_metrics_text/1]).
:- use_module(source_utils, [normalize_load_uri_allowed_origins/2]).
:- use_module(node_admin, [
    node_admin_page/1,
    node_admin_config_page/1,
    node_admin_principals_page/1,
    node_admin_runtime_page/1,
    node_admin_reclaim_page/1,
    node_admin_maintenance_page/1,
    node_admin_tokens_page/1,
    node_admin_doctor_page/1,
    node_admin_posture_page/1,
    node_admin_tabler_css_page/1
]).
:- use_module(node_auth, [
    auth_mode/1,
    set_dev_auth_config/2,
    request_principal/2,
    principal_id/2,
    principal_execution_authorized/1,
    require_route_access/2,
    require_source_text_access/2
]).
:- use_module(node_profile_policy, [
    node_profile_mode/1,
    effective_profile_for_route/2,
    profile_check_route/1
]).
:- use_module(node_builtin_policy, [
    default_builtin_family_policy/1
]).
:- use_module(node_limits, [
    normalize_max_inflight_calls/2,
    normalize_max_sessions_per_principal/2,
    normalize_max_ws_actors_per_principal/2,
    clear_limit_scope/1,
    with_inflight_call_limit/2
]).
:- use_module(node_input_limits, [
    normalize_max_term_text_bytes/2,
    normalize_max_load_text_bytes/2,
    normalize_max_ws_frame_bytes/2,
    normalize_max_admin_json_bytes/2,
    check_term_text_size/2
]).
:- use_module(node_rate_limits, [
    normalize_rate_window_seconds/2,
    normalize_max_call_requests_per_window/2,
    normalize_max_session_spawns_per_window/2,
    normalize_max_ws_commands_per_window/2,
    clear_rate_limit_scope/1,
    enforce_call_request_rate_limit/1,
    enforce_session_spawn_rate_limit/1
]).
:- use_module(node_ip_policy, [ip_access_denied/1, record_ip_offense/1]).
:- use_module(node_metrics_counters, [
    note_request_admitted/0,
    note_request_error/1,
    note_ip_rejection/0,
    clear_metric_counters_scope/1
]).
:- use_module(node_relation_policy, [
    normalize_relation_patterns/2,
    relation_check_call/3
]).
:- use_module(node_principal_policy, [
    normalize_principal_policies/2,
    set_principal_policies/1
]).
:- use_module(node_runtime_state, [
    register_node_runtime/2,
    with_node_request_context/2,
    with_node_port_context/2,
    current_node_value/2,
    update_current_node_runtime/1,
    current_node_url/1,
    set_node_maintenance/2,
    current_node_maintenance/1
]).
:- use_module(node_log, [
    clear_log_scope/1,
    request_client_meta/3,
    log_event/1
]).
:- use_module(node_interaction_log, [
    log_interaction_request/2,
    log_browser_interaction_request/2
]).
:- use_module(node_log_viewer, []).
:- use_module(node_sandbox).
:- use_module(node_response, [respond_with_answer/2]).
:- use_module(node_session, [
    isotope_session_queue/2,
    require_isotope_session_owner/2,
    set_isotope_session_trace/2,
    wait_for_session_event/4,
    with_isotope_session_public_execution_profile/2
]).
:- use_module(node_isotope_controller, [
    isotope_spawn_event/5,
    isotope_call_event/11,
    isotope_respond_event/3,
    parse_isotope_wait_request/4
]).
:- use_module(node_engine, [
    compute_answer/5,
    compute_answer/6,
    compute_answer/7,
    compute_answer/8,
    cache/3
]).
:- use_module(node_execution_context, [with_public_execution_profile/2]).
:- use_module(node_ws).
:- use_module(dollar_expansion, [capture_answer_bindings/1]).
:- use_module(pid_utils, [parse_pid_or_throw/4, self_node_url/1]).

:- use_module(library(settings)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_files)).
:- use_module(library(debug)).


:- meta_predicate
    execute_and_respond(+, 1, 2),
    execute_and_respond_logged(+, +, +, +, 1, 2),
    with_request_node_context(+, 0).

                 /*******************************
                 *             NODE             *
                 *******************************/    


:- use_module(library(http/http_server)).
:- use_module(library(http/http_error)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_host), []).
:- setting(cache_size, integer, 100, 'Max number of cache entries').
:- setting(timeout,    number,  1,   'Timeout in seconds').
:- setting(sandbox,   atom,    blacklist, 'Sandbox policy: off, whitelist, or blacklist (on/demo/strict accepted as aliases for whitelist)').

:- dynamic node_shared_source/1.

/*
HTTP endpoint layout:

  Stateless (ISOBASE):
    - GET /call

  Semi-stateful (ISOTOPE):
    - POST/GET /toplevel_spawn
    - GET      /toplevel_call
    - GET      /toplevel_next
    - GET      /toplevel_poll
    - GET      /toplevel_stop
    - GET      /toplevel_abort
    - GET      /toplevel_trace
    - GET      /toplevel_respond
*/

:- http_handler(root(.), node_controller_root, []).
:- http_handler(root(call), node_controller_isobase, []).
:- http_handler(root(toplevel_spawn), node_controller_isotope_spawn, []).
:- http_handler(root(toplevel_call), node_controller_isotope_call, []).
:- http_handler(root(toplevel_next), node_controller_isotope_next, []).
:- http_handler(root(toplevel_poll), node_controller_isotope_poll, []).
:- http_handler(root(toplevel_stop), node_controller_isotope_stop, []).
:- http_handler(root(toplevel_abort), node_controller_isotope_abort, []).
:- http_handler(root(toplevel_trace), node_controller_isotope_trace, []).
:- http_handler(root(statechart_trace), node_controller_isotope_trace, []).
:- http_handler(root(toplevel_respond), node_controller_isotope_respond, []).
:- http_handler(root(portal), node_portal_page, []).
:- http_handler(root(demonstrator), node_portal_page, []).
:- http_handler(root('discovery-hub'), node_discovery_hub_page, []).
:- http_handler(root(calculator), node_calculator_page, []).
:- http_handler(root(tutorial), node_tutorial_page, []).
:- http_handler(root(manual), node_manual_page, []).
:- http_handler(root(editor_frame), node_editor_frame_page, []).
:- http_handler(root('swi_wasm_actor_worker.js'), node_swi_wasm_actor_worker_page, []).
:- http_handler(root('swipl-bundle.js'), node_swipl_bundle_page, []).
:- http_handler(root(node_info), node_info_page, []).
:- http_handler(root(healthz), node_healthz_page, []).
:- http_handler(root(readyz), node_readyz_page, []).
:- http_handler(root(version), node_version_page, []).
:- http_handler(root(metrics), node_metrics_page, []).
:- http_handler(root(examples_index), node_examples_index_page, []).
:- http_handler(root(interaction_log), node_interaction_log_page, []).
:- http_handler(root(admin), node_admin_page, []).
:- http_handler(root('admin/config'), node_admin_config_page, []).
:- http_handler(root('admin/principals'), node_admin_principals_page, []).
:- http_handler(root('admin/runtime'), node_admin_runtime_page, []).
:- http_handler(root('admin/reclaim'), node_admin_reclaim_page, []).
:- http_handler(root('admin/maintenance'), node_admin_maintenance_page, []).
:- http_handler(root('admin/tokens'), node_admin_tokens_page, []).
:- http_handler(root('admin/doctor'), node_admin_doctor_page, []).
:- http_handler(root('admin/posture'), node_admin_posture_page, []).
:- http_handler(root('admin/tabler.min.css'), node_admin_tabler_css_page, []).
:- http_handler(root(img), node_image_page, [prefix]).
:- http_handler(root(vendor), node_vendor_page, [prefix]).
:- http_handler(root(examples), node_examples_page, [prefix]).
:- http_handler(root(statecharts), node_statecharts_page, [prefix]).
:- http_handler(root(wasm), node_wasm_modules_page, [prefix]).

%!  node_controller_root(+Request) is det.
%
%   Serve node shared database source text at `/`.
node_controller_root(Request) :-
    with_request_node_context(Request,
                              node_controller_root_1).

node_controller_root_1 :-
    shared_db(Source),
    format('Content-type: text/plain; charset=UTF-8~n~n'),
    format('~s', [Source]).


with_request_node_context(Request, Goal) :-
    with_node_request_context(Request, Goal).

%!  shared_db(-Source:string) is det.
%
%   Current node shared database source text.
shared_db(Source) :-
    (   current_node_value(shared_db_source, Source0)
    ->  Source = Source0
    ;   node_shared_source(Source0)
    ->  Source = Source0
    ;   Source = ""
    ).

%!  set_node_shared_db(+Text) is det.
%
%   Replace current node shared database source text.
%   The source is loaded into a dedicated runtime module once and actors
%   import that module, so shared clauses are not copied per actor.
set_node_shared_db(Text0) :-
    text_to_string(Text0, Text),
    (   current_shared_db_module(SharedModule),
        current_node_value(url, _)
    ->  update_current_node_runtime(_{shared_db_source:Text}),
        load_shared_db_runtime(SharedModule, Text)
    ;   set_global_shared_db_fallback(Text)
    ).

set_global_shared_db_fallback(Text) :-
    retractall(node_shared_source(_)),
    assertz(node_shared_source(Text)),
    load_shared_db_runtime(node_shared_db_runtime, Text).

current_shared_db_module(SharedModule) :-
    (   current_node_value(shared_db_module, SharedModule0)
    ->  SharedModule = SharedModule0
    ;   SharedModule = node_shared_db_runtime
    ).

%!  call_current_shared_db(+Goal) is semidet.
%
%   Execute Goal against the shared DB module for the current node context, or
%   the fallback global shared DB module when no node context is active.
call_current_shared_db(Goal) :-
    must_be(callable, Goal),
    current_shared_db_module(SharedModule),
    functor(Goal, Name, Arity),
    current_predicate(SharedModule:Name/Arity),
    call(SharedModule:Goal).

%!  load_shared_db_runtime(+SharedModule, +Text) is det.
%
%   Load shared DB source text into the per-node shared runtime module. Uses
%   fixed source IDs within that module so that reloading replaces previous
%   definitions.
load_shared_db_runtime(SharedModule, Text) :-
    configure_shared_db_module(SharedModule),
    actor_io_prelude_text(Prelude),
    shared_db_source_id(SharedModule, node_shared_db_prelude, PreludeSourceId),
    shared_db_source_id(SharedModule, node_shared_db, SharedSourceId),
    load_shared_db_source(PreludeSourceId, SharedModule, Prelude),
    load_shared_db_source(SharedSourceId, SharedModule, Text),
    load_shared_db_user_wrappers(SharedModule).

shared_db_source_id(SharedModule, Base, SourceId) :-
    format(atom(LocalSourceId), '~w_~w', [Base, SharedModule]),
    SourceId = SharedModule:LocalSourceId.

load_shared_db_source(SourceId, Module, Text) :-
    setup_call_cleanup(
        open_chars_stream(Text, Stream),
        load_files(SourceId, [
            stream(Stream),
            module(Module),
            silent(true)
        ]),
        close(Stream)).

configure_shared_db_module(SharedModule) :-
    add_import_module(SharedModule, actor, start),
    SharedModule:op(800, xfx, !),
    SharedModule:op(200, xfx, @),
    SharedModule:op(1000, xfy, if).

load_shared_db_user_wrappers(SharedModule) :-
    shared_db_user_wrapper_source(SharedModule, Source),
    load_shared_db_source(user:node_shared_db_user, user, Source).

shared_db_user_wrapper_source(SharedModule, Source) :-
    findall(ClauseText,
            shared_db_user_wrapper_clause(SharedModule, ClauseText),
            Clauses),
    atomics_to_string(Clauses, "", Source).

shared_db_user_wrapper_clause(SharedModule, ClauseText) :-
    current_predicate(SharedModule:Name/Arity),
    atom(Name),
    \+ sub_atom(Name, 0, 1, _, '$'),
    \+ shared_db_private_predicate(Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(SharedModule:Head, imported_from(_)),
    \+ predicate_property(SharedModule:Head, built_in),
    \+ predicate_property(SharedModule:Head, dynamic),
    term_string((Head :- node:call_current_shared_db(Head)),
                Clause0, [quoted(true)]),
    string_concat(Clause0, ".\n", ClauseText).

shared_db_private_predicate(write/1).
shared_db_private_predicate(writeq/1).
shared_db_private_predicate(write_term/2).
shared_db_private_predicate(writeln/1).
shared_db_private_predicate(print/1).
shared_db_private_predicate(display/1).
shared_db_private_predicate(write_canonical/1).
shared_db_private_predicate(nl/0).
shared_db_private_predicate(format/1).
shared_db_private_predicate(format/2).
shared_db_private_predicate(read/1).


%!  node_controller_isobase(+Request) is det.
%
%   Stateless `/call` endpoint.
%
%   The controller parses query/template/format/options, computes one answer
%   slice via compute_answer/8, and serializes it as JSON or Prolog.
node_controller_isobase(Request) :-
    with_request_node_context(Request,
        with_ip_gate(Request,
                     with_drain_gate(node_controller_isobase_1(Request)))).

%!  with_drain_gate(:Goal) is det.
%
%   In maintenance/drain mode the node accepts no new execution work:
%   reply 503 (with Retry-After) instead of running Goal.  Must run
%   inside a node port context (it reads the per-node maintenance flag).
%   In-flight work on existing sessions is unaffected — only the entry
%   points that START new work wrap themselves in this gate.
:- meta_predicate with_drain_gate(0).
with_drain_gate(Goal) :-
    (   current_node_maintenance(true)
    ->  reply_draining
    ;   call(Goal)
    ).

reply_draining :-
    reply_json(json{type:"error", error:"node draining; not accepting new work"},
               [status(503)]).

%!  with_ip_gate(+Request, :Goal) is det.
%
%   IP/CIDR access control at the execution edge: if the request's client
%   IP is barred (blocklist, or an allowlist that excludes it), reply 403
%   instead of running Goal. Off by default (both lists empty ⇒ never
%   denied). Health/readiness/metrics are deliberately not gated.
:- meta_predicate with_ip_gate(+, 0).
with_ip_gate(Request, Goal) :-
    (   ip_access_denied(Request)
    ->  note_ip_rejection,
        reply_json(json{type:"error", error:"forbidden"}, [status(403)])
    ;   call(Goal)
    ).

node_controller_isobase_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        format(Format, [atom, default(json)])
    ]),
    safe_isobase_log_context(Request, LogContext),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        LogContext,
        isobase_request_event(Request, Principal, Format),
        plain_error_mapper
    ).

safe_isobase_log_context(Request, LogContext) :-
    catch(
        (
            http_parse_call_request(Request, [],
                                    GoalAtom, TemplateAtom0, Offset, Limit, _Format,
                                    LoadText, Once0, RequestedTimeout0),
            call_request_log_context(call, GoalAtom, TemplateAtom0, Offset, Limit,
                                     LoadText, Once0, RequestedTimeout0, LogContext)
        ),
        _,
        LogContext = _{route:"call", action:"call"}
    ).

isobase_request_event(Request, Principal, Format, Answer) :-
    http_parse_call_request(Request, [],
                            GoalAtom, TemplateAtom0, Offset, Limit, _ParsedFormat,
                            LoadText, Once0, RequestedTimeout0),
    isobase_event(Principal, GoalAtom, TemplateAtom0, Offset, Limit, Format,
                  LoadText, Once0, RequestedTimeout0, Answer).


%!  node_controller_isotope_spawn(+Request) is det.
%
%   Spawn a session toplevel actor and register associated ISOTOPE queue state.
node_controller_isotope_spawn(Request) :-
    with_request_node_context(Request,
        with_ip_gate(Request,
                     with_drain_gate(node_controller_isotope_spawn_1(Request)))).

node_controller_isotope_spawn_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        format(Format, [atom, default(json)])
    ]),
    principal_id(Principal, PrincipalId),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"toplevel_spawn", action:"toplevel_spawn"},
        isotope_spawn_authorized_event(Request, Principal, PrincipalId),
        plain_error_mapper
    ).


%!  node_controller_isotope_call(+Request) is det.
%
%   Submit a goal to an existing session actor.
%
%   If `load_text` is provided and changed since the previous call, the session
%   private module is refreshed before executing the goal.
node_controller_isotope_call(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_call_1(Request)).

node_controller_isotope_call_1(Request) :-
    request_principal(Request, Principal),
    http_parse_call_request(Request, [pid(Pid0, [atom])],
                            GoalAtom, TemplateAtom0, Offset, Limit, Format,
                            LoadText0, Once0, RequestedTimeout0),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    call_request_log_context(toplevel_call, GoalAtom, TemplateAtom0,
                             Offset, Limit, LoadText0, Once0,
                             RequestedTimeout0, BaseLogContext),
    put_dict(_{pid:Pid}, BaseLogContext, LogContext),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        LogContext,
        isotope_call_authorized_event(Principal, Pid, GoalAtom, TemplateAtom0,
                                      Offset, Limit, Format, LoadText0, Once0,
                                      RequestedTimeout0),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_next(+Request) is det.
%
%   Continue a previous nondeterministic toplevel call.
node_controller_isotope_next(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_next_1(Request)).

node_controller_isotope_next_1(Request) :-
    request_principal(Request, Principal),
    parse_isotope_wait_request(Request, Pid, Format, Timeout),
    http_parameters(Request, [
        limit(Limit, [integer, default(10 000 000 000)])
    ]),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"toplevel_next", action:"toplevel_next", pid:Pid,
          timeout_seconds:Timeout, limit:Limit},
        isotope_next_authorized_event(Principal, Pid, Timeout, Limit),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_poll(+Request) is det.
%
%   Wait for the next event from the session queue (output/prompt/answer/etc).
node_controller_isotope_poll(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_poll_1(Request)).

node_controller_isotope_poll_1(Request) :-
    request_principal(Request, Principal),
    parse_isotope_wait_request(Request, Pid, Format, Timeout),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"toplevel_poll", action:"toplevel_poll", pid:Pid,
          timeout_seconds:Timeout},
        isotope_poll_authorized_event(Principal, Pid, Timeout),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_stop(+Request) is det.
%
%   Ask session to stop paging current answer sequence.
node_controller_isotope_stop(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_stop_1(Request)).

node_controller_isotope_stop_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        pid(Pid0, [atom]),
        format(Format, [atom, default(json)])
    ]),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"toplevel_stop", action:"toplevel_stop", pid:Pid},
        isotope_stop_authorized_event(Principal, Pid),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_abort(+Request) is det.
%
%   Abort currently running goal in session actor.
node_controller_isotope_abort(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_abort_1(Request)).

node_controller_isotope_abort_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        pid(Pid0, [atom]),
        format(Format, [atom, default(json)])
    ]),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"toplevel_abort", action:"toplevel_abort", pid:Pid},
        isotope_abort_authorized_event(Principal, Pid),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_trace(+Request) is det.
%
%   Update the per-session trace flag used by client-owned statechart actors.
node_controller_isotope_trace(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_trace_1(Request)).

node_controller_isotope_trace_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        pid(Pid0, [atom]),
        statechart_trace(StatechartTrace0, [atom, default('')]),
        enabled(LegacyEnabled0, [atom, default('')]),
        format(Format, [atom, default(json)])
    ]),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    pick_isotope_trace_value(StatechartTrace0, LegacyEnabled0, EnabledRaw),
    parse_enabled_atom(EnabledRaw, Enabled),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        _{route:"statechart_trace", action:"statechart_trace", pid:Pid,
          statechart_trace:Enabled},
        isotope_trace_authorized_event(Principal, Pid, Enabled),
        pid_error_mapper(Pid)
    ).


%!  node_controller_isotope_respond(+Request) is det.
%
%   Deliver input value for a pending `read/1`-style prompt from a session.
node_controller_isotope_respond(Request) :-
    with_request_node_context(Request,
                              node_controller_isotope_respond_1(Request)).

node_controller_isotope_respond_1(Request) :-
    request_principal(Request, Principal),
    http_parameters(Request, [
        pid(Pid0, [atom]),
        format(Format, [atom, default(json)])
    ]),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    isotope_respond_log_context(Pid, Request, LogContext),
    execute_and_respond_logged(
        Request,
        Principal,
        Format,
        LogContext,
        isotope_respond_request_event(Request, Principal),
        pid_error_mapper(Pid)
    ).


%!  execute_and_respond(+Format, :BuildResult, :ErrorMapper) is det.
%
%   Run endpoint goal that computes one response term, map exceptions to
%   endpoint-specific error terms, and serialize using requested format.
execute_and_respond(Format, BuildResult, ErrorMapper) :-
    catch(
        call(BuildResult, Result),
        Error,
        call(ErrorMapper, Error, Result)
    ),
    respond_with_answer(Format, Result).

%!  execute_and_respond_logged(+Request, +Principal, +Format, +LogContext0,
%!                             :BuildResult, :ErrorMapper) is det.
%
%   Like execute_and_respond/3, but also records a structured request log
%   entry containing principal/client metadata, duration, and normalized
%   outcome.
execute_and_respond_logged(Request, Principal, Format, LogContext0,
                           BuildResult, ErrorMapper) :-
    get_time(StartedAt),
    note_request_admitted,
    catch(
        call(BuildResult, Result),
        Error,
        (   note_request_error(Error),
            note_ip_offense(Request, Error),
            call(ErrorMapper, Error, Result)
        )
    ),
    get_time(FinishedAt),
    DurationMs is max(0, round((FinishedAt - StartedAt) * 1000)),
    ignore(
        catch(
            log_http_request_result(Request, Principal, LogContext0, Result,
                                    DurationMs),
            _,
            true
        )
    ),
    respond_with_answer(Format, Result).

%!  note_ip_offense(+Request, +Error) is det.
%
%   Count a rate-limit violation as an offense toward an auto-ban (no-op
%   unless auto-ban is configured). Only rate-limit errors count;
%   authorization errors include legitimate denials (e.g. anonymous on a
%   private node) and must not auto-ban real users.
note_ip_offense(Request, error(rate_limit_exceeded(_, _, _, _), _)) :-
    !,
    ignore(catch(record_ip_offense(Request), _, true)).
note_ip_offense(_, _).

%!  plain_error_mapper(+Error, -Mapped) is det.
%
%   Wrap controller exception into a generic JSON/prolog error payload.
plain_error_mapper(Error, error(Error)).

%!  pid_error_mapper(+Pid, +Error, -Mapped) is det.
%
%   Wrap controller exception and include the ISOTOPE session pid context.
pid_error_mapper(Pid, Error, error(Pid, Error)).

isotope_respond_request_event(Request, Principal, Event) :-
    http_parameters(Request, [
        pid(Pid0, [atom]),
        input(InputAtom, [atom])
    ]),
    check_term_text_size(input, InputAtom),
    parse_pid_or_throw(Pid0, node:parse_request_pid/2,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    isotope_respond_authorized_event(Principal, Pid, InputAtom, Event).

%!  isobase_event(+Principal, +GoalAtom, +TemplateAtom0, +Offset, +Limit, +Format,
%!                +LoadText, +Once0, +RequestedTimeout0, -Answer) is det.
isobase_event(Principal, GoalAtom, TemplateAtom0, Offset, Limit, Format, LoadText,
              Once0, RequestedTimeout0, Answer) :-
    profile_check_route(call),
    require_route_access(Principal, call),
    require_source_text_access(Principal, LoadText),
    enforce_call_request_rate_limit(Principal),
    effective_profile_for_route(call, EffectiveProfile),
    parse_call_context(GoalAtom, TemplateAtom0, Format, Once0,
                       RequestedTimeout0, Goal, Template, Once,
                       RequestedTimeout),
    relation_check_call(EffectiveProfile, Goal, LoadText),
    sandbox_check_goal_with_source(EffectiveProfile, node_engine, Goal, LoadText),
    with_inflight_call_limit(
        Principal,
        with_public_execution_profile(
            EffectiveProfile,
            compute_answer(Goal, Template, Offset, Limit, LoadText,
                           RequestedTimeout, Once, Answer)
        )
    ).

%!  node(+Port) is det.
%!  node(+Port, +Options) is det.
%
%   Start the node HTTP server on Port.
%
%   node/1 is equivalent to node(Port, []).
%
%   node/2 accepts startup options:
%
%     - load_shared_db_text(+Text)
%     - load_shared_db_file(+File)
%     - load_shared_db_uri(+URI)
%     - sandbox(+Mode)
%     - profile(+Profile)  % workbench (default), relation, isobase, isotope, or actor
%     - auth(+Mode)
%     - dev_principal(+PrincipalId)
%     - dev_capabilities(+Capabilities)
%     - owner(+PrincipalId)
%     - principal(+PrincipalId, +Capabilities)
%     - principal(+PrincipalId, +Capabilities, +Profile)  % rejected
%     - timeout(+Seconds)
%     - cache_size(+Entries)
%     - max_inflight_calls(+Count)
%     - max_sessions_per_principal(+Count)
%     - max_ws_actors_per_principal(+Count)
%     - max_term_text_bytes(+Bytes)
%     - max_load_text_bytes(+Bytes)
%     - max_ws_frame_bytes(+Bytes)
%     - max_admin_json_bytes(+Bytes)
%     - tutorial_sections(+Sections)  % names of the tutorial sections shown by this node
%     - rate_window_seconds(+Seconds)
%     - max_call_requests_per_window(+Count)
%     - max_session_spawns_per_window(+Count)
%     - max_ws_commands_per_window(+Count)
%     - load_uri_allowed_origins(+Origins)
%     - relations(+Patterns)
%
%   The 3-argument `principal/3` form is rejected. Node profile is configured
%   separately and applies uniformly to all authorized clients.
%
%   Shared DB source built from these options is:
%
%     - served at `/` as plain text,
%     - loaded into a dedicated runtime module imported by actors.
%
%   Runtime state is now keyed per node for HTTP and WS execution, including
%   shared DB state and timeout/cache policy. The remaining global fallback is
%   only for direct no-context local experimentation in one SWI process.
node(Port) :-
    node(Port, []).

node(Port, Options0) :-
    %  Resource ceilings are extracted here rather than threaded
    %  through node_options/24 (whose arity is pinned by tests): they
    %  are node runtime values consumed by the layer-0/2 hooks, not
    %  startup-option plumbing. Defaults are `unlimited`, so a node
    %  configured without them behaves exactly as the demonstrator.
    extract_resource_ceiling(max_actor_stack_bytes, Options0, MaxActorStackBytes, Options1),
    extract_resource_ceiling(max_call_inferences, Options1, MaxCallInferences, Options2),
    extract_resource_ceiling(max_actors, Options2, MaxActors, Options3),
    extract_resource_ceiling(max_interaction_log_bytes, Options3, MaxLogBytes, Options4),
    extract_plain_option(max_interaction_log_backups, 5, Options4, MaxLogBackups, Options),
    extract_tutorial_sections(Options, TutorialSections, Options5),
    node_options(Options5, SharedDB, SandboxMode, Profile, AuthMode,
                 DevPrincipal0, DevCapabilities0, PrincipalPolicies0,
                 Timeout0, CacheSize0, MaxInflightCalls0,
                 MaxSessionsPerPrincipal0, MaxWSActorsPerPrincipal0,
                 MaxTermTextBytes0, MaxLoadTextBytes0, MaxWSFrameBytes0,
                 MaxAdminJSONBytes0, RateWindowSeconds0,
                 MaxCallRequestsPerWindow0, MaxSessionSpawnsPerWindow0,
                 MaxWSCommandsPerWindow0, LoadURIAllowedOrigins0,
                 RelationPatterns0, HTTPOptions),
    normalize_principal_policies(PrincipalPolicies0, PrincipalPolicies),
    normalize_relation_patterns(RelationPatterns0, RelationPatterns),
    resolve_node_setting(timeout, normalize_timeout,
                         Timeout0, Timeout),
    resolve_node_setting(cache_size, normalize_cache_size,
                         CacheSize0, CacheSize),
    resolve_node_setting(node_limits:max_inflight_calls, normalize_max_inflight_calls,
                         MaxInflightCalls0, MaxInflightCalls),
    resolve_node_setting(node_limits:max_sessions_per_principal, normalize_max_sessions_per_principal,
                         MaxSessionsPerPrincipal0, MaxSessionsPerPrincipal),
    resolve_node_setting(node_limits:max_ws_actors_per_principal, normalize_max_ws_actors_per_principal,
                         MaxWSActorsPerPrincipal0, MaxWSActorsPerPrincipal),
    resolve_node_setting(node_input_limits:max_term_text_bytes, normalize_max_term_text_bytes,
                         MaxTermTextBytes0, MaxTermTextBytes),
    resolve_node_setting(node_input_limits:max_load_text_bytes, normalize_max_load_text_bytes,
                         MaxLoadTextBytes0, MaxLoadTextBytes),
    resolve_node_setting(node_input_limits:max_ws_frame_bytes, normalize_max_ws_frame_bytes,
                         MaxWSFrameBytes0, MaxWSFrameBytes),
    resolve_node_setting(node_input_limits:max_admin_json_bytes, normalize_max_admin_json_bytes,
                         MaxAdminJSONBytes0, MaxAdminJSONBytes),
    resolve_node_setting(node_rate_limits:rate_window_seconds, normalize_rate_window_seconds,
                         RateWindowSeconds0, RateWindowSeconds),
    resolve_node_setting(node_rate_limits:max_call_requests_per_window, normalize_max_call_requests_per_window,
                         MaxCallRequestsPerWindow0, MaxCallRequestsPerWindow),
    resolve_node_setting(node_rate_limits:max_session_spawns_per_window, normalize_max_session_spawns_per_window,
                         MaxSessionSpawnsPerWindow0, MaxSessionSpawnsPerWindow),
    resolve_node_setting(node_rate_limits:max_ws_commands_per_window, normalize_max_ws_commands_per_window,
                         MaxWSCommandsPerWindow0, MaxWSCommandsPerWindow),
    resolve_load_uri_allowed_origins(LoadURIAllowedOrigins0, LoadURIAllowedOrigins),
    set_setting(node:sandbox, SandboxMode),
    set_setting(node_auth:auth, AuthMode),
    %  Mirror the interaction-log rotation config into global settings
    %  so it applies even where the log is written outside a node port
    %  context (e.g. portal_load).  `unlimited` ⇒ 0 (no rotation).
    log_bytes_setting(MaxLogBytes, MaxLogBytesSetting),
    set_setting(node_interaction_log:max_interaction_log_bytes, MaxLogBytesSetting),
    set_setting(node_interaction_log:max_interaction_log_backups, MaxLogBackups),
    set_dev_auth_config(DevPrincipal0, DevCapabilities0),
    node_auth:dev_auth_config(DevPrincipal, DevCapabilities),
    set_principal_policies(PrincipalPolicies),
    set_setting(node_profile_policy:profile, Profile),
    default_builtin_family_policy(BuiltinFamilyPolicy),
    clear_limit_scope(node_port(Port)),
    clear_log_scope(node_port(Port)),
    clear_rate_limit_scope(node_port(Port)),
    clear_metric_counters_scope(node_port(Port)),
    http_server(http_dispatch, [port(Port)|HTTPOptions]),
    get_time(StartedAt),
    server_url(Port, URL),
    shared_db_runtime_module(Port, SharedDBModule),
    register_node_runtime(Port, node_runtime{
        url:URL,
        shared_db_source:SharedDB,
        shared_db_module:SharedDBModule,
        sandbox:SandboxMode,
        profile:Profile,
        auth:AuthMode,
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
        load_uri_allowed_origins:LoadURIAllowedOrigins,
        builtin_family_policy:BuiltinFamilyPolicy,
        relation_patterns:RelationPatterns,
        max_actor_stack_bytes:MaxActorStackBytes,
        max_call_inferences:MaxCallInferences,
        max_actors:MaxActors,
        max_interaction_log_bytes:MaxLogBytes,
        max_interaction_log_backups:MaxLogBackups,
        tutorial_sections:TutorialSections,
        started_at:StartedAt,
        dev_principal:DevPrincipal,
        dev_capabilities:DevCapabilities,
        principal_policies:PrincipalPolicies
    }),
    with_node_port_context(Port, set_node_shared_db(SharedDB)),
    set_global_shared_db_fallback(SharedDB),
    register_node_self(URL).


call_request_log_context(Route0, GoalAtom, TemplateAtom0, Offset, Limit,
                         LoadText0, Once0, RequestedTimeout0, Context) :-
    value_text(Route0, Route),
    text_hash_string(GoalAtom, GoalHash),
    text_hash_string(TemplateAtom0, TemplateHash),
    text_size(LoadText0, LoadTextChars),
    requested_timeout_log_value(RequestedTimeout0, RequestedTimeout),
    Context = _{
        route:Route,
        action:Route,
        goal_hash:GoalHash,
        template_hash:TemplateHash,
        offset:Offset,
        limit:Limit,
        once:Once0,
        requested_timeout:RequestedTimeout,
        load_text_chars:LoadTextChars
    }.


isotope_respond_log_context(Pid, Request, Context) :-
    http_parameters(Request, [
        input(InputAtom, [atom])
    ]),
    text_size(InputAtom, InputChars),
    Context = _{
        route:"toplevel_respond",
        action:"toplevel_respond",
        pid:Pid,
        input_chars:InputChars
    }.


log_http_request_result(Request, Principal, LogContext0, Result, DurationMs) :-
    request_client_meta(Request, Principal, ClientMeta),
    result_log_fields(Result, ResultFields),
    request_log_summary(LogContext0, ResultFields, Summary),
    put_dict(_{
        event_type:"request",
        transport:"http",
        duration_ms:DurationMs,
        summary:Summary
    }, ClientMeta, Event0),
    put_dict(LogContext0, Event0, Event1),
    put_dict(ResultFields, Event1, Event),
    log_event(Event).


request_log_summary(LogContext, ResultFields, Summary) :-
    route_or_action(LogContext, Route),
    get_dict(status, ResultFields, Status),
    (   get_dict(row_count, ResultFields, RowCount)
    ->  format(string(Summary), '~w ~w (~w rows)', [Route, Status, RowCount])
    ;   get_dict(error_kind, ResultFields, ErrorKind)
    ->  format(string(Summary), '~w ~w (~w)', [Route, Status, ErrorKind])
    ;   get_dict(pid, ResultFields, Pid)
    ->  format(string(Summary), '~w ~w (~w)', [Route, Status, Pid])
    ;   format(string(Summary), '~w ~w', [Route, Status])
    ).


route_or_action(LogContext, Route) :-
    (   get_dict(route, LogContext, Route0)
    ->  value_text(Route0, Route)
    ;   get_dict(action, LogContext, Action0)
    ->  value_text(Action0, Route)
    ;   Route = "request"
    ).


result_log_fields(error(Error), Fields) :-
    !,
    error_result_log_fields("", Error, Fields).
result_log_fields(error(Pid0, Error), Fields) :-
    !,
    value_text(Pid0, Pid),
    error_result_log_fields(Pid, Error, Fields).
result_log_fields(timeout(Pid0), _{status:"timeout", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(success(Slice, More), _{
    status:"success",
    row_count:RowCount,
    more:More
}) :-
    !,
    slice_row_count(Slice, RowCount).
result_log_fields(success(Pid0, Slice, More), _{
    status:"success",
    pid:Pid,
    row_count:RowCount,
    more:More
}) :-
    !,
    value_text(Pid0, Pid),
    slice_row_count(Slice, RowCount).
result_log_fields(failure, _{status:"failure"}) :-
    !.
result_log_fields(failure(Pid0), _{status:"failure", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(spawned(Pid0), _{status:"success", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(stop(Pid0), _{status:"success", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(abort(Pid0), _{status:"success", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(responded(Pid0), _{status:"success", pid:Pid}) :-
    !,
    value_text(Pid0, Pid).
result_log_fields(output(Pid0, Data0), _{
    status:"success",
    pid:Pid,
    output_chars:Chars
}) :-
    !,
    value_text(Pid0, Pid),
    text_size(Data0, Chars).
result_log_fields(terminal_output(Pid0, Data0), _{
    status:"success",
    pid:Pid,
    output_chars:Chars
}) :-
    !,
    value_text(Pid0, Pid),
    text_size(Data0, Chars).
result_log_fields(terminal_io_output(Pid0, Data0), _{
    status:"success",
    pid:Pid,
    output_chars:Chars
}) :-
    !,
    value_text(Pid0, Pid),
    text_size(Data0, Chars).
result_log_fields(prompt(Pid0, Prompt0), _{
    status:"success",
    pid:Pid,
    prompt_chars:Chars
}) :-
    !,
    value_text(Pid0, Pid),
    text_size(Prompt0, Chars).
result_log_fields(Result, _{status:"success", result_kind:Kind}) :-
    compound(Result),
    !,
    Result =.. [Name|_],
    value_text(Name, Kind).
result_log_fields(_, _{status:"success"}).


error_result_log_fields(Pid, Error, Fields) :-
    error_status(Error, Status),
    error_kind_text(Error, ErrorKind),
    Base = _{status:Status, error_kind:ErrorKind},
    (   Pid == ""
    ->  Fields = Base
    ;   put_dict(_{pid:Pid}, Base, Fields)
    ).


error_status(error(authorization_error(_, _), _), "denied") :-
    !.
error_status(error(profile_violation(_, _), _), "denied") :-
    !.
error_status(error(rate_limit_exceeded(_, _, _, _), _), "limited") :-
    !.
error_status(error(resource_limit_exceeded(_, _, _), _), "limited") :-
    !.
error_status(error(timeout, _), "timeout") :-
    !.
error_status(timeout, "timeout") :-
    !.
error_status(_, "error").


error_kind_text(error(Term, _), ErrorKind) :-
    !,
    error_term_kind_text(Term, ErrorKind).
error_kind_text(Term, ErrorKind) :-
    error_term_kind_text(Term, ErrorKind).


error_term_kind_text(Term, ErrorKind) :-
    compound(Term),
    !,
    compound_name_arity(Term, Name, _),
    value_text(Name, ErrorKind).
error_term_kind_text(Term, ErrorKind) :-
    value_text(Term, ErrorKind).


slice_row_count(Slice, RowCount) :-
    is_list(Slice),
    !,
    length(Slice, RowCount).
slice_row_count(_, 1).


text_hash_string(Text0, HashText) :-
    value_text(Text0, Text),
    term_hash(Text, Hash),
    format(string(HashText), '~16r', [Hash]).


text_size(Text0, Size) :-
    value_text(Text0, Text),
    string_length(Text, Size).


requested_timeout_log_value(Value0, "default") :-
    var(Value0),
    !.
requested_timeout_log_value(Value0, Value) :-
    value_text(Value0, Value).


value_text(Value0, Value) :-
    (   string(Value0)
    ->  Value = Value0
    ;   atom(Value0)
    ->  atom_string(Value0, Value)
    ;   term_string(Value0, Value)
    ).

%!  resolve_node_setting(+SettingPath, +Normalizer, +Value0, -Value) is det.
%
%   Generic resolver for node startup options. When Value0 is the atom
%   `default`, the value is read from the setting at SettingPath and then
%   normalized; otherwise the supplied value is normalized directly.
resolve_node_setting(SettingPath, Normalizer, default, Value) :-
    !,
    setting(SettingPath, Value0),
    call(Normalizer, Value0, Value).
resolve_node_setting(_, Normalizer, Value0, Value) :-
    call(Normalizer, Value0, Value).

resolve_load_uri_allowed_origins(default, unrestricted) :-
    !.
resolve_load_uri_allowed_origins(Origins0, Origins) :-
    normalize_load_uri_allowed_origins(Origins0, Origins).

normalize_cache_size(CacheSize0, CacheSize) :-
    must_be(integer, CacheSize0),
    (   CacheSize0 > 0
    ->  CacheSize = CacheSize0
    ;   throw(error(domain_error(node_cache_size, CacheSize0),
                    context(node:normalize_cache_size/2,
                            'cache_size must be a positive integer')))
    ).

shared_db_runtime_module(Port, SharedDBModule) :-
    format(atom(SharedDBModule), 'node_shared_db_runtime_~w', [Port]).

%!  server_url(+Address, -URL) is det.
%
%   Canonical URL for this node used in global pid values.
server_url(localhost:Port, URL) :-
    !,
    format(atom(URL), 'http://localhost:~w', [Port]).
server_url(_Address, URL) :-
    setting(http:public_host, Host),
    Host \== '',
    !,
    setting(http:public_port, Port),
    setting(http:public_scheme, Scheme),
    make_url(Scheme, Host, Port, URL).
server_url(Host:Port, URL) :-
    atom(Host),
    integer(Port),
    !,
    http_server_property(Port, scheme(Scheme)),
    make_url(Scheme, Host, Port, URL).
server_url(Port, URL) :-
    integer(Port),
    !,
    http_server_property(Port, scheme(Scheme)),
    make_url(Scheme, localhost, Port, URL).
server_url(Address, URL) :-
    format(atom(URL), 'http://~w', [Address]).

make_url(Scheme, Host, Port, URL) :-
    (   default_port(Scheme, Port)
    ->  format(atom(URL), '~w://~w', [Scheme, Host])
    ;   format(atom(URL), '~w://~w:~w', [Scheme, Host, Port])
    ).

default_port(http, 80).
default_port(https, 443).

%!  node_portal_page(+Request) is det.
%
%   Serve the browser demonstrator frontend.
node_portal_page(Request) :-
    ignore(catch(
        log_interaction_request(Request, _{event:"portal_load", route:"portal"}),
        _,
        true
    )),
    node_demonstrator_file(File),
    reply_uncached_file(File, Request).

%!  node_discovery_hub_page(+Request) is det.
%
%   Serve the discovery-hub directory UI (a Tabler page that renders the
%   live register over /call).  Useful on a discovery hub node; on any
%   other node it loads but reports the hub query unavailable.
node_discovery_hub_page(Request) :-
    node_discovery_hub_file(File),
    reply_uncached_file(File, Request).

%!  node_calculator_page(+Request) is det.
%
%   Serve the calculator demo backed by a spawned statechart actor.
node_calculator_page(Request) :-
    node_calculator_file(File),
    reply_uncached_file(File, Request).

%!  node_tutorial_page(+Request) is det.
%
%   Serve the legacy tutorial document used inside the demonstrator tutorial tab.
node_tutorial_page(Request) :-
    node_tutorial_file(File),
    reply_uncached_file(File, Request).

%!  node_manual_page(+Request) is det.
%
%   Serve the HTML version of the appendix manual predicate reference.
node_manual_page(Request) :-
    node_manual_file(File),
    reply_uncached_file(File, Request).

%!  node_editor_frame_page(+Request) is det.
%
%   Serve the isolated CodeMirror editor frame used by the demonstrator.
node_editor_frame_page(Request) :-
    node_editor_frame_file(File),
    reply_uncached_file(File, Request).

%!  node_swi_wasm_actor_worker_page(+Request) is det.
%
%   Serve the experimental SWI-WASM worker actor runtime.
node_swi_wasm_actor_worker_page(Request) :-
    node_swi_wasm_actor_worker_file(File),
    reply_uncached_file(File, [mime_type('text/javascript; charset=UTF-8')], Request).

%!  node_swipl_bundle_page(+Request) is det.
%
%   Serve the vendored SWI-Prolog WASM bundle from this node (no CDN), so
%   the in-browser runtimes work offline / behind a strict CSP. Served
%   cached (the bundle is large and effectively immutable).
node_swipl_bundle_page(Request) :-
    node_swipl_bundle_file(File),
    http_reply_file(File, [unsafe(true), mime_type('text/javascript; charset=UTF-8')], Request).

%!  reply_uncached_file(+File, +Request) is det.
%
%   Serve a static file with caching disabled. This keeps the browser-facing
%   demonstrator HTML in sync with local edits during development.
reply_uncached_file(File, Request) :-
    reply_uncached_file(File, [], Request).

reply_uncached_file(File, ExtraOptions, Request) :-
    http_reply_file(
        File,
        [ unsafe(true),
          cache(false),
          headers([
              cache_control('no-store, no-cache, must-revalidate, max-age=0'),
              pragma('no-cache'),
              expires('0')
          ])
        | ExtraOptions ],
        Request
    ).

%!  node_info_page(+Request) is det.
%
%   Return small node identity data needed by browser clients.
node_info_page(Request) :-
    with_request_node_context(Request,
                              node_info_page_1(Request)).

%!  node_healthz_page(+Request) is det.
%
%   Liveness probe.  Unauthenticated, no node-context dependency: a
%   200 here means the HTTP server thread is alive and answering.
%   Orchestrators restart the process when this stops responding.
node_healthz_page(_Request) :-
    reply_json(json{status:"ok"}, [status(200)]).

%!  node_readyz_page(+Request) is det.
%
%   Readiness probe.  200 once the node servicing this port is
%   configured and accepting work; 503 otherwise (still starting, or
%   — once implemented — in maintenance mode).  Unauthenticated and
%   side-effect-free.
node_readyz_page(Request) :-
    (   catch(with_request_node_context(Request, node_is_ready), _, fail)
    ->  reply_json(json{status:"ready"}, [status(200)])
    ;   reply_json(json{status:"not_ready"}, [status(503)])
    ).

node_is_ready :-
    current_node_value(profile, _),
    current_node_maintenance(false).

%!  node_version_page(+Request) is det.
%
%   Build identity (pack version, SWI version, git revision).
%   Unauthenticated: version disclosure is standard for an operational
%   endpoint and carries no secret; an operator wanting to hide it can
%   front the node with a proxy rule.
node_version_page(_Request) :-
    node_version_info(Info),
    reply_json(Info, [status(200)]).

%!  node_metrics_page(+Request) is det.
%
%   Prometheus text-exposition metrics. Unauthenticated and
%   aggregate-only (no per-principal detail), so it is safe to scrape
%   like /healthz; operators wanting it private restrict it at the
%   proxy. Wrapped in the node context so per-node activity and limits
%   resolve.
node_metrics_page(Request) :-
    with_request_node_context(Request, node_metrics_page_1).

node_metrics_page_1 :-
    node_metrics_text(Text),
    format("Content-type: text/plain; version=0.0.4; charset=UTF-8~n~n", []),
    format("~s", [Text]).

node_info_page_1(Request) :-
    (   current_node_url(SelfURL)
    ->  true
    ;   self_node_url(SelfURL)
    ),
    node_profile_mode(Profile),
    auth_mode(AuthMode),
    request_principal(Request, Principal),
    principal_id(Principal, PrincipalId0),
    text_to_string(PrincipalId0, PrincipalId),
    (   principal_execution_authorized(Principal)
    ->  PrincipalExecution = true
    ;   PrincipalExecution = false
    ),
    node_info_services(Services),
    node_info_provides(Provides),
    node_info_self_contained(SelfContained),
    node_info_tutorial_sections(TutorialSections),
    reply_json(json{
        self_url:SelfURL,
        profile:Profile,
        auth:AuthMode,
        auth_boundary:trusted_headers,
        trusted_identity_headers:[
            "X-Web-Prolog-User",
            "X-Web-Prolog-Principal",
            "X-Authenticated-User"
        ],
        trusted_capability_headers:[
            "X-Web-Prolog-Capabilities",
            "X-Web-Prolog-Caps"
        ],
        internal_transport_principal_prefix:"node:",
        principal_id:PrincipalId,
        principal_execution:PrincipalExecution,
        services:Services,
        provides:Provides,
        self_contained:SelfContained,
        tutorial_sections:TutorialSections
    }).

%!  node_info_tutorial_sections(-Sections:list(string)) is det.
%
%   The tutorial sections this node presents.  This is presentation metadata,
%   not an execution capability: the node profile remains authoritative.
node_info_tutorial_sections(Sections) :-
    (   current_node_value(tutorial_sections, Sections0)
    ->  maplist(atom_string, Sections0, Sections)
    ;   Sections = ["all"]
    ).

%!  node_info_services(-Services:list(string)) is det.
%
%   The names of the node-resident services published with
%   register_service/2 (e.g. counter, pubsub_service) — the node's
%   advertised, name-reachable services. Sorted, de-duplicated.
node_info_services(Services) :-
    findall(S,
            ( actors:registered_service(Name, _Pid),
              atom_string(Name, S) ),
            Services0),
    sort(Services0, Services).

%!  node_info_provides(-Provides:list(string)) is det.
%
%   The predicates the node advertises as its contract, derived from the
%   shared database itself rather than hand-curated: every predicate the
%   shared-DB source defines or imports via use_module/2, minus the Web
%   Prolog machinery (the I/O prelude and the actor API import, captured
%   by the baseline below), SWI built-ins, and the control facts an owner
%   may place in the shared DB (provides/1, relation_filter/1).  Absent
%   shared DB ⇒ empty.
node_info_provides(Provides) :-
    (   current_shared_db_module(Module)
    ->  findall(S,
                ( node_resident_predicate(Module, PI),
                  format(string(S), "~w", [PI]) ),
                Provides0),
        sort(Provides0, Provides)
    ;   Provides = []
    ).

%!  node_resident_predicate(+SharedModule, -PI) is nondet.
%
%   PI (Name/Arity) is a node-resident predicate: one the owner's shared
%   DB contributes itself — defined in its source or imported into it
%   with use_module/2 — as opposed to the I/O prelude, the actor API
%   import, and SWI built-ins, which are present in every shared module
%   and are subtracted via the baseline.  The module boundary does the
%   work: we never enumerate "all Web Prolog predicates", we just
%   subtract what a stock shared module already has.  (Self-contained vs
%   dependent — whether resolved imports are carried with the DB — is a
%   separate portability property, not encoded here.)
node_resident_predicate(SharedModule, Name/Arity) :-
    current_predicate(SharedModule:Name/Arity),
    atom(Name),
    \+ sub_atom(Name, 0, 1, _, '$'),
    \+ shared_db_contract_excluded(Name/Arity),
    \+ shared_db_baseline_predicate(Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(SharedModule:Head, built_in).

%  Web Prolog control facts an owner may write into the shared DB; they
%  drive node behaviour and are not part of the advertised contract.
shared_db_contract_excluded(provides/1).
shared_db_contract_excluded(relation_filter/1).

%!  shared_db_baseline_predicate(?PI) is nondet.
%
%   True for a predicate that a shared module carries before any owner
%   data is loaded: the I/O prelude (write/1, nl/0, format/1-2, …) and
%   the actor API import.  Computed once into a throwaway module and
%   cached, so it always tracks the real prelude.
shared_db_baseline_predicate(PI) :-
    shared_db_baseline_set(Set),
    memberchk(PI, Set).

:- dynamic shared_db_baseline_set_cache/1.

shared_db_baseline_set(Set) :-
    (   shared_db_baseline_set_cache(Set0)
    ->  Set = Set0
    ;   compute_shared_db_baseline_set(Set0),
        assertz(shared_db_baseline_set_cache(Set0)),
        Set = Set0
    ).

compute_shared_db_baseline_set(Set) :-
    Baseline = node_shared_db_baseline,
    configure_shared_db_module(Baseline),
    actor_io_prelude_text(Prelude),
    shared_db_source_id(Baseline, node_shared_db_prelude, PreludeSourceId),
    %  The I/O prelude interleaves clauses for several predicates, which
    %  raises (harmless) discontiguous warnings on load. Suppress them
    %  thread-locally for this throwaway baseline load; real errors still
    %  surface (the hook only swallows warning/informational messages).
    setup_call_cleanup(
        asserta((user:thread_message_hook(_, Kind, _) :-
                    memberchk(Kind, [warning, informational])), Ref),
        load_shared_db_source(PreludeSourceId, Baseline, Prelude),
        erase(Ref)),
    findall(Name/Arity,
            ( current_predicate(Baseline:Name/Arity),
              atom(Name),
              functor(Head, Name, Arity),
              \+ predicate_property(Baseline:Head, built_in)
            ),
            Set0),
    sort(Set0, Set).


%!  node_info_self_contained(-SelfContained:boolean) is det.
%
%   A shared DB is *self-contained* when it could be copied to a fresh
%   stock node and still work: every predicate its node-resident clauses
%   call resolves either locally (a node-resident clause) or on any node
%   (a built-in, the actor API, or a standard SWI library).  It is
%   *dependent* when it imports from a custom — non-library — module
%   (which would not travel) or calls a predicate that is undefined here.
%   Absent shared DB ⇒ self-contained (nothing to depend on).
node_info_self_contained(SelfContained) :-
    (   current_shared_db_module(Module),
        shared_db_dependent(Module)
    ->  SelfContained = false
    ;   SelfContained = true
    ).

%!  shared_db_dependent(+SharedModule) is semidet.
shared_db_dependent(Module) :-
    (   shared_db_custom_import(Module, _)
    ->  true
    ;   shared_db_undefined_call(Module, _)
    ).

%!  shared_db_custom_import(+SharedModule, -PI) is nondet.
%
%   A node-resident predicate imported from a module that is not a
%   standard SWI library (so it would not be carried to another node).
shared_db_custom_import(Module, Name/Arity) :-
    node_resident_predicate(Module, Name/Arity),
    functor(Head, Name, Arity),
    predicate_property(Module:Head, imported_from(Source)),
    \+ library_module(Source).

%!  shared_db_undefined_call(+SharedModule, -PI) is nondet.
%
%   A predicate called by a locally-defined node-resident clause that
%   does not resolve on a stock node — not local, built-in, autoloadable
%   from a library, nor imported.
shared_db_undefined_call(Module, Name/Arity) :-
    shared_db_called_predicates(Module, PIs),
    member(Name/Arity, PIs),
    functor(Head, Name, Arity),
    \+ stock_resolvable(Module, Head).

stock_resolvable(Module, Head) :-
    (   predicate_property(Module:Head, built_in)
    ;   predicate_property(Module:Head, defined)
    ;   predicate_property(Module:Head, autoload(_))
    ;   predicate_property(Module:Head, imported_from(_))
    ),
    !.

node_resident_local_clause_body(Module, Body) :-
    node_resident_predicate(Module, Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(Module:Head, imported_from(_)),
    \+ predicate_property(Module:Head, built_in),
    clause(Module:Head, Body).

:- thread_local shared_db_called_pi_/1.

%!  shared_db_called_predicates(+Module, -PIs) is det.
%
%   The set of (unqualified) predicate indicators called from the bodies
%   of the module's locally-defined node-resident clauses.  Module-
%   qualified calls are the owner's explicit choice and are skipped.
shared_db_called_predicates(Module, PIs) :-
    setup_call_cleanup(
        retractall(shared_db_called_pi_(_)),
        forall(node_resident_local_clause_body(Module, Body),
               ignore(goal_walker:walk_goal(node:record_called_pi_, Body))),
        true),
    findall(PI, retract(shared_db_called_pi_(PI)), PIs0),
    sort(PIs0, PIs).

record_called_pi_(Goal) :-
    (   nonvar(Goal),
        Goal \= _:_,
        callable(Goal),
        functor(Goal, Name, Arity),
        atom(Name)
    ->  assertz(shared_db_called_pi_(Name/Arity))
    ;   true
    ).

%!  library_module(+Module) is semidet.
%
%   True when Module's source file lives under an SWI library directory,
%   i.e. it is a standard library present on any node.
library_module(Module) :-
    module_property(Module, file(File)),
    file_in_library_dir(File),
    !.

file_in_library_dir(File) :-
    absolute_file_name(library('.'), LibDir0,
                       [ file_type(directory), solutions(all),
                         file_errors(fail), access(read) ]),
    (   sub_atom(LibDir0, _, 1, 0, '/')
    ->  LibDir = LibDir0
    ;   atom_concat(LibDir0, '/', LibDir)
    ),
    atom_concat(LibDir, _, File),
    !.

%!  node_examples_index_page(+Request) is det.
%
%   Return the file names and URLs for the actor and statechart example sets.
node_examples_index_page(Request) :-
    with_request_node_context(Request,
                              node_examples_index_page_1).

node_examples_index_page_1 :-
    node_actor_examples_dir(ActorDir),
    node_statecharts_dir(StatechartDir),
    example_directory_entries(ActorDir, '/examples/actors/', prolog, ActorEntries),
    example_directory_entries(StatechartDir, '/examples/statecharts/', statechart, StatechartEntries),
    reply_json(json{
        actors:ActorEntries,
        statecharts:StatechartEntries,
        swi_wasm:[]
    }).


%!  node_interaction_log_page(+Request) is det.
%
%   Accept browser-reported public demonstrator interaction events and append
%   them to the durable JSONL interaction log.
node_interaction_log_page(Request) :-
    with_request_node_context(Request,
                              node_interaction_log_page_1(Request)).

node_interaction_log_page_1(Request) :-
    catch(
        (
            http_read_json_dict(Request, Event),
            log_browser_interaction_request(Request, Event),
            reply_json(json{status:ok})
        ),
        Error,
        (
            message_to_string(Error, Message),
            reply_json_dict(json{status:error, message:Message}, [status(400)])
        )
    ).


isotope_spawn_authorized_event(Request, Principal, PrincipalId, Event) :-
    require_route_access(Principal, toplevel_spawn),
    enforce_session_spawn_rate_limit(Principal),
    effective_profile_for_route(toplevel_spawn, EffectiveProfile),
    isotope_spawn_event(Request, Principal, PrincipalId, EffectiveProfile, Event).


isotope_call_authorized_event(Principal, Pid, GoalAtom, TemplateAtom0, Offset, Limit,
                              Format, LoadText0, Once0, RequestedTimeout0, Event) :-
    authorize_isotope_session_access(Principal, toplevel_call, Pid),
    require_source_text_access(Principal, LoadText0),
    effective_profile_for_route(toplevel_call, EffectiveProfile),
    isotope_call_event(Pid, EffectiveProfile, GoalAtom, TemplateAtom0, Offset, Limit,
                       Format, LoadText0, Once0, RequestedTimeout0, Event).


isotope_next_authorized_event(Principal, Pid, Timeout, Limit, Event) :-
    authorize_isotope_session_access(Principal, toplevel_next, Pid),
    isotope_next_event(Pid, Timeout, Limit, Event).


isotope_poll_authorized_event(Principal, Pid, Timeout, Event) :-
    authorize_isotope_session_access(Principal, toplevel_poll, Pid),
    isotope_poll_event(Pid, Timeout, Event).


isotope_stop_authorized_event(Principal, Pid, Event) :-
    authorize_isotope_session_access(Principal, toplevel_stop, Pid),
    isotope_stop_event(Pid, Event).


isotope_abort_authorized_event(Principal, Pid, Event) :-
    authorize_isotope_session_access(Principal, toplevel_abort, Pid),
    isotope_abort_event(Pid, Event).


isotope_trace_authorized_event(Principal, Pid, Enabled, Event) :-
    authorize_isotope_session_access(Principal, toplevel_call, Pid),
    set_isotope_session_trace(Pid, Enabled),
    Event = responded(Pid).


isotope_respond_authorized_event(Principal, Pid, InputAtom, Event) :-
    authorize_isotope_session_access(Principal, toplevel_respond, Pid),
    isotope_respond_event(Pid, InputAtom, Event).


authorize_isotope_session_access(Principal, RouteId, Pid) :-
    require_route_access(Principal, RouteId),
    principal_id(Principal, PrincipalId),
    require_isotope_session_owner(PrincipalId, Pid).


%!  pick_isotope_trace_value(+StatechartTrace, +LegacyEnabled, -Chosen) is det.
%
%   Prefer the new `statechart_trace` query parameter; fall back to legacy
%   `enabled`.  Empty atom means "not supplied".  When neither is supplied,
%   default to `true` (preserves the historical `/toplevel_trace` default).
pick_isotope_trace_value('', '', true) :- !.
pick_isotope_trace_value('', Legacy, Legacy) :- !.
pick_isotope_trace_value(Statechart, _, Statechart).


parse_enabled_atom(true, true) :-
    !.
parse_enabled_atom(false, false) :-
    !.
parse_enabled_atom(@(true), true) :-
    !.
parse_enabled_atom(@(false), false) :-
    !.
parse_enabled_atom(Atom0, Enabled) :-
    atom(Atom0),
    !,
    atom_string(Atom0, Text),
    parse_enabled_atom(Text, Enabled).
parse_enabled_atom(Text0, Enabled) :-
    string(Text0),
    !,
    string_lower(Text0, Text),
    parse_enabled_atom(Text, Enabled).
parse_enabled_atom('true', true) :-
    !.
parse_enabled_atom('false', false) :-
    !.
parse_enabled_atom("true", true) :-
    !.
parse_enabled_atom("false", false) :-
    !.
parse_enabled_atom(Value, _) :-
    throw(error(domain_error(boolean, Value),
                context(node:parse_enabled_atom/2,
                        'enabled must be true or false'))).


isotope_next_event(Pid, Timeout, Limit, Event) :-
    profile_check_route(toplevel_next),
    isotope_session_queue(Pid, Queue),
    with_isotope_session_public_execution_profile(
        Pid,
        toplevel_next(Pid, [
            limit(Limit),
            target(Queue)
        ])
    ),
    wait_for_session_event(Pid, Queue, Timeout, Event),
    capture_answer_bindings(Event).


isotope_poll_event(Pid, Timeout, Event) :-
    profile_check_route(toplevel_poll),
    isotope_session_queue(Pid, Queue),
    wait_for_session_event(Pid, Queue, Timeout, Event),
    capture_answer_bindings(Event).


isotope_stop_event(Pid, stop(Pid)) :-
    profile_check_route(toplevel_stop),
    toplevel_stop(Pid).


isotope_abort_event(Pid, abort(Pid)) :-
    profile_check_route(toplevel_abort),
    toplevel_abort(Pid).

%!  node_image_page(+Request) is det.
%
%   Serve static image assets referenced by the tutorial and demonstrator.
node_image_page(Request) :-
    node_image_dir(Dir),
    option(path_info(PathInfo), Request, ''),
    image_relative_path(PathInfo, RelPath),
    safe_image_file(Dir, RelPath, File),
    http_reply_file(File, [unsafe(true)], Request).

%!  node_examples_page(+Request) is det.
%
%   Serve example source files under examples/.
node_examples_page(Request) :-
    node_examples_dir(Dir),
    option(path_info(PathInfo), Request, ''),
    asset_relative_path(PathInfo, RelPath),
    safe_asset_file(Dir, RelPath, File),
    http_reply_file(File, [unsafe(true)], Request).

%!  node_vendor_page(+Request) is det.
%
%   Serve the vendored third-party browser assets (Vue, jQuery, jQuery
%   Terminal, Bootstrap CSS, CodeMirror, IBM Plex Mono) from this node,
%   so the portal works offline / behind a strict CSP with no external
%   CDNs. Mime is set by extension; served cached (the assets are
%   versioned and effectively immutable).
node_vendor_page(Request) :-
    node_vendor_dir(Dir),
    option(path_info(PathInfo), Request, ''),
    asset_relative_path(PathInfo, RelPath),
    safe_asset_file(Dir, RelPath, File),
    vendor_asset_mime(RelPath, Mime),
    http_reply_file(File, [unsafe(true), mime_type(Mime)], Request).

node_vendor_dir(Dir) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, ModuleDir),
    directory_file_path(ModuleDir, '../../web/vendor', Dir).

vendor_asset_mime(RelPath, Mime) :-
    file_name_extension(_, Ext, RelPath),
    (   vendor_ext_mime(Ext, Mime)
    ->  true
    ;   Mime = 'application/octet-stream'
    ).

vendor_ext_mime(js,    'text/javascript; charset=UTF-8').
vendor_ext_mime(css,   'text/css; charset=UTF-8').
vendor_ext_mime(woff2, 'font/woff2').
vendor_ext_mime(woff,  'font/woff').
vendor_ext_mime(map,   'application/json; charset=UTF-8').

%!  node_statecharts_page(+Request) is det.
%
%   Serve statechart examples under examples/statecharts/.
node_statecharts_page(Request) :-
    node_statecharts_dir(Dir),
    option(path_info(PathInfo), Request, ''),
    asset_relative_path(PathInfo, RelPath),
    safe_asset_file(Dir, RelPath, File),
    http_reply_file(File, [unsafe(true), mime_type('text/xml; charset=UTF-8')], Request).

%!  node_wasm_modules_page(+Request) is det.
%
%   Serve the allowlisted SWI-WASM statechart modules.
node_wasm_modules_page(Request) :-
    option(path_info(PathInfo), Request, ''),
    asset_relative_path(PathInfo, RelPath),
    node_wasm_module_file(RelPath, File),
    http_reply_file(File, [unsafe(true), mime_type('text/plain; charset=UTF-8')], Request).

%!  node_wasm_module_file(+RelPath, -File) is semidet.
%
%   Resolve an allowlisted SWI-WASM statechart module.  The node can be
%   loaded from prolog/web_prolog/, src/, or an interactive working
%   directory; try the known repo layouts before giving up.
node_wasm_module_file(RelPath, File) :-
    wasm_module_file_name(RelPath),
    node_wasm_modules_dir(Dir),
    safe_asset_file(Dir, RelPath, File),
    !.

%!  wasm_module_file_name(+RelPath) is semidet.
%
%   True iff RelPath names one of the modules the SWI-WASM statechart
%   port loads from /wasm/.
wasm_module_file_name('statechart_wasm.pl').
wasm_module_file_name('statechart_wasm_model.pl').
wasm_module_file_name('statechart_wasm_exec.pl').
wasm_module_file_name('statechart_wasm_runtime.pl').


%!  node_demonstrator_file(-File) is det.
%
%   Resolve absolute path to `demonstrator.html` shipped with this module.
node_demonstrator_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/demonstrator.html', File).

%!  node_discovery_hub_file(-File) is det.
%
%   Resolve absolute path to `discovery-hub.html` shipped with this module.
node_discovery_hub_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/discovery-hub.html', File).

%!  node_calculator_file(-File) is det.
%
%   Resolve absolute path to `calculator.html` shipped with this module.
node_calculator_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/calculator.html', File).

%!  node_tutorial_file(-File) is det.
%
%   Resolve absolute path to `tutorial.html` shipped with this module.
node_tutorial_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/tutorial.html', File).

%!  node_manual_file(-File) is det.
%
%   Resolve absolute path to `manual.html` shipped with this module.
node_manual_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/manual.html', File).

%!  node_editor_frame_file(-File) is det.
%
%   Resolve absolute path to `editor_frame.html` shipped with this module.
node_editor_frame_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/editor_frame.html', File).

%!  node_swi_wasm_actor_worker_file(-File) is det.
%
%   Resolve absolute path to the experimental SWI-WASM actor worker.
node_swi_wasm_actor_worker_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/swi_wasm_actor_worker.js', File).

%!  node_swipl_bundle_file(-File) is det.
node_swipl_bundle_file(File) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../../web/swipl-bundle.js', File).

%!  node_image_dir(-Dir) is det.
%
%   Resolve absolute path to the `img` asset directory shipped with this module.
node_image_dir(Dir) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir0),
    directory_file_path(Dir0, '../../img', Dir).

%!  node_examples_dir(-Dir) is det.
%
%   Resolve absolute path to the `examples` directory shipped with this module.
node_examples_dir(Dir) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir0),
    directory_file_path(Dir0, '../../examples', Dir).

%!  node_actor_examples_dir(-Dir) is det.
%
%   Resolve absolute path to the `examples/actors` directory.
node_actor_examples_dir(Dir) :-
    node_examples_dir(ExamplesDir),
    directory_file_path(ExamplesDir, 'actors', Dir).

%!  node_statecharts_dir(-Dir) is det.
%
%   Resolve absolute path to the `examples/statecharts` directory.
node_statecharts_dir(Dir) :-
    node_examples_dir(ExamplesDir),
    directory_file_path(ExamplesDir, 'statecharts', Dir).

%!  node_wasm_modules_dir(-Dir) is det.
%
%   Resolve absolute path to the directory containing the SWI-WASM
%   statechart modules served to the in-browser SWI-Prolog.
node_wasm_modules_dir(Dir) :-
    module_property(node, file(ThisFile)),
    file_directory_name(ThisFile, Dir0),
    directory_file_path(Dir0, 'wasm', Dir).
node_wasm_modules_dir(Dir) :-
    working_directory(Cwd, Cwd),
    directory_file_path(Cwd, 'prolog/web_prolog/wasm', Dir).

%!  example_directory_entries(+Dir, +BaseURL, +Kind, -Entries) is det.
%
%   Enumerate regular files from Dir as JSON-ready example entry dicts.
example_directory_entries(Dir, BaseURL, Kind, Entries) :-
    directory_files(Dir, Names0),
    include(example_visible_file_name(Kind), Names0, Names1),
    sort(Names1, Names),
    findall(json{name:Name, url:URL, kind:Kind},
            ( member(Name, Names),
              directory_file_path(Dir, Name, File),
              exists_file(File),
              atom_concat(BaseURL, Name, URL)
            ),
            Entries).

example_visible_file_name(Kind, Name) :-
    Name \== '.',
    Name \== '..',
    \+ sub_atom(Name, 0, _, _, '.'),
    \+ hidden_example_file_name(Kind, Name).

hidden_example_file_name(statechart, 'game.xml').

%!  image_relative_path(+PathInfo, -RelPath) is det.
%
%   Turn the request path_info for `/img/...` into a relative file path.
image_relative_path(PathInfo, RelPath) :-
    (   atom_concat('/', RelPath0, PathInfo)
    ->  RelPath = RelPath0
    ;   RelPath = PathInfo
    ).

%!  asset_relative_path(+PathInfo, -RelPath) is det.
%
%   Turn request path_info into a relative file path.
asset_relative_path(PathInfo, RelPath) :-
    image_relative_path(PathInfo, RelPath).

%!  safe_image_file(+Dir, +RelPath, -File) is det.
%
%   Resolve image asset path under Dir and reject traversal attempts.
safe_image_file(Dir, RelPath, File) :-
    safe_relative_file(Dir, RelPath, File).

%!  safe_asset_file(+Dir, +RelPath, -File) is det.
%
%   Resolve a file under Dir and reject traversal attempts.
safe_asset_file(Dir, RelPath, File) :-
    safe_relative_file(Dir, RelPath, File).

%!  safe_relative_file(+Dir, +RelPath, -File) is semidet.
%
%   Resolve RelPath under Dir, rejecting any traversal attempt.
%   Guards against `..`, absolute paths, symlink escapes, and encoded
%   sequences by canonicalizing both paths and confirming the result
%   stays under Dir (with a path-separator boundary, so a sibling
%   directory whose name merely extends Dir's name cannot pass).
safe_relative_file(Dir, RelPath, File) :-
    \+ sub_atom(RelPath, _, _, _, '..'),
    \+ is_absolute_file_name(RelPath),
    directory_file_path(Dir, RelPath, File),
    exists_file(File),
    absolute_file_name(Dir, CanonicalDir),
    absolute_file_name(File, CanonicalFile),
    directory_file_path(CanonicalDir, '', CanonicalDirSlash),
    sub_atom(CanonicalFile, 0, _, _, CanonicalDirSlash).

%!  extract_resource_ceiling(+Name, +Options0, -Value, -Options) is det.
%
%   Pull a resource-ceiling option (`Name(V)`) out of the option list,
%   normalizing it to a positive integer or the atom `unlimited`
%   (the default — and `0`/`unlimited` both mean off). Options is
%   Options0 with every `Name(_)` removed, so node_options/24 never
%   sees it and it cannot leak to the HTTP server as a bogus option.
extract_resource_ceiling(Name, Options0, Value, Options) :-
    Probe =.. [Name, Raw],
    (   select(Probe, Options0, Options1)
    ->  normalize_resource_ceiling(Raw, Value),
        exclude_ceiling(Name, Options1, Options)
    ;   Value = unlimited,
        Options = Options0
    ).

exclude_ceiling(Name, Options0, Options) :-
    exclude(is_ceiling_option(Name), Options0, Options).

is_ceiling_option(Name, Opt) :-
    compound(Opt),
    functor(Opt, Name, 1).

%!  extract_plain_option(+Name, +Default, +Options0, -Value, -Options) is det.
%
%   Like extract_resource_ceiling/4 but with an arbitrary default and
%   no unlimited-normalization — for options (e.g. backup count) where
%   0 is a literal value, not "off".
extract_plain_option(Name, Default, Options0, Value, Options) :-
    Probe =.. [Name, Raw],
    (   select(Probe, Options0, Options1)
    ->  Value = Raw,
        exclude_ceiling(Name, Options1, Options)
    ;   Value = Default,
        Options = Options0
    ).

%!  extract_tutorial_sections(+Options0, -Sections, -Options) is det.
%
%   Keep the tutorial catalogue node-scoped without extending the pinned
%   node_options/24 interface.  `all` is the backwards-compatible default.
extract_tutorial_sections(Options0, Sections, Options) :-
    (   select(tutorial_sections(Raw), Options0, Options1)
    ->  must_be(list, Raw),
        maplist(normalize_tutorial_section, Raw, Sections0),
        sort(Sections0, Sections),
        exclude(is_tutorial_sections_option, Options1, Options)
    ;   Sections = [all],
        Options = Options0
    ).

is_tutorial_sections_option(tutorial_sections(_)).

normalize_tutorial_section(Value, Section) :-
    must_be(atom, Value),
    (   Value == ''
    ->  throw(error(domain_error(tutorial_section, Value),
                    context(node:extract_tutorial_sections/3,
                            'tutorial section names must be non-empty atoms')))
    ;   Section = Value
    ).

log_bytes_setting(unlimited, 0) :- !.
log_bytes_setting(N, N) :- integer(N), !.
log_bytes_setting(_, 0).

normalize_resource_ceiling(Raw, unlimited) :-
    ( var(Raw) ; Raw == unlimited ; Raw == none ; Raw == 0 ),
    !.
normalize_resource_ceiling(Raw, Raw) :-
    integer(Raw),
    Raw > 0,
    !.
normalize_resource_ceiling(Raw, _) :-
    throw(error(domain_error(resource_ceiling, Raw),
                context(node:extract_resource_ceiling/4,
                        'resource ceiling must be a positive integer, 0, or unlimited'))).

%!  effective_timeout(+RequestedTimeout0, -EffectiveTimeout) is det.
%
%   Owner timeout is a hard upper bound. Client may only request a lower value.
effective_timeout(RequestedTimeout0, EffectiveTimeout) :-
    (   current_node_value(timeout, OwnerTimeout1)
    ->  OwnerTimeout0 = OwnerTimeout1
    ;   setting(timeout, OwnerTimeout0)
    ),
    normalize_timeout(OwnerTimeout0, OwnerTimeout),
    normalize_requested_timeout(RequestedTimeout0, RequestedTimeout),
    (   RequestedTimeout == none
    ->  EffectiveTimeout = OwnerTimeout
    ;   EffectiveTimeout is min(OwnerTimeout, RequestedTimeout)
    ).

%!  effective_cache_size(-CacheSize) is det.
effective_cache_size(CacheSize) :-
    (   current_node_value(cache_size, CacheSize0)
    ->  CacheSize = CacheSize0
    ;   setting(cache_size, CacheSize)
    ).
