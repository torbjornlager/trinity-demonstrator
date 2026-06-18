/** <module> Default Node Shared Database (layer 4)

The out-of-the-box public knowledge base a node exposes to RELATION /
ISOBASE queries: a few example facts (humans, family relations) plus a
tiny echo-server actor. It is consulted into the node's shared module
rather than declared as its own module, so a deployment can replace it
wholesale with its own data. This is demonstration content, not part of
the node's trusted computing base.
*/

% Default node-wide shared database.

%  The node's advertised contract (surfaced through /node_info and
%  harvested by a discovery hub into node_provides/2) is derived
%  automatically from the predicates this file defines or imports —
%  see node_info_provides/1 — so there is no hand-curated provides/1
%  list to keep in sync.

human(socrates).
human(plato).
human(aristotle).


ancestor_descendant(X, Y) :- parent_child(X, Y).
ancestor_descendant(X, Z) :- parent_child(X, Y), ancestor_descendant(Y, Z).

parent_child(X, Y) :- mother_child(X, Y).
parent_child(X, Y) :- father_child(X, Y).

mother_child(trude, sally).

father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).


echo_server :-
    echo_actor.

echo_actor :-
    receive({
        echo(From, Msg) ->
            From ! echo(Msg),
            echo_actor
    }).

   
alarm :-
    receive({
        ring ->
            writeln('Alarm ringing!'),
            alarm;
        stop ->
            true
    }).


fridge(FoodList0) :-
    receive({
        store(From, Food) ->
            self(Self),
            From ! Self-ok,
            fridge([Food|FoodList0]);
        take(From, Food) ->
            self(Self),
            (   select(Food, FoodList0, FoodList)
            ->  From ! Self-ok(Food),
                fridge(FoodList)
            ;   From ! Self-not_found,
                fridge(FoodList0)
            );
        terminate ->
            true
    }).
    
    


    
