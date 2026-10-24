:- module(http_stop_gated,[run/0]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(socket)).
:- dynamic main/1,armed/0.
:- multifile http:schedule_workers/1.
http:schedule_workers(Dict) :- http_stop_gated:gate(Dict).
:- http_handler(root(block),block,[]).
:- http_handler(root(second),second,[]).
log(Term) :- get_time(T),format(user_error,'~Ncontrol(~q,~q).~n',[T,Term]),flush_output(user_error).
block(_) :- main(Main),thread_self(Self),thread_send_message(Main,handler_ready(Self)),thread_get_message(release),second(_).
second(_) :- format('Content-type: text/plain~n~nhello~n').
gate(Dict) :-
 retract(armed),main(Main),thread_self(Acceptor),
 log(scheduler_gate(Dict,Acceptor)),thread_send_message(Main,scheduling(Acceptor)),
 thread_get_message(release_scheduler),log(unexpected_scheduler_release).
client(URL) :- catch(setup_call_cleanup(http_open(URL,S,[]),read_string(S,_,_),close(S)),E,log(client_error(E))).
run :-
 thread_self(Main),assertz(main(Main)),assertz(armed),
 tcp_socket(Socket),tcp_bind(Socket,Port),tcp_close_socket(Socket),
 http_server(http_dispatch,[port(Port),workers(1)]),
 format(atom(First),'http://localhost:~w/block',[Port]),format(atom(Second),'http://localhost:~w/second',[Port]),
 thread_create(client(First),_,[detached(true)]),thread_get_message(handler_ready(Worker)),
 thread_create(client(Second),_,[detached(true)]),thread_get_message(scheduling(Acceptor)),
 log(releasing_worker(Worker)),thread_send_message(Worker,release),
 log(stop_begin(Port,Acceptor)),http_stop_server(Port,[]),log(stop_completed(Port)).
