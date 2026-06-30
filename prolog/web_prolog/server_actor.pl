:- module(server_actor, [

       server_spawn/3,
       server_spawn/4,
       server_request/3,
       server_request/4,
       server_promise/3,
       server_promise/4,
       server_yield/2,
       server_yield/3,
       server_yield/4,
       server_upgrade/2,
       server_upgrade/3,
       server_halt/2,
       server_stop/2

   ]).

/** <module> Generic Server Behaviour

Implements the server behaviour described in the Web Prolog book: a
stateful server actor with a stable message protocol, synchronous
request-response communication, hot code swapping, and fail-fast
monitoring support.

The callback predicate `Pred` must be arity 4:

  `Pred(Request, OldState, Response, NewState)`.

Message protocol (internal):

  - `'$call'(From, Ref, Request)`  - client request
  - `'$upgrade'(From, Ref, Pred1, Source)` - acknowledged hot code swap
  - `'$stop'(From)`                - graceful shutdown
  - `Ref-Response`                 - server reply (to client)
  - `reply(true)`                  - stop acknowledgement (to client)
*/

:- use_module(library(option)).
:- use_module(actors).
:- use_module(isolation, [
    actor_module/2,
    load_options_text/3
]).

:- meta_predicate
       server_spawn(:, +, -),
       server_spawn(:, +, -, +),
       server_upgrade(+, :),
       server_upgrade(+, :, +).


%!  server_spawn(+Pred, +State, -Pid) is det.
%!  server_spawn(+Pred, +State, -Pid, +Options) is det.
%
%   Spawn a server actor running server_loop/2 with the given callback
%   predicate and initial state. Options are forwarded to spawn/3.

server_spawn(Pred, State, Pid) :-
    server_spawn(Pred, State, Pid, []).

server_spawn(Pred0, State, Pid, Options) :-
    normalize_server_callback(Pred0, Pred),
    strip_module(Pred, SourceModule, _),
    exclude(is_server_spawn_opt, Options, SpawnOpts0),
    ensure_source_module(SourceModule, SpawnOpts0, SpawnOpts),
    spawn(server_loop(Pred, State), Pid, SpawnOpts),
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).

is_server_spawn_opt(name(_)).

ensure_source_module(_, Options, Options) :-
    option(source_module(_), Options),
    !.
ensure_source_module(Module, Options, [source_module(Module)|Options]).

normalize_server_callback(Pred0, Pred) :-
    strip_module(Pred0, Module0, PlainPred),
    callback_definition_module(Module0, PlainPred, Module),
    Pred = Module:PlainPred.

callback_definition_module(Module0, PlainPred, Module) :-
    callback_head(PlainPred, Head),
    predicate_property(Module0:Head, imported_from(Module1)),
    !,
    Module = Module1.
callback_definition_module(Module, _, Module).

callback_head(PlainPred, Head) :-
    callable(PlainPred),
    functor(PlainPred, Name, ExtraArity),
    Arity is ExtraArity + 4,
    functor(Head, Name, Arity).


%!  server_loop(+Pred, +State) is det.
%
%   Generic server receive loop. Handles three message forms:
%
%     - '$call'(From, Ref, Request): invoke Pred/4, reply, recur.
%     - '$upgrade'(From,Ref,Pred1,Source): load and replace callback, recur.
%     - '$stop'(From):               acknowledge and exit.

server_loop(Pred, State0) :-
    receive({
        '$call'(From, Ref, Request) ->
            (   call(Pred, Request, State0, Response, State)
            ->  From ! Ref-Response,
                server_loop(Pred, State)
            ;   % A callback with no matching clause is a server crash,
                % not a quiet receive-loop failure.  exit/1 records the
                % reason before aborting, so monitors receive down/3.
                exit(false)
            ) ;
        '$upgrade'(From, Ref, Pred1, Source) ->
            catch((   prepare_server_upgrade(Ref, Pred1, Source, NewPred)
                  ->  true
                  ;   throw(error(server_upgrade_failed(Pred1),
                                  server_actor:server_upgrade/3))
                  ),
                  Error,
                  true),
            (   var(Error)
            ->  From ! Ref-ok,
                server_loop(NewPred, State0)
            ;   From ! Ref-error(Error),
                server_loop(Pred, State0)
            ) ;
        '$stop'(From) ->
            From ! reply(true)
    }).


%!  server_request(+To, +Request, -Response) is det.
%!  server_request(+To, +Request, -Response, +Options) is det.
%
%   Synchronous request-response call to a server. Installs a monitor
%   so that the call fails fast if the server terminates before
%   replying. Options are passed to receive/2 (e.g. timeout).

server_request(To, Request, Response) :-
    server_request(To, Request, Response, []).

server_request(To, Request, Response, Options) :-
    server_promise(To, Request, Ref, MonRef),
    server_yield(Ref, MonRef, Response, Options).


%!  server_promise(+To, +Request, -Ref) is det.
%
%   Send a request to a server and return the correlation reference.
%   The caller must later collect the response with server_yield/2-3.
%   Does not install a monitor; use server_promise/4 for fail-fast
%   behaviour.

server_promise(To, Request, Ref) :-
    self(Self),
    make_ref(Ref),
    To ! '$call'(Self, Ref, Request).


%!  server_promise(+To, +Request, -Ref, -MonRef) is det.
%
%   Fail-fast variant of server_promise/3. Installs a monitor on the
%   server before sending the request; MonRef must be passed to
%   server_yield/4 so the monitor can be cancelled on receipt of the
%   reply and a server_down/1 exception can be raised if the server
%   dies.

server_promise(To, Request, Ref, MonRef) :-
    self(Self),
    monitor(To, MonRef),
    make_ref(Ref),
    To ! '$call'(Self, Ref, Request).


%!  server_yield(+Ref, -Response) is det.
%!  server_yield(+Ref, -Response, +Options) is det.
%
%   Wait for the server reply matching Ref. Options are passed to
%   receive/2.

server_yield(Ref, Response) :-
    server_yield(Ref, Response, []).

server_yield(Ref, Response, Options) :-
    receive({
        Ref-Response -> true
    }, Options).


%!  server_yield(+Ref, +MonRef, -Response, +Options) is det.
%
%   Fail-fast variant of server_yield/3. Waits for Ref-Response or a
%   down/3 message for MonRef. Cancels the monitor on normal reply;
%   throws server_down(Reason) if the server terminates first.

server_yield(Ref, MonRef, Response, Options) :-
    receive({
        Ref-Response0 ->
            demonitor(MonRef),
            Response = Response0 ;
        down(MonRef, _Pid, Reason) ->
            throw(server_down(Reason))
    }, Options).


%!  server_upgrade(+To, +Pred) is det.
%
%   Replace the callback predicate of a running server without
%   stopping it or disturbing its state. Pred must be arity 4.

server_upgrade(To, Pred0) :-
    server_upgrade_source(To, Pred0, "").


%!  server_upgrade(+To, +Pred, +Options) is det.
%
%   Load the source selected by the load_* Options into the server's private
%   module, then replace its callback without disturbing its state.

server_upgrade(To, Pred0, Options) :-
    normalize_server_callback(Pred0, Pred),
    strip_module(Pred, SourceModule, PlainPred),
    load_options_text(SourceModule, Options, Source),
    server_upgrade_source(To, PlainPred, Source).


server_upgrade_source(To, Pred0, Source) :-
    strip_module(Pred0, _SourceModule, PlainPred),
    self(Self),
    make_ref(Ref),
    To ! '$upgrade'(Self, Ref, PlainPred, Source),
    receive({
        Ref-ok ->
            true ;
        Ref-error(Error) ->
            throw(Error)
    }).


prepare_server_upgrade(_Ref, PlainPred, Source, Pred) :-
    self(Self),
    (   actor_module(Self, Module)
    ->  true
    ;   throw(error(existence_error(actor_module, Self),
                    server_actor:server_upgrade/3))
    ),
    load_upgrade_source(Source, Module, PlainPred),
    ensure_server_callback(Module, PlainPred),
    Pred = Module:PlainPred.

load_upgrade_source("", _, _) :-
    !.
load_upgrade_source(Source, Module, PlainPred) :-
    abolish_local_callback(Module, PlainPred),
    setup_call_cleanup(
        open_string(Source, Stream),
        read_upgrade_source(Stream, Module),
        close(Stream)
    ).

abolish_local_callback(Module, PlainPred) :-
    callback_head(PlainPred, Head),
    (   predicate_property(Module:Head, defined),
        \+ predicate_property(Module:Head, imported_from(_))
    ->  functor(Head, Name, Arity),
        abolish(Module:Name/Arity)
    ;   true
    ).

read_upgrade_source(Stream, Module) :-
    read_term(Stream, Term, [module(Module)]),
    (   Term == end_of_file
    ->  true
    ;   Module:expand_term(Term, Expanded),
        install_upgrade_terms(Expanded, Module),
        read_upgrade_source(Stream, Module)
    ).

install_upgrade_terms([], _) :-
    !.
install_upgrade_terms([Term|Terms], Module) :-
    !,
    install_upgrade_term(Term, Module),
    install_upgrade_terms(Terms, Module).
install_upgrade_terms(Term, Module) :-
    install_upgrade_term(Term, Module).

install_upgrade_term((:- Directive), Module) :-
    !,
    call(Module:Directive).
install_upgrade_term((?- Goal), Module) :-
    !,
    call(Module:Goal).
install_upgrade_term(Clause, Module) :-
    assertz(Module:Clause).

ensure_server_callback(Module, PlainPred) :-
    callback_head(PlainPred, Head),
    functor(Head, Name, Arity),
    (   predicate_property(Module:Head, defined),
        \+ predicate_property(Module:Head, imported_from(_))
    ->  true
    ;   throw(error(existence_error(procedure, Module:Name/Arity),
                    context(server_actor:server_upgrade/3,
                            'upgrade callback is not loaded in the server')))
    ).


%!  server_halt(+To, -Reply) is det.
%
%   Ask the server to stop gracefully and wait for its acknowledgement.

server_halt(To, Reply) :-
    self(Self),
    To ! '$stop'(Self),
    receive({
        reply(Reply) -> true
    }).

%!  server_stop(+To, -Reply) is det.
%
%   Backward-compatible alias for server_halt/2.

server_stop(To, Reply) :-
    server_halt(To, Reply).
