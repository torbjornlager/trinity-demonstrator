
:- consult('/Users/torbjorn.lager/Documents/GitHub/swi-prolog-node/load.pl').
:- use_module(library(socket)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(http/thread_httpd)).
probe :- module_property(node,file(F)),
    assertion(same_file(F,'/Users/torbjorn.lager/Documents/GitHub/swi-prolog-node/prolog/web_prolog/node.pl')),
    tcp_socket(S),tcp_bind(S,Port),tcp_close_socket(S),
    setup_call_cleanup(node(Port,[profile(actor),auth(open)]),
        (format(atom(URL),'http://localhost:~w/healthz',[Port]),
         http_get(URL,Health,[json_object(dict)]),assertion(Health.status=="ok"),
         format(atom(Call),'http://localhost:~w/call?goal=true&format=json',[Port]),
         http_get(Call,Answer,[json_object(dict)]),assertion(Answer.type=="success"),
         format('headless_api(~q,~q).~n',[Health,Answer])),http_stop_server(Port,[])).
