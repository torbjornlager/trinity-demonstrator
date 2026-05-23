:- module(multi_node_harness, [
    with_test_nodes/2,        % +NodeSpecs, :Goal
    pick_free_port/1,         % -Port
    wait_until/2,             % :Predicate, +TimeoutSeconds
    wait_until/3,             % :Predicate, +TimeoutSeconds, +PollIntervalSeconds
    node_ws_actor_pids/2,     % +URL, -Pids
    node_ws_actor_count/2,    % +URL, -Count
    node_admin_runtime/2,     % +URL, -RuntimeDict
    assert_no_orphans/1       % +URL
]).

/** <module> Multi-node integration test harness

A small harness for tests that need two or more nodes running in the
same SWI-Prolog process.  Each node is started on a free port and
addressed by its localhost URL, so cross-node messaging, spawning,
linking, and monitoring can be exercised end-to-end without external
processes.

Important caveat: nodes share the same actor.pl module within one
process, so dynamic predicates such as `link/2`, `monitor/3`, and
`remote_pid_proxy/2` are global.  This is a simplified model of a
real deployment, where each node is its own OS process with its own
copy of those tables.  Tests written against this harness still catch
the great majority of cross-node lifecycle bugs (wire-format
round-trips, remote spawn/exit/halt protocols, orphan/cleanup
invariants on ws_actor/2 rows), but a few categories of bug --
notably ones that would only appear when actor-table state is
genuinely separated -- can hide here.  Add OS-level tests if you need
that fidelity.

Usage:

==
    test(my_cross_node_test, Result == ok) :-
        with_test_nodes(
            [node_spec(a, [profile(actor), auth(open)]),
             node_spec(b, [profile(actor), auth(open)])],
            (   nb_getval(node_url_a, URLA),
                nb_getval(node_url_b, URLB),
                spawn(echo_actor, Pid, [node(URLB), monitor(true)]),
                ...
                Result = ok
            )).
==

Each node's URL is stored under the global variable `node_url_<Tag>`
(e.g. `node_url_a`) for the duration of `Goal`.  Use `nb_getval/2` to
read it inside the body.
*/

:- use_module('../src/actor.pl').
:- use_module('../src/node.pl').
:- use_module(library(socket)).
:- use_module(library(http/thread_httpd), [http_stop_server/2]).
:- use_module(library(http/http_client), [http_get/3]).
:- use_module(library(http/http_json), []).
:- use_module(library(option)).
:- use_module(library(apply)).

:- meta_predicate
    with_test_nodes(+, 0),
    wait_until(0, +),
    wait_until(0, +, +).


%!  with_test_nodes(+NodeSpecs, :Goal) is det.
%
%   Start a list of test nodes, bind each one's URL to the global
%   variable `node_url_<Tag>`, run Goal, and tear down all nodes on
%   exit.  Cleanup runs on normal exit, failure, exception, or
%   abort.
%
%   NodeSpecs is a list of `node_spec(Tag, Options)` terms.  Tag is
%   any atom usable as a global variable suffix; Options is forwarded
%   to node/2.
with_test_nodes(NodeSpecs, Goal) :-
    setup_call_cleanup(
        start_test_nodes(NodeSpecs, Ports),
        Goal,
        stop_test_nodes(NodeSpecs, Ports)
    ).


start_test_nodes(NodeSpecs, Ports) :-
    maplist(start_one_test_node, NodeSpecs, Ports).

start_one_test_node(node_spec(Tag, Options), Port) :-
    pick_free_port_with_retry(Port, Options),
    format(atom(URL), 'http://localhost:~w', [Port]),
    atom_concat(node_url_, Tag, VarName),
    nb_setval(VarName, URL).

%  Bind a free port and start a node on it.  pick_free_port/1 races
%  with the kernel reclaiming the port between bind and listen, so
%  retry a few times if node/2 reports the port already in use.
pick_free_port_with_retry(Port, Options) :-
    between(1, 20, _),
    pick_free_port(Port),
    catch(node(Port, Options), _, fail),
    !.

stop_test_nodes(NodeSpecs, Ports) :-
    maplist(stop_one_test_node, NodeSpecs, Ports).

stop_one_test_node(node_spec(Tag, _Options), Port) :-
    catch(http_stop_server(Port, []), _, true),
    atom_concat(node_url_, Tag, VarName),
    catch(nb_delete(VarName), _, true).


%!  pick_free_port(-Port) is det.
%
%   Bind to port 0, get the kernel-assigned port number, close the
%   socket.  The port is briefly racy after this call -- another
%   process could grab it before we reopen.  Use
%   pick_free_port_with_retry/2 for robust startup.
pick_free_port(Port) :-
    tcp_socket(Socket),
    tcp_bind(Socket, Port),
    tcp_close_socket(Socket).


%!  wait_until(:Predicate, +TimeoutSeconds) is semidet.
%!  wait_until(:Predicate, +TimeoutSeconds, +PollIntervalSeconds) is semidet.
%
%   Poll Predicate until it succeeds or TimeoutSeconds elapses.
%   Useful for asserting on eventual-consistency conditions
%   (e.g. "no more ws_actor rows on n4").  Default poll interval is
%   50 ms.
wait_until(Predicate, TimeoutSeconds) :-
    wait_until(Predicate, TimeoutSeconds, 0.05).

wait_until(Predicate, TimeoutSeconds, PollSeconds) :-
    get_time(Start),
    Deadline is Start + TimeoutSeconds,
    wait_until_loop(Predicate, Deadline, PollSeconds).

wait_until_loop(Predicate, Deadline, PollSeconds) :-
    (   call(Predicate)
    ->  true
    ;   get_time(Now),
        Now < Deadline,
        sleep(PollSeconds),
        wait_until_loop(Predicate, Deadline, PollSeconds)
    ).


%!  node_admin_runtime(+URL, -RuntimeDict) is det.
%
%   Fetch /admin/runtime JSON for the node at URL.
node_admin_runtime(URL, RuntimeDict) :-
    atom_concat(URL, '/admin/runtime', RuntimeURL),
    http_get(RuntimeURL, RuntimeDict,
             [json_object(dict), timeout(5)]).


%!  node_ws_actor_pids(+URL, -Pids) is det.
%
%   Return the list of pid strings listed as ws_actors on the node.
node_ws_actor_pids(URL, Pids) :-
    node_admin_runtime(URL, Runtime),
    get_dict(ws_actors, Runtime, Entries),
    findall(P, (member(E, Entries), get_dict(pid, E, P)), Pids).


%!  node_ws_actor_count(+URL, -Count) is det.
%
%   Number of ws_actor rows currently listed on the node.
node_ws_actor_count(URL, Count) :-
    node_ws_actor_pids(URL, Pids),
    length(Pids, Count).


%!  assert_no_orphans(+URL) is det.
%
%   Assert that the node has no active ws_actors AND that the
%   activity_summary counter agrees with the listing (no stale rows).
%   This is the central post-condition for tests that exercise
%   cross-node lifecycle: when a test ends, the only state that
%   should remain on a node is what the test deliberately left
%   behind.
assert_no_orphans(URL) :-
    node_admin_runtime(URL, Runtime),
    get_dict(activity_summary, Runtime, Summary),
    get_dict(active_ws_actors, Summary, Counter),
    get_dict(ws_actors, Runtime, Listed),
    length(Listed, ListedCount),
    (   Counter =:= 0, ListedCount =:= 0
    ->  true
    ;   throw(error(node_has_orphans(URL, Counter, ListedCount, Listed),
                    context(assert_no_orphans/1,
                            'node has leftover ws_actor state at end of test')))
    ).
