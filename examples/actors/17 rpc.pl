%%  rpc(+Node, +Goal) is nondet.
%%  rpc(+Node, +Goal, +Options) is nondet.
%
%   Remote procedure call: run a goal on ANOTHER node and get its answers
%   back here, as if it were a local call. This is where the examples
%   leave a single machine behind -- the whole point of the Prolog Web.
%
%   rpc/2-3 is synchronous and network-transparent: it sends Goal to Node,
%   the remote node proves it, and the bindings come back to bind the
%   caller's variables, with backtracking across the network enumerating
%   further solutions. Because a node hosts no application predicates by
%   default, the interesting question is where the code Goal needs comes
%   from. The Options answer that:
%
%     - src_list/1        -- a list of clauses to install for the call;
%     - src_text/1        -- the same, as program text;
%     - src_predicates/1  -- ship named predicates from THIS session
%                            (edge/2 and path/2 below);
%     - src_uri/1         -- have the remote node load its code from yet
%                            another node, so a call can span three nodes.
%
%   rpc/2-3 also translates a remote exception back into a local one, so
%   remote failures surface through the ordinary Prolog interface. The
%   asynchronous counterpart is promise/3-4 with yield/2-3.
%
%   The edge/2 and path/2 clauses below exist to be shipped to a remote
%   node via src_predicates in one of the example queries.

edge(a, b).
edge(b, c).
edge(c, d).
edge(a, d).

path(X, Y) :- edge(X, Y).
path(X, Y) :- edge(X, Z), path(Z, Y).


/** <examples>

% Call a built-in on a remote node; backtracking enumerates X = a, b, c
% across the network.

?- rpc('https://n1.elfenbenstornet.se', member(X, [a,b,c])).

% Supply the code the call needs -- as a clause list, then as text.

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       src_list([p(a),p(b),p(c)])
   ]).

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       src_text('p(a). p(b). p(c).')
   ]).

% Ship our own local predicates (edge/2, path/2) to the remote node and
% run a recursive query there.

?- rpc('https://n1.elfenbenstornet.se', path(a, X), [
       src_predicates([edge/2, path/2])
   ]).

% A three-node call: n3 runs the goal, loading its code from n2.

?- rpc('https://n3.elfenbenstornet.se', ancestor_descendant(X,Y), [
       src_uri('https://n2.elfenbenstornet.se')
   ]).

?- rpc(localhost, ancestor_descendant(X,Y),
       [src_uri('https://n2.elfenbenstornet.se')
   ]).

*/
