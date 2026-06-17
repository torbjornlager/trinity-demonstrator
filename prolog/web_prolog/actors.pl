:- module(actors,
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
     flush/0,                %
     make_ref/1,             % -Ref
     canonical_pid/2,        % +Pid0, -Pid

     % The spawn-handshake protocol travels INSIDE hook_start_body/6
     % as closures, so no callable plumbing API is exported; sibling
     % layers read the few remaining internals (pid_local/2,
     % resolve_thread/2, actor_in_current_namespace/1, is_main_pid/1)
     % via explicitly qualified calls, documented at each site.

     op(800,  xfx, !),       %
     op(1000, xfy, if)       %
   ]).

/** <module> Minimal Erlang-style Actors for SWI-Prolog (layer 0)

This module is the stand-alone core of Web Prolog's actor runtime,
extracted from the trinity-demonstrator's actor.pl.  It provides:

  - one actor == one Prolog thread,
  - stable opaque pid separate from thread id,
  - mailbox messaging with selective receive,
  - directional links and monitors for supervision patterns.

It loads with no project dependencies and no sandbox: an actor's goal
runs in the spawning module's context with all of SWI-Prolog available.
Per-actor isolated modules, policy guards, toplevel query actors, and
distribution are *separate layers* that attach themselves through the
multifile hooks declared below; nothing here refers to them.

## Pids (layer-0 representation)

A local pid is the opaque compound `actor(N)` with `N` allocated from a
monotonically increasing counter, so a pid is never reused within a
process and remains a valid key for monitors, links, and exit reasons
after the actor has died.  Integer pids and the global `Id@Node` form
are introduced by the distribution layer through `hook_make_pid/1`,
`hook_canonical_pid/2`, and `hook_local_pid/2`; no code in this module
assumes any particular pid shape beyond `main` being the REPL thread.

## Hooks

All hooks are multifile, have no clauses here, and every call site
supplies a local default, so this library is fully functional alone.

Identity-style (semidet; first solution wins, default = identity/fail):

  - hook_make_pid(-Pid): mint a fresh local pid.
  - hook_make_ref(-Ref): mint a fresh monitor reference.
  - hook_canonical_pid(+Pid0, -Pid): canonicalize/globalize a pid.
  - hook_local_pid(+Pid0, -LocalPid): localize a pid (fail = not local).
  - hook_self(-Pid): override self/1's result.
  - hook_namespace(-NS): current registry/visibility namespace.

Takeover-style (semidet; if a clause succeeds the core path is skipped):

  - hook_spawn(:Goal, -Pid, +Options): take over a spawn entirely
    (distribution claims spawns whose node(N) is non-local).
  - hook_send(+Pid, +Message): take over delivery (Id@Node, sockets).
  - hook_exit(+Pid, +Reason): take over exit delivery.
  - hook_start_body(+Pid, :Goal, +Options, :OnReady, :OnPrepError,
    :Runner): take over the child-side start sequence (the
    composition layer forwards this to isolation, which prepares the
    actor's module).  The spawn-handshake protocol travels as
    closures constructed here: implementations call(OnReady) once
    prepared — or, on a preparation error E, call(OnPrepError, E),
    then call(OnReady), then rethrow — and run the goal via
    call(Runner, PreparedGoal).  No callback predicate of this
    module needs to be named, let alone imported.
  - hook_spawn_options(:Goal, +Options0, -Options): caller-side spawn
    option rewriting (node-layer policy).
  - hook_spawn_context(+Goal0, -Goal): caller-side wrapping of the
    child's start goal (node-layer execution-context propagation).

Side-effect-style (all solutions are run via forall/2; no clauses = no-op):

  - hook_monitor(+Watcher, +Pid, +Ref): mirror a new monitor.
  - hook_demonitor(+Ref): mirror monitor removal.
  - hook_pid_activated(+Pid): the child thread has registered its pid.
  - hook_spawn_failed(+Pid): a local spawn aborted before activation.
  - hook_stop(+Pid): an actor is going down (cleanup mirrors).
  - hook_admit_spawn(+LiveCount, +Options): spawn-admission control; a
    clause that throws rejects a local spawn (global concurrency cap).

Resource-ceiling style:

  - hook_thread_options(-Options): extra thread_create/3 options for a
    new actor thread (default `[]`); the node supplies stack_limit/1 to
    cap per-actor memory.

Transactional triple (semidet prepare; commit/abort run via forall/2):

  - hook_spawn_prepare(+Self, +Options, -Ctx)
  - hook_spawn_commit(+Ctx, +Pid)
  - hook_spawn_abort(+Ctx)
*/

:- use_module(library(debug)).
:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(aggregate)).

:- multifile
    hook_make_pid/1,
    hook_make_ref/1,
    hook_canonical_pid/2,
    hook_local_pid/2,
    hook_self/1,
    hook_namespace/1,
    hook_service_registry_denied/0,
    hook_spawn/3,
    hook_send/2,
    hook_exit/2,
    hook_start_body/6,
    hook_spawn_options/3,
    hook_spawn_context/2,
    hook_monitor/3,
    hook_demonitor/1,
    hook_pid_activated/1,
    hook_spawn_failed/1,
    hook_stop/1,
    hook_spawn_prepare/3,
    hook_spawn_commit/2,
    hook_spawn_abort/1,
    hook_thread_options/1,
    hook_admit_spawn/2.

:- meta_predicate
    spawn(:),
    spawn(:, -),
    spawn(:, -, +),
    receive(:),
    receive(:, +),
    with_io_target(+, 0),
    run_start_goal(:, +),
    best_effort(0),
    best_effort_fail(0),
    best_effort_if_gone(0).

/*
Runtime bookkeeping (as in the demonstrator):

  - pid_thread/2 and thread_pid/2 map between logical pids and thread ids.
  - link/2 tracks parent->child crash propagation direction.
  - monitor/3 tracks monitor references for down messages.
  - io_target/1 is a thread-local override for output/input target.
*/

:- dynamic link/2.
:- dynamic pid_thread/2.
:- dynamic spawn_reservation/1.
:- dynamic thread_pid/2.
:- dynamic actor_public_namespace/2.
:- dynamic main_pid/1.
:- thread_local io_target/1.

:- initialization(init_main_pid, after_load).

best_effort(Goal) :-
    catch(Goal, _, true).

best_effort_fail(Goal) :-
    catch(Goal, _, fail).

best_effort_if_gone(Goal) :-
    catch(Goal, error(existence_error(_,_), _), true).


                /*******************************
                *             PIDS             *
                *******************************/

%!  make_pid(-Pid) is det.
%
%   Mint a fresh local pid.  The layer-0 default is the opaque
%   compound `actor(N)` with N from a process-monotonic counter:
%   never reused, so post-mortem state (monitors, exit_reason) keyed
%   by pid cannot be confused by recycling.  The distribution layer
%   overrides this through hook_make_pid/1.
make_pid(Pid) :-
    (   hook_make_pid(Pid0)
    ->  Pid = Pid0
    ;   flag(wp_actor_pid_counter, N, N + 1),
        Pid = actor(N)
    ).

%!  make_ref(-Ref) is det.
%
%   Mint a fresh monitor reference (an opaque token, not a pid).
make_ref(Ref) :-
    (   hook_make_ref(Ref0)
    ->  Ref = Ref0
    ;   flag(wp_actor_ref_counter, N, N + 1),
        Ref = ref(N)
    ).

%!  canonical_pid(+Pid0, -Pid) is det.
%
%   Layer-0 canonicalization is the identity; the distribution layer
%   installs Id@Node globalization through hook_canonical_pid/2.
canonical_pid(Pid0, Pid) :-
    (   hook_canonical_pid(Pid0, Pid1)
    ->  Pid = Pid1
    ;   Pid = Pid0
    ).

%!  pid_local(+Pid0, -LocalPid) is semidet.
%
%   Strip a pid to its local form.  Layer-0 default: every pid is
%   local and already in local form.
pid_local(Pid0, LocalPid) :-
    (   hook_local_pid(Pid0, LocalPid0)
    ->  LocalPid = LocalPid0
    ;   LocalPid = Pid0
    ).

%!  is_local_pid(@Term) is semidet.
%
%   True if Term has the shape of a layer-0 local pid.
is_local_pid(actor(N)) :-
    integer(N).
is_local_pid(main).


                /*******************************
                *             SPAWN            *
                *******************************/

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
%     - node(+Node)
%       Spawn on Node.  Handled by the distribution layer through
%       hook_spawn/3; without that layer only `localhost` is valid.

spawn(Goal) :-
    spawn(Goal, _Pid).

spawn(Goal, Pid) :-
    spawn(Goal, Pid, []).

spawn(Goal, Pid, Options) :-
    (   hook_spawn(Goal, Pid, Options)
    ->  true
    ;   option(node(Node), Options, localhost),
        (   Node == localhost
        ->  spawn_local(Goal, Pid, Options)
        ;   throw(error(existence_error(procedure, hook_spawn/3),
                        context(actors:spawn/3,
                                'spawning on a remote node requires the distribution layer')))
        )
    ).

%!  spawn_local(:Goal, -Pid, +Options) is det.
%
%   Spawn a regular local actor in this Prolog node.
spawn_local(Goal, Pid, Options) :-
    inherit_local_spawn_options(Options, EffectiveOptions0),
    prepare_spawn_options(Goal, EffectiveOptions0, EffectiveOptions),
    make_pid(LocalPid),
    canonical_pid(LocalPid, Pid),
    %  Admission reserves a slot for LocalPid (under a mutex) and the
    %  reservation lives until the actor is activated or the spawn fails,
    %  so concurrent spawns cannot all observe the same below-ceiling
    %  count and overshoot a global cap.  See admit_local_spawn/2.
    setup_call_cleanup(
        admit_local_spawn(LocalPid, EffectiveOptions),
        spawn_local_activate(LocalPid, Pid, Goal, EffectiveOptions),
        release_spawn_reservation(LocalPid)
    ).

spawn_local_activate(LocalPid, Pid, Goal, EffectiveOptions) :-
    self(Self),
    spawn_prepare_context(Self, EffectiveOptions, PreparedContext),
    install_preconfigured_monitor(Pid, EffectiveOptions),
    local_actor_start_goal(Self, LocalPid, Goal, EffectiveOptions, StartGoal),
    spawn_thread_options(ThreadOptions),
    catch(
        (
            thread_create(StartGoal, _Thread,
                          [at_exit(stop_self(Self))|ThreadOptions]),
            thread_get_message(initialized(Pid)),
            check_actor_start_error(Pid),
            forall(hook_spawn_commit(PreparedContext, Pid), true)
        ),
        Error,
        (
            forall(hook_spawn_failed(LocalPid), true),
            forall(hook_spawn_abort(PreparedContext), true),
            throw(Error)
        )
    ).

install_preconfigured_monitor(Pid, Options) :-
    option(monitor_target(Target), Options),
    !,
    option(monitor_ref(Ref), Options, Pid),
    assertz(monitor(Target, Pid, Ref)).
install_preconfigured_monitor(_, _).

%!  admit_local_spawn(+LocalPid, +Options) is det.
%
%   Spawn-admission control with reservation: the distribution/node layer
%   may impose a global ceiling on the number of live local actors (a
%   multi-tenant total-memory bound when paired with a per-actor stack
%   limit).  Under a mutex, count the live actors *plus the in-flight
%   reservations* and offer that total to the hook; any clause that throws
%   rejects the spawn (backpressure).  On admission, record a reservation
%   for LocalPid so a concurrent admission sees this not-yet-live spawn in
%   its count — without it, several spawns could observe the same
%   below-ceiling live count and together exceed the ceiling.  The
%   reservation is released by spawn_local/3 once the actor is live (its
%   pid_thread/2 then carries the count) or the spawn has failed.  No hook
%   clause ⇒ unbounded, the stand-alone default.
admit_local_spawn(LocalPid, Options) :-
    with_mutex(actors_spawn_admission,
        (   aggregate_all(count, pid_thread(_, _), Live),
            aggregate_all(count, spawn_reservation(_), Reserved),
            Count is Live + Reserved,
            forall(hook_admit_spawn(Count, Options), true),
            assertz(spawn_reservation(LocalPid))
        )).

%!  release_spawn_reservation(+LocalPid) is det.
%
%   Drop LocalPid's spawn reservation (idempotent).  Called from
%   spawn_local/3's cleanup, after the actor is live or the spawn failed.
release_spawn_reservation(LocalPid) :-
    with_mutex(actors_spawn_admission,
               retractall(spawn_reservation(LocalPid))).

%!  spawn_thread_options(-Options) is det.
%
%   Extra options for the actor's thread_create/3 — the node layer
%   supplies `stack_limit(Bytes)` here to cap per-actor memory.  No
%   clause ⇒ `[]`, i.e. SWI's default per-thread stack limit.
spawn_thread_options(Options) :-
    (   hook_thread_options(Options0)
    ->  Options = Options0
    ;   Options = []
    ).

%!  check_actor_start_error(+Pid) is det.
%
%   After receiving initialized(Pid), check whether the actor thread
%   also sent a start_error message indicating that start preparation
%   failed.  Preparation errors are sent *before* initialized, so if
%   one is present it is already in the queue.  A zero-timeout peek is
%   sufficient — no heuristic delay.
check_actor_start_error(Pid) :-
    thread_self(Me),
    (   thread_get_message(Me, start_error(Pid, Error), [timeout(0)])
    ->  throw(Error)
    ;   true
    ).

startup_exit_signal(Pid, unwind(abort)) :-
    exit_reason(Pid, _).

local_actor_start_goal(Self, LocalPid, Goal, EffectiveOptions, StartGoal) :-
    %  Module-qualified so hook_spawn_context wrappers built in other
    %  modules cannot strand start/4 in a foreign calling context.
    StartGoal0 = actors:start(Self, LocalPid, Goal, EffectiveOptions),
    (   hook_spawn_context(StartGoal0, StartGoal1)
    ->  StartGoal = StartGoal1
    ;   StartGoal = StartGoal0
    ).

inherit_local_spawn_options(Options0, Options) :-
    (   option(target(_), Options0)
    ->  Options = Options0
    ;   io_target(Target)
    ->  Options = [target(Target)|Options0]
    ;   Options = Options0
    ).

spawn_prepare_context(Self, Options, Context) :-
    (   hook_spawn_prepare(Self, Options, Context0)
    ->  Context = Context0
    ;   Context = none
    ).

prepare_spawn_options(Goal, Options0, Options) :-
    (   hook_spawn_options(Goal, Options0, Options1)
    ->  Options = Options1
    ;   Options = Options0
    ).


%!  init_main_pid is det.
%
%   Ensure the main REPL thread also has a pid mapping.  The pid is
%   minted like any other (the atom `main` stays a resolvable *alias*,
%   see resolve_thread/2, but is not the pid itself — a pid must never
%   coincide with a thread/queue alias, or target-type discrimination
%   in send_terminal_output/4 misfires).
init_main_pid :-
    thread_property(main, id(MainThreadId)),
    (   thread_pid(MainThreadId, ExistingPid)
    ->  (   main_pid(ExistingPid)
        ->  true
        ;   assertz(main_pid(ExistingPid))
        )
    ;   make_pid(MainPid),
        assertz(pid_thread(MainPid, MainThreadId)),
        assertz(thread_pid(MainThreadId, MainPid)),
        assertz(main_pid(MainPid))
    ).

%!  is_main_pid(+Pid) is semidet.
%
%   True when Pid is the REPL/main thread's pid.  Upper layers use
%   this to map the main pid to the `user` module.
is_main_pid(Pid) :-
    main_pid(Pid).

:- thread_local '$parent'/1.

%!  '$actor_parent'(-Parent) is semidet.

'$actor_parent'(Parent) :-
    '$parent'(Parent).


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
%     3. run the start body — by default: notify the parent and call
%        Goal in the caller's module; the isolation glue takes this
%        over through hook_start_body/4 to prepare a private module
%        first (it must reproduce the initialized/start_error
%        handshake via actor_started/2 and actor_start_failed/3).
start(Parent, Pid, Goal, Options) :-
    thread_self(Thread),
    thread_property(Thread, id(ThreadId)),
    assertz(pid_thread(Pid, ThreadId)),
    forall(hook_pid_activated(Pid), true),
    assertz(thread_pid(ThreadId, Pid)),
    canonical_pid(Pid, GlobalPid),
    assertz('$parent'(Parent)),
    remember_actor_namespace(Pid),
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
    catch(
        start_body(GlobalPid, Parent, Goal, Options),
        StartError,
        (   (   startup_exit_signal(Pid, StartError)
            ->  true
            ;   true
            ),
            throw(StartError)
        )
    ).

start_body(GlobalPid, Parent, Goal, Options) :-
    %  The handshake closures are constructed HERE, module-qualified,
    %  so hook implementations receive them as opaque callables and
    %  the protocol needs no exported API (and no wrapper can strand
    %  them in a foreign calling context).
    OnReady = actors:actor_started(Parent, GlobalPid),
    OnPrepError = actors:actor_start_failed(Parent, GlobalPid),
    Runner = actors:start_goal_runner(Options),
    (   hook_start_body(GlobalPid, Goal, Options,
                        OnReady, OnPrepError, Runner)
    ->  true
    ;   call(OnReady),
        call(Runner, Goal)
    ).

%!  actor_started(+Parent, +Pid) is det.
%!  actor_start_failed(+Parent, +Pid, +Error) is det.
%
%   The spawn handshake protocol: the parent blocks on
%   `initialized(Pid)` and then peeks for `start_error(Pid, Error)`.
%   On preparation failure, send start_error *before* initialized so
%   the parent's zero-timeout peek finds it.  Internal: reach
%   hook_start_body/6 implementations only as the OnReady/OnPrepError
%   closures.
actor_started(Parent, Pid) :-
    send_thread_message(Parent, initialized(Pid)).

actor_start_failed(Parent, Pid, Error) :-
    send_thread_message(Parent, start_error(Pid, Error)).

%!  start_goal_runner(+Options, :Goal) is det.
%!  run_start_goal(:Goal, +Options) is det.
%
%   Run an actor start goal, honoring an optional spawn-time I/O
%   target.  start_goal_runner/2 is the closure form passed through
%   hook_start_body/6 (called as call(Runner, Goal)).
start_goal_runner(Options, Goal) :-
    run_start_goal(Goal, Options).

run_start_goal(Goal, Options) :-
    (   option(target(Target), Options)
    ->  with_io_target(Target, call(Goal))
    ;   call(Goal)
    ).

remember_actor_namespace(Pid) :-
    (   hook_namespace(Namespace)
    ->  retractall(actor_public_namespace(Pid, _)),
        assertz(actor_public_namespace(Pid, Namespace))
    ;   true
    ).

%!  actor_in_current_namespace(+LocalPid) is semidet.
%
%   True when no namespace context is active, or when LocalPid was
%   spawned in the currently active namespace.  Upper layers use this
%   for visibility checks (e.g. listing_private/1).
actor_in_current_namespace(LocalPid) :-
    (   hook_namespace(Namespace)
    ->  actor_public_namespace(LocalPid, Namespace)
    ;   true
    ).


%!  stop(+Pid, +Parent) is det.
%
%   Final actor cleanup:
%
%     - remove links, names and delayed-send records,
%     - kill linked children,
%     - notify monitors with down messages,
%     - remove pid/thread mappings.
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
    forall(hook_stop(GlobalPid), true),
    down_reason(Pid, Reason),
    forall(retract(monitor(Other, GlobalPid, Ref)),
           Other ! down(Ref, GlobalPid, Reason)),
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
    (   hook_namespace(Namespace)
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


%!  self(-Pid) is det.
%
%   Find who we are.

self(Self) :-
    (   hook_self(Self0)
    ->  Self = Self0
    ;   self_local(LocalPid),
        canonical_pid(LocalPid, Self)
    ).

self_local(Self) :-
    thread_self(Thread),
    thread_property(Thread, id(ThreadId)),
    (   thread_pid(ThreadId, Pid)
    ->  Self = Pid
    ;   Self = ThreadId
    ).


                /*******************************
                *      MONITORS AND NAMES      *
                *******************************/

%!  monitor(+Pid, -Ref) is det.
%!  demonitor(+Ref) is det.
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
    make_ref(Ref),
    assertz(monitor(Self, CanonPid, Ref)),
    forall(hook_monitor(Self, CanonPid, Ref), true).

demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    retractall(monitor(_, _, Ref)),
    forall(hook_demonitor(Ref), true),
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
    %  Availability check and insert must be atomic, or two threads can
    %  both pass the check and then both assert — duplicate registrations
    %  or two pids claiming one name.
    with_mutex(actors_registry,
        (   ensure_name_registration_available(Namespace, Name, Pid, CanonPid),
            asserta(registered(Namespace, Name, CanonPid))
        )).

%!  register_service(+Name, +Pid) is det.
%
%   Publish Pid under Name in the node-wide *service* registry, visible
%   across all namespaces (unlike register/2, which is namespace-local).
%   Throws `process_already_has_a_name(Pid)` if Pid is already
%   registered, or `name_is_in_use(Name)` if Name is taken.  The node
%   layer restricts access for public callers through
%   hook_namespace/1-scoped policy; stand-alone use is unrestricted.

register_service(Name, Pid) :-
    require_service_registry_access(register_service(Name, Pid)),
    must_be(atom, Name),
    canonical_pid(Pid, CanonPid),
    with_mutex(actors_registry,
        (   ensure_service_registration_available(Name, Pid, CanonPid),
            asserta(registered_service(Name, CanonPid))
        )).

%!  unregister(+Name) is det.

unregister(Name) :-
    must_be(atom, Name),
    current_registry_namespace(Namespace),
    retractall(registered(Namespace, Name, _)).

%!  unregister_service(+Name) is det.
%
%   Remove Name from the service registry.  Succeeds even if Name was
%   not registered.

unregister_service(Name) :-
    require_service_registry_access(unregister_service(Name)),
    must_be(atom, Name),
    retractall(registered_service(Name, _)).

%!  whereis(?Name, -Pid) is det.

whereis(Name, Pid) :-
    must_be(atom, Name),
    current_registered(Name, Pid),
    !.
whereis(_Name, undefined).

%!  whereis_service(+Name, -Pid) is det.
%
%   Pid is the actor registered under Name in the service registry, or
%   the atom `undefined` if no such registration exists.

whereis_service(Name, Pid) :-
    require_service_registry_access(whereis_service(Name, Pid)),
    must_be(atom, Name),
    registered_service(Name, Pid),
    !.
whereis_service(Name, undefined) :-
    require_service_registry_access(whereis_service(Name, undefined)).

%!  require_service_registry_access(+Goal) is det.
%
%   The node layer reserves the service registry for node-owned
%   runtime code through hook_service_registry_denied/0 (denied when
%   a public execution profile is active).  Stand-alone use is
%   unrestricted.  The error is the demonstrator's exact term.
require_service_registry_access(Goal) :-
    (   hook_service_registry_denied
    ->  throw(error(permission_error(access, actor_service_registry, Goal),
                    context(actor:require_service_registry_access/1,
                            'service registration is reserved for node-owned runtime code')))
    ;   true
    ).

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
    (   hook_namespace(Namespace0)
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


                /*******************************
                *             EXIT             *
                *******************************/

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


%!  exit(+Pid, +Reason) is det.
%
%   Exit the actor known as Pid.  Non-local pids are handled by the
%   distribution layer through hook_exit/2.

exit(Pid, Reason) :-
    hook_exit(Pid, Reason),
    !.
exit(Pid, Reason) :-
    (   resolve_thread(Pid, ThreadId)
    ->  best_effort_if_gone(thread_signal(ThreadId, exit(Reason)))
    ;   true
    ).


                /*******************************
                *             SEND             *
                *******************************/

%!  !(+Pid, +Message) is det.
%!  send(+Pid, +Message) is det.
%!  send(+Pid, +Message, +Options) is det.
%!  cancel(+ID) is det.
%
%   Send Message to Pid.

Pid ! Message :-
    send(Pid, Message).

send(Pid, Message) :-
    hook_send(Pid, Message),
    !.
send(Name, Message) :-
    registered_target(Name, Pid),
    !,
    send(Pid, Message).
send(Name, _Message) :-
    is_name(Name),
    !,
    %  The context literal is the demonstrator's exact error term:
    %  observable error shape is part of the semantics freeze.
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


                /*******************************
                *           ACTOR I/O          *
                *******************************/

%!  output(+Term) is det.
%!  output(+Term, +Options) is det.
%
%   Send Term to the target process.  Default is the parent.

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
%   Send textual I/O output to the target process.  Default is the parent.

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
%   Send Prompt to the target process and wait for input.  Prompt may
%   be any term, compound or atomic.  Default target is the parent.

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


                /*******************************
                *            RECEIVE           *
                *******************************/

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
clauses_module(_, actors).

select_body(M:{Clauses}, Message, M, Body) :-
    !,
    select_body_aux(Clauses, Message, M, Body).
select_body(Clauses, Message, actors, Body) :-
    select_body_aux(Clauses, Message, actors, Body).

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
%   Print all pending messages.

flush :-
    receive({
        Message ->
            term_to_atom(Message, Atom),
            atomics_to_string(['Shell got ', Atom], MessageString),
            terminal_output(MessageString),
            flush
    }, [timeout(0)]).


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
