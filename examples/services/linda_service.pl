:- module(linda_service, [start_linda_service/1, stop_linda_service/0, linda_client_file/1]).

:- use_module(library(web_prolog/actor_api)).

% Implementation belongs to the node owner, not the Examples drawer.
:- include(linda_space).
:- include(linda_client).

:- dynamic linda_directory/1.
:- prolog_load_context(directory, Dir), assertz(linda_directory(Dir)).

linda_client_file(File) :-
    linda_directory(Dir),
    directory_file_path(Dir, 'linda_client.pl', File).

start_linda(Pid) :- spawn(linda_loop([], []), Pid, [link(false)]).

start_linda_service(Pid) :-
    stop_linda_service,
    spawn(linda_loop([], []), Pid, [link(false)]),
    catch(register_service(linda, Pid), Error,
          (exit(Pid, kill), throw(Error))).

stop_linda_service :-
    (  whereis_service(linda, Pid), Pid \== undefined
    -> exit(Pid, kill)
    ;  true
    ),
    unregister_service(linda).
