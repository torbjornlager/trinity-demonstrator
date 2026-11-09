:- module(server_behaviours).
:- use_module(actors).
:- import exit/1 from actors.
:- import exit/2 from actors.
:- lib(prolog_extras).

:- export supervisor_spawn/3, supervisor_halt/1.
:- export server_request/3, server_promise/3, server_yield/2, server_upgrade/3.
:- export supervise_server/4, server_loop/2.
:- tool(supervisor_spawn/3, supervisor_spawn_/4).
:- tool(server_upgrade/3, server_upgrade_/4).

% Local single-child supervisor for a permanent server. A linked child
% inherits the owner's lifetime. Each restart begins with the initial state.
supervisor_spawn_(Specs, Sup, Options, Module) :-
    ( ground(Specs),
      Specs = [child(Name, [start(server(Callback, [initial_state(State)])), restart(permanent)])],
      atom(Name), atom(Callback) -> true
    ; throw(error(domain_error(local_server_supervisor, Specs), supervisor_spawn/3)) ),
    require_source_options(Options, supervisor_spawn/3),
    source_options_text(Options, Module, Source),
    self(Parent),
    fresh_reference(Ref),
    spawn(supervise_server(Parent, Ref, Name, server(Callback, State, Source)),
          Sup, [monitor(true)]),
    setup_call_cleanup(true,
        receive({
            Ref-ready -> true
        ; down(Sup, Sup, Reason) -> throw(supervisor_start_failed(Sup, Reason))
        }, [timeout(2), on_timeout((exit(Sup, kill), throw(supervisor_start_timeout)))]),
        demonitor(Sup, [flush])).

supervise_server(Parent, Ref, Name, Spec) :-
    start_server(Name, Spec, Child),
    send(Parent, Ref-ready),
    supervise_child(Name, Spec, Child, none).

start_server(Name, server(Callback, State, Source), Child) :-
    spawn(server_behaviours:server_loop(Callback, State), Child,
          [src_text(Source), monitor(true)]),
    catch(register(Name, Child), Error, (exit(Child, kill), throw(Error))).

supervise_child(Name, Spec, Child, LastRestart) :-
    receive({
        down(Child, Child, _) ->
            elapsed(Now),
            % SWI's default intensity allows one restart in five seconds.
            ( ( LastRestart == none ; Now - LastRestart >= 5 ) ->
                start_server(Name, Spec, Replacement),
                supervise_child(Name, Spec, Replacement, Now)
            ; exit(shutdown) )
    ; '$supervisor_halt' ->
        exit(Child, shutdown),
        receive({down(Child, Child, _) -> true})
    }).

supervisor_halt(Sup) :-
    setup_call_cleanup(monitor(Sup, Monitor),
        ( send(Sup, '$supervisor_halt'),
          receive({down(Sup, Monitor, _) -> true},
                  [timeout(2), on_timeout(throw(supervisor_halt_timeout))]) ),
        demonitor(Monitor, [flush])).

server_loop(Callback, State) :-
    self(Self),
    actor_module(Self, Module),
    receive({
        '$server_call'(From, Ref, Request) ->
            ( call(Callback, Request, State, Reply, Next)@Module ->
                send(From, Ref-Reply),
                server_loop(Callback, Next)
            ; fail )
    ; '$server_upgrade'(From, Ref, New, Source) ->
        ( catch(prepare_upgrade(New, Source, Module), Error, true) ->
            ( var(Error) -> send(From, Ref-ok), server_loop(New, State)
            ; send(From, Ref-error(Error)), server_loop(Callback, State) )
        ; send(From, Ref-error(server_upgrade_failed(New))),
          server_loop(Callback, State) )
    }).

prepare_upgrade(New, Source, Module) :-
    load_actor_source(Source, Module),
    get_flag(New/4, definition_module, Module)@Module.

server_request(To, Request, Response) :-
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_call'(From, Ref, Request), Response).

server_promise(To, Request, Ref) :-
    fresh_reference(Ref),
    self(From),
    send(To, '$server_call'(From, Ref, Request)).

server_yield(Ref, Response) :-
    ( ground(Ref) -> true ; throw(error(instantiation_error, server_yield/2)) ),
    receive({Ref-Reply -> Response = Reply},
            [timeout(2), on_timeout(throw(server_reply_timeout(Ref)))]).

server_upgrade_(To, Callback, Options, Module) :-
    ( atom(Callback) -> true ; throw(error(type_error(atom, Callback), server_upgrade/3)) ),
    require_source_options(Options, server_upgrade/3),
    source_options_text(Options, Module, Source),
    fresh_reference(Ref),
    self(From),
    server_exchange(To, Ref, '$server_upgrade'(From, Ref, Callback, Source), Reply),
    ( Reply == ok -> true ; Reply = error(Error), throw(Error) ).

server_exchange(To, Ref, Message, Response) :-
    % Resolve a name once so the monitor and send refer to the same server,
    % even if the supervisor publishes a replacement in the meantime.
    ( atom(To) ->
        whereis(To, Pid),
        ( Pid \== undefined -> true ; throw(error(existence_error(actor_name, To), server_request/3)) )
    ; Pid = To ),
    setup_call_cleanup(monitor(Pid, Monitor),
        ( send(Pid, Message),
          receive({
              Ref-Reply -> Response = Reply
          ; down(Pid, Monitor, Reason) -> throw(server_down(Reason))
          }, [timeout(2), on_timeout(throw(server_reply_timeout(Ref)))]) ),
        demonitor(Monitor, [flush])).

require_source_options(Options, Caller) :-
    ( is_list(Options), checklist(source_option, Options) -> true
    ; throw(error(domain_error(server_source_options, Options), Caller)) ).
