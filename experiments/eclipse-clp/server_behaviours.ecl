:- module(server_behaviours).
:- use_module(actors).
:- import exit/1 from actors.
:- import exit/2 from actors.
:- lib(prolog_extras).
:- lib(lists).

:- export supervisor_spawn/2, supervisor_spawn/3, supervisor_halt/1.
:- export server_spawn/3, server_spawn/4, server_halt/2.
:- export server_request/3, server_request/4, server_promise/3, server_promise/4.
:- export server_yield/2, server_yield/3, server_yield/4.
:- export server_upgrade/2, server_upgrade/3, server_run/3.
:- export supervisor_which_children/2, supervisor_count_children/2.
:- export supervisor_spawn_child/3, supervisor_terminate_child/3.
:- export supervisor_respawn_child/3, supervisor_delete_child/3.
:- tool(server_request/4, server_request_/5).
:- tool(server_yield/3, server_yield_/4).
:- tool(server_yield/4, server_yield_/5).
:- tool(server_spawn/3, server_spawn_/4).
:- tool(server_spawn/4, server_spawn_/5).
:- tool(server_upgrade/2, server_upgrade_/3).
:- tool(supervisor_spawn/2, supervisor_spawn_/3).
:- tool(supervisor_spawn/3, supervisor_spawn_/4).
:- tool(server_upgrade/3, server_upgrade_/4).

server_spawn_(Callback, State, Pid, Module) :-
    server_spawn_(Callback, State, Pid, [], Module).

server_spawn_(Callback, State, Pid, Options, Module) :-
    ( callable_callback(Callback) -> true
    ; throw(error(type_error(callable, Callback), server_spawn/4)) ),
    ( is_list(Options) -> true
    ; throw(error(type_error(list, Options), server_spawn/4)) ),
    ( select_named_option(Options, Name, SpawnOptions) ->
        ( atom(Name), Name \== undefined -> true
        ; throw(error(domain_error(server_name, Name), server_spawn/4)) ),
        Registration = name(Name)
    ; SpawnOptions = Options, Registration = none ),
    start_named_server(Registration, Callback, State, Pid, SpawnOptions, Module).

select_named_option([Option|Rest], Name, Rest) :-
    nonvar(Option), Option = name(Name), !.
select_named_option([Option|Rest], Name, [Option|Options]) :-
    select_named_option(Rest, Name, Options).

start_named_server(Registration, Callback, State, Pid, Options, Module) :-
    ( Registration == none -> NamedOptions = Options
    ; NamedOptions = [Registration|Options] ),
    spawn(server_behaviours:server_run(Callback, State, Module), Pid,
          [src_text("")|NamedOptions])@Module.

callable_callback(Callback) :-
    nonvar(Callback),
    ( atom(Callback) ; compound(Callback) ).

server_run(Callback, State, Fallback) :-
    self(Self),
    actor_module(Self, Private),
    ( callback_in_module(Callback, Private) -> Module = Private
    ; callback_in_module(Callback, Fallback) -> Module = Fallback
    ; throw(error(existence_error(server_callback, Callback), server_spawn/4)) ),
    server_loop(Callback, State, Module, Private).

callback_in_module(Callback, Module) :-
    functor(Callback, Name, Extra),
    Arity is Extra + 4,
    get_flag(Name/Arity, definition_module, Module)@Module.

server_loop(Callback, State, Module, Private) :-
    receive({
        '$server_call'(From, Ref, Request) ->
            ( call(Callback, Request, State, Reply, Next)@Module ->
                send(From, Ref-Reply),
                server_loop(Callback, Next, Module, Private)
            ; fail )
    ; '$server_upgrade'(From, Ref, New, Source) ->
        ( catch(prepare_upgrade(New, Source, Module, Private, NextModule), Error, true) ->
            ( var(Error) -> send(From, Ref-ok), server_loop(New, State, NextModule, Private)
            ; send(From, Ref-error(Error)), server_loop(Callback, State, Module, Private) )
        ; send(From, Ref-error(server_upgrade_failed(New))),
          server_loop(Callback, State, Module, Private) )
    ; '$server_stop'(From, Ref) ->
        send(From, Ref-true)
    }).

prepare_upgrade(New, "", Module, Private, NextModule) :- !,
    ( callback_in_module(New, Private) -> NextModule = Private
    ; callback_in_module(New, Module), NextModule = Module ).
prepare_upgrade(New, Source, _, Private, Private) :-
    load_actor_source(Source, Private),
    callback_in_module(New, Private).

server_request(To, Request, Response) :-
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_call'(From, Ref, Request), Response).

server_request_(To, Request, Response, Options, Module) :-
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_call'(From, Ref, Request), Response, Options, Module).

server_promise(To, Request, Ref) :-
    fresh_reference(Ref),
    self(From),
    send(To, '$server_call'(From, Ref, Request)).

server_promise(To, Request, Ref, Monitor) :-
    fresh_reference(Ref),
    self(From),
    start_server_exchange(To, '$server_call'(From, Ref, Request), Monitor).

server_yield(Ref, Response) :-
    ( ground(Ref) -> true ; throw(error(instantiation_error, server_yield/2)) ),
    receive({Ref-Reply -> Response = Reply},
            [timeout(2), on_timeout(throw(server_reply_timeout(Ref)))]).

server_yield_(Ref, Response, Options, Module) :-
    ( ground(Ref) -> true ; throw(error(instantiation_error, server_yield/3)) ),
    receive({Ref-Reply -> Response = Reply}, Options)@Module.

server_yield_(Ref, Monitor, Response, Options, Module) :-
    setup_call_cleanup(
        true,
        wait_server_reply(Ref, Monitor, Response, Options, Module),
        demonitor(Monitor, [flush])
    ).

wait_server_reply(Ref, Monitor, Response, Options, Module) :-
    receive({
        Ref-Reply -> Response = Reply
    ; down(_, Monitor, Reason) -> throw(server_down(Reason))
    }, Options)@Module.

server_halt(To, Reply) :-
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_stop'(From, Ref), Reply).

server_upgrade_(To, Callback, Module) :-
    server_upgrade_(To, Callback, [], Module).

server_upgrade_(To, Callback, Options, Module) :-
    ( callable_callback(Callback) -> true
    ; throw(error(type_error(callable, Callback), server_upgrade/3)) ),
    require_source_options(Options, server_upgrade/3),
    source_options_text(Options, Module, Source),
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_upgrade'(From, Ref, Callback, Source), Reply),
    ( Reply == ok -> true ; Reply = error(Error), throw(Error) ).

server_exchange(To, Ref, Message, Response) :-
    server_exchange(To, Ref, Message, Response,
                    [timeout(2), on_timeout(throw(server_reply_timeout(Ref)))]).

server_exchange(To, Ref, Message, Response, Options) :-
    server_exchange(To, Ref, Message, Response, Options, server_behaviours).

server_exchange(To, Ref, Message, Response, Options, Module) :-
    server_target(To, Pid),
    setup_call_cleanup(
        monitor(Pid, Monitor),
        ( send(Pid, Message),
          wait_server_reply(Ref, Monitor, Response, Options, Module) ),
        demonitor(Monitor, [flush])
    ).

start_server_exchange(To, Message, Monitor) :-
    server_target(To, Pid),
    monitor(Pid, Monitor),
    ( catch(send(Pid, Message), Error, (demonitor(Monitor, [flush]), throw(Error))) -> true
    ; demonitor(Monitor, [flush]), fail ).

server_target(To, Pid) :-
    % Resolve a name once so the monitor and send refer to the same server,
    % even if the supervisor publishes a replacement in the meantime.
    ( atom(To) ->
        whereis(To, Pid),
        ( Pid \== undefined -> true ; throw(error(existence_error(actor_name, To), server_request/3)) )
    ; Pid = To ).

require_source_options(Options, Caller) :-
    ( is_list(Options), checklist(source_option, Options) -> true
    ; throw(error(domain_error(server_source_options, Options), Caller)) ).

supervisor_spawn_(Specs, Sup, Module) :-
    supervisor_spawn_(Specs, Sup, [], Module).

supervisor_spawn_(Specs, Sup, Options, Module) :-
    supervisor_config(Options, Config, SourceOptions, Startup, Monitor),
    normalise_children(Specs, Children),
    source_options_text(SourceOptions, Module, Source),
    launch_supervisor(Children, Config, Source, Startup, Sup),
    ( Monitor == true -> true ; demonitor(Sup, [flush]) ).

supervisor_config(Options, config(Strategy, Intensity, Period), Sources, Startup, Monitor) :-
    ( is_list(Options), checklist(supervisor_option, Options) -> true
    ; throw(error(domain_error(supervisor_options, Options), supervisor_spawn/3)) ),
    behaviour_option(strategy, Options, one_for_one, Strategy),
    behaviour_option(intensity, Options, 1, Intensity),
    behaviour_option(period, Options, 5, Period),
    findall(Option, (member(Option, Options), supervisor_start_option(Option)), Startup),
    behaviour_option(monitor, Options, false, Monitor),
    findall(Option, (member(Option, Options), source_option(Option)), Sources).

supervisor_option(Option) :-
    nonvar(Option),
    ( Option = strategy(S), nonvar(S), memberchk(S, [one_for_one, one_for_all, rest_for_one])
    ; Option = intensity(N), integer(N), N >= 0
    ; Option = period(T), number(T), T > 0
    ; supervisor_start_option(Option)
    ; Option = monitor(B), boolean(B)
    ; source_option(Option)
    ).

supervisor_start_option(link(B)) :- boolean(B).
supervisor_start_option(name(Name)) :- atom(Name), Name \== undefined.
supervisor_start_option('$state_owned').
supervisor_start_option(io_target(Target)) :- ground(Target).

boolean(B) :- B == true ; B == false.

behaviour_option(Name, Options, Default, Value) :-
    functor(Option, Name, 1),
    ( memberchk(Option, Options) -> arg(1, Option, Value) ; Value = Default ).

normalise_children(Specs, Children) :-
    ( is_list(Specs) -> maplist(normalise_child, Specs, Children)
    ; throw(error(type_error(list, Specs), supervisor_spawn/3)) ),
    ( foreach(spec(Name, _, _, _, _), Children), fromto([], Seen, [Name|Seen], _) do
        ( memberchk(Name, Seen) -> throw(error(duplicate_child(Name), supervisor_spawn/3))
        ; true )
    ).

normalise_child(Raw, spec(Name, Start, Restart, Type, Shutdown)) :-
    ( nonvar(Raw), Raw = child(Name, Options) -> true
    ; throw(error(domain_error(supervisor_child_spec, Raw), supervisor_spawn/3)) ),
    require_child_name(Name, supervisor_spawn/3),
    ( is_list(Options), checklist(child_option, Options),
      memberchk(start(Start), Options) -> true
    ; throw(error(domain_error(supervisor_child_spec, Raw), supervisor_spawn/3)) ),
    behaviour_option(restart, Options, permanent, Restart),
    behaviour_option(type, Options, worker, Type),
    ( Type == supervisor -> Default = infinity ; Default = 5 ),
    behaviour_option(shutdown, Options, Default, Shutdown).

require_child_name(Name, Caller) :-
    ( var(Name) -> throw(error(instantiation_error, Caller))
    ; atom(Name) -> true
    ; throw(error(type_error(atom, Name), Caller)) ).

child_option(Option) :-
    nonvar(Option),
    ( Option = start(Goal), callable_callback(Goal)
    ; Option = restart(R), nonvar(R), memberchk(R, [permanent, transient, temporary])
    ; Option = type(T), nonvar(T), memberchk(T, [worker, supervisor])
    ; Option = shutdown(S), ( S == infinity ; S == brutal_kill ; number(S), S >= 0 )
    ).

launch_supervisor(Children, Config, Source, Startup, Sup) :-
    self(Parent),
    fresh_reference(Ref),
    spawn(supervisor_init(Parent, Ref, Children, Config, Source), Sup,
          [monitor(true)|Startup]),
    catch(receive({
              Ref-ready -> true
          ; down(Sup, Sup, Reason) -> throw(error(supervisor_start_failed(Sup, Reason), supervisor_spawn/3))
          }, [timeout(2), on_timeout(throw(supervisor_start_timeout))]),
          Error, (exit(Sup, kill), demonitor(Sup, [flush]), throw(Error))).

supervisor_init(Parent, Ref, Specs, Config, Source) :-
    catch(start_children(Specs, Source, Children), start_failed(_, Error), exit(Error)),
    send(Parent, Ref-ready),
    supervisor_loop(Children, Config, Source, []).

start_children([], _, []).
start_children([Spec|Specs], Source, [child(Spec, Pid)|Children]) :-
    Spec = spec(Name, _, _, _, _),
    catch(start_child(Spec, Source, Pid), Error, throw(start_failed(Name, Error))),
    catch(start_children(Specs, Source, Children), Error,
          (stop_child(Spec, Pid), throw(Error))).

start_child(spec(Name, Start, _, _, _), Source, Pid) :-
    ( Start = server(Callback, Options) ->
        ( is_list(Options), checklist(server_child_option, Options) -> true
        ; throw(error(domain_error(supervisor_server_options, Options), supervisor_spawn/3)) ),
        behaviour_option(initial_state, Options, [], State),
        findall(Option, (member(Option, Options), source_option(Option)), Sources),
        start_named_server(name(Name), Callback, State, Pid,
                           [src_text(Source), monitor(true)|Sources], server_behaviours)
    ; Start = start_sub_supervisor(Specs, Options) ->
        normalise_children(Specs, Children),
        supervisor_config(Options, Config, _, _, _),
        launch_supervisor(Children, Config, Source, [], Pid)
    ; spawn(Start, Pid, [src_text(Source), monitor(true)]) ).

server_child_option(Option) :-
    nonvar(Option),
    ( Option = initial_state(_) ; source_option(Option) ).

supervisor_halt(Sup) :-
    server_target(Sup, Pid),
    monitor(Pid, Ref),
    send(Pid, '$supervisor_halt'),
    catch(receive({down(Pid, Ref, _) -> true},
                  [timeout(10), on_timeout(throw(supervisor_halt_timeout))]),
          Error, (demonitor(Ref, [flush]), throw(Error))).

supervisor_which_children(Sup, Infos) :- supervisor_request(Sup, which, Infos).
supervisor_count_children(Sup, Counts) :- supervisor_request(Sup, count, Counts).
supervisor_spawn_child(Sup, Spec, Reply) :- supervisor_request(Sup, start(Spec), Reply).
supervisor_terminate_child(Sup, Name, Reply) :-
    require_child_name(Name, supervisor_terminate_child/3),
    supervisor_request(Sup, terminate(Name), Reply).
supervisor_respawn_child(Sup, Name, Reply) :-
    require_child_name(Name, supervisor_respawn_child/3),
    supervisor_request(Sup, respawn(Name), Reply).
supervisor_delete_child(Sup, Name, Reply) :-
    require_child_name(Name, supervisor_delete_child/3),
    supervisor_request(Sup, delete(Name), Reply).

supervisor_request(Sup, Request, Reply) :-
    self(From),
    fresh_reference(Ref),
    server_exchange(Sup, Ref, '$supervisor_call'(From, Ref, Request), Reply,
                    [timeout(10), on_timeout(throw(supervisor_call_timeout(Sup, Request)))]).

supervisor_loop(Children, Config, Source, Restarts) :-
    receive({
        '$supervisor_halt' -> stop_children(Children)
    ; '$supervisor_call'(From, Ref, Request) ->
        supervisor_call(Request, Children, Source, Next, Reply),
        send(From, Ref-Reply),
        supervisor_loop(Next, Config, Source, Restarts)
    ; down(Pid, Pid, Reason) if known_child(Pid, Children) ->
        child_down(Pid, Reason, Children, Config, Source, Restarts)
    }).

known_child(Pid, Children) :-
    ground(Pid), Pid \== undefined,
    memberchk(child(_, Pid), Children).

supervisor_call(which, Children, _, Children, Infos) :- !,
    ( foreach(child(spec(Name, _, Restart, Type, _), Pid), Children),
      foreach(info(Name, Pid, Type, Restart), Infos) do true ).
supervisor_call(count, Children, _, Children,
                [specs-Specs,active-Active,supervisors-Supervisors,workers-Workers]) :- !,
    length(Children, Specs),
    findall(Type, (member(child(spec(_, _, _, Type, _), Pid), Children), Pid \== undefined), Types),
    length(Types, Active),
    findall(1, member(supervisor, Types), Sups),
    length(Sups, Supervisors),
    Workers is Active - Supervisors.
supervisor_call(start(Raw), Children, Source, Next, Reply) :- !,
    catch((normalise_child(Raw, Spec), Spec = spec(Name, _, _, _, _),
           ( select_child(Name, Children, _, _, _) ->
               Reply = error(already_present), Next = Children
           ; start_child(Spec, Source, Pid),
             append(Children, [child(Spec, Pid)], Next), Reply = ok )),
          Error, (Reply = error(Error), Next = Children)).
supervisor_call(Request, Children, Source, Next, Reply) :-
    Request =.. [Action, Name],
    ( select_child(Name, Children, Before, Child, After) ->
        edit_child(Action, Child, Source, Replacement, Reply),
        append(Replacement, After, Tail),
        append(Before, Tail, Next)
    ; Next = Children, Reply = error(not_found) ).

select_child(Name, [Child|After], [], Child, After) :-
    Child = child(spec(Id, _, _, _, _), _),
    Id == Name, !.
select_child(Name, [Child|Rest], [Child|Before], Found, After) :-
    select_child(Name, Rest, Before, Found, After).

edit_child(terminate, child(Spec, Pid), _, [child(Spec, undefined)], ok) :-
    stop_child(Spec, Pid).
edit_child(delete, Child, _, Replacement, Reply) :-
    ( Child = child(_, undefined) -> Replacement = [], Reply = ok
    ; Replacement = [Child], Reply = error(running) ).
edit_child(respawn, Child, Source, Replacement, Reply) :-
    ( Child = child(Spec, undefined) ->
        catch((start_child(Spec, Source, Pid), Replacement = [child(Spec, Pid)], Reply = ok(Pid)),
              Error, (Replacement = [Child], Reply = error(Error)))
    ; Replacement = [Child], Reply = error(running) ).

child_down(Pid, Reason, Children, Config, Source, Restarts) :-
    append(Before, [child(Spec, Pid)|After], Children), !,
    Spec = spec(_, _, Policy, _, _),
    ( Policy == temporary ->
        append(Before, After, Next),
        supervisor_loop(Next, Config, Source, Restarts)
    ; Policy == transient, Reason == true ->
        append(Before, [child(Spec, undefined)|After], Next),
        supervisor_loop(Next, Config, Source, Restarts)
    ; append(Before, [child(Spec, undefined)|After], Stopped),
      restart_children(Config, Spec, Before, After, Stopped, Source, Restarts) ).

restart_children(Config, Spec, Before, After, Stopped, Source, Restarts) :-
    Config = config(Strategy, Intensity, Period),
    elapsed(Now),
    findall(Time, (member(Time, Restarts), Now - Time < Period), Recent),
    length(Recent, Count),
    ( Count >= Intensity ->
        stop_children(Stopped), exit(shutdown)
    ; restart_group(Strategy, Before, Spec, After, KeepBefore, Group, KeepAfter),
      stop_children(Group),
      ( foreach(child(ChildSpec, _), Group), foreach(ChildSpec, Specs) do true ),
      catch(start_children(Specs, Source, Replacements), start_failed(Name, Error),
            (stop_children(KeepBefore), stop_children(KeepAfter),
             exit(restart_failed(Name, Error)))),
      append(Replacements, KeepAfter, Tail),
      append(KeepBefore, Tail, Next),
      supervisor_loop(Next, Config, Source, [Now|Recent]) ).

restart_group(one_for_one, Before, Spec, After, Before, [child(Spec, undefined)], After).
restart_group(one_for_all, Before, Spec, After, [], Group, []) :-
    append(Before, [child(Spec, undefined)|After], Group).
restart_group(rest_for_one, Before, Spec, After, Before, [child(Spec, undefined)|After], []).

stop_children(Children) :-
    reverse(Children, Reversed),
    ( foreach(child(Spec, Pid), Reversed) do stop_child(Spec, Pid) ).

stop_child(_, undefined) :- !.
stop_child(spec(_, Start, _, _, Shutdown), Pid) :-
    ( Shutdown == brutal_kill -> exit(Pid, kill), await_child(Pid, [])
    ; Start = server(_, _) ->
        self(From), fresh_reference(Ref),
        send(Pid, '$server_stop'(From, Ref)),
        ( Shutdown == infinity -> await_child(Pid, [])
        ; await_child(Pid, [timeout(Shutdown), on_timeout(fail)]) -> true
        ; exit(Pid, shutdown), await_child(Pid, []) ),
        receive({Ref-_ -> true}, [timeout(0)])
    ; exit(Pid, shutdown), await_child(Pid, []) ).

await_child(Pid, Options) :-
    receive({down(Pid, Pid, _) -> true}, Options).
