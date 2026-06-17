:- module(distribution,
   [ make_id/1,               % -Id
     remote_request_spawn/3,  % +NodeURL, +Command, -RemotePid
     remote_request_halt/3,   % +NodeURL, +RemotePid, -Reply
     remote_send_command/2,   % +NodeURL, +Command
     register_remote_pid/2,   % +CompoundPid, +Target
     flush_pending_for_pid/2, % +NodeURL, +RemotePid
     remote_drop_connection/1,% +NodeURL
     op(200, xfx, @)
   ]).

/** <module> Web Prolog Distribution Layer (layer 3)

Cross-node actors: integer pids, `Id@Node` global addressing, the
controller routing tables, the JSON-over-WebSocket wire client, and
remote spawn/send/exit/monitor/link/toplevel — extracted verbatim from
the demonstrator's actor.pl and toplevel_actor.pl and installed as
implementations of the layer-0/layer-2 hooks.

Loading this module changes pid representation to the demonstrator's:
locally minted pids become random 10-digit integers (make_id/1), and
canonicalization globalizes them to `Id@SelfNodeURL` (pid_utils).  The
main thread's pid is re-minted accordingly at load time.

Own hooks (multifile, implemented by the node layer in Phase 6):

  - hook_event(+Dict): observability sink for structured events
    (e.g. remote_exit_failed).  All solutions run; also emitted on the
    `distribution` debug topic.
  - hook_connection_context(+Goal0, -Goal): wrap the WS reader
    thread's goal with node-scoped context (logging scope).
  - hook_ws_endpoint_override(+NodeURL, -WsURL): map a node URL to a
    non-default WS endpoint (the in-process test harness uses this).
*/

:- use_module(library(option)).
:- use_module(library(random)).
:- use_module(library(apply)).
:- use_module(library(debug)).
:- use_module(library(http/websocket)).
:- use_module(library(http/http_json)).
:- use_module(actors, [
    self/1,
    send/2,
    spawn/3,
    canonical_pid/2
]).
:- use_module(pid_utils, [
    localhost_node/1,
    node_url_atom/2,
    local_node_url/1,
    self_node_url/1,
    registered_self_node_url/1
]).
:- use_module(node_controller, []).
:- use_module(remote_protocol, [
    protocol_version/1,
    term_to_wire_atom/2,
    ws_json_down_reason/2,
    ws_json_is_io_output/1,
    ws_json_to_actor_event/3
]).
:- use_module(isolation, [rewrite_source_options/3]).
:- use_module(toplevel_actors, []).

:- multifile
    hook_event/1,
    hook_connection_context/2,
    hook_ws_endpoint_override/2.

:- dynamic ws_connection/4.
:- dynamic ws_pending_event/3.

best_effort(Goal) :-
    catch(Goal, _, true).

best_effort_fail(Goal) :-
    catch(Goal, _, fail).


                /*******************************
                *   PID MINTING (layer-0 hooks) *
                *******************************/

%!  make_id(-Id) is det.
%
%   Generate a random, currently-unused 10-digit actor id.
%   A mutex makes the uniqueness check and reservation atomic.
%   The reserved_id/1 fact acts as a lightweight claim so that
%   concurrent spawners cannot pick the same id before the child
%   thread asserts pid_thread/2.  The reservation is cleaned up
%   through actors' hook_pid_activated/1 once the mapping is in place.
:- dynamic reserved_id/1.

make_id(Id) :-
    with_mutex('$make_id', (
        repeat,
        random_between(1000000000, 9999999999, Id),
        \+ actors:pid_thread(Id, _),
        \+ reserved_id(Id),
        !,
        assertz(reserved_id(Id))
    )).

actors:hook_make_pid(Pid) :-
    make_id(Pid).

actors:hook_make_ref(Ref) :-
    make_id(Ref).

actors:hook_pid_activated(Pid) :-
    retractall(reserved_id(Pid)).

actors:hook_spawn_failed(Pid) :-
    retractall(reserved_id(Pid)).

actors:hook_canonical_pid(Pid0, Pid) :-
    pid_utils:canonical_pid(Pid0, Pid).

actors:hook_local_pid(Pid0, LocalPid) :-
    pid_utils:pid_local(Pid0, LocalPid).

%  Re-mint the main thread's pid as an integer (the demonstrator's
%  representation) if layer 0 already gave it a counter pid and no
%  references to it can exist yet (load time).  If layer 0's own
%  after-load init has not run yet, this is a no-op and that init
%  will mint an integer directly through hook_make_pid/1.
:- initialization(distribution_init_main_pid).

distribution_init_main_pid :-
    thread_property(main, id(MainThreadId)),
    (   actors:thread_pid(MainThreadId, actor(N))
    ->  make_id(MainPid),
        retractall(actors:pid_thread(actor(N), _)),
        retractall(actors:thread_pid(MainThreadId, _)),
        retractall(actors:main_pid(_)),
        assertz(actors:pid_thread(MainPid, MainThreadId)),
        assertz(actors:thread_pid(MainThreadId, MainPid)),
        assertz(actors:main_pid(MainPid)),
        retractall(reserved_id(MainPid))
    ;   true
    ).


                /*******************************
                *      REMOTE SPAWN / SEND     *
                *******************************/

actors:hook_spawn(Goal, Pid, Options) :-
    select_option(node(Node), Options, RestOptions),
    Node \== localhost,
    !,
    (   localhost_node(Node)
    ->  actors:spawn(Goal, Pid, RestOptions)
    ;   spawn_remote(Goal, Pid, Node, Options)
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
    %  No per-pid proxy actor.  Set up monitor and link FIRST, then
    %  register_remote_pid (which sets the controller's target row --
    %  the readiness marker for inbound dispatch), then flush any
    %  events the WS reader buffered during the spawn round-trip.
    %  Ordering matters: target last means a buffered down arriving in
    %  the race window has the monitor entries it needs by the time
    %  flush replays it.
    option(monitor(Monitor), Options, false),
    (   Monitor == true
    ->  assertz(actors:monitor(Self, CompoundPid, CompoundPid)),
        node_controller:add_remote_monitor(Self, CompoundPid, CompoundPid)
    ;   true
    ),
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(actors:link(Self, CompoundPid)),
        node_controller:add_remote_link(Self, CompoundPid)
    ;   true
    ),
    register_remote_pid(CompoundPid, Self),
    flush_pending_for_pid(NodeURL, RemotePid).

%!  normalize_goal_module(+GoalModule0, +PlainGoal, -GoalModule) is det.
normalize_goal_module(actors, Plain, user) :-
    \+ ( callable(Plain),
         functor(Plain, Name, Arity),
         current_predicate(actors:Name/Arity)
       ),
    !.
normalize_goal_module(Module, _, Module).

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


%  Cross-node sends go directly over the per-node WebSocket.  If the
%  pid is known to the node controller (because a cross-node spawn
%  registered a remote_target_/2 row), or if its Node component is
%  not the local node, the message goes over the wire.  The
%  controller-table check comes first so the in-process integration
%  harness still routes correctly when self_node_url makes a "remote"
%  Node look local.
actors:hook_send(Id@Node, Message) :-
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
actors:hook_send(Id@Node, Message) :-
    local_node_url(Node),
    !,
    actors:send(Id, Message).

%  Cross-node exits go directly over the per-node WebSocket via
%  safe_remote_kill_send/4.  Failures emit a remote_exit_failed event
%  (transient on first try, terminal after the single retry) and never
%  propagate, because exit/2 runs inside another actor's cleanup chain
%  (stop/2) where a throw would corrupt link-driven termination.
actors:hook_exit(Id@Node, Reason) :-
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
actors:hook_exit(Id@Node, Reason) :-
    local_node_url(Node),
    !,
    actors:exit(Id, Reason).

%  Cross-node monitor/demonitor/stop mirrors into the controller
%  tables.
actors:hook_monitor(Self, CanonPid, Ref) :-
    node_controller:current_remote_target(CanonPid, _),
    node_controller:add_remote_monitor(Self, CanonPid, Ref).

actors:hook_demonitor(Ref) :-
    node_controller:remove_remote_monitor_by_ref(Ref).

actors:hook_stop(GlobalPid) :-
    node_controller:take_remote_children_for_parent(GlobalPid, _Drained).


%!  safe_remote_kill_send(+Node, +Pid, +ReasonAtom, +Command) is det.
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
          Event = _{
              event_type: "remote_exit_failed",
              action: "exit",
              pid: PidText,
              node: NodeText,
              reason: ReasonAtom,
              error: ErrorText,
              status: Status,
              terminal: Terminal,
              summary: Summary
          },
          debug(distribution(remote), 'remote_exit_failed: ~p', [Event]),
          forall(hook_event(Event), true)
        ),
        _,
        true
    ).


                /*******************************
                *       REMOTE TOPLEVELS       *
                *******************************/

toplevel_actors:hook_toplevel_spawn(RemotePid@NodeURL, SourceModule, Options) :-
    option(node(NodeURL), Options),
    \+ localhost_node(NodeURL),
    !,
    self(Self),
    option(target(Target), Options, Self),
    remote_toplevel_spawn_options(Options, SourceModule, RemoteOptions),
    term_to_wire_atom(RemoteOptions, RemoteOptionsAtom),
    remote_request_spawn(NodeURL, json{
        command: toplevel_spawn,
        options: RemoteOptionsAtom
    }, RemotePid),
    CompoundPid = RemotePid@NodeURL,
    %  Install monitor + link first, then register the target (the
    %  readiness marker for inbound dispatch), then flush.  See
    %  spawn_remote/4 for the rationale.
    maybe_register_toplevel_name(Options, CompoundPid),
    (   option(monitor(true), Options)
    ->  assertz(actors:monitor(Self, CompoundPid, CompoundPid)),
        node_controller:add_remote_monitor(Self, CompoundPid, CompoundPid)
    ;   true
    ),
    %  Mirror the link-default behavior of the remote spawn path.
    %  Without this, a cross-node toplevel_spawn never installs the
    %  parent->child link, so when the parent dies, stop/2 has no link
    %  record to walk and the remote toplevel is orphaned on the
    %  target node.
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(actors:link(Self, CompoundPid)),
        node_controller:add_remote_link(Self, CompoundPid)
    ;   true
    ),
    register_remote_pid(CompoundPid, Target),
    flush_pending_for_pid(NodeURL, RemotePid).

remote_toplevel_spawn_options(Options0, SourceModule, RemoteOptions) :-
    rewrite_source_options(Options0, SourceModule, Options),
    exclude(remote_toplevel_local_option, Options, RemoteOptions).

remote_toplevel_local_option(node(_)).
remote_toplevel_local_option(link(_)).
remote_toplevel_local_option(monitor(_)).
remote_toplevel_local_option(target(_)).
remote_toplevel_local_option(source_module(_)).
remote_toplevel_local_option(name(_)).

maybe_register_toplevel_name(Options, Pid) :-
    (   option(name(Name), Options)
    ->  actors:register(Name, Pid)
    ;   true
    ).

toplevel_actors:hook_toplevel_halt(RemoteId@NodeURL, Reply) :-
    \+ localhost_node(NodeURL),
    !,
    remote_request_halt(NodeURL, RemoteId, Reply).


                /*******************************
                *        WS WIRE CLIENT        *
                *******************************/

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

%!  register_remote_pid(+CompoundPid, +Target) is det.
%
%   Records CompoundPid -> Target in the node_controller table.  Does
%   NOT flush pending events: callers must finish their controller
%   setup (monitor/link installation) before calling
%   flush_pending_for_pid/2 so that any buffered down events have the
%   correct monitor entries to deliver against.
register_remote_pid(RemotePid@NodeURL, Target) :-
    node_controller:register_remote_target(RemotePid@NodeURL, Target).


%!  flush_pending_for_pid(+NodeURL, +RemotePid) is det.
%
%   Re-dispatch every WS event that the reader buffered for
%   RemotePid before the local side finished registering the pid.
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
        %  The node layer wraps the reader goal with its logging scope
        %  through hook_connection_context/2.  Module-qualified so the
        %  wrapper cannot strand it in a foreign calling context.
        ReaderGoal0 = distribution:remote_ws_reader(NodeURL, Socket, SpawnQueue),
        (   hook_connection_context(ReaderGoal0, ReaderGoal)
        ->  true
        ;   ReaderGoal = ReaderGoal0
        ),
        thread_create(ReaderGoal, ReaderThread, [
            detached(true)
        ]),
        assertz(ws_connection(NodeURL, Socket, ReaderThread, SpawnQueue))
    ).


internal_transport_ws_options([
    request_header('X-Web-Prolog-User'=PrincipalId),
    request_header('X-Web-Prolog-Capabilities'=CapabilityHeader),
    request_header('X-Web-Prolog-Protocol'=ProtocolVersion)
]) :-
    self_node_url(SelfURL),
    format(string(PrincipalId), "node:~w", [SelfURL]),
    CapabilityHeader = "execute,internal_transport",
    %  Announce the wire-protocol version so a peer can detect it; a
    %  demonstrator-era node simply ignores the unknown header.
    protocol_version(ProtocolVersion).

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
    (   %  Down events are handled entirely by the controller.
        %  Discriminator: if a target is registered for the pid, the
        %  local side has completed its setup and we can deliver now;
        %  otherwise we are racing ahead of the spawn caller's
        %  register_remote_pid -- buffer the dict and let
        %  flush_pending_for_pid replay it later.
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
        %  the terminal I/O channel).
        remote_event_pid(Dict, _RemotePid),
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
%   atomically prevents double delivery of the same down events.
deliver_remote_down_via_controller(CompoundPid, Dict) :-
    (   ws_json_down_reason(Dict, Reason)
    ->  true
    ;   Reason = unknown
    ),
    node_controller:take_remote_monitors_for_pid(CompoundPid, Entries),
    retractall(actors:monitor(_, CompoundPid, _)),
    %  The remote pid is gone, so its target registration and any
    %  link records that pointed to it are now stale.
    node_controller:forget_remote_target(CompoundPid),
    retractall(node_controller:remote_link_(_, CompoundPid)),
    retractall(actors:link(_, CompoundPid)),
    forall(member(monitor(Watcher, Ref), Entries),
           send(Watcher, down(Ref, CompoundPid, Reason))).

%!  parse_halted_reply(+Raw, -Term) is semidet.
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
           ( retractall(actors:monitor(_, CompoundPid, _)),
             send(Watcher, down(Ref, CompoundPid, connection_closed))
           )),
    node_controller:drop_remote_state_for_node(NodeURL).

ws_mutex(NodeURL, Prefix, Mutex) :-
    format(atom(Mutex), '~w::~w', [Prefix, NodeURL]).

%!  node_url_to_ws_endpoint(+NodeURL, -WsURL) is det.
node_url_to_ws_endpoint(NodeURL, WsURL) :-
    hook_ws_endpoint_override(NodeURL, WsURL),
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


                /*******************************
                *       MODULE PREP GLUE       *
                *******************************/

%  Actor modules read and write `Id@Node` pids once distribution is
%  loaded; give them the operator, as the demonstrator's
%  configure_actor_operators/1 did.
:- multifile isolation:prepare_module/3.
isolation:prepare_module(Module, _GoalModule, _Options) :-
    Module:op(200, xfx, @).

%  Node-relative load_uri resolution uses the registered self URL.
:- multifile source_utils:self_base_url/1.
source_utils:self_base_url(URL) :-
    registered_self_node_url(URL).
