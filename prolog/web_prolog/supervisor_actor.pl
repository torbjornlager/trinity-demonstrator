:- module(supervisor_actor, [

       supervisor_spawn/2,
       supervisor_spawn/3,
       supervisor_spawn_child/3,
       supervisor_terminate_child/3,
       supervisor_delete_child/3,
       supervisor_respawn_child/3,
       supervisor_which_children/2,
       supervisor_count_children/2,
       supervisor_halt/1,
       supervisor_stop/1

   ]).

/** <module> Supervisor Behaviour (layer 2)

An OTP-style supervisor actor: it starts, monitors and restarts a set of
child actors according to per-child restart/shutdown specifications and a
restart strategy (one_for_one, one_for_all, rest_for_one). Built on
actors.pl and server_actor.pl.

The detailed child-specification and option syntax is documented in the
comment block below.
*/

%% ===================================================================
%% supervisor_actor.pl — Supervisor behaviour for actor.pl
%% ===================================================================
%%
%% Consulted into user space.  Requires actors.pl and server_actor.pl.
%%
%% Child specification syntax:
%%
%%   child(Id, Options)
%%
%%   Options:
%%     start(Goal)       — required; a callable goal, or
%%                          server(Pred, ServerOpts)
%%     restart(R)        — permanent (default), transient, temporary
%%     shutdown(S)       — brutal_kill, a number (seconds), or
%%                          infinity.  Default: infinity for
%%                          supervisor-type children, 5 for workers.
%%     type(T)           — worker (default) or supervisor



:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(library(debug)).

:- use_module(actors).
:- use_module(server_actor).
:- use_module(supervisor_startup, [with_startup_scope/1, remember_monitor/2]).
:- use_module(isolation, [execution_source_module/2]).

:- meta_predicate
       supervisor_spawn(:, -),
       supervisor_spawn(:, -, +),
       supervisor_spawn_child(+, :, -),
       start_sub_supervisor(:, +).



%% -------------------------------------------------------------------
%% Child specification normalisation
%% -------------------------------------------------------------------

normalise_child_specs(Caller, ChildSpecs, Specs) :-
    must_be(list, ChildSpecs),
    check_acyclic_child_spec(ChildSpecs),
    maplist(normalise_child_spec(Caller), ChildSpecs, Specs),
    unique_child_ids(Specs, []).

unique_child_ids([], _).
unique_child_ids([spec(Id,_,_,_,_)|Specs], Seen) :-
    (   memberchk(Id, Seen)
    ->  permission_error(duplicate, supervisor_child_id, Id)
    ;   unique_child_ids(Specs, [Id|Seen])
    ).

check_acyclic_child_spec(Spec) :-
    (acyclic_term(Spec) -> true ; representation_error(cyclic_term)).

normalise_child_spec(Caller, ChildSpec,
                     spec(Id, Start, Restart, Shutdown, Type)) :-
    must_be(nonvar, ChildSpec),
    check_acyclic_child_spec(ChildSpec),
    (   compound(ChildSpec), compound_name_arity(ChildSpec, child, 2)
    ->  arg(1, ChildSpec, Id), arg(2, ChildSpec, Opts)
    ;   type_error(supervisor_child_spec, ChildSpec)
    ),
    must_be(ground, Id),
    must_be(list, Opts),
    maplist(validate_child_option(Caller,Id), Opts),
    (   option(start(Start0), Opts)
    ->  qualify_start_term(Caller, Start0, Start)
    ;   throw(error(missing_start_option(Id), supervisor))
    ),
    option(restart(Restart), Opts, permanent),
    option(type(Type), Opts, worker),
    default_shutdown(Type, DefShutdown),
    option(shutdown(Shutdown), Opts, DefShutdown).

validate_child_option(Caller, Id, Option) :-
    must_be(nonvar, Option),
    (   compound(Option), compound_name_arity(Option, Name, 1),
        memberchk(Name, [start,restart,shutdown,type])
    ->  arg(1, Option, Value), validate_child_value(Name, Caller, Id, Value)
    ;   domain_error(supervisor_child_option, Option)
    ).

validate_child_value(start, Caller, Id, Start) :-
    validate_child_callable(Start),
    (   Start = server(Pred, Options)
    ->  must_be(atom, Id), validate_child_callable(Pred),
        actors:validate_spawn_wrapper_options(Options, runtime,
            supervisor_actor:supervisor_spawn/3,
            [initial_state=supervisor_actor:child_state_value,
             name=error:must_be(atom)])
    ;   Start = start_sub_supervisor(Specs, Options)
    ->  validate_nested_supervisor(Caller, Specs, Options)
    ;   Start = supervisor_actor:start_sub_supervisor(Specs, Options)
    ->  validate_nested_supervisor(Caller, Specs, Options)
    ;   true
    ).
validate_child_value(restart, _, _, Policy) :-
    must_be(oneof([permanent,transient,temporary]), Policy).
validate_child_value(type, _, _, Type) :-
    must_be(oneof([worker,supervisor]), Type).
validate_child_value(shutdown, _, _, Shutdown) :-
    must_be(nonvar, Shutdown),
    (   Shutdown == brutal_kill -> true
    ;   Shutdown == infinity -> true
    ;   number(Shutdown), Shutdown >= 0 -> true
    ;   domain_error(supervisor_child_shutdown, Shutdown)
    ).

% Only the module qualification is inspected, not the goal's arguments or
% predicate availability. Start goals and states may retain shared variables.
validate_child_callable(Goal) :-
    must_be(callable, Goal),
    (   Goal = Module:Inner
    ->  must_be(atom, Module), validate_child_callable(Inner)
    ;   true
    ).

child_state_value(_).

validate_nested_supervisor(Caller, Specs0, Options) :-
    validate_supervisor_options(Options),
    child_specs_module(Specs0, Caller, Module, Specs),
    normalise_child_specs(Module, Specs, _).

child_specs_module(Specs0, Default, Module, Specs) :-
    (   nonvar(Specs0), Specs0 = Qualified:Inner
    ->  must_be(atom, Qualified), child_specs_module(Inner, Qualified, Module, Specs)
    ;   Module = Default, Specs = Specs0
    ).

default_shutdown(supervisor, infinity).
default_shutdown(worker, 5).

qualify_start_term(Caller, server(Pred0, ServerOpts),
                   server(Pred, ServerOpts)) :-
    !,
    qualify_goal_term(Caller, Pred0, Pred).
qualify_start_term(Caller, Goal0, Goal) :-
    qualify_goal_term(Caller, Goal0, Goal).

qualify_goal_term(_, Mod:Goal, Mod:Goal) :- !.
qualify_goal_term(Caller, start_sub_supervisor(Specs, Opts),
                  supervisor_actor:start_sub_supervisor(Caller:Specs, Opts)) :- !.
qualify_goal_term(Caller, Goal, Caller:Goal).


%% -------------------------------------------------------------------
%% Supervisor state:  sup(Strategy, MaxR, MaxT, Children, RestartLog)
%%
%% Children = list of ch(Id, Pid, Spec) in start order
%% Pid = actor pid | undefined
%% RestartLog = list of timestamps (seconds since epoch)
%% -------------------------------------------------------------------


%% -------------------------------------------------------------------
%% Public API — starting
%% -------------------------------------------------------------------

supervisor_spawn(ChildSpecs, Pid) :-
    supervisor_spawn(ChildSpecs, Pid, []).

supervisor_spawn(ChildSpecs0, Pid, Options) :-
    validate_supervisor_options(Options),
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    execution_source_module(Caller, SourceModule),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxR), Options, 1),
    option(period(MaxT), Options, 5),
    normalise_child_specs(SourceModule, ChildSpecs, Specs),
    exclude(is_sup_option, Options, SpawnOpts0),
    ensure_source_module(SourceModule, SpawnOpts0, SpawnOpts),
    State0 = sup(Strategy, MaxR, MaxT, [], []),
    spawn_with_name(sup_init(Specs, State0), Pid, SpawnOpts, Options).

is_sup_option(strategy(_)).
is_sup_option(intensity(_)).
is_sup_option(period(_)).
is_sup_option(name(_)).

validate_supervisor_options(Options) :-
    actors:validate_spawn_wrapper_options(Options, runtime,
        supervisor_actor:supervisor_spawn/3,
        [name=error:must_be(atom),
         strategy=supervisor_actor:validate_strategy,
         intensity=error:must_be(nonneg),
         period=supervisor_actor:validate_period]).

validate_strategy(Strategy) :-
    must_be(nonvar, Strategy),
    (   memberchk(Strategy, [one_for_one,one_for_all,rest_for_one])
    ->  true
    ;   domain_error(supervisor_strategy, Strategy)
    ).

validate_period(Period) :-
    must_be(number, Period),
    (Period > 0 -> true ; domain_error(supervisor_period, Period)).

ensure_source_module(_, Options, Options) :-
    option(source_module(_), Options),
    !.
ensure_source_module(Module, Options, [source_module(Module)|Options]).


%% -------------------------------------------------------------------
%% Starting a nested (child) supervisor
%% -------------------------------------------------------------------
%%
%% Used as the start goal for a child of type supervisor.
%% Runs sup_init directly in the spawned process, so the child
%% becomes a supervisor loop.
%%
%% Example child spec:
%%
%%   child(inner, [
%%       start(start_sub_supervisor(InnerChildSpecs, InnerOpts)),
%%       type(supervisor)
%%   ])

start_sub_supervisor(ChildSpecs0, Options) :-
    validate_supervisor_options(Options),
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxR), Options, 1),
    option(period(MaxT), Options, 5),
    normalise_child_specs(Caller, ChildSpecs, Specs),
    State0 = sup(Strategy, MaxR, MaxT, [], []),
    sup_init(Specs, State0).


%% -------------------------------------------------------------------
%% Public API — dynamic child management (synchronous)
%% -------------------------------------------------------------------

supervisor_spawn_child(Sup, ChildSpec0, Reply) :-
    strip_module(ChildSpec0, Caller, ChildSpec),
    normalise_child_spec(Caller, ChildSpec, NormSpec),
    sup_call(Sup, start_child(NormSpec), Reply).

supervisor_terminate_child(Sup, Id, Reply) :-
    sup_call(Sup, terminate_child(Id), Reply).

supervisor_delete_child(Sup, Id, Reply) :-
    sup_call(Sup, delete_child(Id), Reply).

supervisor_respawn_child(Sup, Id, Reply) :-
    sup_call(Sup, restart_child(Id), Reply).

supervisor_which_children(Sup, Children) :-
    sup_call(Sup, which_children, Children).

supervisor_count_children(Sup, Counts) :-
    sup_call(Sup, count_children, Counts).

supervisor_halt(Sup) :-
    sup_halt_call(Sup).

supervisor_stop(Sup) :-
    supervisor_halt(Sup).


%% -------------------------------------------------------------------
%% Synchronous call infrastructure
%% -------------------------------------------------------------------

% Own the private wait monitor across sending and every exit from receive.
% Flushing this reference leaves application monitors and late replies alone.
sup_call(Sup, Request, Reply) :-
    self(Self),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(Sup, MonRef),
        ( Sup ! '$sup'(Self, Ref, Request),
          receive({
              Ref-Reply0 -> Reply = Reply0
          ;
              down(_, MonRef, Reason) -> throw(supervisor_down(Reason))
          }, [timeout(10),
              on_timeout(throw(supervisor_call_timeout(Sup, Request)))])
        ),
        demonitor(MonRef, [flush])).

% A normal down can overtake the acknowledgement on another connection.
% Only halt waits tolerate that ordering; retain one deadline and require ack.
sup_halt_call(Supervisor) :-
    self(Self),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(Supervisor, MonitorRef),
        ( Supervisor ! '$sup'(Self, Ref, stop),
          get_time(Now), Deadline is Now + 10,
          sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, pending)
        ),
        demonitor(MonitorRef, [flush])).

sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, Outcome) :-
    get_time(Now), Remaining is max(0, Deadline - Now),
    receive({
        Ref-_ -> true ;
        down(_, MonitorRef, Reason) ->
            ( Reason == true
            -> sup_halt_wait(Supervisor, Ref, MonitorRef, Deadline, normal_down)
            ; throw(supervisor_down(Reason)) )
    }, [timeout(Remaining),
        on_timeout(sup_halt_timeout(Supervisor, Outcome))]).

sup_halt_timeout(_, normal_down) :- !,
    throw(supervisor_down(true)).
sup_halt_timeout(Supervisor, pending) :-
    throw(supervisor_call_timeout(Supervisor, stop)).

sup_reply(From, Ref, Reply) :-
    From ! Ref-Reply.


%% -------------------------------------------------------------------
%% Initialisation
%% -------------------------------------------------------------------

sup_init(Specs, State0) :-
    (   with_startup_scope(start_children(Specs, State0, State))
    ->  sup_loop(State)
    ;   exit(init_failed)
    ).

start_children([], State, State).
start_children([Spec | Rest], State0, State) :-
    do_start_child(Spec, State0, State1),
    start_children(Rest, State1, State).


%% -------------------------------------------------------------------
%% Starting a single child
%% -------------------------------------------------------------------

do_start_child(spec(Id, Start, Restart, Shutdown, Type),
               sup(Str, MR, MT, Children, RL),
               sup(Str, MR, MT, Children1, RL)) :-
    \+ member(ch(Id, _, _), Children),
    Spec = spec(Id, Start, Restart, Shutdown, Type),
    supervisor_startup:start_child(Spec, Start, Id, Pid),
    monitor(Pid, MonitorRef),
    remember_monitor(Pid, MonitorRef),
    append(Children, [ch(Id, Pid, Spec)], Children1),
    debug(supervisor, '[sup] Started ~w  pid=~w', [Id, Pid]).

%% Children are spawned with link(true) so that if the supervisor
%% dies unexpectedly, actor.pl's stop/2 will cascade-kill all
%% linked children.  This is safe because links are directional:
%% link(Supervisor, Child) means "kill Child when Supervisor dies"
%% but a child's death does NOT kill the supervisor — it only
%% cleans up the link.  The supervisor learns about child deaths
%% through monitor/2 messages, which are independent of links.

do_spawn_child(server(Pred, ServerOpts), Name, Pid) :- !,
    option(initial_state(State), ServerOpts, []),
    exclude(is_server_actor_opt, ServerOpts, ExtraOpts),
    ensure_callback_load(Pred, ExtraOpts, ChildOpts),
    server_spawn(Pred, State, Pid,
                 [name(Name), link(true) | ChildOpts]).
do_spawn_child(supervisor_actor:start_sub_supervisor(ChildSpecs0, SupOptions),
               _Name, Pid) :-
    !,
    strip_module(ChildSpecs0, SourceModule, ChildSpecs),
    child_specs_source_options(SourceModule, ChildSpecs, SourceOptions),
    spawn(supervisor_actor:start_sub_supervisor(SourceModule:ChildSpecs,
                                                SupOptions),
          Pid, [link(true)|SourceOptions]).
do_spawn_child(Goal0, _Name, Pid) :-
    child_goal_source_options(Goal0, Goal, SourceOptions),
    spawn(Goal, Pid, [link(true)|SourceOptions]).

is_server_actor_opt(initial_state(_)).

callback_load_option(Pred, src_predicates([Name/Arity])) :-
    strip_module(Pred, _, PlainPred),
    functor(PlainPred, Name, ExtraArity),
    Arity is ExtraArity + 4.

ensure_callback_load(Pred, Options0, Options) :-
    (   member(Option, Options0),
        server_source_option(Option)
    ->  LoadedOptions = Options0
    ;   callback_load_option(Pred, CallbackLoad),
        LoadedOptions = [CallbackLoad|Options0]
    ),
    predicate_source_module(Pred, 4, SourceModule),
    ensure_source_module(SourceModule, LoadedOptions, Options).

% Preserve submitted child code across the supervisor-to-child actor
% boundary. Public actors deliberately do not inherit a live caller module,
% so a qualified start goal alone is insufficient: its defining clauses must
% be copied just as they are for a direct public spawn/3.
child_goal_source_options(Goal0, Goal, Options) :-
    strip_module(Goal0, SourceModule, Plain),
    (   callable_pi(Plain, 0, PI),
        local_predicate(SourceModule, PI)
    ->  Goal = SourceModule:Plain,
        Options = [source_module(SourceModule), src_predicates([PI])]
    ;   Goal = Goal0,
        Options = []
    ).

child_specs_source_options(SourceModule, ChildSpecs, Options) :-
    child_specs_pis(ChildSpecs, PIs0),
    include(local_predicate(SourceModule), PIs0, LocalPIs0),
    sort(LocalPIs0, LocalPIs),
    (   LocalPIs == []
    ->  Options = []
    ;   Options = [source_module(SourceModule), src_predicates(LocalPIs)]
    ).

child_specs_pis([], []).
child_specs_pis([child(_, Options)|Specs], PIs) :-
    (   option(start(Start), Options)
    ->  start_term_pis(Start, Here)
    ;   Here = []
    ),
    child_specs_pis(Specs, Rest),
    append(Here, Rest, PIs).

start_term_pis(server(Callback, _), [PI]) :-
    !,
    strip_module(Callback, _, Plain),
    callable_pi(Plain, 4, PI).
start_term_pis(start_sub_supervisor(ChildSpecs0, _), PIs) :-
    !,
    strip_module(ChildSpecs0, _, ChildSpecs),
    child_specs_pis(ChildSpecs, PIs).
start_term_pis(Goal, [PI]) :-
    strip_module(Goal, _, Plain),
    callable_pi(Plain, 0, PI).

callable_pi(Callable, ExtraArity, Name/Arity) :-
    callable(Callable),
    functor(Callable, Name, BaseArity),
    Arity is BaseArity + ExtraArity.

local_predicate(Module, Name/Arity) :-
    functor(Head, Name, Arity),
    predicate_property(Module:Head, number_of_clauses(Count)),
    Count > 0,
    \+ predicate_property(Module:Head, imported_from(_)).

predicate_source_module(Callable0, ExtraArity, SourceModule) :-
    strip_module(Callable0, Module, Callable),
    callable_pi(Callable, ExtraArity, Name/Arity),
    functor(Head, Name, Arity),
    (   predicate_property(Module:Head, imported_from(Imported))
    ->  SourceModule = Imported
    ;   SourceModule = Module
    ).

server_source_option(src_text(_)).
server_source_option(src_list(_)).
server_source_option(src_predicates(_)).
server_source_option(src_uri(_)).


%% -------------------------------------------------------------------
%% The supervisor loop
%% -------------------------------------------------------------------

sup_loop(State) :-
    receive({
        down(Pid, _, Reason) ->
            handle_exit(Pid, Reason, State, State1),
            sup_loop(State1)
        ;
        '$sup'(From, Ref, Request) ->
            handle_call(Request, From, Ref, State, State1),
            sup_loop(State1)
        ;
        '$sup_exit' ->
            sup(_, _, _, Children, _) = State,
            shutdown_children(Children)
    }).


%% -------------------------------------------------------------------
%% Handling child exits
%% -------------------------------------------------------------------

handle_exit(Pid, Reason, State0, State) :-
    sup(Strategy, MaxR, MaxT, Children, RL) = State0,
    (   select(ch(Id, Pid, Spec), Children, _Rest)
    ->  spec(_, _, Restart, _, _) = Spec,
        debug(supervisor, '[sup] Child ~w (~w) exited: ~w',
              [Id, Pid, Reason]),
        (   should_restart(Restart, Reason)
        ->  %% Mark the crashed child as dead so that
            %% group shutdown (used by one_for_all and
            %% rest_for_one) will skip it — its down message
            %% has already been consumed.
            replace_child(Id, ch(Id, undefined, Spec),
                          Children, MarkedChildren),
            (   check_intensity(MaxR, MaxT, RL, RL1)
            ->  restart_attempt(Strategy, Id, Spec, MarkedChildren,
                                MaxR, MaxT, RL1, State)
            ;   intensity_exhausted(MarkedChildren)
            )
        ;   debug(supervisor, '[sup] Not restarting ~w', [Id]),
            (   Restart == temporary
            ->  select(ch(Id, Pid, _), Children, Children1)
            ;   replace_child(Id, ch(Id, undefined, Spec),
                              Children, Children1)
            ),
            State = sup(Strategy, MaxR, MaxT, Children1, RL)
        )
    ;   debug(supervisor, '[sup] Ignoring down from unknown ~w', [Pid]),
        State = State0
    ).


%% -------------------------------------------------------------------
%% Restart policy
%% -------------------------------------------------------------------

should_restart(permanent, _).
should_restart(transient, Reason) :- Reason \= true.
%% temporary: never restart.


%% -------------------------------------------------------------------
%% Restart intensity
%% -------------------------------------------------------------------

check_intensity(MaxR, MaxT, RL0, RL) :-
    get_time(Now),
    Cutoff is Now - MaxT,
    include(is_recent(Cutoff), RL0, Recent),
    length(Recent, N),
    (   N >= MaxR
    ->  debug(supervisor, '[sup] Intensity exceeded: ~w restarts in ~ws',
              [N, MaxT]),
        fail
    ;   RL = [Now | Recent]
    ).

% Decide exhaustion before starting any replacement, and clean up while the
% supervisor mailbox is still usable. Preserve the public shutdown reason.
intensity_exhausted(Children) :-
    supervisor_startup:cleanup_children(Children),
    (actor_terminating -> abort ; exit(shutdown)).

is_recent(Cutoff, T) :- T > Cutoff.


%% -------------------------------------------------------------------
%% Restart strategies
%% -------------------------------------------------------------------

% Each strategy owns its provisional replacements until the entire attempt
% commits. Intensity checking remains outside this scope.
restart_attempt(Strategy, Id, Spec, Children, MaxR, MaxT, RL, State) :-
    catch((with_startup_scope(
               apply_strategy(Strategy, Id, Spec, Children, MaxR, MaxT, RL, State))
           -> true ; throw(restart_failed(Id, start_failed))),
          Error, restart_attempt_failed(Id, Children, Error)).

restart_attempt_failed(_, _, Error) :-
    actors:guard_control_exception(Error), !, throw(Error).
restart_attempt_failed(_, _, _) :- actor_terminating, !, abort.
restart_attempt_failed(Id, Children, Error) :-
    supervisor_startup:cleanup_children(Children),
    (actor_terminating -> abort ; true),
    (Error = restart_failed(_, _) -> Reason=Error ; Reason=restart_failed(Id, Error)),
    exit(Reason).

start_replacement(Spec, Pid) :-
    Spec=spec(Id, Start, _, _, _),
    supervisor_startup:start_child(Spec, Start, Id, Pid),
    monitor(Pid, MonitorRef), remember_monitor(Pid, MonitorRef).

restart_child_record(Id, Spec, Pid) :-
    catch((start_replacement(Spec, Pid) -> true ; throw(start_failed)),
          Error, restart_child_error(Id, Error)).
restart_child_error(_, Error) :-
    actors:guard_control_exception(Error), !, throw(Error).
restart_child_error(Id, Error) :- throw(restart_failed(Id, Error)).

apply_strategy(one_for_one, Id, Spec, Children,
               MaxR, MaxT, RL, State) :-
    restart_child_record(Id, Spec, NewPid),
    replace_child(Id, ch(Id, NewPid, Spec), Children, Children1),
    debug(supervisor, '[sup] Restarted ~w  pid=~w (one_for_one)',
          [Id, NewPid]),
    State = sup(one_for_one, MaxR, MaxT, Children1, RL).

apply_strategy(one_for_all, _Id, _Spec, AllChildren,
               MaxR, MaxT, RL, State) :-
    debug(supervisor, '[sup] one_for_all: restarting all', []),
    supervisor_startup:stop_children(AllChildren),
    restart_all(AllChildren, [], Children1),
    State = sup(one_for_all, MaxR, MaxT, Children1, RL).

apply_strategy(rest_for_one, Id, _Spec, AllChildren,
               MaxR, MaxT, RL, State) :-
    split_at_child(Id, AllChildren, Before, CrashedAndAfter),
    debug(supervisor, '[sup] rest_for_one: restarting ~w and later', [Id]),
    supervisor_startup:stop_children(CrashedAndAfter),
    restart_all(CrashedAndAfter, [], Restarted),
    append(Before, Restarted, Children1),
    State = sup(rest_for_one, MaxR, MaxT, Children1, RL).


%% -------------------------------------------------------------------
%% Restarting a list of children
%% -------------------------------------------------------------------

restart_all([], Acc, Children) :-
    reverse(Acc, Children).
restart_all([ch(Id, _, Spec) | Rest], Acc, Children) :-
    restart_child_record(Id, Spec, NewPid),
    restart_all(Rest, [ch(Id, NewPid, Spec) | Acc], Children).


%% -------------------------------------------------------------------
%% Shutting down children
%% -------------------------------------------------------------------

%% shutdown_children/1 — reverse-order shutdown of all children
shutdown_children(Children) :-
    reverse(Children, Rev),
    maplist(shutdown_one, Rev).

%% shutdown_running/1 — shut down only those currently running
shutdown_running([]).
shutdown_running([ch(_, undefined, _) | Rest]) :- !,
    shutdown_running(Rest).
shutdown_running([ch(Id, Pid, Spec) | Rest]) :-
    spec(_, Start, _, Shutdown, _) = Spec,
    debug(supervisor, '[sup] Shutting down ~w (~w)', [Id, Pid]),
    do_shutdown(Pid, Shutdown, Start),
    shutdown_running(Rest).

shutdown_one(ch(_, undefined, _)) :- !.
shutdown_one(ch(Id, Pid, Spec)) :-
    spec(_, Start, _, Shutdown, _) = Spec,
    debug(supervisor, '[sup] Shutting down ~w (~w)', [Id, Pid]),
    do_shutdown(Pid, Shutdown, Start).


%% do_shutdown(+Pid, +ShutdownSpec, +Start)
%%
%% Termination is untrappable and the first committed exit reason
%% wins, so a later `exit(Pid, kill)` cannot override an `exit(Pid,
%% shutdown)` already in progress.  An orderly, time-bounded shutdown
%% is therefore a message-level stop request followed, after the
%% timeout, by the termination signal:
%%
%%   - brutal_kill: terminate at once with reason `kill`;
%%   - Timeout: ask a server child to stop ('$stop'/2), wait up to
%%     Timeout seconds for it to exit, then send `exit(Pid, shutdown)`;
%%   - infinity: ask a server child to stop and wait for it without
%%     limit.
%%
%% Children with no stop protocol (plain actors, nested supervisors)
%% receive `exit(Pid, shutdown)` directly; their cleanup handlers run
%% as they unwind.

do_shutdown(Pid, brutal_kill, _) :- !,
    exit(Pid, kill),
    wait_down(Pid).
do_shutdown(Pid, Shutdown, Start) :-
    (   request_stop(Pid, Start, Ref)
    ->  (   Shutdown == infinity
        ->  wait_down(Pid)
        ;   number(Shutdown),
            wait_down_timeout(Pid, Shutdown)
        ->  true
        ;   exit(Pid, shutdown),
            wait_down(Pid)
        ),
        flush_stop_reply(Ref)
    ;   exit(Pid, shutdown),
        wait_down(Pid)
    ).

request_stop(Pid, server(_, _), Ref) :-
    self(Self),
    make_ref(Ref),
    Pid ! '$stop'(Self, Ref).

flush_stop_reply(Ref) :-
    receive({ Ref-_ -> true }, [timeout(0)]).

wait_down(Pid) :-
    receive({ down(Pid, _, _) -> true }).

wait_down_timeout(Pid, Timeout) :-
    Got = got(false),
    receive({
        down(Pid, _, _) ->
            nb_setarg(1, Got, true)
    }, [timeout(Timeout)]),
    arg(1, Got, true).


%% -------------------------------------------------------------------
%% Handling synchronous calls
%% -------------------------------------------------------------------

handle_call(start_child(NormSpec), From, Ref, State0, State) :-
    spec(Id, _, _, _, _) = NormSpec,
    sup(_, _, _, Children, _) = State0,
    (   member(ch(Id, _, _), Children)
    ->  sup_reply(From, Ref, error(already_present)),
        State = State0
    ;   catch((with_startup_scope(do_start_child(NormSpec, State0, NewState))
               -> Result=ok ; Result=error(start_failed)),
              Error, startup_error_reply(Error, Result)),
        (Result == ok -> State=NewState ; State=State0),
        sup_reply(From, Ref, Result)
    ).

handle_call(terminate_child(Id), From, Ref, State0, State) :-
    sup(Str, MR, MT, Children, RL) = State0,
    (   member(ch(Id, Pid, Spec), Children), Pid \= undefined
    ->  spec(_, Start, _, Shutdown, _) = Spec,
        do_shutdown(Pid, Shutdown, Start),
        replace_child(Id, ch(Id, undefined, Spec), Children, Children1),
        sup_reply(From, Ref, ok),
        State = sup(Str, MR, MT, Children1, RL)
    ;   member(ch(Id, undefined, _), Children)
    ->  sup_reply(From, Ref, ok),
        State = State0
    ;   sup_reply(From, Ref, error(not_found)),
        State = State0
    ).

handle_call(delete_child(Id), From, Ref, State0, State) :-
    sup(Str, MR, MT, Children, RL) = State0,
    (   select(ch(Id, undefined, _), Children, Rest)
    ->  sup_reply(From, Ref, ok),
        State = sup(Str, MR, MT, Rest, RL)
    ;   member(ch(Id, Pid, _), Children), Pid \= undefined
    ->  sup_reply(From, Ref, error(running)),
        State = State0
    ;   sup_reply(From, Ref, error(not_found)),
        State = State0
    ).

handle_call(restart_child(Id), From, Ref, State0, State) :-
    sup(Str, MR, MT, Children, RL) = State0,
    (   member(ch(Id, undefined, Spec), Children)
    ->  catch((with_startup_scope(start_replacement(Spec, NewPid))
               -> Result=ok(NewPid) ; Result=error(start_failed)),
              Error, startup_error_reply(Error, Result)),
        (   Result=ok(Pid)
        ->  replace_child(Id, ch(Id, Pid, Spec), Children, Children1),
            State=sup(Str, MR, MT, Children1, RL)
        ;   State=State0
        ),
        sup_reply(From, Ref, Result)
    ;   member(ch(Id, Pid, _), Children), Pid \= undefined
    ->  sup_reply(From, Ref, error(running)),
        State = State0
    ;   sup_reply(From, Ref, error(not_found)),
        State = State0
    ).

handle_call(which_children, From, Ref, State, State) :-
    sup(_, _, _, Children, _) = State,
    maplist(ch_to_info, Children, Infos),
    sup_reply(From, Ref, Infos).

handle_call(count_children, From, Ref, State, State) :-
    sup(_, _, _, Children, _) = State,
    length(Children, NSpecs),
    include(ch_running, Children, Running),
    length(Running, NActive),
    include(ch_is_sup, Children, Sups),
    length(Sups, NSups),
    NWorkers is NActive - NSups,
    sup_reply(From, Ref, [
        specs-NSpecs, active-NActive,
        supervisors-NSups, workers-NWorkers
    ]).

handle_call(stop, From, Ref, State, State) :-
    sup_reply(From, Ref, ok),
    self(Self),
    Self ! '$sup_exit'.


startup_error_reply(Error, _) :-
    actors:guard_control_exception(Error), !, throw(Error).
startup_error_reply(Error, error(Error)).

ch_to_info(ch(Id, Pid, spec(_, _, Restart, _, Type)),
           info(Id, Pid, Type, Restart)).

ch_running(ch(_, Pid, _)) :- Pid \= undefined.

ch_is_sup(ch(_, _, spec(_, _, _, _, supervisor))).


%% -------------------------------------------------------------------
%% Utilities
%% -------------------------------------------------------------------

replace_child(_, _, [], []).
replace_child(Id, New, [ch(Id, _, _) | Rest], [New | Rest]) :- !.
replace_child(Id, New, [H | T], [H | T1]) :-
    replace_child(Id, New, T, T1).

split_at_child(Id, Children, Before, [Crashed | After]) :-
    split_at_(Id, Children, [], Before, Crashed, After).

split_at_(Id, [ch(Id, P, S) | Rest], Acc, Before, ch(Id, P, S), Rest) :- !,
    reverse(Acc, Before).
split_at_(Id, [H | T], Acc, Before, Crashed, After) :-
    split_at_(Id, T, [H | Acc], Before, Crashed, After).
