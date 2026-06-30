:- module(node_glue, []).

/** <module> Node-layer hook implementations

Every hook the lower layers declared, implemented in one place — the
node-side half of the composition (the umbrella owns the layer-0/1
spawn chain; this module owns everything that exists only on a node).
Loaded by node.pl.

Sections mirror the hook inventory in docs/LAYERED_REAL_NODE_PLAN.md
§2.2, with the demonstrator call sites these clauses replace noted
inline.
*/

:- use_module(actors, []).
:- use_module(isolation, []).
:- use_module(distribution, []).
:- use_module(pid_utils, []).
:- use_module(source_utils, []).
:- use_module(statechart_actor, []).
:- use_module(actor_api, []).
:- use_module(actor_io_support, [actor_public_guard_prelude_text/1]).
:- use_module(node_runtime_state, [
    current_node_port/1,
    current_node_url/1,
    current_node_value/2
]).
:- use_module(node_execution_context, [
    current_public_execution_profile/1,
    current_public_execution_namespace/1
]).
:- use_module(public_goal_guard, [
    rewrite_goal_if_needed/3,
    rewrite_source_text_if_needed/3,
    blacklist_guard_active/0
]).
:- use_module(node_sandbox, []).
:- use_module(node_session, []).
:- use_module(node_ws, []).
:- use_module(node_log, [log_event/1]).

:- op(200, xfx, @).


                /*******************************
                *     THE COMPOSITION SPINE    *
                *******************************/

%  The single hook_start_body chain lives in composition.pl, shared
%  with the umbrella (plan §2.3: one clause, one place).
:- use_module(composition, []).


                /*******************************
                *        ACTORS HOOKS          *
                *******************************/

%  Caller-side spawn option rewriting (was prepare_public_spawn/3 in
%  actor.pl): when a public execution profile is active, the sandbox
%  vets and rewrites the spawn options.
:- multifile actors:hook_spawn_options/3.
actors:hook_spawn_options(Goal, Options0, Options) :-
    current_public_execution_profile(Profile),
    strip_module(Goal, GoalModule0, PlainGoal),
    glue_goal_module(GoalModule0, PlainGoal, GoalModule),
    exclude(internal_spawn_option, Options0, PublicOptions),
    node_sandbox:sandbox_prepare_public_spawn(Profile, GoalModule,
                                              PlainGoal, PublicOptions,
                                              PreparedOptions),
    public_spawn_module_options(GoalModule, PlainGoal, PreparedOptions,
                                Options).

internal_spawn_option(inherit_goal_module(_)).

public_spawn_module_options(GoalModule, Goal, Options, Options) :-
    public_framework_start_goal(GoalModule, Goal),
    !.
public_spawn_module_options(_, _, Options,
                            [inherit_goal_module(false)|Options]).

% Framework entry points execute trusted runtime code from their defining
% module. Their client-supplied callbacks and child goals are checked by the
% public profile separately.
public_framework_start_goal(toplevel_actors, Goal) :-
    goal_has_pi(Goal, ptcp/3).
public_framework_start_goal(server_actor, Goal) :-
    goal_has_pi(Goal, server_loop/2).
public_framework_start_goal(supervisor_actor, Goal) :-
    goal_has_pi(Goal, sup_init/2).

goal_has_pi(Goal, Name/Arity) :-
    callable(Goal),
    functor(Goal, Name, Arity).

glue_goal_module(actors, Plain, user) :-
    \+ ( callable(Plain),
         functor(Plain, Name, Arity),
         current_predicate(actors:Name/Arity)
       ),
    !.
glue_goal_module(Module, _, Module).

%  Caller-side start-goal wrapping (was local_actor_start_goal/5 in
%  actor.pl): propagate node port, public namespace, and public
%  profile into the child thread.
:- multifile actors:hook_spawn_context/2.
actors:hook_spawn_context(StartGoal0, StartGoal) :-
    (   current_node_port(NodePort)
    ->  StartGoal1 = node_runtime_state:with_node_port_context(NodePort, StartGoal0)
    ;   StartGoal1 = StartGoal0
    ),
    (   current_public_execution_namespace(Namespace)
    ->  StartGoal2 = node_execution_context:with_public_execution_namespace(Namespace, StartGoal1)
    ;   StartGoal2 = StartGoal1
    ),
    (   current_public_execution_profile(Profile)
    ->  StartGoal = node_execution_context:with_public_execution_profile(Profile, StartGoal2)
    ;   StartGoal = StartGoal2
    ).

%  Registry/visibility namespace (was current_public_execution_namespace
%  read directly by actor.pl).
:- multifile actors:hook_namespace/1.
actors:hook_namespace(Namespace) :-
    current_public_execution_namespace(Namespace).

%  The service registry is reserved for node-owned runtime code (was
%  require_service_registry_access/1 in actor.pl).
:- multifile actors:hook_service_registry_denied/0.
actors:hook_service_registry_denied :-
    current_public_execution_profile(_).

%  Per-actor memory ceiling: cap each actor thread's stack at the
%  node's max_actor_stack_bytes. Paired with the global actor cap
%  below, this bounds total node memory at max_actors × this value.
:- multifile actors:hook_thread_options/1.
actors:hook_thread_options([stack_limit(Bytes)]) :-
    current_node_value(max_actor_stack_bytes, Bytes),
    integer(Bytes),
    Bytes > 0.

%  Global concurrency cap: reject a local spawn once the node already
%  has max_actors live actors. Throws resource_error(actors), which
%  surfaces to clients as an ordinary error rather than a crash.
:- multifile actors:hook_admit_spawn/2.
actors:hook_admit_spawn(LiveCount, _Options) :-
    current_node_value(max_actors, Max),
    integer(Max),
    Max > 0,
    LiveCount >= Max,
    throw(error(resource_error(actors),
                context(node_glue:hook_admit_spawn/2,
                        'node actor limit reached'))).

%  Per-call inference ceiling for the toplevel /call and session path.
:- multifile toplevel_actors:hook_inference_limit/1.
toplevel_actors:hook_inference_limit(Limit) :-
    current_node_value(max_call_inferences, Limit),
    integer(Limit),
    Limit > 0.

%  The WS-context inheritance triple (was current_predicate-guarded
%  calls into node_ws from actor.pl's spawn_local).
:- multifile actors:hook_spawn_prepare/3.
actors:hook_spawn_prepare(Self, Options, Context) :-
    node_ws:prepare_inherited_ws_actor_spawn(Self, Options, Context).

:- multifile actors:hook_spawn_commit/2.
actors:hook_spawn_commit(Context, Pid) :-
    node_ws:commit_inherited_ws_actor_spawn(Context, Pid).

:- multifile actors:hook_spawn_abort/1.
actors:hook_spawn_abort(Context) :-
    node_ws:abort_inherited_ws_actor_spawn(Context).

%  Sandbox the goals a statechart embeds in its <onentry>/<onexit>/<go>
%  scripts and transition conditions.  The interpreter runs these as
%  statechart_actor:Goal with no checking of its own, so for a chart
%  spawned by an untrusted client (public execution profile active, and
%  propagated into the interpreter actor by hook_spawn_context/2) they
%  must pass the node sandbox -- otherwise a load_text/1 chart could run
%  arbitrary predicates.  No public profile (trusted desktop/test charts)
%  => no clause => check_chart_goal/1 is a no-op and behaviour is frozen.
:- multifile statechart_runtime:hook_check_chart_goal/1.
statechart_runtime:hook_check_chart_goal(Goal) :-
    current_public_execution_profile(Profile),
    !,
    node_sandbox:sandbox_check_goal_in_module(Profile, statechart_actor, Goal).


                /*******************************
                *       ISOLATION HOOKS        *
                *******************************/

%  Per-goal public guard (was rewrite_goal_if_needed/3 called from
%  actor.pl's execute_start_goal and toplevel_actor.pl's state_2).
:- multifile isolation:prepare_goal/3.
isolation:prepare_goal(Module, Goal0, Goal) :-
    rewrite_goal_if_needed(Module, Goal0, Goal).

%  Sandbox vetting of load options (was prepare_runtime_source_options
%  in actor_source.pl).
:- multifile isolation:prepare_source_options/3.
isolation:prepare_source_options(SourceModule, Options0, Options) :-
    current_public_execution_profile(Profile),
    node_sandbox:sandbox_prepare_source_options(Profile, SourceModule,
                                                Options0, Options).

%  Public runtime guard prelude (was inject_public_runtime_guards in
%  actor_source.pl).
:- multifile isolation:extra_prelude_text/2.
isolation:extra_prelude_text(_Options, Text) :-
    current_public_execution_profile(_),
    actor_public_guard_prelude_text(Text).

%  Blacklist source rewriting (was public_goal_guard calls in
%  source_loader.pl).
:- multifile isolation:rewrite_source_text/3.
isolation:rewrite_source_text(Module, Source0, Source) :-
    rewrite_source_text_if_needed(Module, Source0, Source).

:- multifile isolation:source_text_guard_active/0.
isolation:source_text_guard_active :-
    blacklist_guard_active.

%  Shared database module (was import_node_shared_db +
%  restore_shadowed_shared_db_imports reading node_runtime_state).
:- multifile isolation:shared_database_module/1.
isolation:shared_database_module(SharedModule) :-
    (   current_node_value(shared_db_module, SharedModule0)
    ->  SharedModule = SharedModule0
    ;   SharedModule = node_shared_db_runtime
    ).

%  Actor modules on a node see the full legacy actor.pl surface
%  (node_setting/2 and the distribution helpers included), as they
%  did through the legacy import_actor_api/1.
:- multifile isolation:prepare_module/3.
isolation:prepare_module(Module, _GoalModule, _Options) :-
    add_import_module(Module, actor_api, start).


                /*******************************
                *  PID_UTILS / SOURCE_UTILS    *
                *******************************/

%  Per-request node-URL scoping (was pid_utils' node_runtime_state
%  import).
:- multifile pid_utils:hook_current_node_url/1.
pid_utils:hook_current_node_url(URL) :-
    current_node_url(URL).

%  load_uri origin allowlist (was source_utils' node_runtime_state
%  import).
:- multifile source_utils:load_uri_allowed_origins/1.
source_utils:load_uri_allowed_origins(Origins) :-
    current_node_value(load_uri_allowed_origins, Origins).


                /*******************************
                *      DISTRIBUTION HOOKS      *
                *******************************/

%  Structured event sink (was node_log:log_event/1 called from
%  actor.pl's safe_remote_kill_send failure path).
:- multifile distribution:hook_event/1.
distribution:hook_event(Event) :-
    log_event(Event).

%  WS reader threads inherit the node's logging scope (was the
%  with_node_port_context wrap in actor.pl's remote_connection).
:- multifile distribution:hook_connection_context/2.
distribution:hook_connection_context(Goal0,
        node_runtime_state:with_node_port_context(Port, Goal0)) :-
    current_node_port(Port).

%  WS endpoint overrides for the in-process test harness (was
%  current_node_value(ws_endpoint_overrides) in actor.pl).
:- multifile distribution:hook_ws_endpoint_override/2.
distribution:hook_ws_endpoint_override(NodeURL, WsURL) :-
    current_node_value(ws_endpoint_overrides, Overrides),
    memberchk(NodeURL-WsURL, Overrides).


                /*******************************
                *      STATECHART HOOKS        *
                *******************************/

%  Session trace integration (was statechart_actor's node_session
%  import).
:- multifile statechart_actor:hook_set_session_trace/2.
statechart_actor:hook_set_session_trace(Pid, Enabled) :-
    node_session:set_isotope_session_trace(Pid, Enabled).

:- multifile statechart_actor:hook_session_trace_enabled/1.
statechart_actor:hook_session_trace_enabled(ClientPid) :-
    node_session:isotope_session_trace_enabled(ClientPid).

:- multifile statechart_actor:hook_client_session_pid/1.
statechart_actor:hook_client_session_pid(Pid) :-
    node_session:is_client_session_pid(Pid).
