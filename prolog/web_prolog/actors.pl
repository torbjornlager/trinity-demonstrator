:- module(actors,
   [ spawn/1,                % :Goal
     spawn/2,                % :Goal, -Pid
     spawn/3,                % :Goal, -Pid, +Options
     spawn_with_name/4,      % :Goal, -Pid, +SpawnOptions, +WrapperOptions
     validate_spawn_options/2, % +Options, +Scope (runtime composition API)
     validate_spawn_wrapper_options/4, % +Options, +Scope, +PI, +ExtraSpecs
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
     actor_terminating/0,
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
     current_io_target/1,    % -Target
     with_io_target/2,       % +Target, :Goal
     flush/0,                %
     make_ref/1,             % -Ref
     canonical_pid/2,        % +Pid0, -Pid
     transportable_term/1,   % @Term

     % The spawn-handshake protocol travels INSIDE hook_start_body/7
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
  - hook_registry_namespace_status(+NS, -Status): claim a managed namespace
    as open or closed; unclaimed namespaces remain available.
  - hook_registry_retire(+Pid): registry teardown before pid retirement,
    called under actors_registry, before actors_monitor_lifecycle.
  - hook_local_spawn_node(+Node): recognise this node's local URL aliases
    for the named-creation helper (localhost is local without this hook).

Takeover-style (semidet; if a clause succeeds the core path is skipped):

  - hook_spawn(:Goal, -Pid, +Options): take over a spawn entirely
    (distribution claims spawns whose node(N) is non-local).
  - hook_send(+Pid, +Message): take over delivery (Id@Node, sockets).
  - hook_exit(+Pid, +Reason): take over exit delivery.
  - hook_start_body(+Pid, :Goal, +Options, :OnReady, :OnPrepError,
    :Runner, -Start): select a module-qualified closure for the child-side
    start sequence without executing it. The core commits to the selected
    closure before calling it, so actor goal failure cannot trigger fallback
    startup or repeat effects. The composition layer returns an isolation
    closure that prepares the actor's module. When executed, it calls
    OnReady once prepared — or, on a preparation error E, calls
    OnPrepError(E), then OnReady, then rethrows — and runs the goal via
    call(Runner, PreparedGoal). No callback predicate of this module needs
    to be named, let alone imported.
  - hook_spawn_options(:Goal, +Options0, -Options): caller-side spawn
    option rewriting (node-layer policy).
  - hook_spawn_option(+Name, -Visibility, -Validator): declare an additional
    unary option, public or internal, with a module-qualified unary value
    validator. Validators succeed or throw on invalid values; they must not
    fetch source or instantiate user terms.
  - hook_spawn_context(+Goal0, -Goal): caller-side wrapping of the
    child's start goal (node-layer execution-context propagation).

Side-effect-style (all solutions are run via forall/2; no clauses = no-op):

  - hook_monitor(+Watcher, +Pid, +Ref): mirror a new monitor.
  - hook_demonitor(+Ref): mirror monitor removal.
  - hook_pid_activated(+Pid): the child thread has registered its pid.
  - hook_spawn_failed(+Pid): a local spawn aborted before activation.
  - hook_stop(+Pid): an actor is going down (cleanup mirrors).
  - hook_pid_retired(+Pid): pid mappings have been removed; runs outside
    registry/monitor locks, before the at-exit callback returns.
  - hook_admit_spawn(+LiveCount, +Options): spawn-admission control; a
    clause that throws rejects a local spawn (global concurrency cap).

  - hook_admit_spawn(+Pid, +LiveCount, +Options): record ownership and
    reserve subtree capacity before the child can start.
  - hook_check_spawn/1, hook_check_exit/1, hook_check_monitor/1,
    hook_check_send/2: caller-side authority and term-admission checks.
  - hook_message_consumed/0: release a queued or deferred message charge.

First-success delivery style:

  - hook_deliver_message(+Pid, +Thread, +Message): reserve receiver mailbox
    capacity and enqueue atomically; default delivery applies if no hook handles it.

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
:- use_module(library(crypto)).
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
    hook_registry_namespace_status/2,
    hook_registry_retire/1,
    hook_service_registry_denied/0,
    hook_spawn/3,
    hook_local_spawn_node/1,
    hook_send/2,
    hook_exit/2,
    hook_start_body/7,
    hook_spawn_options/3,
    hook_spawn_option/3,
    hook_spawn_context/2,
    hook_monitor/3,
    hook_demonitor/1,
    hook_pid_activated/1,
    hook_spawn_failed/1,
    hook_stop/1,
    hook_pid_retired/1,
    hook_spawn_prepare/3,
    hook_spawn_commit/2,
    hook_spawn_abort/1,
    hook_thread_options/1,
    hook_admit_spawn/2,
    hook_admit_spawn/3,
    hook_check_spawn/1,
    hook_check_exit/1,
    hook_check_monitor/1,
    hook_check_send/2,
    hook_deliver_message/3,
    hook_message_consumed/0.

:- meta_predicate
    spawn(:),
    spawn(:, -),
    spawn(:, -, +),
    spawn_with_name(:, -, +, +),
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

:- dynamic issued_local_ref/1.

%!  make_ref(-Ref) is det.
%
%   Mint a fresh monitor reference (an opaque token, not a pid).
make_ref(Ref) :-
    (   hook_make_ref(Ref0)
    ->  Ref = Ref0
    ;   with_mutex(actor_references,
            (   repeat,
                crypto_n_random_bytes(16, Bytes),
                Ref = ref(Bytes),
                \+ issued_local_ref(Ref), !,
                assertz(issued_local_ref(Ref))
            ))
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
    validate_spawn_options(Options, runtime),
    forall(hook_check_spawn(Options), true),
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

:- multifile hook_remote_named_spawn/4.

% Composition helper for naming wrappers. Distribution reserves caller-side
% aliases separately from the local child's readiness handshake.
spawn_with_name(Goal, Pid, Options, WrapperOptions) :-
    (   option(name(Name), WrapperOptions)
    ->  must_be(atom, Name),
        option(node(Node), Options, localhost),
        (   (Node == localhost ; once(hook_local_spawn_node(Node)))
        ->  setup_call_catcher_cleanup(
                reserve_spawn_name(Name, Token),
                spawn(Goal, Pid, [name_reservation(Token)|Options]),
                Catcher, finish_spawn_name(Token, Catcher))
        ;   (predicate_property(hook_remote_named_spawn(_,_,_,_),number_of_clauses(N)),N>0
            -> hook_remote_named_spawn(Goal, Pid, Options, Name)
            ;  spawn(Goal, Pid, Options), register(Name, Pid))
        )
    ;   spawn(Goal, Pid, Options)
    ).

%!  spawn_local(:Goal, -Pid, +Options) is det.
%
%   Spawn a regular local actor in this Prolog node.
spawn_local(Goal, Pid, Options) :-
    inherit_local_spawn_options(Options, EffectiveOptions0),
    prepare_spawn_options(Goal, EffectiveOptions0, EffectiveOptions),
    validate_spawn_options(EffectiveOptions, runtime),
    make_pid(LocalPid),
    canonical_pid(LocalPid, Pid),
    attach_spawn_name(EffectiveOptions, Pid),
    %  Admission reserves a slot for LocalPid (under a mutex) and the
    %  reservation lives until the actor is activated or the spawn fails,
    %  so concurrent spawns cannot all observe the same below-ceiling
    %  count and overshoot a global cap.  See admit_local_spawn/2.
    setup_call_cleanup(
        admit_local_spawn(LocalPid, EffectiveOptions),
        spawn_local_activate(LocalPid, Pid, Goal, EffectiveOptions),
        release_spawn_reservation(LocalPid)
    ).

%!  validate_spawn_options(+Options, +Scope) is det.
%
%   Composition helper. runtime admits recognized framework metadata;
%   public checks raw remote-client options before metadata is injected.
%   Recognition is not authorization: existing policy hooks still apply.
validate_spawn_options(Options, Scope) :-
    must_be(oneof([public,runtime]), Scope),
    catch((must_be(list, Options), maplist(validate_spawn_option(Scope), Options)),
          error(Formal, _),
          throw(error(Formal, context(actors:spawn/3, 'invalid spawn option')))).

% Wrapper-owned schemas are local to each wrapper, not global extensions
% of spawn/3. ExtraSpecs contains Name=UnaryValidator pairs. The complete
% list is checked before the wrapper consumes any options or starts work.
validate_spawn_wrapper_options(Options, Scope, PI, ExtraSpecs) :-
    must_be(oneof([public,runtime]), Scope),
    catch((must_be(list, Options),
           maplist(validate_spawn_wrapper_option(Scope,ExtraSpecs), Options)),
          error(Formal, _),
          throw(error(Formal, context(PI, 'invalid spawn wrapper option')))).

validate_spawn_wrapper_option(Scope, ExtraSpecs, Option) :-
    must_be(nonvar, Option),
    (   compound(Option), compound_name_arity(Option, Name, 1),
        memberchk(Name=Validator, ExtraSpecs)
    ->  arg(1, Option, Value), call(Validator, Value)
    ;   validate_spawn_option(Scope, Option)
    ).

validate_spawn_option(Scope, Option) :-
    must_be(nonvar, Option),
    (   compound(Option), compound_name_arity(Option, Name, 1),
        spawn_option_spec(Name, Visibility, Validator)
    ->  (   Scope == 'public', Visibility == internal
        ->  permission_error(option, internal_spawn_option, Option)
        ;   arg(1, Option, Value), call(Validator, Value)
        )
    ;   domain_error(spawn_option, Option)
    ).

spawn_option_spec(Name, Visibility, Validator) :-
    (   core_spawn_option(Name, Visibility, Validator)
    ->  true
    ;   hook_spawn_option(Name, Visibility, Validator)
    ).

core_spawn_option(link, public, error:must_be(boolean)).
core_spawn_option(monitor, public, error:must_be(boolean)).
core_spawn_option(target, public, error:must_be(nonvar)).
core_spawn_option(io_target, public, error:must_be(nonvar)).
core_spawn_option(node, public, actors:spawn_node_value).
core_spawn_option(monitor_target, internal, error:must_be(nonvar)).
core_spawn_option(monitor_ref, internal, error:must_be(nonvar)).
core_spawn_option(name_reservation, internal, error:must_be(nonvar)).

spawn_node_value(Node) :-
    must_be(nonvar, Node),
    (atom(Node) -> true ; string(Node) -> true ; type_error(atom_or_string, Node)).

spawn_local_activate(LocalPid, Pid, Goal, EffectiveOptions) :-
    self(Self),
    spawn_prepare_context(Self, EffectiveOptions, PreparedContext),
    install_preconfigured_monitor(Pid, EffectiveOptions),
    %  The parent records the link and the spawn-time monitor before the
    %  child thread exists, so no termination of the child can go
    %  unreported and no termination of the parent can miss the link.
    install_spawn_relations(Self, Pid, EffectiveOptions),
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
            remove_spawn_relations(Self, Pid),
            forall(hook_spawn_failed(LocalPid), true),
            forall(hook_spawn_abort(PreparedContext), true),
            throw(Error)
        )
    ).

install_spawn_relations(Parent, Pid, Options) :-
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(link(Parent, Pid))
    ;   true
    ),
    option(monitor(Monitor), Options, false),
    (   Monitor == true
    ->  assertz(monitor(Parent, Pid, Pid))
    ;   true
    ).

remove_spawn_relations(Parent, Pid) :-
    retractall(link(Parent, Pid)),
    retractall(monitor(Parent, Pid, Pid)).

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
            forall(hook_admit_spawn(LocalPid, Count, Options), true),
            assertz(spawn_reservation(LocalPid))
        )).

%!  release_spawn_reservation(+LocalPid) is det.
%
%   Drop LocalPid's spawn reservation (idempotent).  Called from
%   spawn_local/3's cleanup, after the actor is live or the spawn failed.
release_spawn_reservation(LocalPid) :-
    with_mutex(actors_spawn_admission,
               retractall(spawn_reservation(LocalPid))),
    (pid_thread(LocalPid, _) -> true; forall(hook_spawn_failed(LocalPid), true)).

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
    % Startup may be inside a signal-protected ownership handoff. Inspect
    % without waiting, then consume the known message from our own queue.
    (   thread_peek_message(Me, start_error(Pid, Error))
    ->  thread_get_message(Me, start_error(Pid, Error)),
        throw(Error)
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
%     2. check that a linked parent is still alive (the parent itself
%        recorded the link and monitor before creating this thread),
%     3. run the start body — by default: notify the parent and call
%        Goal in the caller's module; the isolation glue takes this
%        over through hook_start_body/7 to prepare a private module
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
    %  The link and monitor were recorded by the parent before this thread
    %  was created.  If the link record has already gone, the parent
    %  stopped before this pid became resolvable, so its cleanup could not
    %  reach us: terminate now rather than run as an orphan.
    (   option(link(true), Options, true),
        \+ link(Parent, GlobalPid)
    ->  exit(kill)
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
    OnReady = actors:actor_started(Parent, GlobalPid, Options),
    OnPrepError = actors:actor_start_failed(Parent, GlobalPid, Options),
    Runner = actors:start_goal_runner(Options),
    (   hook_start_body(GlobalPid, Goal, Options,
                        OnReady, OnPrepError, Runner, Start)
    ->  true
    ;   Start = (call(OnReady), call(Runner, Goal))
    ),
    call(Start).

%!  actor_started(+Parent, +Pid, +Options) is det.
%!  actor_start_failed(+Parent, +Pid, +Options, +Error) is det.
%
%   The spawn handshake protocol: the parent blocks on
%   `initialized(Pid)` and then peeks for `start_error(Pid, Error)`.
%   On preparation failure, send start_error *before* initialized so
%   the parent's zero-timeout peek finds it.  Internal: reach
%   hook_start_body/7 implementations only as the OnReady/OnPrepError
%   closures.
actor_started(Parent, Pid, Options) :-
    catch(publish_spawn_name(Parent, Pid, Options), Error,
          (send_thread_message(Parent, start_error(Pid, Error)),
           send_thread_message(Parent, initialized(Pid)), throw(Error))),
    send_thread_message(Parent, initialized(Pid)).

actor_start_failed(Parent, Pid, Options, Error) :-
    fail_spawn_name(Parent, Pid, Options),
    send_thread_message(Parent, start_error(Pid, Error)).

%!  start_goal_runner(+Options, :Goal) is det.
%!  run_start_goal(:Goal, +Options) is det.
%
%   Run an actor start goal, honoring an optional spawn-time I/O
%   target.  start_goal_runner/2 is the closure form passed through
%   hook_start_body/7 (called as call(Runner, Goal)).
start_goal_runner(Options, Goal) :-
    run_start_goal(Goal, Options).

run_start_goal(Goal, Options) :-
    (   option(io_target(Target), Options)
    ->  with_io_target(Target, call(Goal))
    ;   option(target(Target), Options)
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
    retractall(delayed_send(_Owner, _ID, GlobalPid)),
    forall(retract(link(GlobalPid, ChildPid)),
           exit(ChildPid, kill)),
    forall(hook_stop(GlobalPid), true),
    %  Monitor delivery and pid removal form one lifecycle transaction.
    %  monitor/2 and demonitor/2 use the same mutex, so either a monitor
    %  is present here and receives exactly one down/3, or demonitor/2
    %  removes it before delivery and can safely flush the mailbox.
    %  Registration and pid retirement share the registry mutex.  A
    %  concurrent registration therefore either publishes before this
    %  transaction (and is removed here), or observes the retired pid and
    %  fails; it cannot install a stale local binding after cleanup.
    with_mutex(actors_registry,
        (   retractall(spawn_name_reservation(_, _, _, _, GlobalPid, _)),
            retractall(spawn_name_reservation(_, _, _, GlobalPid, _, _)),
            retractall(registered(_Namespace, _Name, GlobalPid)),
            retractall(registered_service(_ServiceName, GlobalPid)),
            forall(hook_registry_retire(GlobalPid), true),
            with_mutex(actors_monitor_lifecycle,
                (   down_reason(Pid, Reason),
                    forall(retract(monitor(Other, GlobalPid, Ref)),
                           send_system(Other, down(GlobalPid, Ref, Reason))),
                    retractall(pid_thread(Pid, _)),
                    retractall(thread_pid(_, Pid))
                ))
        )),
    retractall(actor_public_namespace(Pid, _)),
    forall(hook_pid_retired(GlobalPid), true).


%!  down_reason(+Pid, -Reason) is det.
%
%   Derive best available termination reason for monitor notifications.
%   exit_reason/2 is checked first because it is an application-level
%   fact that survives thread detach/join; relying on is_thread/1 as a
%   guard caused the lookup to fall through to no_process when the thread
%   had already been cleaned up.
down_reason(Pid, Reason) :-
    retract(exit_reason(Pid, Reason0)),
    monitor_reason(Reason0, Reason),
    !.
down_reason(Pid, Reason) :-
    pid_thread(Pid, ThreadId),
    is_thread(ThreadId),
    thread_property(ThreadId, status(Reason0)),
    monitor_reason(Reason0, Reason),
    !.
down_reason(_, no_process).

%!  monitor_reason(+Reason0, -Reason) is det.
%
%   Monitor notifications cross an actor boundary and may ultimately cross a
%   public node boundary.  Preserve the formal exception classification while
%   eliding implementation context and private actor-module qualification.
monitor_reason(exception(error(Formal0, _)),
               exception(error(Formal, _))) :-
    !,
    monitor_formal_error(Formal0, Formal).
monitor_reason(Reason, Reason).

monitor_formal_error(existence_error(procedure, Module:PI),
                     existence_error(procedure, PI)) :-
    atom(Module),
    sub_atom(Module, 0, _, _, 'actor_'),
    !.
monitor_formal_error(Formal, Formal).


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
%!  demonitor(+Ref, +Options:list) is det.
%
%   Monitoring/demonitoring of processes. The `flush` option removes any
%   pending `down(_, Ref, _)` messages for Ref from the caller's mailbox.

:- dynamic monitor/3.

monitor(Name, Ref) :-
    current_registered(Name, Pid),
    !,
    monitor(Pid, Ref).
monitor(Pid, Ref) :-
    self(Self),
    canonical_pid(Pid, CanonPid),
    forall(hook_check_monitor(CanonPid), true),
    make_ref(Ref),
    with_mutex(actors_monitor_lifecycle,
        install_monitor(Self, CanonPid, Ref, Outcome)),
    deliver_missing_monitor(Outcome, Self, Ref, CanonPid).

%!  install_monitor(+Watcher, +Pid, +Ref, -Outcome) is det.
%
%   Atomically install a monitor for a live local actor or for a target
%   claimed by a distribution hook.  A pid that is already gone is not
%   recorded: its watcher receives an immediate no_process notification.
install_monitor(Self, CanonPid, Ref, installed) :-
    monitor_target_alive(CanonPid),
    !,
    assertz(monitor(Self, CanonPid, Ref)),
    forall(hook_monitor(Self, CanonPid, Ref), true).
install_monitor(Self, CanonPid, Ref, installed) :-
    findall(true, hook_monitor(Self, CanonPid, Ref), HookResults),
    HookResults \== [],
    !,
    assertz(monitor(Self, CanonPid, Ref)).
install_monitor(_, _, _, missing).

monitor_target_alive(CanonPid) :-
    pid_local(CanonPid, LocalPid),
    (   LocalPid == main
    ->  is_thread(main)
    ;   pid_thread(LocalPid, ThreadId),
        is_thread(ThreadId)
    ).

deliver_missing_monitor(installed, _, _, _).
deliver_missing_monitor(missing, Self, Ref, CanonPid) :-
    send_system(Self, down(CanonPid, Ref, no_process)).

demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    must_be(ground, Ref),
    self(Self),
    with_mutex(actors_monitor_lifecycle,
        (   (   retract(monitor(Self, _, Ref))
            ->  forall(hook_demonitor(Ref), true)
            ;   true
            )
        )),
    (   option(flush, Options)
    ->  flush_monitor_down(Ref)
    ;   true
    ).

flush_monitor_down(Ref) :-
    receive({
        down(_, Ref, _) ->
            flush_monitor_down(Ref)
    }, [timeout(0)]).

%!  register(+Name, +Pid) is det.
%
%   Register the given Pid under the name Name.

:- dynamic registered/3.
:- dynamic registered_service/2.
:- dynamic spawn_name_reservation/6. % Token, Namespace, Name, Owner, Pid, State
:- dynamic delayed_send/3.

register(Name, Pid) :-
    must_be(atom, Name),
    canonical_pid(Pid, CanonPid),
    current_registry_namespace(Namespace),
    %  Availability check and insert must be atomic, or two threads can
    %  both pass the check and then both assert — duplicate registrations
    %  or two pids claiming one name.
    with_mutex(actors_registry,
        (   ensure_name_registration_available(Namespace, Name, Pid, CanonPid),
            ensure_registry_namespace_open(Namespace),
            ensure_registerable_local_pid(Pid, CanonPid),
            asserta(registered(Namespace, Name, CanonPid))
        )).

%!  register_service(+Name, +Pid) is det.
%
%   Publish Pid under Name in the node-wide *service* registry, visible
%   across all namespaces (unlike register/2, which is namespace-local).
%   The ordinary and public service registries are independent namespaces.
%   The node layer restricts mutation to owner-side code; stand-alone use is
%   unrestricted.

register_service(Name, Pid) :-
    require_service_registry_access(register_service(Name, Pid)),
    must_be(atom, Name),
    canonical_pid(Pid, CanonPid),
    with_mutex(actors_registry,
        (   ensure_publishable_service_pid(Pid, CanonPid),
            ensure_service_registration_available(Name),
            asserta(registered_service(Name, CanonPid))
        )).

%!  unregister(+Name) is det.

unregister(Name) :-
    must_be(atom, Name),
    current_registry_namespace(Namespace),
    with_mutex(actors_registry, retractall(registered(Namespace, Name, _))).

%!  unregister_service(+Name) is det.
%
%   Remove Name from the service registry.  Succeeds even if Name was
%   not registered.

unregister_service(Name) :-
    require_service_registry_access(unregister_service(Name)),
    must_be(atom, Name),
    with_mutex(actors_registry,
               retractall(registered_service(Name, _))).

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
    published_service_target(Name, Pid),
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
    ->  service_registry_access_error(Goal)
    ;   true
    ).

service_registry_access_error(register_service(Name, _Pid)) :-
    throw(error(permission_error(register, service, Name),
                context(actors:register_service/2,
                        'service publication is reserved for node-owned runtime code'))).
service_registry_access_error(unregister_service(Name)) :-
    throw(error(permission_error(unregister, service, Name),
                context(actors:unregister_service/1,
                        'service withdrawal is reserved for node-owned runtime code'))).
service_registry_access_error(Goal) :-
    throw(error(permission_error(access, actor_service_registry, Goal),
                context(actors:require_service_registry_access/1,
                        'service registry inspection is reserved for node-owned runtime code'))).

% Internal composition API. The node closes admission under the same lock
% before clearing bindings and reservations; actors themselves are untouched.
retire_registry_namespace(Namespace) :-
    with_mutex(actors_registry,
        (retractall(registered(Namespace, _, _)),
         retractall(spawn_name_reservation(_, Namespace, _, _, _, _)))).

ensure_registry_namespace_open(Namespace) :-
    (   hook_registry_namespace_status(Namespace, Status)
    ->  (Status == open -> true;
         throw(error(permission_error(register, closed_namespace, Namespace),
                     context(actors:register/2, 'client namespace has ended'))))
    ;   true
    ).

%  Called under actors_registry, also held while retiring pid mappings.
%  Only local actor pids are checked; remote aliases retain their semantics.
ensure_registerable_local_pid(Pid, CanonPid) :-
    pid_local(CanonPid, LocalPid),
    (   (integer(LocalPid) ; LocalPid == main
        ; nonvar(LocalPid), LocalPid = actor(Id), integer(Id))
    ->  (   monitor_target_alive(CanonPid)
        ->  true
        ;   throw(error(existence_error(process, Pid),
                        context(actors:register/2, 'local actor no longer exists')))
        )
    ;   true
    ).

ensure_name_registration_available(Namespace, Name, Pid, CanonPid) :-
    (   (ordinary_registered_pid(Namespace, CanonPid) ; reserved_spawn_pid(Namespace, CanonPid))
    ->  throw(process_already_has_a_name(Pid))
    ;   (ordinary_registered_name(Namespace, Name) ; reserved_spawn_name(Namespace, Name))
    ->  throw(name_is_in_use(Name))
    ;   true
    ).

reserve_spawn_name(Name, Token) :-
    self(Owner), make_ref(Token), current_registry_namespace(Namespace),
    with_mutex(actors_registry,
        (   ensure_registry_namespace_open(Namespace),
            (   (ordinary_registered_name(Namespace,Name) ; reserved_spawn_name(Namespace,Name))
            ->  throw(name_is_in_use(Name))
            ;   assertz(spawn_name_reservation(Token,Namespace,Name,Owner,pending,reserved))
            )
        )).

reserved_spawn_name(Namespace, Name) :-
    spawn_name_reservation(_, NS, Name, _, _, State), State \== published,
    (nonvar(Namespace) -> Namespace == NS ; true).

reserved_spawn_pid(Namespace, Pid) :-
    spawn_name_reservation(_, NS, _, _, Child, State), State \== published,
    Child \== pending, Pid == Child,
    (nonvar(Namespace) -> Namespace == NS ; true).

attach_spawn_name(Options, Pid) :-
    (   option(name_reservation(Token),Options)
    ->  self(Owner), current_registry_namespace(Namespace),
        with_mutex(actors_registry,
            (   ensure_registry_namespace_open(Namespace),
                (   retract(spawn_name_reservation(Token,NS,Name,Owner,pending,reserved))
                ->  assertz(spawn_name_reservation(Token,NS,Name,Owner,Pid,reserved))
                ;   existence_error(name_reservation,Token)
                )
            ))
    ;   true
    ).

publish_spawn_name(Owner, Pid, Options) :-
    (   option(name_reservation(Token),Options)
    ->  current_registry_namespace(Namespace),
        with_mutex(actors_registry,
            (   ensure_registry_namespace_open(Namespace),
                (   retract(spawn_name_reservation(Token,NS,Name,Owner,Pid,reserved))
                ->  ensure_registry_namespace_open(NS),
                    assertz(registered(NS,Name,Pid)),
                    assertz(spawn_name_reservation(Token,NS,Name,Owner,Pid,published))
                ;   spawn_name_reservation(Token,_,_,Owner,Pid,failed)
                ->  true  % preparation failed: acknowledge, without publication
                ;   existence_error(name_reservation,Token)
                )
            ))
    ;   true
    ).

fail_spawn_name(Owner, Pid, Options) :-
    (   option(name_reservation(Token),Options)
    ->  with_mutex(actors_registry,
            (   retract(spawn_name_reservation(Token,NS,Name,Owner,Pid,reserved))
            ->  assertz(spawn_name_reservation(Token,NS,Name,Owner,Pid,failed))
            ;   true
            ))
    ;   true
    ).

finish_spawn_name(Token, Catcher) :-
    with_mutex(actors_registry,
        forall(retract(spawn_name_reservation(Token,NS,Name,_,Pid,State)),
            (   Catcher \== exit, Catcher \== (!), State == published
            ->  retractall(registered(NS,Name,Pid))
            ;   true
            ))).

ensure_service_registration_available(Name) :-
    (   published_service_name(Name)
    ->  throw(error(permission_error(register, service, Name),
                    context(actors:register_service/2,
                            'service name is already published')))
    ;   true
    ).

ensure_publishable_service_pid(Pid, CanonPid) :-
    (   compound(CanonPid),
        compound_name_arity(CanonPid, '@', 2),
        \+ hook_local_pid(CanonPid, _)
    ->  throw(error(permission_error(register, service, Pid),
                    context(actors:register_service/2,
                            'only actors on the publishing node may be published')))
    ;   resolve_thread(CanonPid, _)
    ->  true
    ;   throw(error(existence_error(process, Pid),
                    context(actors:register_service/2,
                            'service pid does not identify a live actor')))
    ).

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

%!  published_service_target(+Name, -Pid) is semidet.
%!  published_service_names(-Names) is det.
%!  send_service(+Name, +Message) is det.
%
%   Owner/runtime helpers used by the node and distribution layers.  They are
%   deliberately not exported as client predicates.  send_service/2 is
%   non-revealing: an absent service is treated like a dead pid.
published_service_target(Name, Pid) :-
    atom(Name),
    with_mutex(actors_registry,
               once(registered_service(Name, Pid))).

published_service_names(Names) :-
    with_mutex(actors_registry,
        (   findall(Name, registered_service(Name, _), Names0),
            sort(Names0, Names)
        )).

send_service(Name, Message) :-
    (   published_service_target(Name, Pid)
    ->  send(Pid, Message)
    ;   true
    ).


                /*******************************
                *             EXIT             *
                *******************************/

%!  exit(+Reason)
%
%   Exit the calling process.  Termination commits when the first exit
%   reason is recorded: from then on the actor is terminating, its reason
%   is fixed, and later exit requests (and exit signals) have no effect.

:- dynamic exit_reason/2.

exit(Reason) :-
    var(Reason),
    instantiation_error(Reason).
exit(Reason) :-
    self_local(LocalSelf),
    (   exit_reason(LocalSelf, _)
    ->  true
    ;   assertz(exit_reason(LocalSelf, Reason)),
        abort
    ).

%!  actor_terminating is semidet.
%
%   True once termination of the calling actor has been committed.  Used by
%   the PTCP boundary so that an abort cannot resume a terminating toplevel.

actor_terminating :-
    self_local(LocalSelf),
    exit_reason(LocalSelf, _),
    !.


%!  exit(+Pid, +Reason) is det.
%
%   Exit the actor known as Pid.  Non-local pids are handled by the
%   distribution layer through hook_exit/2.

exit(Pid, Reason) :-
    must_be(ground, Pid),
    forall(hook_check_exit(Pid), true),
    exit_actor(Pid, Reason).

exit_actor(Pid, Reason) :-
    hook_exit(Pid, Reason),
    !.
exit_actor(Pid, Reason) :-
    (   resolve_actor_thread(Pid, ThreadId)
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

:- thread_local system_delivery/0.

send_system(Pid, Message) :-
    setup_call_cleanup(asserta(system_delivery, Ref),
                       catch(send(Pid, Message), _, true), erase(Ref)).

Pid ! Message :-
    send(Pid, Message).

send(Pid, Message) :-
    (system_delivery -> true; forall(hook_check_send(Pid, Message), true)),
    send_checked(Pid, Message).

send_checked(Pid, Message) :-
    hook_send(Pid, Message),
    !.
send_checked(Name, Message) :-
    registered_target(Name, Pid),
    !,
    send(Pid, Message).
send_checked(Name, _Message) :-
    is_name(Name),
    !,
    %  The context literal is the demonstrator's exact error term:
    %  observable error shape is part of the semantics freeze.
    throw(error(existence_error(actor_name, Name),
                context(actor:send/2,
                        'no actor registered under name'))).
send_checked(Pid, Message) :-
    (   resolve_thread(Pid, ThreadId)
    ->  deliver_actor_message(Pid, ThreadId, Message)
    ;   true
    ).

deliver_actor_message(Pid, ThreadId, Message) :-
    (   hook_deliver_message(Pid, ThreadId, Message)
    ->  true
    ;   best_effort_if_gone(thread_send_message(ThreadId, Message))
    ).

send(Pid, Message, Options) :-
    option(delay(Delay), Options, 0),
    self(Owner),
    spawn(send_with_delay(Pid, Message, Delay), DelayPid),
    (   option(id(ID), Options)
    ->  assertz(delayed_send(Owner, ID, DelayPid))
    ;   true
    ).

%!  transportable_term(@Term) is semidet.
%
%   True when Term has the portable actor-message representation shared by
%   native and SWI-WASM runtimes: an acyclic ordinary Prolog term without
%   attributed variables, streams, or other blob values. Plain variables are
%   allowed and arrive as fresh variables in the receiver's copied term.
%   SWI's text and ucs_text blob types both represent ordinary text atoms.
transportable_term(Term) :-
    acyclic_term(Term),
    term_attvars(Term, []),
    \+ ( sub_term(Sub, Term),
         nonvar(Sub),
         blob(Sub, BlobType),
         BlobType \== text,
         BlobType \== ucs_text,
         BlobType \== reserved_symbol
       ).

cancel(ID) :-
    self(Owner),
    forall(retract(delayed_send(Owner, ID, DelayPid)),
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
    retractall(delayed_send(_, _, Self)).


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

%!  current_io_target(-Target) is semidet.
%
%   True for the terminal target inherited by the current actor.  This is an
%   internal capability-discovery operation used by the distribution layer;
%   actor_api deliberately does not re-export it to public actor programs.

current_io_target(Target) :-
    io_target(Target),
    !.

default_io_target(_Fallback, Target) :-
    io_target(Target),
    !.
default_io_target(Fallback, Fallback).


                /*******************************
                *            RECEIVE           *
                *******************************/

%!  receive(+ReceiveClauses) is nondet.
%!  receive(+ReceiveClauses, +Options) is nondet.
%
%   Committed message selection by one-sided matching: a pattern may bind its
%   own variables but never variables inside the message. One invocation consumes at most
%   one message, but its ordinary Prolog clause body may yield several logical
%   solutions. Backtracking through that body never selects another message or
%   clause.

:- thread_local deferred/1.

%!  discard_deferred(:Test) is det.
%
%   Remove the messages that receive/1-2 has already skipped, the ones that
%   arrived before the message most recently received, for which
%   call(Test, Message) succeeds.  Messages still in the queue, which
%   arrived later, are untouched.  Not exported: the toplevel layer calls it
%   qualified, to discard commands left over from an earlier query.

:- meta_predicate discard_deferred(1).

discard_deferred(Test) :-
    forall(( clause(deferred(Msg), true, Ref),
             call(Test, Msg)
           ),
           (erase(Ref), forall(hook_message_consumed, true))).

receive(Clauses) :-
    receive(Clauses, []).

receive(Clauses, Options) :-
    thread_self(Mailbox),
    (   clause(deferred(Msg), true, Ref),
        select_body(Clauses, Msg, Module, Body)
    ->  erase(Ref),
        forall(hook_message_consumed, true),
        call(Module:Body)
    ;   receive(Mailbox, Clauses, Options)
    ).

receive(Mailbox, Clauses, Options) :-
    (   selectchk(timeout(Seconds), Options, Rest),
        Seconds > 0
    ->  get_time(Now),
        Deadline is Now + Seconds,
        receive_scan(Mailbox, Clauses, [deadline(Deadline)|Rest], Options)
    ;   receive_scan(Mailbox, Clauses, Options, Options)
    ).

% Keep one deadline throughout the scan: unrelated arrivals do not restart
% the wait. Preserve timeout(0), whose queue-inspection semantics differ
% from an expired deadline. The original options retain the timeout body.
%
% A new message is recorded as deferred before its guards run, and the
% record is erased only when a clause is selected.  A control exception that
% escapes from a guard therefore leaves the message in the mailbox, in its
% original position.
receive_scan(Mailbox, Clauses, GetOptions, Options) :-
    (   receive_message(Mailbox, Msg, GetOptions, Ref)
    ->  (   select_body(Clauses, Msg, Module, Body)
        ->  erase(Ref),
            forall(hook_message_consumed, true),
            call(Module:Body)
        ;   receive_scan(Mailbox, Clauses, GetOptions, Options)
        )
    ;   option(on_timeout(Goal), Options, true),
        clauses_module(Clauses, Module),
        call(Module:Goal)
    ).

% A zero-time poll must not enter a timed wait. SWI 10.1.17 can retry
% forever if a signal is pending while cleanup masks signal handling, even
% with timeout(0). Only this thread consumes its actor mailbox, so a peek
% followed by an unbounded read cannot wait for a message that was absent.
% Protect peek, read and deferred recording together. Guards and bodies remain
% outside this region. Other waits use protected 50 ms slices and return to
% ordinary signal handling between slices. This candidate requires SWI's
% 09b6299 protected-wait fix; the official 10.1.18 package predates that fix.
% Restrict the shortcut to the documented receive options; host extensions,
% mixed duplicate timeouts and malformed lists retain native option handling.
receive_message(Mailbox, Msg, Options, Ref) :-
    (   is_list(Options),
        memberchk(timeout(Seconds), Options),
        number(Seconds), Seconds =:= 0,
        maplist(zero_poll_option, Options)
    ->  sig_atomic((thread_peek_message(Mailbox, _),
                    thread_get_message(Mailbox, Msg),
                    assertz(deferred(Msg), Ref)))
    ;   receive_wait_options(Mailbox, Options, Deadline, WaitOptions),
        receive_message_until(Mailbox, Msg, WaitOptions, Deadline, Ref)
    ).

% Validate host options through SWI itself without taking a message or waiting.
% The final, already-expired deadline prevents acquisition. Retain unknown host
% options and their native validation rather than introducing a second scanner.
% Resolve any relative native timeout once, before the first bounded wait.
receive_wait_options(Mailbox, Options, Deadline, WaitOptions) :-
    must_be(list, Options),
    append(Options, [deadline(-1)], ValidationOptions),
    (thread_get_message(Mailbox, _, ValidationOptions) -> true ; true),
    get_time(Now),
    findall(T, member(timeout(T), Options), Timeouts),
    findall(D, member(deadline(D), Options), Deadlines),
    (Timeouts == [] -> Relative=infinite
    ; last(Timeouts, Timeout),
      (Timeout < 0 -> Relative=expired
      ; Timeout =:= 0 -> Relative=poll
      ; Relative is Now+Timeout)),
    (Deadlines == [] -> Absolute=infinite ; last(Deadlines, Absolute)),
    receive_wait_deadline(Relative, Absolute, Now, Deadline),
    exclude(receive_time_option, Options, WaitOptions).

receive_time_option(timeout(_)).
receive_time_option(deadline(_)).

receive_wait_deadline(expired, _, _, expired) :- !.
receive_wait_deadline(_, Absolute, Now, expired) :-
    number(Absolute), Absolute < Now, !.
receive_wait_deadline(poll, _, _, poll) :- !.
receive_wait_deadline(infinite, Absolute, _, Absolute) :- !.
receive_wait_deadline(Relative, infinite, _, Relative) :- !.
receive_wait_deadline(Relative, Absolute, _, Deadline) :-
    Deadline is min(Relative, Absolute).

receive_message_until(_, _, _, expired, _) :- !, fail.
receive_message_until(Mailbox, Msg, _Options, poll, Ref) :-
    !,
    sig_atomic((thread_peek_message(Mailbox, _),
                thread_get_message(Mailbox, Msg),
                assertz(deferred(Msg), Ref))).
% Preserve the native host extension that explicitly disables signal checks
% while waiting. Public/default receives use the bounded interruptible path.
receive_message_until(Mailbox, Msg, Options, Deadline, Ref) :-
    findall(Signal, member(signals(Signal), Options), Signals),
    Signals \== [], last(Signals, false), !,
    (Deadline == infinite -> FinalOptions=Options
    ; append(Options, [deadline(Deadline)], FinalOptions)),
    sig_atomic((thread_get_message(Mailbox, Msg, FinalOptions),
                assertz(deferred(Msg), Ref))).
receive_message_until(Mailbox, Msg, Options, Deadline, Ref) :-
    get_time(Now),
    (Deadline == infinite -> Slice is Now+0.05
    ; Now < Deadline, Slice is min(Deadline, Now+0.05)),
    append(Options, [deadline(Slice)], SliceOptions),
    (   sig_atomic((thread_get_message(Mailbox, Msg, SliceOptions),
                    assertz(deferred(Msg), Ref)))
    ->  true
    ;   % A failed slice leaves sig_atomic/1 before retrying: pending signals
        % can run here, even when the public receive has no timeout.
        receive_message_until(Mailbox, Msg, Options, Deadline, Ref)
    ).

zero_poll_option(timeout(Seconds)) :- number(Seconds), Seconds =:= 0.
zero_poll_option(on_timeout(_)).

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
%   Match a message against receive patterns, including guarded `if/2` forms.
%   Matching is one-sided: the pattern must subsume the message, so a pattern
%   never specializes variables in the receiver's copy of a message.  A guard
%   that fails or raises an ordinary exception rejects the candidate; a
%   reserved control exception (abort, termination, enforced limits)
%   propagates.  Failed candidates undo both pattern and guard bindings before
%   trying the next clause or message. The enclosing receive commits to the
%   first match.
select_body_aux((Clause ; Clauses), Message, Module, Body) :-
    (   select_body_aux(Clause,  Message, Module, Body)
    ;   select_body_aux(Clauses, Message, Module, Body)
    ).
select_body_aux((Head -> Body), Message, Module, Body) :-
    (   nonvar(Head),
        Head = if(Pattern, Guard)
    ->  match_message(Pattern, Message),
        catch(once(Module:Guard), E, guard_exception(E))
    ;   match_message(Head, Message)
    ).

match_message(Pattern, Message) :-
    subsumes_term(Pattern, Message),
    Pattern = Message.

guard_exception(E) :-
    guard_control_exception(E),
    !,
    throw(E).
guard_exception(_) :-
    fail.

%   The reserved control transfers of control_guard:reserved_control/1,
%   repeated here because this layer may not import control_guard.  Any
%   host unwind (abort or halt) is included.
guard_control_exception('$abort_goal').
guard_control_exception('$ptcp_time_limit').
guard_control_exception(unwind(_)).


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
% Public termination resolves only runtime-issued actor pids. Internal I/O
% may still address private queues, but no thread alias is a termination pid.
resolve_actor_thread(Pid, ThreadId) :-
    nonvar(Pid),
    pid_local(Pid, LocalPid),
    pid_thread(LocalPid, ThreadId),
    is_thread(ThreadId).

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
