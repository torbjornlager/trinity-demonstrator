:- ['/Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/source/load.pl'].
:- use_module(library(socket)).
:- use_module(library(settings)).
:- use_module('/Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/source/examples/services/node_resident_services.pl').
:- use_module('/Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/source/examples/services/model_service.pl', []).
:- use_module('/Users/torbjorn.lager/.local/share/trinity-local-nodes/n3/rollback/source/examples/services/jev_service.pl', []).
:- initialization(main,main).
main :-
    current_prolog_flag(argv,[Name]),
    config(Name,Port,Auth,Files,Sections),
    set_setting(http:public_host,localhost),
    set_setting(http:public_port,Port),
    set_setting(http:public_scheme,http),
    tcp_socket(Socket),tcp_setopt(Socket,reuseaddr),tcp_bind(Socket,ip(127,0,0,1):Port),tcp_listen(Socket,128),
    maplist(shared_option,Files,Shared),
    append([profile(actor),sandbox(blacklist),auth(Auth),timeout(10),
            tutorial_sections(Sections),tcp_socket(Socket),
            ws_allowed_origins(['http://localhost:3053','http://localhost:3060',
                                'http://127.0.0.1:3053','http://127.0.0.1:3060'])],Shared,Options),
    node(Port,Options),
    (Name==n3 -> node_runtime_state:with_node_port_context(Port,start_example_services(_,_));true),
    node_runtime_state:with_node_port_context(Port,
        node_runtime_state:update_current_node_runtime(_{anon_per_ws_connection:true})),
    format('LOCAL ~w READY http://localhost:~w/portal~n',[Name,Port]),flush_output,
    thread_get_message(_).
shared_option(File,load_shared_db_file(File)).
config(n3,51854,open,
 ['/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_common.pl',
  '/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_actor_common.pl',
  '/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_n3.pl'],
 [local_actor,toplevels,distributed_actor,behaviours,statecharts]).
config(n5,3060,dev,
 ['/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/prolog/web_prolog/shared_db.pl',
  '/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator/Deployment/shared_db_n5.pl'],all).
