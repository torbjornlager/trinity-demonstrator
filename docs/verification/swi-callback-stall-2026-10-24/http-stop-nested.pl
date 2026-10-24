:- module(http_stop_nested,[run/0]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(socket)).
:- dynamic base/1.
:- http_handler(root(outer),outer,[]).
:- http_handler(root(inner),inner,[]).
outer(_) :-
 base(Base),atom_concat(Base,'/inner',URL),
 thread_create(client(URL),_,[detached(true)]),
 reply_json_dict(_{type:"error",data:"sandboxed"}).
inner(_) :- sleep(0.1),format('Content-type: text/plain~n~nhello~n').
client(URL) :- catch(setup_call_cleanup(http_open(URL,S,[]),read_string(S,_,_),close(S)),_,true).
run :-
 tcp_socket(S),tcp_bind(S,Port),tcp_close_socket(S),
 format(atom(Base),'http://localhost:~w',[Port]),assertz(base(Base)),
 http_server(http_dispatch,[port(Port)]),atom_concat(Base,'/outer',URL),
 setup_call_cleanup(http_open(URL,R,[]),json_read_dict(R,JSON),close(R)),
 assertion(JSON.type=="error"),assertion(JSON.data=="sandboxed"),
 format(user_error,'~Nresponse_verified(~w).~nstop_begin(~w).~n',[Port,Port]),flush_output(user_error),
 http_stop_server(Port,[]),format(user_error,'~Nstop_end(~w).~n',[Port]).
