%%  root/0, child/0, grandchild/0
%
%   Lifetime dependence between actors. A spawned actor is, by default,
%   LINKED to its parent (link(true)): when the parent terminates -- for
%   whatever reason -- its children are terminated too, transitively down
%   the whole subtree. The dependence is one-way: a child's death never
%   affects its parent. Passing link(false) detaches a child, leaving a
%   long-lived, unparented actor that no parent teardown will reclaim.
%
%   This is a deliberate departure from Erlang, whose links are symmetric
%   and off by default. Web Prolog builds a one-way parent-owns-child
%   dependence into spawn and makes it the default.
%
%   root/0 spawns a child and blocks; the child spawns a grandchild and
%   blocks; the grandchild just blocks. The only structure is the spawn
%   hierarchy itself. (Each inner spawn ships the code it needs onward
%   with src_predicates, since a public node does not let one actor's
%   predicates cross into another implicitly.)
%
%	@author Adapted from an example in the Web Prolog book.

root :-
    spawn(child, _, [
        src_predicates([child/0, grandchild/0])
    ]),
    receive({}).

child :-
    spawn(grandchild, _, [
        src_predicates([grandchild/0])
    ]),
    receive({}).

grandchild :-
    receive({}).


/** <examples>

% --- The cascade -------------------------------------------------------
% Spawn a three-deep hierarchy. actors/1 lists every live actor: the
% shell, plus root, child and grandchild.

?- spawn(root, Pid, [
       src_predicates([root/0, child/0, grandchild/0])
   ]).

?- actors(Alive).

% Terminate ONLY the root, by force. The child and grandchild go with it
% -- even though we sent a signal to neither. Lifetime dependence
% propagates down the whole subtree.

?- exit($Pid, die).

?- actors(Alive).


% --- The dependence is one-way ----------------------------------------
% The inner actor kills itself immediately, but its parent lives on:

?- spawn((spawn(exit(die)), receive({})), Pid2).

?- actors(Alive).


% --- Declining the link with link(false) ------------------------------
% The outer actor completes at once; the inner actor, spawned detached,
% survives it -- now without a living parent.

?- spawn(spawn(receive({}), _, [link(false)]), Pid3).

?- actors(Alive).

*/
