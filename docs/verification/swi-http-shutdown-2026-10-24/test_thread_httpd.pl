:- module(test_thread_httpd, [test_thread_httpd/0]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_open)).
:- use_module(library(socket)).
:- use_module(library(plunit)).
:- dynamic gate/2, parent/2.
:- multifile http:schedule_workers/1.

http:schedule_workers(Data) :-
    test_thread_httpd:schedule(Data).

schedule(Data) :-
    retract(gate(Data.port, Main)),
    thread_self(Acceptor),
    thread_send_message(Main, scheduling(Acceptor)),
    thread_get_message(resume(Action)),
    call(Action).

handler(Request) :-
    memberchk(path(Path), Request),
    (   Path == '/block'
    ->  thread_self(Self), parent(SelfMain, _),
        thread_send_message(SelfMain, handler_ready(Self)),
        thread_get_message(release)
    ;   true
    ),
    format('Content-type: text/plain~n~nhello~n').

client(URL, Main, Tag) :-
    catch(setup_call_cleanup(http_open(URL, Stream, [timeout(5)]),
                             read_string(Stream, _, Body), close(Stream)),
          Error, Body = error(Error)),
    thread_send_message(Main, done(Tag, Body)).

start(Port) :-
    thread_self(Main),
    http_server(test_thread_httpd:handler, [port(Port), workers(1)]),
    assertz(parent(Main, Port)).

stop(Port) :-
    retractall(gate(Port, _)),
    retractall(parent(_, Port)),
    ( http_current_server(_, Port) -> http_stop_server(Port, []) ; true ).

prepare(Port, Worker, Acceptor) :-
    thread_self(Main),
    format(atom(First), 'http://localhost:~w/block', [Port]),
    format(atom(Second), 'http://localhost:~w/second', [Port]),
    thread_create(client(First, Main, first), _, [detached(true)]),
    wait_message(handler_ready(Worker)),
    assertz(gate(Port, Main)),
    thread_create(client(Second, Main, second), _, [detached(true)]),
    wait_message(scheduling(Acceptor)).

wait_message(Message) :-
    thread_self(Self), thread_get_message(Self, Message, [timeout(5)]).

await_clients :-
    wait_message(done(first, A)),
    wait_message(done(second, B)),
    assertion(A == "hello\n"), assertion(B == "hello\n").

test_thread_httpd :- run_tests(http_shutdown).

:- begin_tests(http_shutdown).

test(stop_during_scheduler, [setup(start(Port)), cleanup(stop(Port))]) :-
    prepare(Port, Worker, _),
    thread_send_message(Worker, release),
    http_stop_server(Port, []),
    assertion(\+ http_current_server(_, Port)),
    % Closing pending accepts may prevent the second request completing.
    wait_message(done(first, _)),
    wait_message(done(second, _)).

test(ordinary_scheduler_error_still_recovers,
     [setup(start(Port)), cleanup(stop(Port))]) :-
    prepare(Port, Worker, Acceptor),
    thread_send_message(Worker, release),
    thread_send_message(Acceptor, resume(throw(error(test_scheduler_error, _)))),
    await_clients,
    http_stop_server(Port, []),
    assertion(\+ http_current_server(_, Port)).

test(normal_shutdown, [setup(start(Port)), cleanup(stop(Port))]) :-
    http_stop_server(Port, []),
    assertion(\+ http_current_server(_, Port)).

:- end_tests(http_shutdown).
