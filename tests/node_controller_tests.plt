/*  Unit tests for the node_controller table API.

    These pin the controller's behavior in isolation, before any
    cross-node migration uses it.  At the skeleton stage (step 1)
    the controller is not yet wired in anywhere, so these tests are
    pure data-structure tests; they will grow as the controller
    starts serving real routing decisions.
*/

:- use_module('../node_controller.pl').

:- use_module(library(plunit)).

:- begin_tests(node_controller).

%  Each test clears all controller state via the by_pid /
%  by_parent drains, so tests do not contaminate each other.

reset_controller :-
    retractall(node_controller:remote_target_(_, _)),
    retractall(node_controller:remote_monitor_(_, _, _)),
    retractall(node_controller:remote_link_(_, _)).


test(register_and_lookup_target, [setup(reset_controller)]) :-
    register_remote_target(rpid1, target1),
    current_remote_target(rpid1, T),
    assertion(T == target1).

test(register_overrides_prior_target, [setup(reset_controller)]) :-
    register_remote_target(rpid1, target1),
    register_remote_target(rpid1, target2),
    findall(T, current_remote_target(rpid1, T), Ts),
    assertion(Ts == [target2]).

test(forget_target_removes_entry, [setup(reset_controller)]) :-
    register_remote_target(rpid1, target1),
    forget_remote_target(rpid1),
    assertion(\+ current_remote_target(rpid1, _)).

test(add_monitor_take_drains_atomically, [setup(reset_controller)]) :-
    add_remote_monitor(watcher1, rpid1, ref1),
    add_remote_monitor(watcher2, rpid1, ref2),
    %  Unrelated monitor must not be drained.
    add_remote_monitor(watcher3, rpid2, ref3),
    take_remote_monitors_for_pid(rpid1, Entries),
    sort(Entries, EntriesSorted),
    assertion(EntriesSorted ==
              [monitor(watcher1, ref1), monitor(watcher2, ref2)]),
    %  Drained entries are gone.
    take_remote_monitors_for_pid(rpid1, []),
    %  rpid2's monitor is untouched.
    take_remote_monitors_for_pid(rpid2, [monitor(watcher3, ref3)]).

test(remove_monitor_by_ref, [setup(reset_controller)]) :-
    add_remote_monitor(watcher1, rpid1, ref1),
    add_remote_monitor(watcher1, rpid1, ref2),
    remove_remote_monitor_by_ref(ref1),
    take_remote_monitors_for_pid(rpid1, [monitor(watcher1, ref2)]).

test(remove_monitor_by_pid, [setup(reset_controller)]) :-
    add_remote_monitor(watcher1, rpid1, ref1),
    add_remote_monitor(watcher2, rpid1, ref2),
    remove_remote_monitor_by_pid(rpid1),
    take_remote_monitors_for_pid(rpid1, []).

test(add_link_and_drain_children, [setup(reset_controller)]) :-
    add_remote_link(parent1, rpid1),
    add_remote_link(parent1, rpid2),
    add_remote_link(parent2, rpid3),
    take_remote_children_for_parent(parent1, Children1),
    sort(Children1, Children1Sorted),
    assertion(Children1Sorted == [rpid1, rpid2]),
    take_remote_children_for_parent(parent1, []),
    take_remote_children_for_parent(parent2, [rpid3]).

test(remove_one_link, [setup(reset_controller)]) :-
    add_remote_link(parent1, rpid1),
    add_remote_link(parent1, rpid2),
    remove_remote_link(parent1, rpid1),
    take_remote_children_for_parent(parent1, [rpid2]).

:- end_tests(node_controller).
