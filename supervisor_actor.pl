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

%% ===================================================================
%% supervisor_actor.pl — Supervisor behaviour for actor.pl
%% ===================================================================
%%
%% Consulted into user space.  Requires actor.pl and server.pl.
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

:- use_module(actor).
:- use_module(server_actor).

:- meta_predicate
       supervisor_spawn(:, -),
       supervisor_spawn(:, -, +),
       supervisor_spawn_child(+, :, -),
       start_sub_supervisor(:, +).



%% -------------------------------------------------------------------
%% Child specification normalisation
%% -------------------------------------------------------------------

normalise_child_spec(Caller, child(Id, Opts),
                     spec(Id, Start, Restart, Shutdown, Type)) :-
    (   option(start(Start0), Opts)
    ->  qualify_start_term(Caller, Start0, Start)
    ;   throw(error(missing_start_option(Id), supervisor))
    ),
    option(restart(Restart), Opts, permanent),
    option(type(Type), Opts, worker),
    default_shutdown(Type, DefShutdown),
    option(shutdown(Shutdown), Opts, DefShutdown).

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
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxR), Options, 1),
    option(period(MaxT), Options, 5),
    maplist(normalise_child_spec(Caller), ChildSpecs, Specs),
    exclude(is_sup_option, Options, SpawnOpts),
    State0 = sup(Strategy, MaxR, MaxT, [], []),
    spawn(sup_init(Specs, State0), Pid, SpawnOpts),
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).

is_sup_option(strategy(_)).
is_sup_option(intensity(_)).
is_sup_option(period(_)).
is_sup_option(name(_)).


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
    strip_module(ChildSpecs0, Caller, ChildSpecs),
    option(strategy(Strategy), Options, one_for_one),
    option(intensity(MaxR), Options, 1),
    option(period(MaxT), Options, 5),
    maplist(normalise_child_spec(Caller), ChildSpecs, Specs),
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
    sup_call(Sup, stop, _).

supervisor_stop(Sup) :-
    supervisor_halt(Sup).


%% -------------------------------------------------------------------
%% Synchronous call infrastructure
%% -------------------------------------------------------------------

sup_call(Sup, Request, Reply) :-
    self(Self),
    make_id(Ref),
    monitor(Sup, MonRef),
    Sup ! '$sup'(Self, Ref, Request),
    Replied = replied(false),
    receive({
        Ref-Reply0 ->
            demonitor(MonRef),
            nb_setarg(1, Replied, true),
            Reply = Reply0
        ;
        down(MonRef, _, Reason) ->
            nb_setarg(1, Replied, true),
            throw(supervisor_down(Reason))
    }, [timeout(10)]),
    (   arg(1, Replied, true)
    ->  true
    ;   demonitor(MonRef),
        throw(supervisor_call_timeout(Sup, Request))
    ).

sup_reply(From, Ref, Reply) :-
    From ! Ref-Reply.


%% -------------------------------------------------------------------
%% Initialisation
%% -------------------------------------------------------------------

sup_init(Specs, State0) :-
    (   start_children(Specs, State0, State)
    ->  sup_loop(State)
    ;   exit(init_failed)
    ).

start_children([], State, State).
start_children([Spec | Rest], State0, State) :-
    (   do_start_child(Spec, State0, State1)
    ->  start_children(Rest, State1, State)
    ;   sup(_, _, _, Children, _) = State0,
        shutdown_children(Children),
        fail
    ).


%% -------------------------------------------------------------------
%% Starting a single child
%% -------------------------------------------------------------------

do_start_child(spec(Id, Start, Restart, Shutdown, Type),
               sup(Str, MR, MT, Children, RL),
               sup(Str, MR, MT, Children1, RL)) :-
    \+ member(ch(Id, _, _), Children),
    Spec = spec(Id, Start, Restart, Shutdown, Type),
    do_spawn_child(Start, Id, Pid),
    monitor(Pid, _),
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
    server_spawn(Pred, State, Pid, [name(Name), link(true) | ExtraOpts]).
do_spawn_child(Goal, _Name, Pid) :-
    spawn(Goal, Pid, [link(true)]).

is_server_actor_opt(initial_state(_)).


%% -------------------------------------------------------------------
%% The supervisor loop
%% -------------------------------------------------------------------

sup_loop(State) :-
    receive({
        down(_, Pid, Reason) ->
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
        ->  check_intensity(MaxR, MaxT, RL, RL1),
            %% Mark the crashed child as dead so that
            %% shutdown_running (used by one_for_all and
            %% rest_for_one) will skip it — its down message
            %% has already been consumed.
            replace_child(Id, ch(Id, undefined, Spec),
                          Children, MarkedChildren),
            apply_strategy(Strategy, Id, Spec, MarkedChildren,
                           MaxR, MaxT, RL1, State)
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
        exit(shutdown)
    ;   RL = [Now | Recent]
    ).

is_recent(Cutoff, T) :- T > Cutoff.


%% -------------------------------------------------------------------
%% Restart strategies
%% -------------------------------------------------------------------

apply_strategy(one_for_one, Id, Spec, Children,
               MaxR, MaxT, RL, State) :-
    spec(_, Start, _, _, _) = Spec,
    do_spawn_child(Start, Id, NewPid),
    monitor(NewPid, _),
    replace_child(Id, ch(Id, NewPid, Spec), Children, Children1),
    debug(supervisor, '[sup] Restarted ~w  pid=~w (one_for_one)',
          [Id, NewPid]),
    State = sup(one_for_one, MaxR, MaxT, Children1, RL).

apply_strategy(one_for_all, _Id, _Spec, AllChildren,
               MaxR, MaxT, RL, State) :-
    debug(supervisor, '[sup] one_for_all: restarting all', []),
    shutdown_running(AllChildren),
    restart_all(AllChildren, [], Children1),
    State = sup(one_for_all, MaxR, MaxT, Children1, RL).

apply_strategy(rest_for_one, Id, _Spec, AllChildren,
               MaxR, MaxT, RL, State) :-
    split_at_child(Id, AllChildren, Before, CrashedAndAfter),
    debug(supervisor, '[sup] rest_for_one: restarting ~w and later', [Id]),
    shutdown_running(CrashedAndAfter),
    restart_all(CrashedAndAfter, [], Restarted),
    append(Before, Restarted, Children1),
    State = sup(rest_for_one, MaxR, MaxT, Children1, RL).


%% -------------------------------------------------------------------
%% Restarting a list of children
%% -------------------------------------------------------------------

restart_all([], Acc, Children) :-
    reverse(Acc, Children).
restart_all([ch(Id, _, Spec) | Rest], Acc, Children) :-
    spec(_, Start, _, _, _) = Spec,
    do_spawn_child(Start, Id, NewPid),
    monitor(NewPid, _),
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
    spec(_, _, _, Shutdown, _) = Spec,
    debug(supervisor, '[sup] Shutting down ~w (~w)', [Id, Pid]),
    do_shutdown(Pid, Shutdown),
    shutdown_running(Rest).

shutdown_one(ch(_, undefined, _)) :- !.
shutdown_one(ch(Id, Pid, Spec)) :-
    spec(_, _, _, Shutdown, _) = Spec,
    debug(supervisor, '[sup] Shutting down ~w (~w)', [Id, Pid]),
    do_shutdown(Pid, Shutdown).


%% do_shutdown(+Pid, +ShutdownSpec)
%%
%% Shutdown uses `exit(Pid, shutdown)` as the termination signal,
%% matching Erlang/OTP semantics.  The signal is delivered as a
%% thread interrupt that raises `exit(shutdown)`.
%%
%% Behaviour actors (server_actor, statechart_actor) catch this
%% signal and run their cleanup logic before exiting.  Plain actors
%% are terminated immediately.
%%
%% For the timed variant the supervisor waits up to Timeout seconds
%% for the child to exit, then escalates to `exit(Pid, kill)`.

do_shutdown(Pid, brutal_kill) :- !,
    exit(Pid, kill),
    wait_down(Pid).

do_shutdown(Pid, infinity) :- !,
    exit(Pid, shutdown),
    wait_down(Pid).

do_shutdown(Pid, Timeout) :-
    number(Timeout),
    exit(Pid, shutdown),
    (   wait_down_timeout(Pid, Timeout)
    ->  true
    ;   exit(Pid, kill),
        wait_down(Pid)
    ).

wait_down(Pid) :-
    receive({ down(_, Pid, _) -> true }).

wait_down_timeout(Pid, Timeout) :-
    Got = got(false),
    receive({
        down(_, Pid, _) ->
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
    ;   (   do_start_child(NormSpec, State0, State)
        ->  sup_reply(From, Ref, ok)
        ;   sup_reply(From, Ref, error(start_failed)),
            State = State0
        )
    ).

handle_call(terminate_child(Id), From, Ref, State0, State) :-
    sup(Str, MR, MT, Children, RL) = State0,
    (   member(ch(Id, Pid, Spec), Children), Pid \= undefined
    ->  spec(_, _, _, Shutdown, _) = Spec,
        do_shutdown(Pid, Shutdown),
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
    ->  spec(_, Start, _, _, _) = Spec,
        (   do_spawn_child(Start, Id, NewPid)
        ->  monitor(NewPid, _),
            replace_child(Id, ch(Id, NewPid, Spec), Children, Children1),
            sup_reply(From, Ref, ok(NewPid)),
            State = sup(Str, MR, MT, Children1, RL)
        ;   sup_reply(From, Ref, error(start_failed)),
            State = State0
        )
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
