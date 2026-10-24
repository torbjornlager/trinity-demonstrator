:- module(http_stop_standalone,[run/0]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(socket)).
:- use_module(library(prolog_wrap)).
:- http_handler(root(.),reply,[]).
reply(_) :- format('Content-type: text/plain~n~nhello~n').
log(Term) :- get_time(T),format(user_error,'~Nstandalone(~q,~q).~n',[T,Term]),flush_output(user_error).
run :-
 tcp_socket(S),tcp_bind(S,Port),tcp_close_socket(S),
 http_server(http_dispatch,[port(Port)]),
 format(atom(URL),'http://localhost:~w/',[Port]),
 setup_call_cleanup(http_open(URL,R,[]),read_string(R,_,_),close(R)),
 thread_self(Main),thread_create(client(URL,Main),_,[detached(true)]),
 thread_get_message(opening),
 log(stop_begin(Port)),http_stop_server(Port,[]),log(stop_end(Port)).
client(URL,Main) :-
 thread_send_message(Main,opening),
 catch(setup_call_cleanup(http_open(URL,S,[]),read_string(S,_,_),close(S)),_,true).
