:- module(server, [

       server_spawn/3,
       server_request/3,
       server_halt/2,
       server_stop/2

   ]).

/** <module> Generic Server Loop on Top of actor.pl

Small "gen_server"-style helper built from actor primitives.

`server_spawn/3` creates an actor running `server_loop/2`.
Client requests are synchronous and use a request/reply protocol:

  - request message: `'$srv_call'(From, Ref, Request)`
  - reply message:   `Ref-Response`

Server state is explicit and threaded through handler calls:

  `Pred(Request, OldState, Response, NewState)`.
*/

:- use_module(library(option)).
:- use_module(actor).

%!  server_spawn(+Pred, -Pid, +Options) is det.
%
%   Spawn a server actor.
%
%   Options:
%
%     - initial_state(S) : initial state term (default `[]`)
%     - name(Name)       : register server under Name
%
%   All other options are forwarded to actor `spawn/3`.

server_spawn(Pred, Pid, Options) :-
    option(initial_state(State), Options, []),
    exclude(is_server_opt, Options, SpawnOpts),
    spawn(server_loop(Pred, State), Pid, SpawnOpts),
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).

is_server_opt(initial_state(_)).
is_server_opt(name(_)).


%!  server_loop(+Pred, +State) is det.
%
%   Generic server receive loop.
%
%   `Pred` must be arity 4:
%
%     `Pred(Request, OldState, Response, NewState)`.

server_loop(Pred, State0) :-
    receive({
        '$srv_call'(From, Ref, Request) ->
            (   call(Pred, Request, State0, Response, State)
            ->  From ! Ref-Response,
                server_loop(Pred, State)
            ;   From ! Ref-error(no_clause),
                server_loop(Pred, State0)
            )
        ;
        '$srv_upgrade'(Pred1) ->
            server_loop(Pred1, State0)
        ;
        '$srv_stop'(From) ->
            From ! srv_reply(true)
    }).


%!  server_request(+To, +Request, -Response) is det.
%
%   Perform synchronous request/reply call to server.

server_request(To, Request, Response) :-
    self(Self),
    make_id(Ref),
    To ! '$srv_call'(Self, Ref, Request),
    receive({
        Ref-Response0 ->
            Response = Response0
    }).


%!  server_halt(+To, -Reply) is det.
%
%   Ask server to stop and wait for acknowledgement.

server_halt(To, Reply) :-
    self(Self),
    To ! '$srv_stop'(Self),
    receive({
        srv_reply(Reply) -> true
    }).

%!  server_stop(+To, -Reply) is det.
%
%   Backward-compatible alias for server_halt/2.

server_stop(To, Reply) :-
    server_halt(To, Reply).
