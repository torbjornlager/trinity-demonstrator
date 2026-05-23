:- module(pid_utils, [
    localhost_node/1,
    node_url_atom/2,
    normalize_node_url/2,
    register_node_self/1,
    registered_self_node_url/1,
    self_node_url/1,
    canonical_pid/2,
    local_node_url/1,
    pid_local/2,
    parse_pid_or_throw/4,
    parse_transport_pid_or_throw/4
]).

/** <module> Pid and Node URL Helpers

Shared normalization utilities for:

  - local-vs-global pid handling,
  - canonical node URL handling,
  - transport-facing pid parsing.
*/

:- use_module(node_runtime_state, [current_node_url/1]).

:- dynamic self_node/1.
:- op(200, xfx, @).


%!  localhost_node(+Node) is semidet.
%
%   True if Node denotes the local node — the atom `localhost`, or any
%   atom/string whose lowercase form is `"localhost"`. Used to short-
%   circuit remote-dispatch paths when a "remote" URL actually points
%   back at this process.

localhost_node(localhost).
localhost_node(Node) :-
    atom(Node),
    downcase_atom(Node, localhost).
localhost_node(Node) :-
    string(Node),
    string_lower(Node, "localhost").


%!  node_url_atom(+Node0, -NodeURL) is det.
node_url_atom(NodeURL, NodeURL) :-
    atom(NodeURL),
    !.
node_url_atom(Node0, NodeURL) :-
    string(Node0),
    !,
    atom_string(NodeURL, Node0).


%!  normalize_node_url(+Node0, -Node) is det.
normalize_node_url(Node0, Node) :-
    node_url_atom(Node0, Node1),
    (   sub_atom(Node1, _, 1, 0, '/')
    ->  sub_atom(Node1, 0, _, 1, Node)
    ;   Node = Node1
    ).


%!  register_node_self(+URL0) is det.
register_node_self(URL0) :-
    normalize_node_url(URL0, URL),
    retractall(self_node(_)),
    assertz(self_node(URL)).

%!  registered_self_node_url(-URL) is semidet.
%
%   True when a node self URL has been explicitly registered.
registered_self_node_url(URL) :-
    self_node(URL).


%!  self_node_url(-URL) is det.
self_node_url(URL) :-
    current_node_url(URL),
    !.
self_node_url(URL) :-
    self_node(URL),
    !.
self_node_url('http://localhost').


%!  canonical_pid(+Pid0, -Pid) is det.
%
%   Canonicalize pid values coming from local terms, JSON strings, or atoms.
canonical_pid(Pid0, Pid) :-
    nonvar(Pid0),
    canonical_pid_1(Pid0, Pid1),
    canonical_pid_2(Pid1, Pid).

canonical_pid_1(main, main) :-
    !.
canonical_pid_1(Pid@Node0, Pid@Node) :-
    integer(Pid),
    !,
    normalize_node_url(Node0, Node).
canonical_pid_1(Pid, Pid) :-
    integer(Pid),
    !.
canonical_pid_1(PidAtom0, Pid) :-
    atom(PidAtom0),
    !,
    (   atom_number(PidAtom0, PidInt)
    ->  Pid = PidInt
    ;   catch(term_to_atom(Term, PidAtom0), _, fail),
        Term \== PidAtom0
    ->  canonical_pid_1(Term, Pid)
    ;   Pid = PidAtom0
    ).
canonical_pid_1(PidString, Pid) :-
    string(PidString),
    !,
    atom_string(PidAtom, PidString),
    canonical_pid_1(PidAtom, Pid).
canonical_pid_1(Pid, Pid).

canonical_pid_2(main, main) :-
    !.
canonical_pid_2(Pid@Node, Pid@Node) :-
    integer(Pid),
    !.
canonical_pid_2(Pid, Pid@Node) :-
    integer(Pid),
    !,
    self_node_url(Node).
canonical_pid_2(Pid, Pid).


%!  local_node_url(+Node0) is semidet.
local_node_url(Node0) :-
    normalize_node_url(Node0, Node),
    self_node_url(Self0),
    normalize_node_url(Self0, Self),
    Node == Self.


%!  pid_local(+Pid0, -LocalPid) is semidet.
pid_local(main, main) :-
    !.
pid_local(Pid@Node0, Pid) :-
    integer(Pid),
    local_node_url(Node0),
    !.
pid_local(Pid, Pid) :-
    integer(Pid),
    !.


%!  parse_pid_or_throw(+Raw, +Context, +Message, -Pid) is det.
parse_pid_or_throw(Raw, Context, Message, Pid) :-
    (   catch(canonical_pid(Raw, Pid), _, fail)
    ->  true
    ;   throw(error(type_error(pid, Raw), context(Context, Message)))
    ).


%!  parse_transport_pid_or_throw(+Raw, +Context, +Message, -Pid) is det.
%
%   Parse pid/name values received over HTTP/WS transports while preserving
%   plain local integer pids and registered-name atoms. Compound `Id@Node`
%   forms are still normalized.
parse_transport_pid_or_throw(Raw, Context, Message, Pid) :-
    (   catch(parse_transport_pid(Raw, Pid), _, fail)
    ->  true
    ;   throw(error(type_error(pid, Raw), context(Context, Message)))
    ).

parse_transport_pid(main, main) :-
    !.
parse_transport_pid(Pid@Node0, Pid@Node) :-
    integer(Pid),
    !,
    normalize_node_url(Node0, Node).
parse_transport_pid(Pid, Pid) :-
    integer(Pid),
    !.
parse_transport_pid(PidAtom0, Pid) :-
    atom(PidAtom0),
    !,
    (   atom_number(PidAtom0, PidInt)
    ->  Pid = PidInt
    ;   catch(term_to_atom(Term, PidAtom0), _, fail),
        Term \== PidAtom0
    ->  parse_transport_pid(Term, Pid)
    ;   Pid = PidAtom0
    ).
parse_transport_pid(PidString, Pid) :-
    string(PidString),
    !,
    atom_string(PidAtom, PidString),
    parse_transport_pid(PidAtom, Pid).
