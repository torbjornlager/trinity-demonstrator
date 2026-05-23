:- module(node_controller, [
    %  Cross-node routing tables.  See the migration notes below.
    register_remote_target/2,         % +RemotePid, +LocalTarget
    forget_remote_target/1,           % +RemotePid
    current_remote_target/2,          % ?RemotePid, ?LocalTarget

    add_remote_monitor/3,             % +Watcher, +RemotePid, +Ref
    remove_remote_monitor_by_ref/1,   % +Ref
    remove_remote_monitor_by_pid/1,   % +RemotePid (e.g. when proxy dies)
    take_remote_monitors_for_pid/2,   % +RemotePid, -Entries (atomic drain)

    add_remote_link/2,                % +LocalParent, +RemotePid
    remove_remote_link/2,             % +LocalParent, +RemotePid
    take_remote_children_for_parent/2,% +LocalParent, -Children (atomic drain)

    %  Node-scoped operations for connection-drop cleanup.
    take_remote_monitors_on_node/2,   % +NodeURL, -Entries (atomic drain)
    drop_remote_state_for_node/1      % +NodeURL (target + link entries)
]).

:- op(200, xfx, @).

/** <module> Node-controller skeleton for proxy-less cross-node routing

This module is the seed of the proxy-less cross-node design described
in Chapter 4 of the book ("the in-flight layer is a semantic device
rather than an implementation requirement"; "all side-effecting
operations are mediated by a node controller abstraction").

It is added in skeleton form so that subsequent commits can migrate
responsibilities off the per-pid proxy actors (`remote_actor_proxy/3`,
`remote_toplevel_proxy/3`) and onto these tables, one slice at a time,
with the cross-node integration tests in
`tests/cross_node_lifecycle_tests.plt` acting as the safety net at
each step.

==Three tables==

  - `remote_target_/2`  — for each remote pid we know about, the
    local target (queue or pid) that should receive its actor-level
    events (`success/3`, `output/2`, `prompt/2`, etc.).  Eventually
    replaces the proxy's `Target` argument and its `'$ws_remote_event'`
    forwarding loop.

  - `remote_monitor_/3` — every cross-node monitor: which local
    watcher is watching which remote pid, under which Ref.  Eventually
    replaces the post-loop monitor-table walk in
    `remote_actor_proxy_finalize/5` and
    `remote_toplevel_proxy_finalize/4`.

  - `remote_link_/2`    — every cross-node link (local parent, remote
    child).  Eventually replaces the use of `link/2` for cross-node
    children, so the local node controller can propagate kills
    directly via `safe_remote_kill_send/4` instead of through the
    proxy's `'$kill'(Reason)` mailbox handler.

The underscored internal names (`remote_target_/2` etc.) are
deliberately distinct from the proxy era's `remote_pid_proxy/2` and
the actor module's `link/2` and `monitor/3` so that during the
migration both worlds can coexist without name clashes.

==Migration plan (completed)==

All six steps are now in.  The cross-node tests in
`tests/cross_node_lifecycle_tests.plt` are the safety net for any
future change to this layer.

1. (Done.) Introduce the module skeleton.
2. (Done.) Mirror proxy state into the controller tables, with an
   integration test asserting the two views agree.
3. (Done.) Monitor delivery for cross-node down events reads
   `remote_monitor_/3`.
4. (Done.) Cross-node `send/2` goes direct via
   `remote_send_command/2`; controller's `remote_target_/2` is the
   readiness discriminator.
5. (Done.) Cross-node `exit/2` goes direct via
   `safe_remote_kill_send/4`.
5.5. (Done.) Per-pid event forwarding (success/output/prompt/...)
   delivered via `remote_target_/2` instead of through the proxy
   mailbox.
6. (Done.) `remote_actor_proxy/3`, `remote_toplevel_proxy/3`, and
   `remote_pid_proxy/2` deleted.  The controller is the only path.

==In-process caveat==

Because nodes started inside one Prolog process share this module
(same dynamic tables), the in-process integration harness will not
catch bugs that would only appear when controller state is truly
node-local.  This was already true for the proxy era and is called
out in `tests/multi_node_harness.pl`.  OS-level multi-process tests
are still future work.
*/

%  ---------------------- dynamic state ----------------------------

:- dynamic remote_target_/2.       % RemotePid, LocalTarget
:- dynamic remote_monitor_/3.      % Watcher, RemotePid, Ref
:- dynamic remote_link_/2.         % LocalParent, RemotePid


%  ---------------------- target table API -------------------------

%!  register_remote_target(+RemotePid, +LocalTarget) is det.
%
%   Record where actor-level events for RemotePid should be
%   forwarded locally.  Replaces a prior entry, if any.
register_remote_target(RemotePid, LocalTarget) :-
    retractall(remote_target_(RemotePid, _)),
    assertz(remote_target_(RemotePid, LocalTarget)).


%!  forget_remote_target(+RemotePid) is det.
forget_remote_target(RemotePid) :-
    retractall(remote_target_(RemotePid, _)).


%!  current_remote_target(?RemotePid, ?LocalTarget) is nondet.
current_remote_target(RemotePid, LocalTarget) :-
    remote_target_(RemotePid, LocalTarget).


%  ---------------------- monitor table API ------------------------

%!  add_remote_monitor(+Watcher, +RemotePid, +Ref) is det.
%
%   Record that Watcher is monitoring RemotePid under Ref.
add_remote_monitor(Watcher, RemotePid, Ref) :-
    assertz(remote_monitor_(Watcher, RemotePid, Ref)).


%!  remove_remote_monitor_by_ref(+Ref) is det.
%
%   Remove the monitor identified by Ref (idempotent).
remove_remote_monitor_by_ref(Ref) :-
    retractall(remote_monitor_(_, _, Ref)).


%!  remove_remote_monitor_by_pid(+RemotePid) is det.
%
%   Remove all monitors of RemotePid -- intended for use when the
%   controller has just decided that RemotePid is gone and is
%   delivering down/3 to its watchers.
remove_remote_monitor_by_pid(RemotePid) :-
    retractall(remote_monitor_(_, RemotePid, _)).


%!  take_remote_monitors_for_pid(+RemotePid, -Entries) is det.
%
%   Atomic snapshot-and-clear: returns all current monitors of
%   RemotePid as a list of monitor(Watcher, Ref) terms, and removes
%   them from the table.  Designed for the death-of-remote-pid
%   delivery path, where we want exactly one chance to fire each
%   monitor.
take_remote_monitors_for_pid(RemotePid, Entries) :-
    findall(monitor(Watcher, Ref),
            retract(remote_monitor_(Watcher, RemotePid, Ref)),
            Entries).


%  ----------------------- link table API --------------------------

%!  add_remote_link(+LocalParent, +RemotePid) is det.
add_remote_link(LocalParent, RemotePid) :-
    assertz(remote_link_(LocalParent, RemotePid)).


%!  remove_remote_link(+LocalParent, +RemotePid) is det.
remove_remote_link(LocalParent, RemotePid) :-
    retractall(remote_link_(LocalParent, RemotePid)).


%!  take_remote_children_for_parent(+LocalParent, -Children) is det.
%
%   Atomic snapshot-and-clear: returns all remote children linked
%   from LocalParent and removes the entries.  Intended for the
%   stop/2 path of a local actor whose linked remote children must
%   be killed.
take_remote_children_for_parent(LocalParent, Children) :-
    findall(Child,
            retract(remote_link_(LocalParent, Child)),
            Children).


%  --------------- node-scoped connection-drop helpers ---------------

%!  take_remote_monitors_on_node(+NodeURL, -Entries) is det.
%
%   Atomic snapshot-and-clear of every cross-node monitor whose
%   watched pid resides on NodeURL.  Used by the connection-drop
%   path to fire `down(Ref, CompoundPid, connection_closed)` to
%   every watcher of an actor on the disconnected node.  Each entry
%   in Entries is a term `monitor(Watcher, CompoundPid, Ref)`.
take_remote_monitors_on_node(NodeURL, Entries) :-
    findall(monitor(Watcher, CompoundPid, Ref),
            ( remote_monitor_(Watcher, CompoundPid, Ref),
              CompoundPid = _@NodeURL
            ),
            Entries),
    forall(member(monitor(W, C, R), Entries),
           retractall(remote_monitor_(W, C, R))).


%!  drop_remote_state_for_node(+NodeURL) is det.
%
%   Forget every cross-node target and link record whose remote pid
%   resides on NodeURL.  Called after monitor delivery during a
%   connection drop to leave the controller's tables clean.
drop_remote_state_for_node(NodeURL) :-
    retractall(remote_target_(_@NodeURL, _)),
    retractall(remote_link_(_, _@NodeURL)).
