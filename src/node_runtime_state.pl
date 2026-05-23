:- module(node_runtime_state, [
    register_node_runtime/2,
    node_request_port/2,
    with_node_request_context/2,
    with_node_port_context/2,
    current_node_port/1,
    current_node_value/2,
    current_node_url/1,
    update_current_node_runtime/1
]).

/** <module> Per-node Runtime State

Request-scoped access to runtime configuration for nodes running in the same
SWI process. State is keyed by the local server port announced in HTTP
requests.
*/

:- use_module(library(error)).

:- dynamic node_runtime/2.
:- thread_local current_node_port_local/1.

:- meta_predicate
    with_node_request_context(+, 0),
    with_node_port_context(+, 0).


%!  register_node_runtime(+Port, +Runtime) is det.
register_node_runtime(Port, Runtime) :-
    must_be(integer, Port),
    must_be(dict, Runtime),
    retractall(node_runtime(Port, _)),
    assertz(node_runtime(Port, Runtime)).


%!  node_request_port(+Request, -Port) is det.
node_request_port(Request, Port) :-
    (   memberchk(port(Port0), Request)
    ->  Port = Port0
    ;   memberchk(pool(client(ClientId, _, _, _)), Request),
        pool_client_port(ClientId, Port)
    ),
    must_be(integer, Port).

pool_client_port(ClientId, Port) :-
    atom(ClientId),
    sub_atom(ClientId, _, _, 0, PortAtom),
    sub_atom(ClientId, _, 1, _, '@'),
    atom_number(PortAtom, Port).


%!  with_node_request_context(+Request, :Goal) is det.
with_node_request_context(Request, Goal) :-
    node_request_port(Request, Port),
    with_node_port_context(Port, Goal).


%!  with_node_port_context(+Port, :Goal) is det.
with_node_port_context(Port, Goal) :-
    must_be(integer, Port),
    setup_call_cleanup(
        asserta(current_node_port_local(Port), Ref),
        Goal,
        erase(Ref)
    ).


%!  current_node_port(-Port) is semidet.
current_node_port(Port) :-
    current_node_port_local(Port).


%!  current_node_value(+Key, -Value) is semidet.
current_node_value(Key, Value) :-
    current_node_port(Port),
    node_runtime(Port, Runtime),
    get_dict(Key, Runtime, Value).


%!  current_node_url(-URL) is semidet.
current_node_url(URL) :-
    current_node_value(url, URL).


%!  update_current_node_runtime(+Updates) is det.
update_current_node_runtime(Updates) :-
    must_be(dict, Updates),
    current_node_port(Port),
    node_runtime(Port, Runtime0),
    put_dict(Updates, Runtime0, Runtime),
    retractall(node_runtime(Port, _)),
    assertz(node_runtime(Port, Runtime)).
