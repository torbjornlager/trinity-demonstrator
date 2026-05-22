:- module(actor,  
   [ spawn/1,                % :Goal
     spawn/2,                % :Goal, -Pid
     spawn/3,                % :Goal, -Pid, +Options
     actors/1,               % -List of actors
     self/1,                 % -Pid
     monitor/2,              % +Pid, -Ref
     demonitor/1,            % +Ref
     demonitor/2,            % +Ref, +Options
     register/2,             % +Name, +Pid
     register_service/2,     % +Name, +Pid
     unregister/1,           % +Name
     unregister_service/1,   % +Name
     whereis/2,              % +Name, -Pid
     whereis_service/2,      % +Name, -Pid
     exit/1,                 % +Reason
     exit/2,                 % +Pid, +Reason
     (!)/2,                  % +Pid, +Message
     send/2,                 % +Pid, +Message
     send/3,                 % +Pid, +Message, +Options
     cancel/1,               % +ID
     input/2,                % +Prompt, ?Answer
     input/3,                % +Prompt, ?Answer, +Options
     respond/2,              % +Pid, +Answer
     output/1,               % +Term
     output/2,               % +Term, +Options
     terminal_output/1,      % +Term
     terminal_output/2,      % +Term, +Options
     receive/1,              % +ReceiveClauses
     receive/2,              % +ReceiveClauses, +Options
     with_io_target/2,       % +Target, :Goal
     make_id/1,              % -Id
     flush/0,                %
     actor_module/2,         % +Pid, -Module
     localhost_node/1,       % +Node
     register_node_self/1,   % +URL
     self_node_url/1,        % -URL
     canonical_pid/2,        % +Pid0, -Pid
     remote_request_spawn/3, % +NodeURL, +Command, -RemotePid
     remote_request_halt/3,  % +NodeURL, +RemotePid, -Reply
     remote_send_command/2,  % +NodeURL, +Command
     register_remote_pid/2,  % +CompoundPid, +Target
     flush_pending_for_pid/2,% +NodeURL, +RemotePid
     resolve_thread/2,       % +Pid, -ThreadId
     node_setting/2,         % ?Key, ?Value

     op(800,  xfx, !),       %
     op(200,  xfx, @),       %
     op(1000, xfy, if)       %
   ]).

/** <module> Minimal Erlang-style Actors for SWI-Prolog

This module provides a compact actor runtime used by the PoC.

Core properties:

  - one actor == one Prolog thread,
  - stable numeric pid separate from thread id,
  - mailbox messaging with selective receive,
  - directional links and monitors for supervision patterns,
  - per-actor module for loading private source code.

The implementation favors readability and explicitness over feature breadth.
*/

        
                /*******************************
                *             ACTOR            *
                *******************************/            

               
:- use_module(library(debug)).
:- use_module(library(option)).
:- use_module(library(random)).
:- use_module(library(modules)).
:- use_module(library(memfile)).
:- use_module(library(error)).
:- use_module(library(http/websocket)).
:- use_module(library(http/http_json)).
:- reexport(pid_utils, [
    localhost_node/1,
    register_node_self/1,
    self_node_url/1,
    canonical_pid/2
]).
:- use_module(pid_utils, [
    node_url_atom/2,
    local_node_url/1,
    pid_local/2
]).
:- use_module(remote_protocol, [
    term_to_wire_atom/2,
    ws_json_down_reason/2,
    ws_json_is_io_output/1,
    ws_json_to_actor_event/3
]).
:- use_module(source_utils, [terms_to_source/2]).
:- use_module(source_loader, [
    load_source_text/3,
    rewrite_source_options/3
]).
:- use_module(actor_source, [prepare_actor_module/3]).
:- use_module(node_runtime_state, [
    current_node_port/1,
    current_node_value/2,
    with_node_port_context/2
]).
:- use_module(node_execution_context, [
    current_public_execution_profile/1,
    with_public_execution_profile/2,
    current_public_execution_namespace/1,
    with_public_execution_namespace/2
]).
:- use_module(public_goal_guard, [rewrite_goal_if_needed/3]).
:- use_module(node_builtin_policy, [builtin_family_enabled/2]).
:- use_module(node_log, [log_event/1]).
:- use_module(node_controller, []).

:- meta_predicate
    spawn(:),
    spawn(:, -),
    spawn(:, -, +),
    receive(:),
    receive(:, +),
    with_io_target(+, 0),
    best_effort(0),
    best_effort_fail(0),
    best_effort_if_gone(0).



%!  spawn(:Goal) is det.
%!  spawn(:Goal, -Pid) is det.
%!  spawn(:Goal, -Pid, +Options) is det.
%
%   Spawn a new process.  Options:
%
%     - monitor(+Bool)
%       Send monitor events to the creator if the argument is `true`.
%     - link(+Bool)
%       If true, exit the spawned process if we exit.

/*
Runtime bookkeeping:

  - pid_thread/2 and thread_pid/2 map between logical pids and thread ids.
  - link/2 tracks parent->child crash propagation direction.
  - monitor/3 tracks monitor references for down messages.
  - io_target/1 is a thread-local override for output/input target.
*/

:- dynamic link/2.
:- dynamic pid_thread/2.
:- dynamic thread_pid/2.
:- dynamic actor_public_namespace/2.
:- dynamic main_pid/1.
:- thread_local io_target/1.

:- dynamic ws_connection/4.
:- dynamic ws_pending_event/3.

:- initialization(init_main_pid, after_load).

best_effort(Goal) :-
    catch(Goal, _, true).

best_effort_fail(Goal) :-
    catch(Goal, _, fail).

best_effort_if_gone(Goal) :-
    catch(Goal, error(existence_error(_,_), _), true).

%!  safe_remote_kill_send(+Node, +Pid, +ReasonAtom, +Command) is det.
%
%   Send a cross-node kill (`exit`) Command to Node over the shared
%   per-node WebSocket. Unlike best_effort/1, this helper makes failures
%   observable: on any I/O / connection error it logs a structured
%   ``remote_exit_failed`` event via node_log:log_event/1, sleeps briefly,
%   retries once, and on a second failure logs a terminal event that will
%   surface in /admin/runtime's recent_events. The helper never raises an
%   exception because callers run inside another actor's cleanup chain
%   (see exit/2 / stop/2) where a throw would corrupt the cleanup.
safe_remote_kill_send(Node, Pid, ReasonAtom, Command) :-
    catch(remote_send_command(Node, Command), Error1, true),
    (   var(Error1)
    ->  true
    ;   log_remote_exit_failure(Node, Pid, ReasonAtom, Error1, false),
        catch(sleep(0.05), _, true),
        catch(remote_send_command(Node, Command), Error2, true),
        (   var(Error2)
        ->  true
        ;   log_remote_exit_failure(Node, Pid, ReasonAtom, Error2, true)
        )
    ).

log_remote_exit_failure(Node, Pid, ReasonAtom, Error, Terminal) :-
    catch(
        ( format(string(PidText), '~w', [Pid]),
          format(string(NodeText), '~w', [Node]),
          format(string(ErrorText), '~q', [Error]),
          (   Terminal == true
          ->  Status = "terminal"
          ;   Status = "transient"
          ),
          format(string(Summary),
                 'remote exit send ~w (pid=~w node=~w)',
                 [Status, PidText, NodeText]),
          log_event(_{
              event_type: "remote_exit_failed",
              action: "exit",
              pid: PidText,
              node: NodeText,
              reason: ReasonAtom,
              error: ErrorText,
              status: Status,
              terminal: Terminal,
              summary: Summary
          })
        ),
        _,
        true
    ).

spawn(Goal) :-
    spawn(Goal, _Pid).

spawn(Goal, Pid) :-
    spawn(Goal, Pid, []).

spawn(Goal, Pid, Options) :-
    option(node(Node0), Options, localhost),
    (   localhost_node(Node0)
    ->  spawn_local(Goal, Pid, Options)
    ;   spawn_remote(Goal, Pid, Node0, Options)
    ).

%!  spawn_local(:Goal, -Pid, +Options) is det.
%
%   Spawn a regular local actor in this Prolog node.
spawn_local(Goal, Pid, Options) :-
    inherit_local_spawn_options(Options, EffectiveOptions0),
    prepare_public_spawn(Goal, EffectiveOptions0, EffectiveOptions),
    self(Self),
    inherited_ws_spawn_context(Self, EffectiveOptions, InheritedWSContext),
    make_id(LocalPid),
    canonical_pid(LocalPid, Pid),
    install_preconfigured_monitor(Pid, EffectiveOptions),
    local_actor_start_goal(Self, LocalPid, Goal, EffectiveOptions, StartGoal),
    catch(
        (
            thread_create(StartGoal, _Thread, [
                at_exit(stop_self(Self))
            ]),
            thread_get_message(initialized(Pid)),
            check_actor_start_error(Pid),
            commit_inherited_ws_spawn_context(InheritedWSContext, Pid)
        ),
        Error,
        (
            retractall(reserved_id(LocalPid)),
            abort_inherited_ws_spawn_context(InheritedWSContext),
            throw(Error)
        )
    ).

install_preconfigured_monitor(Pid, Options) :-
    option(monitor_target(Target), Options),
    !,
    option(monitor_ref(Ref), Options, Pid),
    assertz(monitor(Target, Pid, Ref)).
install_preconfigured_monitor(_, _).

%!  check_actor_start_error(+Pid) is det.
%
%   After receiving initialized(Pid), check whether the actor thread
%   also sent a start_error message indicating that module preparation
%   failed.  Module preparation errors are sent *before* initialized,
%   so if one is present it is already in the queue.  A zero-timeout
%   peek is sufficient — no heuristic delay.
check_actor_start_error(Pid) :-
    thread_self(Me),
    (   thread_get_message(Me, start_error(Pid, Error), [timeout(0)])
    ->  throw(Error)
    ;   true
    ).

startup_exit_signal(Pid, unwind(abort)) :-
    exit_reason(Pid, _).

local_actor_start_goal(Self, LocalPid, Goal, EffectiveOptions, StartGoal) :-
    StartGoal0 = start(Self, LocalPid, Goal, EffectiveOptions),
    (   current_node_port(NodePort)
    ->  StartGoal1 = with_node_port_context(NodePort, StartGoal0)
    ;   StartGoal1 = StartGoal0
    ),
    (   current_public_execution_namespace(Namespace)
    ->  StartGoal2 = with_public_execution_namespace(Namespace, StartGoal1)
    ;   StartGoal2 = StartGoal1
    ),
    (   current_public_execution_profile(Profile)
    ->  StartGoal = with_public_execution_profile(Profile, StartGoal2)
    ;   StartGoal = StartGoal2
    ).

inherit_local_spawn_options(Options0, Options) :-
    (   option(target(_), Options0)
    ->  Options = Options0
    ;   io_target(Target)
    ->  Options = [target(Target)|Options0]
    ;   Options = Options0
    ).

inherited_ws_spawn_context(Self, Options, Context) :-
    (   current_predicate(node_ws:prepare_inherited_ws_actor_spawn/3)
    ->  node_ws:prepare_inherited_ws_actor_spawn(Self, Options, Context)
    ;   Context = none
    ).

commit_inherited_ws_spawn_context(Context, Pid) :-
    (   current_predicate(node_ws:commit_inherited_ws_actor_spawn/2)
    ->  node_ws:commit_inherited_ws_actor_spawn(Context, Pid)
    ;   true
    ).

abort_inherited_ws_spawn_context(Context) :-
    (   current_predicate(node_ws:abort_inherited_ws_actor_spawn/1)
    ->  node_ws:abort_inherited_ws_actor_spawn(Context)
    ;   true
    ).

prepare_public_spawn(Goal, Options0, Options) :-
    (   current_public_execution_profile(Profile),
        current_predicate(node_sandbox:sandbox_prepare_public_spawn/5)
    ->  strip_module(Goal, GoalModule0, PlainGoal),
        normalize_goal_module(GoalModule0, PlainGoal, GoalModule),
        node_sandbox:sandbox_prepare_public_spawn(Profile, GoalModule,
                                                  PlainGoal, Options0, Options)
    ;   Options = Options0
    ).

%!  spawn_remote(:Goal, -Pid, +Node0, +Options) is det.
%
%   Spawn a remote actor over WebSocket and return a compound pid `Id@Node`.
%   Cross-node send/exit/monitor for the returned pid is handled by the
%   node_controller's routing tables (no per-pid local proxy actor).
spawn_remote(Goal, RemotePid@NodeURL, Node0, Options) :-
    self(Self),
    node_url_atom(Node0, NodeURL),
    strip_module(Goal, GoalModule0, PlainGoal),
    normalize_goal_module(GoalModule0, PlainGoal, SourceModule),
    term_to_wire_atom(PlainGoal, GoalAtom),
    remote_spawn_options(Options, SourceModule, RemoteOptions),
    term_to_wire_atom(RemoteOptions, RemoteOptionsAtom),
    remote_request_spawn(NodeURL, json{
        command: spawn,
        goal: GoalAtom,
        options: RemoteOptionsAtom
    }, RemotePid),
    CompoundPid = RemotePid@NodeURL,
    %  Step 6: no per-pid proxy actor.  Set up monitor and link
    %  FIRST, then register_remote_pid (which sets the controller's
    %  target row -- the readiness marker for inbound dispatch),
    %  then flush any events the WS reader buffered during the
    %  spawn round-trip.  Ordering matters: target last means a
    %  buffered down arriving in the race window has the monitor
    %  entries it needs by the time flush replays it.
    option(monitor(Monitor), Options, false),
    (   Monitor == true
    ->  assertz(monitor(Self, CompoundPid, CompoundPid)),
        node_controller:add_remote_monitor(Self, CompoundPid, CompoundPid)
    ;   true
    ),
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(link(Self, CompoundPid)),
        node_controller:add_remote_link(Self, CompoundPid)
    ;   true
    ),
    register_remote_pid(CompoundPid, Self),
    flush_pending_for_pid(NodeURL, RemotePid).

%!  remote_spawn_options(+Options, +SourceModule, -RemoteOptions) is det.
%
%   Strip local-only options before sending spawn options to the remote node.
remote_spawn_options(Options0, SourceModule, RemoteOptions) :-
    rewrite_source_options(Options0, SourceModule, Options1),
    exclude(local_only_spawn_option, Options1, RemoteOptions).

local_only_spawn_option(node(_)).
local_only_spawn_option(link(_)).
local_only_spawn_option(monitor(_)).
local_only_spawn_option(monitor_target(_)).
local_only_spawn_option(monitor_ref(_)).
local_only_spawn_option(source_module(_)).

%!  ws_send_json(+WebSocket, +JSONDict) is det.
ws_send_json(WebSocket, JSONDict) :-
    atom_json_dict(Text, JSONDict, []),
    ws_send(WebSocket, text(Text)).

%!  remote_request_spawn(+NodeURL, +Command, -RemotePid) is det.
%
%   Send a spawn-like command (`spawn` or `toplevel_spawn`) on the shared
%   WebSocket connection for NodeURL and wait for the corresponding
%   `spawned(Pid)` event.
remote_request_spawn(NodeURL, Command, RemotePid) :-
    ws_mutex(NodeURL, ws_spawn_lock, Mutex),
    with_mutex(Mutex,
               ( remote_connection(NodeURL, Socket, SpawnQueue),
                 ws_send_json(Socket, Command),
                 remote_wait_spawned(SpawnQueue, RemotePid)
               )).

remote_wait_spawned(SpawnQueue, RemotePid) :-
    catch(thread_get_message(SpawnQueue, Message),
          Error,
          throw(error(remote_spawn_failed(Error),
                      context(actor:remote_request_spawn/3,
                              'failed waiting for spawned event')))),
    (   Message = spawned(RemotePid)
    ->  true
    ;   Message = spawn_error(SpawnError)
    ->  throw(error(remote_spawn_failed(SpawnError),
                    context(actor:remote_request_spawn/3,
                            'remote node reported spawn failure')))
    ;   remote_wait_spawned(SpawnQueue, RemotePid)
    ).


%!  remote_request_halt(+NodeURL, +RemotePid, -Reply) is det.
%
%   Send a toplevel_halt command for RemotePid over the shared per-node
%   WebSocket and synchronously wait for the corresponding halted event.
%   The matching wire response is produced by node_ws.pl's
%   ws_action_toplevel_halt/3 and routed back here by
%   remote_ws_dispatch/3 (which now also recognizes type:"halted").
remote_request_halt(NodeURL, RemotePid, Reply) :-
    ws_mutex(NodeURL, ws_spawn_lock, Mutex),
    with_mutex(Mutex,
               ( remote_connection(NodeURL, Socket, SpawnQueue),
                 ws_send_json(Socket, json{
                     command: toplevel_halt,
                     pid: RemotePid
                 }),
                 remote_wait_halted(SpawnQueue, RemotePid, Reply)
               )).

remote_wait_halted(SpawnQueue, RemotePid, Reply) :-
    catch(thread_get_message(SpawnQueue, Message),
          Error,
          throw(error(remote_halt_failed(Error),
                      context(actor:remote_request_halt/3,
                              'failed waiting for halted event')))),
    (   Message = halted(RemotePid, Reply)
    ->  true
    ;   remote_wait_halted(SpawnQueue, RemotePid, Reply)
    ).

%!  remote_send_command(+NodeURL, +Command) is det.
%
%   Send a JSON command over the shared per-node WebSocket connection.
remote_send_command(NodeURL, Command) :-
    ws_mutex(NodeURL, ws_send_lock, Mutex),
    with_mutex(Mutex,
               ( remote_connection(NodeURL, Socket, _SpawnQueue),
                 ws_send_json(Socket, Command)
               )).

%!  register_remote_proxy(+CompoundPid, +LocalProxyPid) is det.
%
%   Register local proxy for a remote pid and immediately flush any buffered
%   events that arrived before registration completed.
%!  register_remote_pid(+CompoundPid, +Target) is det.
%
%   Step 6 replacement for register_remote_proxy/2.  Records
%   CompoundPid -> Target in the node_controller table.  Does NOT
%   flush pending events: callers must finish their controller setup
%   (monitor/link installation) before calling flush_pending_for_pid/2
%   so that any buffered down events have the correct monitor entries
%   to deliver against.
register_remote_pid(RemotePid@NodeURL, Target) :-
    node_controller:register_remote_target(RemotePid@NodeURL, Target).


%!  flush_pending_for_pid(+NodeURL, +RemotePid) is det.
%
%   Re-dispatch every WS event that the reader buffered for
%   RemotePid before the local side finished registering the pid.
%   Each buffered dict goes through remote_per_pid_dispatch/2 so
%   down events fire monitors via the controller and other events
%   are forwarded to the controller-registered target.
flush_pending_for_pid(NodeURL, RemotePid) :-
    forall(retract(ws_pending_event(NodeURL, RemotePid, Dict)),
           remote_per_pid_dispatch(NodeURL, Dict)).


%!  remote_per_pid_dispatch(+NodeURL, +Dict) is det.
%
%   Per-pid dispatch shared by remote_ws_dispatch/3 (the inline
%   reader path) and flush_pending_for_pid/2 (the buffered-event
%   replay path).
remote_per_pid_dispatch(NodeURL, Dict) :-
    (   remote_event_pid(Dict, RemotePid)
    ->  CompoundPid = RemotePid@NodeURL,
        (   get_dict(type, Dict, "down")
        ->  deliver_remote_down_via_controller(CompoundPid, Dict)
        ;   ws_json_is_io_output(Dict)
        ->  true        % suppress remote I/O outputs -- see remote_ws_dispatch/3
        ;   node_controller:current_remote_target(CompoundPid, Target),
            ws_json_to_actor_event(Dict, CompoundPid, Event)
        ->  send(Target, Event)
        ;   true
        )
    ;   true
    ).

%!  remote_connection(+NodeURL, -Socket, -SpawnQueue) is det.
%
%   Return a live shared WebSocket connection for NodeURL, creating it if
%   needed.
remote_connection(NodeURL, Socket, SpawnQueue) :-
    ws_mutex(NodeURL, ws_connection_lock, Mutex),
    with_mutex(Mutex,
               remote_connection_locked(NodeURL, Socket, SpawnQueue)).

remote_connection_locked(NodeURL, Socket, SpawnQueue) :-
    (   ws_connection(NodeURL, Socket0, ReaderThread, SpawnQueue0),
        thread_running(ReaderThread)
    ->  Socket = Socket0,
        SpawnQueue = SpawnQueue0
    ;   remote_drop_connection(NodeURL),
        node_url_to_ws_endpoint(NodeURL, WsURL),
        internal_transport_ws_options(WSOptions),
        http_open_websocket(WsURL, Socket, WSOptions),
        message_queue_create(SpawnQueue),
        %  Capture the calling thread's node port so the reader thread
        %  inherits the same logging scope as the rest of the local
        %  node's threads -- without this, any log_event from
        %  remote_ws_dispatch (e.g. future telemetry) would fall through
        %  to the `global` scope and not appear in /admin/runtime.
        (   current_node_port(CallerPort)
        ->  ReaderEntry = with_node_port_context(
                              CallerPort,
                              remote_ws_reader(NodeURL, Socket, SpawnQueue))
        ;   ReaderEntry = remote_ws_reader(NodeURL, Socket, SpawnQueue)
        ),
        thread_create(ReaderEntry, ReaderThread, [
            detached(true)
        ]),
        assertz(ws_connection(NodeURL, Socket, ReaderThread, SpawnQueue))
    ).


internal_transport_ws_options([
    request_header('X-Web-Prolog-User'=PrincipalId),
    request_header('X-Web-Prolog-Capabilities'=CapabilityHeader)
]) :-
    self_node_url(SelfURL),
    format(string(PrincipalId), "node:~w", [SelfURL]),
    CapabilityHeader = "execute,internal_transport".

thread_running(ThreadId) :-
    best_effort_fail(thread_property(ThreadId, status(running))).

remote_drop_connection(NodeURL) :-
    forall(retract(ws_connection(NodeURL, Socket, _Reader, SpawnQueue)),
           ( best_effort(ws_close(Socket, 1000, "done")),
             best_effort(message_queue_destroy(SpawnQueue))
           )),
    retractall(ws_pending_event(NodeURL, _, _)).

remote_ws_reader(NodeURL, Socket, SpawnQueue) :-
    best_effort(remote_ws_read_loop(NodeURL, Socket, SpawnQueue)),
    remote_ws_connection_closed(NodeURL).

remote_ws_read_loop(NodeURL, Socket, SpawnQueue) :-
    ws_receive(Socket, Frame, []),
    (   Frame.opcode == close
    ->  true
    ;   Frame.opcode == text,
        best_effort_fail(atom_json_dict(Frame.data, Dict, []))
    ->  remote_ws_dispatch(NodeURL, SpawnQueue, Dict),
        remote_ws_read_loop(NodeURL, Socket, SpawnQueue)
    ;   remote_ws_read_loop(NodeURL, Socket, SpawnQueue)
    ).

remote_ws_dispatch(NodeURL, SpawnQueue, Dict) :-
    (   %  Step 6c: down events handled entirely by the controller.
        %  No more proxy hand-off.  Discriminator: if a target is
        %  registered for the pid, the local side has completed its
        %  setup and we can deliver now; otherwise we are racing
        %  ahead of the spawn caller's register_remote_pid -- buffer
        %  the dict and let flush_pending_for_pid replay it later.
        get_dict(type, Dict, "down"),
        remote_event_pid(Dict, RemotePid)
    ->  CompoundPid = RemotePid@NodeURL,
        (   node_controller:current_remote_target(CompoundPid, _)
        ->  deliver_remote_down_via_controller(CompoundPid, Dict)
        ;   assertz(ws_pending_event(NodeURL, RemotePid, Dict))
        )
    ;   get_dict(type, Dict, "spawned"),
        get_dict(pid, Dict, RawPid),
        normalize_remote_pid(RawPid, RemotePid)
    ->  best_effort(thread_send_message(SpawnQueue, spawned(RemotePid)))
    %  Halted ack from a cross-node toplevel_halt/2 request: route to the
    %  shared SpawnQueue (reused for control-plane request/response) where
    %  remote_request_halt/3 is waiting.  The Reply field is serialized
    %  on the remote node via term_to_json_string/2, so it arrives as a
    %  JSON string -- parse it back to a Prolog term here so callers see
    %  the atom `true` (or whatever term the remote toplevel returned)
    %  instead of the string "true".
    ;   get_dict(type, Dict, "halted"),
        get_dict(pid, Dict, RawPid),
        normalize_remote_pid(RawPid, RemotePid)
    ->  (   get_dict(reply, Dict, Reply0),
            parse_halted_reply(Reply0, ReplyTerm)
        ->  ReplyValue = ReplyTerm
        ;   ReplyValue = true
        ),
        best_effort(thread_send_message(SpawnQueue, halted(RemotePid, ReplyValue)))
    ;   get_dict(type, Dict, "error"),
        \+ get_dict(pid, Dict, _)
    ->  (get_dict(data, Dict, Data) -> ErrorData = Data ; ErrorData = "remote error"),
        best_effort(thread_send_message(SpawnQueue, spawn_error(ErrorData)))
    ;   %  Remote I/O outputs are dropped: a local toplevel only
        %  sees terminal output from actors in its own node and
        %  local descendant lineage (manual.html capability rule for
        %  the terminal I/O channel).  Pinned by node_tests.pl tests
        %  ws_remote_actor_io_output_suppressed and
        %  ws_remote_toplevel_io_output_suppressed.
        remote_event_pid(Dict, RemotePid),
        ws_json_is_io_output(Dict)
    ->  true
    ;   %  Forward non-down per-pid events (success, prompt, stop,
        %  abort, responded, ...) directly to the controller-
        %  registered local target.  When no controller target
        %  exists, fall back to buffering as ws_pending_event so
        %  events arriving before registration completes can be
        %  replayed by flush_pending_for_pid/2.
        remote_event_pid(Dict, RemotePid),
        CompoundPid = RemotePid@NodeURL,
        node_controller:current_remote_target(CompoundPid, Target),
        ws_json_to_actor_event(Dict, CompoundPid, Event)
    ->  send(Target, Event)
    ;   remote_event_pid(Dict, RemotePid)
    ->  route_remote_event(NodeURL, RemotePid, Dict)
    ;   true
    ).

remote_event_pid(Dict, RemotePid) :-
    get_dict(pid, Dict, RawPid),
    normalize_remote_pid(RawPid, RemotePid),
    integer(RemotePid).


%!  deliver_remote_down_via_controller(+CompoundPid, +Dict) is det.
%
%   Drain both the controller's remote_monitor_/3 table and the
%   actor module's monitor/3 table for CompoundPid, and synchronously
%   deliver down/3 messages to each watcher.  Draining both tables
%   atomically prevents the proxy's finalize from re-delivering the
%   same down events.
deliver_remote_down_via_controller(CompoundPid, Dict) :-
    (   ws_json_down_reason(Dict, Reason)
    ->  true
    ;   Reason = unknown
    ),
    node_controller:take_remote_monitors_for_pid(CompoundPid, Entries),
    retractall(monitor(_, CompoundPid, _)),
    %  Step 6 cleanup: the remote pid is gone, so its target
    %  registration and any link records that pointed to it are
    %  now stale.  In the proxy era this was done by the proxy's
    %  setup_call_cleanup finalize; now it is part of the
    %  controller's death-of-remote-pid handling.
    node_controller:forget_remote_target(CompoundPid),
    retractall(node_controller:remote_link_(_, CompoundPid)),
    retractall(link(_, CompoundPid)),
    forall(member(monitor(Watcher, Ref), Entries),
           send(Watcher, down(Ref, CompoundPid, Reason))).

%!  parse_halted_reply(+Raw, -Term) is semidet.
%
%   Convert a halted-reply value (an atom or string in JSON) back into a
%   Prolog term.  The matching producer is node_response.pl's
%   answer_to_json(halted(_, Reply), ...) clause, which serializes Reply
%   via term_to_json_string/2.
parse_halted_reply(Raw, Term) :-
    (   atom(Raw)
    ->  RawAtom = Raw
    ;   string(Raw)
    ->  atom_string(RawAtom, Raw)
    ;   fail
    ),
    catch(term_to_atom(Term, RawAtom), _, fail).

normalize_remote_pid(Pid0, Pid) :-
    integer(Pid0),
    !,
    Pid = Pid0.
normalize_remote_pid(Pid0, Pid) :-
    atom(Pid0),
    !,
    normalize_remote_pid_atom(Pid0, Pid).
normalize_remote_pid(Pid0, Pid) :-
    string(Pid0),
    atom_string(PidAtom, Pid0),
    normalize_remote_pid_atom(PidAtom, Pid).

normalize_remote_pid_atom(PidAtom, Pid) :-
    (   atom_number(PidAtom, Pid)
    ->  true
    ;   best_effort_fail(term_to_atom(Term, PidAtom)),
        Term = Pid@_
    ).

%!  route_remote_event(+NodeURL, +RemotePid, +Dict) is det.
%
%   Fallback buffer for events that arrive before the local side
%   has finished registering the pid (the race between
%   remote_request_spawn returning a pid and spawn_remote calling
%   register_remote_pid + setting monitors).  The buffered entries
%   are drained later by flush_pending_for_pid/2.
route_remote_event(NodeURL, RemotePid, Dict) :-
    assertz(ws_pending_event(NodeURL, RemotePid, Dict)).

remote_ws_connection_closed(NodeURL) :-
    ws_mutex(NodeURL, ws_connection_lock, Mutex),
    with_mutex(Mutex,
               remote_drop_connection(NodeURL)),
    %  Controller-side connection-drop cleanup.  Walk the cross-node
    %  monitor table for pids on NodeURL and fire down/3 with
    %  reason=connection_closed to every watcher; drop target/link
    %  state for the disconnected node.  Also drain the actor
    %  module's monitor/3 table for those pids.
    node_controller:take_remote_monitors_on_node(NodeURL, MonitorEntries),
    forall(member(monitor(Watcher, CompoundPid, Ref), MonitorEntries),
           ( retractall(monitor(_, CompoundPid, _)),
             send(Watcher, down(Ref, CompoundPid, connection_closed))
           )),
    node_controller:drop_remote_state_for_node(NodeURL).

ws_mutex(NodeURL, Prefix, Mutex) :-
    format(atom(Mutex), '~w::~w', [Prefix, NodeURL]).

%!  node_url_to_ws_endpoint(+NodeURL, -WsURL) is det.
node_url_to_ws_endpoint(NodeURL, WsURL) :-
    current_node_value(ws_endpoint_overrides, Overrides),
    memberchk(NodeURL-WsURL, Overrides),
    !.
node_url_to_ws_endpoint(NodeURL, WsURL) :-
    atom_string(NodeURL, URLStr),
    (   sub_string(URLStr, 0, 8, _, "https://")
    ->  sub_string(URLStr, 8, _, 0, Rest),
        Scheme = wss
    ;   sub_string(URLStr, 0, 7, _, "http://")
    ->  sub_string(URLStr, 7, _, 0, Rest),
        Scheme = ws
    ;   Rest = URLStr,
        Scheme = ws
    ),
    (   sub_string(Rest, _, 1, 0, "/")
    ->  sub_string(Rest, 0, _, 1, Base)
    ;   Base = Rest
    ),
    format(atom(WsURL), "~w://~w/ws", [Scheme, Base]).


%!  init_main_pid is det.
%
%   Ensure the main REPL thread also has a pid mapping.
init_main_pid :-
    thread_property(main, id(MainThreadId)),
    (   thread_pid(MainThreadId, ExistingPid)
    ->  (   main_pid(ExistingPid)
        ->  true
        ;   assertz(main_pid(ExistingPid))
        )
    ;   make_id(MainPid),
        assertz(pid_thread(MainPid, MainThreadId)),
        assertz(thread_pid(MainThreadId, MainPid)),
        assertz(main_pid(MainPid))
    ).


%!  pid_module(+Pid, -Module) is det.
%
%   Map actor pid to private module where its code lives.
pid_module(main, user) :- !.
pid_module(Pid, user) :-
    main_pid(Pid),
    !.
pid_module(Pid, Module) :-
    integer(Pid),
    format(atom(Module), 'actor_~w', [Pid]).

%!  actor_module(+Pid, -Module) is det.

actor_module(Pid, Module) :-
    pid_local(Pid, LocalPid),
    pid_module(LocalPid, Module).

:- thread_local '$parent'/1.

%!  '$actor_parent'(-Parent) is semidet.

'$actor_parent'(Parent) :-
    '$parent'(Parent).

%!  make_id(-Id) is det.
%
%   Generate a random, currently-unused 10-digit actor id.
%   A mutex makes the uniqueness check and reservation atomic.
%   The reserved_id/1 fact acts as a lightweight claim so that
%   concurrent spawners cannot pick the same id before the child
%   thread asserts pid_thread/2.  The reservation is cleaned up
%   by the child in start/4 once pid_thread/2 is in place.
:- dynamic reserved_id/1.

make_id(Id) :-
    with_mutex('$make_id', (
        repeat,
        random_between(1000000000, 9999999999, Id),
        \+ pid_thread(Id, _),
        \+ reserved_id(Id),
        !,
        assertz(reserved_id(Id))
    )).


%!  stop_self(+Parent) is det.
%
%   Thread at-exit callback.
stop_self(Parent) :-
    self_local(LocalPid),
    stop(LocalPid, Parent).

%!  start(+Parent, +Pid, :Goal, +Options) is det.
%
%   Actor bootstrap sequence:
%
%     1. register pid/thread mapping,
%     2. install optional link/monitor,
%     3. prepare per-actor module and load sources,
%     4. execute Goal in that module.
start(Parent, Pid, Goal, Options) :-
    thread_self(Thread),
    thread_property(Thread, id(ThreadId)),
    assertz(pid_thread(Pid, ThreadId)),
    retractall(reserved_id(Pid)),
    assertz(thread_pid(ThreadId, Pid)),
    canonical_pid(Pid, GlobalPid),
    assertz('$parent'(Parent)),
    remember_actor_public_namespace(Pid),
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(link(Parent, GlobalPid))
    ;   true
    ),
    option(monitor(Monitor), Options, false),
    (   Monitor == true
    ->  assertz(monitor(Parent, GlobalPid, GlobalPid))
    ;   true
    ),
    strip_module(Goal, GoalModule0, Plain),
    normalize_goal_module(GoalModule0, Plain, GoalModule),
    pid_module(Pid, Module),
    catch(
        in_temporary_module(Module,
                            start_prepare_module(Parent, GlobalPid,
                                                 Module, GoalModule, Options),
                            execute_start_goal(Module, Plain, Options)),
        StartError,
        (   (   startup_exit_signal(Pid, StartError)
            ->  true
            ;   true
            ),
            throw(StartError)
        )
    ).


%!  start_prepare_module(+Parent, +GlobalPid, +Module, +GoalModule, +Options) is det.
%
%   Prepare the actor module and notify the parent.  On success,
%   `initialized(GlobalPid)` is sent so the parent knows the actor
%   is ready.  On failure, `start_error(GlobalPid, Error)` is sent
%   *before* `initialized` so the parent can detect the failure with
%   a zero-timeout peek after receiving `initialized`.
start_prepare_module(Parent, GlobalPid, Module, GoalModule, Options) :-
    catch(
        prepare_actor_module(Module, GoalModule, Options),
        PrepError,
        (   send_thread_message(Parent, start_error(GlobalPid, PrepError)),
            send_thread_message(Parent, initialized(GlobalPid)),
            throw(PrepError)
        )
    ),
    send_thread_message(Parent, initialized(GlobalPid)).

%!  execute_start_goal(+Module, +Goal, +Options) is det.
%
%   Run actor start goal, honoring an optional spawn-time I/O target.
execute_start_goal(Module, Goal, Options) :-
    rewrite_goal_if_needed(Module, Goal, RewrittenGoal),
    (   option(target(Target), Options)
    ->  with_io_target(Target, call(Module:RewrittenGoal))
    ;   call(Module:RewrittenGoal)
    ).

remember_actor_public_namespace(Pid) :-
    (   current_public_execution_namespace(Namespace)
    ->  retractall(actor_public_namespace(Pid, _)),
        assertz(actor_public_namespace(Pid, Namespace))
    ;   true
    ).

%!  normalize_goal_module(+GoalModule0, +PlainGoal, -GoalModule) is det.
%
%   When caller module is `actor` but predicate actually belongs to `user`,
%   use `user` as import source.
normalize_goal_module(actor, Plain, user) :-
    \+ predicate_in_module(actor, Plain),
    !.
normalize_goal_module(Module, _, Module).

predicate_in_module(Module, Goal) :-
    callable(Goal),
    functor(Goal, Name, Arity),
    current_predicate(Module:Name/Arity).
                                       
%!  consult_load_list(+ListOfTerms) is det.
%!  consult_load_list(+ListOfTerms, +Module) is det.
%
%   Consult a list of clauses in the relevant module.   

consult_load_list(List) :-
    self(Pid),
    actor_module(Pid, Module),
    consult_load_list(List, Module).

consult_load_list(List, Module) :-
    terms_to_source(List, Source),
    load_source_text(Source, Module, load_list).

%!  listing_private is det.
%!  listing_private(+Pid) is det.
%
%   Emit a textual listing of predicates defined in the relevant actor's
%   private module. Imported predicates and the injected actor I/O wrapper
%   predicates are excluded. In public execution contexts, `listing_private/1`
%   is namespace-scoped so clients can only inspect their own actors.
listing_private :-
    self(Pid),
    actor_module(Pid, Module),
    emit_private_listing(Module).

listing_private(Pid) :-
    listing_target_module(Pid, Module),
    emit_private_listing(Module).

listing_target_module(Pid0, Module) :-
    (   pid_local(Pid0, LocalPid)
    ->  true
    ;   throw(error(existence_error(actor, Pid0),
                    context(actor:listing_private/1,
                            'actor pid is not local to this node')))
    ),
    (   resolve_thread(LocalPid, _)
    ->  true
    ;   throw(error(existence_error(actor, Pid0),
                    context(actor:listing_private/1,
                            'unknown or expired actor pid')))
    ),
    require_listing_visibility(LocalPid, Pid0),
    pid_module(LocalPid, Module).

require_listing_visibility(LocalPid, Pid0) :-
    (   current_public_execution_namespace(Namespace)
    ->  (   actor_public_namespace(LocalPid, Namespace)
        ->  true
        ;   throw(error(permission_error(access, actor_private_database, Pid0),
                        context(actor:listing_private/1,
                                'actor pid is not visible in current public namespace')))
        )
    ;   true
    ).

emit_private_listing(Module) :-
    findall(Name/Arity,
            private_listing_predicate(Module, Name, Arity),
            PredicateIndicators0),
    sort(PredicateIndicators0, PredicateIndicators),
    new_memory_file(MemoryFile),
    setup_call_cleanup(
        open_memory_file(MemoryFile, write, Stream),
        portray_private_listing(Stream, Module, PredicateIndicators),
        close(Stream)
    ),
    memory_file_to_string(MemoryFile, Text),
    free_memory_file(MemoryFile),
    (   Text == ""
    ->  true
    ;   terminal_output(Text)
    ).

private_listing_predicate(Module, Name, Arity) :-
    current_predicate(Module:Name/Arity),
    \+ private_listing_hidden(Name/Arity),
    functor(Head, Name, Arity),
    \+ predicate_property(Module:Head, imported_from(_)),
    predicate_property(Module:Head, number_of_clauses(ClauseCount)),
    ClauseCount > 0.

portray_private_listing(_Stream, _Module, []) :-
    !.
portray_private_listing(Stream, Module, PredicateIndicators) :-
    nl(Stream),
    portray_private_listing_items(Stream, Module, PredicateIndicators).

portray_private_listing_items(Stream, Module, [Name/Arity]) :-
    !,
    portray_private_predicate(Stream, Module, Name, Arity).
portray_private_listing_items(Stream, Module, [Name/Arity|Rest]) :-
    portray_private_predicate(Stream, Module, Name, Arity),
    nl(Stream),
    portray_private_listing_items(Stream, Module, Rest).

portray_private_predicate(Stream, Module, Name, Arity) :-
    functor(Head, Name, Arity),
    forall(clause(Module:Head, Body),
           portray_private_clause(Stream, Head, Body)).

portray_private_clause(Stream, Head, true) :-
    !,
    system:portray_clause(Stream, Head).
portray_private_clause(Stream, Head, Body) :-
    system:portray_clause(Stream, (Head :- Body)).

private_listing_hidden(display/1).
private_listing_hidden(format/1).
private_listing_hidden(format/2).
private_listing_hidden(listing/0).
private_listing_hidden(listing/1).
private_listing_hidden(nl/0).
private_listing_hidden(print/1).
private_listing_hidden(time/1).
private_listing_hidden(write/1).
private_listing_hidden(write_canonical/1).
private_listing_hidden(write_term/2).
private_listing_hidden(writeq/1).
private_listing_hidden(writeln/1).
private_listing_hidden(actor_time_output/1).
private_listing_hidden(actor_time_string/2).
private_listing_hidden(format_to_atom_safe/2).
private_listing_hidden(reject_format_call_specifier/1).
private_listing_hidden('$parent'/1).



%!  stop(+Pid, +Parent) is det.
%
%   Final actor cleanup:
%
%     - remove links, names and delayed-send records,
%     - kill linked children,
%     - notify monitors with down messages,
%     - remove temporary module and pid/thread mappings.
stop(Pid, Parent) :-
    canonical_pid(Pid, GlobalPid),
    (   pid_thread(Pid, ThreadId)
    ->  thread_detach(ThreadId)
    ;   true
    ),
    retractall(link(Parent, GlobalPid)),
    retractall(registered(_Namespace, _Name, GlobalPid)),
    retractall(registered_service(_ServiceName, GlobalPid)),
    retractall(delayed_send(_ID, GlobalPid)),
    forall(retract(link(GlobalPid, ChildPid)),
           exit(ChildPid, kill)),
    %  Step 2 mirror: drain the node_controller's view of this
    %  parent's cross-node children too, keeping the controller
    %  consistent with the proxy era's link/2 walk above.  Reading
    %  side will move to this in step 5.
    node_controller:take_remote_children_for_parent(GlobalPid, _DrainedRemoteChildren),
    down_reason(Pid, Reason),
    forall(retract(monitor(Other, GlobalPid, Ref)),
           Other ! down(Ref, GlobalPid, Reason)),
    pid_module(Pid, Module),
    best_effort(delete_module(Module)),
    retractall(actor_public_namespace(Pid, _)),
    retractall(pid_thread(Pid, _)),
    retractall(thread_pid(_, Pid)).


%!  down_reason(+Pid, -Reason) is det.
%
%   Derive best available termination reason for monitor notifications.
%   exit_reason/2 is checked first because it is an application-level
%   fact that survives thread detach/join; relying on is_thread/1 as a
%   guard caused the lookup to fall through to noproc when the thread
%   had already been cleaned up.
down_reason(Pid, Reason) :-
    retract(exit_reason(Pid, Reason)),
    !.
down_reason(Pid, Reason) :-
    pid_thread(Pid, ThreadId),
    is_thread(ThreadId),
    thread_property(ThreadId, status(Reason)),
    !.
down_reason(_, noproc).


%!  actors(-Pids) is det.
%
%   Generate a list of active pids.

actors(Pids) :-
    (   current_public_execution_namespace(Namespace)
    ->  findall(
            Pid,
            ( pid_thread(LocalPid, ThreadId),
              is_thread(ThreadId),
              actor_public_namespace(LocalPid, Namespace),
              canonical_pid(LocalPid, Pid)
            ),
            Pids
        )
    ;   findall(
            Pid,
            ( pid_thread(LocalPid, ThreadId),
              is_thread(ThreadId),
              canonical_pid(LocalPid, Pid)
            ),
            Pids
        )
    ).


%!  node_setting(?Key, ?Value) is nondet.
%
%   Query a publicly visible setting of the node servicing this request.
%   With Key unbound, enumerates all keys that the node is willing to
%   share. Sensitive runtime state (shared DB source, principal policies,
%   developer credentials) is deliberately not exposed.

node_setting(Key, Value) :-
    public_node_setting(Key, Family),
    setting_family_visible(Family),
    current_node_value(Key, Value).

setting_family_visible(always) :- !.
setting_family_visible(Family) :-
    current_node_value(profile, Profile),
    builtin_family_enabled(Profile, Family).

public_node_setting(url, always).
public_node_setting(profile, always).
public_node_setting(sandbox, always).
public_node_setting(auth, always).
public_node_setting(timeout, always).
public_node_setting(rate_window_seconds, always).
public_node_setting(max_inflight_calls, stateless_api).
public_node_setting(max_term_text_bytes, stateless_api).
public_node_setting(max_call_requests_per_window, stateless_api).
public_node_setting(max_load_text_bytes, private_db).
public_node_setting(load_uri_allowed_origins, private_db).
public_node_setting(max_sessions_per_principal, semistateful_api).
public_node_setting(max_session_spawns_per_window, semistateful_api).
public_node_setting(max_ws_actors_per_principal, stateful_api).
public_node_setting(max_ws_frame_bytes, stateful_api).
public_node_setting(max_ws_commands_per_window, stateful_api).


%!  self(-Pid) is det.
%
%   Find who we are.

self(Self) :-
    self_local(LocalPid),
    canonical_pid(LocalPid, Self).

self_local(Self) :-
    thread_self(Thread),
    thread_property(Thread, id(ThreadId)),
    (   thread_pid(ThreadId, Pid)
    ->  Self = Pid
    ;   Self = ThreadId
    ).


%!  monitor(+Pid) is det.
%!  demonitor(+Pid) is det.
%
%   Monitoring/demonitoring of processes.

:- dynamic monitor/3.

monitor(Name, Ref) :-
    current_registered(Name, Pid),
    !,
    monitor(Pid, Ref).
monitor(Pid, Ref) :-
    self(Self),
    canonical_pid(Pid, CanonPid),
    make_id(Ref),
    assertz(monitor(Self, CanonPid, Ref)),
    %  Step 2 mirror: if the watched pid is one the controller
    %  already knows about (i.e. it was obtained from a cross-node
    %  spawn that registered a remote_target_/2 row), also record
    %  the monitor in the controller's cross-node table.  Using the
    %  controller's own table as the discriminator -- rather than
    %  `\+ local_node_url(Node)` -- keeps the check correct in the
    %  in-process integration harness, where a single registered
    %  self_node_url makes "remote" pids look local.
    (   node_controller:current_remote_target(CanonPid, _)
    ->  node_controller:add_remote_monitor(Self, CanonPid, Ref)
    ;   true
    ).


demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    retractall(monitor(_, _, Ref)),
    %  Step 2 mirror: keep node_controller's cross-node monitor
    %  table in sync.
    node_controller:remove_remote_monitor_by_ref(Ref),
    (   option(flush, Options)
    ->  receive({
            down(Ref, _, _) ->
                true
        }, [timeout(0)])
    ;   true
    ).

%!  register(+Name, +Pid) is det.
%
%   Register the given Pid under the name Name.

:- dynamic registered/3.
:- dynamic registered_service/2.
:- dynamic delayed_send/2.

register(Name, Pid) :-
    must_be(atom, Name),
    canonical_pid(Pid, CanonPid),
    current_registry_namespace(Namespace),
    ensure_name_registration_available(Namespace, Name, Pid, CanonPid),
    asserta(registered(Namespace, Name, CanonPid)).

register_service(Name, Pid) :-
    require_service_registry_access(register_service(Name, Pid)),
    must_be(atom, Name),
    canonical_pid(Pid, CanonPid),
    ensure_service_registration_available(Name, Pid, CanonPid),
    asserta(registered_service(Name, CanonPid)).
    
%!  unregister(+Name) is det.
%

unregister(Name) :-
    must_be(atom, Name),
    current_registry_namespace(Namespace),
    retractall(registered(Namespace, Name, _)).

unregister_service(Name) :-
    require_service_registry_access(unregister_service(Name)),
    must_be(atom, Name),
    retractall(registered_service(Name, _)).
    
%!  whereis(?Name, Pid) is det.
%

whereis(Name, Pid) :-
    must_be(atom, Name),
    current_registered(Name, Pid),
    !.
whereis(_Name, undefined).

whereis_service(Name, Pid) :-
    require_service_registry_access(whereis_service(Name, Pid)),
    must_be(atom, Name),
    registered_service(Name, Pid),
    !.
whereis_service(_Name, undefined).

ensure_name_registration_available(Namespace, Name, Pid, CanonPid) :-
    (   ordinary_registered_pid(Namespace, CanonPid)
    ->  throw(process_already_has_a_name(Pid))
    ;   service_registered_pid(CanonPid)
    ->  throw(process_already_has_a_name(Pid))
    ;   ordinary_registered_name(Namespace, Name)
    ->  throw(name_is_in_use(Name))
    ;   published_service_name(Name)
    ->  throw(name_is_in_use(Name))
    ;   true
    ).

ensure_service_registration_available(Name, Pid, CanonPid) :-
    (   service_registered_pid(CanonPid)
    ->  throw(process_already_has_a_name(Pid))
    ;   ordinary_registered_pid(_, CanonPid)
    ->  throw(process_already_has_a_name(Pid))
    ;   published_service_name(Name)
    ->  throw(name_is_in_use(Name))
    ;   ordinary_registered_name(_, Name)
    ->  throw(name_is_in_use(Name))
    ;   true
    ).

service_registered_pid(CanonPid) :-
    registered_service(_, CanonPid).

ordinary_registered_pid(Namespace, CanonPid) :-
    nonvar(Namespace),
    !,
    registered(Namespace, _, CanonPid).
ordinary_registered_pid(_, CanonPid) :-
    registered(_, _, CanonPid).

ordinary_registered_name(Namespace, Name) :-
    nonvar(Namespace),
    !,
    registered(Namespace, Name, _).
ordinary_registered_name(_, Name) :-
    registered(_, Name, _).

published_service_name(Name) :-
    registered_service(Name, _).

current_registry_namespace(Namespace) :-
    (   current_public_execution_namespace(Namespace0)
    ->  Namespace = Namespace0
    ;   Namespace = global
    ).

current_registered(Name, Pid) :-
    current_registry_namespace(Namespace),
    registered(Namespace, Name, Pid).

registered_target(Name, Pid) :-
    current_registered(Name, Pid),
    !.
registered_target(Name, Pid) :-
    registered_service(Name, Pid).

require_service_registry_access(_Goal) :-
    \+ current_public_execution_profile(_),
    !.
require_service_registry_access(Goal) :-
    throw(error(permission_error(access, actor_service_registry, Goal),
                context(actor:require_service_registry_access/1,
                        'service registration is reserved for node-owned runtime code'))).


%!  exit(+Reason)
%
%   Exit the calling process.

:- dynamic exit_reason/2.

exit(Reason) :-
    var(Reason),
    instantiation_error(Reason).
exit(Reason) :-
    self_local(LocalSelf),
    asserta(exit_reason(LocalSelf, Reason)),
    abort.


%!  exit(+Pid, Reason) is det.
%
%   Exit the actor known as Pid.  For remote compound Pids of the form
%   `Id@Node`, the kill is sent over the inter-node WebSocket via
%   safe_remote_kill_send/4 (see manual.html:291).

%  Step 5 of the proxy-less migration: cross-node exits no longer
%  hop through the proxy's '$kill'(Reason) mailbox handler.  Instead,
%  if the pid is known to the node controller (registered by a
%  cross-node spawn) or its Node component is non-local, the kill
%  goes straight over the per-node WebSocket via safe_remote_kill_send/4.
%  The controller-table check comes first so the in-process
%  integration harness still routes correctly when self_node_url makes
%  a "remote" Node look local.  Observability policy is preserved:
%  failures emit a remote_exit_failed event (transient on first try,
%  terminal after the single retry) and never propagate, because
%  exit/2 runs inside another actor's cleanup chain (stop/2) where a
%  throw would corrupt link-driven termination.
exit(Id@Node, Reason) :-
    (   node_controller:current_remote_target(Id@Node, _)
    ;   \+ local_node_url(Node)
    ),
    !,
    term_to_wire_atom(Reason, ReasonAtom),
    safe_remote_kill_send(Node, Id, ReasonAtom, json{
        command: exit,
        pid: Id,
        reason: ReasonAtom
    }).
exit(Id@Node, Reason) :-
    local_node_url(Node),
    !,
    exit(Id, Reason).
exit(Pid, Reason) :-
    (   resolve_thread(Pid, ThreadId)
    ->  best_effort_if_gone(thread_signal(ThreadId, exit(Reason)))
    ;   true
    ).


%!  !(+Pid, +Message) is det.
%!  send(+Pid, +Message) is det.
%!  send(+Pid, +Message, +Options) is det.
%!  cancel(+ID) is det.
%
%   Send Message to Pid.

Pid ! Message :-
    send(Pid, Message).

%  Step 4 of the proxy-less migration: cross-node sends no longer
%  hop through a per-pid proxy actor's mailbox.  Instead, if the pid
%  is known to the node controller (because a cross-node spawn
%  registered a remote_target_/2 row), or if its Node component is
%  not the local node, the message goes directly over the per-node
%  WebSocket via remote_send_command/2.  The controller-table check
%  comes first so the in-process integration harness still routes
%  correctly when self_node_url makes a "remote" Node look local.
send(Id@Node, Message) :-
    (   node_controller:current_remote_target(Id@Node, _)
    ;   \+ local_node_url(Node)
    ),
    !,
    term_to_wire_atom(Message, MsgAtom),
    best_effort(remote_send_command(Node, json{
        command: send,
        pid: Id,
        message: MsgAtom
    })).
send(Id@Node, Message) :-
    local_node_url(Node),
    !,
    send(Id, Message).
send(Name, Message) :-
    registered_target(Name, Pid),
    !,
    send(Pid, Message).
send(Name, _Message) :-
    is_name(Name),
    !,
    throw(error(existence_error(actor_name, Name),
                context(actor:send/2,
                        'no actor registered under name'))).
send(Pid, Message) :-
    (   resolve_thread(Pid, ThreadId)
    ->  best_effort_if_gone(thread_send_message(ThreadId, Message))
    ;   true
    ).

send(Pid, Message, Options) :-
    option(delay(Delay), Options, 0),
    spawn(send_with_delay(Pid, Message, Delay), DelayPid),
    (   option(id(ID), Options)
    ->  assertz(delayed_send(ID, DelayPid))
    ;   true
    ).

cancel(ID) :-
    forall(retract(delayed_send(ID, DelayPid)),
           send(DelayPid, '$cancel')).

%!  send_with_delay(+Pid, +Message, +Delay) is det.
%
%   Helper process used to implement delayed send and cancel.
send_with_delay(Pid, Message, Delay) :-
    receive({
        '$cancel' -> true
    }, [
        timeout(Delay),
        on_timeout(send(Pid, Message))
    ]),
    self(Self),
    retractall(delayed_send(_, Self)).
     

%!  output(+Term) is det.
%!  output(+Term, +Options) is det.
%
%   Send Term to the target process. Default is the parent.

output(Term) :-
    output(Term, []).
   
output(Term, Options) :-
    self(Self),
    (   option(target(Target), Options)
    ->  Target ! output(Self, Term)
    ;   '$parent'(Parent)
    ->  Parent ! output(Self, Term)
    ;   system:writeln(Term)
    ).


%!  terminal_output(+Term) is det.
%!  terminal_output(+Term, +Options) is det.
%
%   Send textual I/O output to the target process. Default is the parent.

terminal_output(Term) :-
    terminal_output(Term, []).

terminal_output(Term, Options) :-
    self(Self),
    (   option(target(Target), Options)
    ->  send_terminal_output(Target, Self, Term, Options)
    ;   io_target(DefaultTarget)
    ->  send_terminal_output(DefaultTarget, Self, Term, Options)
    ;   '$parent'(Parent)
    ->  send_terminal_output(Parent, Self, Term, Options)
    ;   system:writeln(Term)
    ).

send_terminal_output(Target, Self, Term, Options) :-
    (   option(source(io), Options),
        best_effort_fail(message_queue_property(Target, size(_)))
    ->  send(Target, terminal_io_output(Self, Term))
    ;   send(Target, terminal_output(Self, Term))
    ).
    

%!  input(+Prompt, -Input) is det.
%!  input(+Prompt, -Input, +Options) is det.
%
%   Send Prompt to the target process and wait for input. Prompt may
%   be any term, compound or atomic. Default target is the parent.

input(Prompt, Input) :-
    input(Prompt, Input, []).
    
input(Prompt, Input, Options) :-
    self(Self),
    '$parent'(Parent),
    default_io_target(Parent, DefaultTarget),
    option(target(Target), Options, DefaultTarget),
    Target ! prompt(Self, Prompt),
    receive({ 
       '$input'(_From, Input) ->
           true
    }).
   

%!  respond(+Pid, +Input) is det.
%
%   Send a response in the form of Term to an actor Pid that
%   has prompted its parent process for input.

respond(Pid, Term) :-
    self(Self),
    Pid ! '$input'(Self, Term).


%!  with_io_target(+Target, :Goal) is semidet.
%
%   Execute Goal with Target as the default target for output/1-2 and
%   input/2-3 in the current actor thread.

with_io_target(Target, Goal) :-
    asserta(io_target(Target), Ref),
    call_cleanup(Goal, erase(Ref)).

default_io_target(_Fallback, Target) :-
    io_target(Target),
    !.
default_io_target(Fallback, Fallback).


%!  receive(+ReceiveClauses) is semidet.
%!  receive(+ReceiveClauses, +Options) is semidet.
%
%   Erlang-style receive.

:- thread_local deferred/1.

receive(Clauses) :-
    receive(Clauses, []).

receive(Clauses, Options) :-
    thread_self(Mailbox),
    (   clause(deferred(Msg), true, Ref),
        select_body(Clauses, Msg, Module, Body)
    ->  erase(Ref),
        call(Module:Body)
    ;   receive(Mailbox, Clauses, Options)
    ).

receive(Mailbox, Clauses, Options) :-    
    (   thread_get_message(Mailbox, Msg, Options)
    ->  (   select_body(Clauses, Msg, Module, Body)
        ->  call(Module:Body)
        ;   assertz(deferred(Msg)),
            receive(Mailbox, Clauses, Options)
        )
    ;   option(on_timeout(Goal), Options, true),
        clauses_module(Clauses, Module),
        call(Module:Goal)
    ).

%!  clauses_module(+Clauses, -Module) is det.
%
%   Resolve module prefix for receive clause DSL.
clauses_module(M:_, M) :- !.
clauses_module(_, actor).

select_body(M:{Clauses}, Message, M, Body) :-
    !,
    select_body_aux(Clauses, Message, M, Body).
select_body(Clauses, Message, actor, Body) :-
    select_body_aux(Clauses, Message, actor, Body).

%!  select_body_aux(+Clauses, +Message, +Module, -Body) is semidet.
%
%   Match a message against receive clauses, including guarded `if/2` forms.
select_body_aux((Clause ; Clauses), Message, Module, Body) :-
    (   select_body_aux(Clause,  Message, Module, Body)
    ;   select_body_aux(Clauses, Message, Module, Body)
    ).
select_body_aux((Head -> Body), Message, Module, Body) :-
    (   subsumes_term(if(Pattern, Guard), Head)
    ->  if(Pattern, Guard) = Head,
        subsumes_term(Pattern, Message),
        Pattern = Message,
        best_effort_fail(once(Module:Guard))
    ;   subsumes_term(Head, Message),
        Head = Message
    ).


                /*******************************
                *      VARIOUS UTILITIES       *
                *******************************/  
                

%!  flush is det.
%
%   Flush the contents of the mailbox.
/*
flush :-
    receive({
       Message ->
          format("Shell got ~q~n",[Message]),
          flush
    },[ timeout(0)]).
*/
%!  flush
%
%   Print all pending messages



flush :-
    receive({
        Message -> 
            term_to_atom(Message, Atom),
            atomics_to_string(['Shell got ', Atom], MessageString),
            terminal_output(MessageString),
            flush
    }, [timeout(0)]).



is_pid(main) :- !.   
is_pid(Pid) :-
    integer(Pid),
    Pid >= 1000000000,
    Pid =< 9999999999.
    
is_name(Name) :-
    atom(Name),
    Name \== main.
    
%!  resolve_thread(+Target, -ThreadId) is semidet.
%
%   Resolve send target that may be pid, queue id, thread id, or `main`.
resolve_thread(main, main) :- !.
resolve_thread(Pid, ThreadId) :-
    pid_local(Pid, LocalPid),
    (   pid_thread(LocalPid, ThreadId0)
    ->  ThreadId = ThreadId0
    ;   is_thread(LocalPid)
    ->  ThreadId = LocalPid
    ),
    !.
resolve_thread(Queue, Queue) :-
    best_effort_fail(message_queue_property(Queue, size(_))),
    !.
resolve_thread(Thread, Thread) :-
    is_thread(Thread).

%!  send_thread_message(+To, +Message) is det.
%
%   Internal helper that combines resolve_thread/2 + thread_send_message/2.
send_thread_message(To, Message) :-
    resolve_thread(To, ThreadId),
    thread_send_message(ThreadId, Message).
