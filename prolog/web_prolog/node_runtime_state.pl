:- module(node_runtime_state, [
    register_node_runtime/2,
    node_request_port/2,
    with_node_request_context/2,
    with_node_port_context/2,
    current_node_port/1,
    current_node_value/2,
    current_node_url/1,
    update_current_node_runtime/1,
    set_node_maintenance/2,
    node_port_in_maintenance/1,
    current_node_maintenance/1
]).

/** <module> Per-node Runtime State

Request-scoped access to runtime configuration for nodes running in the same
SWI process. State is keyed by the local server port announced in HTTP
requests.
*/

:- use_module(library(error)).

:- dynamic node_runtime/2.
:- dynamic node_maintenance/1.            % Port (present ⇒ draining)
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
%
%   Resolve which local node (keyed by its bind port) serves this
%   request.  Prefer the thread-pool client id `httpd@<bind-port>`,
%   which names the socket the node actually listens on.  Only fall
%   back to the request's port(_) field — which SWI derives from the
%   (client-controlled) Host header — when no pool id is present.
%
%   The Host-header port disagrees with the bind port behind any
%   port-remapping front end (a Docker `-p 8080:3060` publish, several
%   nodes behind one reverse proxy on distinct external ports, ...).
%   Keying node identity on it made such nodes resolve to a
%   non-existent runtime and report themselves permanently not-ready.
node_request_port(Request, Port) :-
    (   request_pool_port(Request, Port0)
    ->  Port = Port0
    ;   memberchk(port(Port0), Request),
        Port = Port0
    ),
    must_be(integer, Port).

request_pool_port(Request, Port) :-
    memberchk(pool(client(ClientId, _, _, _)), Request),
    pool_client_port(ClientId, Port).

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


%!  set_node_maintenance(+Port, +Bool) is det.
%
%   Put a node into (true) or out of (false) maintenance/drain mode.
%   While in maintenance a node refuses new execution work and reports
%   itself not-ready (`/readyz` ⇒ 503), so a load balancer drains it
%   while in-flight work finishes.
set_node_maintenance(Port, true) :-
    !,
    must_be(integer, Port),
    (   node_maintenance(Port) -> true ; assertz(node_maintenance(Port)) ).
set_node_maintenance(Port, false) :-
    retractall(node_maintenance(Port)).

%!  node_port_in_maintenance(+Port) is semidet.
node_port_in_maintenance(Port) :-
    node_maintenance(Port).

%!  current_node_maintenance(-Bool) is det.
%
%   Maintenance state of the node servicing the current request.
current_node_maintenance(Bool) :-
    (   current_node_port(Port),
        node_maintenance(Port)
    ->  Bool = true
    ;   Bool = false
    ).


%!  update_current_node_runtime(+Updates) is det.
update_current_node_runtime(Updates) :-
    must_be(dict, Updates),
    current_node_port(Port),
    node_runtime(Port, Runtime0),
    put_dict(Updates, Runtime0, Runtime),
    retractall(node_runtime(Port, _)),
    assertz(node_runtime(Port, Runtime)).
