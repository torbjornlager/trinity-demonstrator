% Read-only knowledge copied into each SWI-WASM actor.

ancestor_descendant(X, Y) :-
    parent_child(X, Y).
ancestor_descendant(X, Z) :-
    parent_child(X, Y),
    ancestor_descendant(Y, Z).

parent_child(X, Y) :-
    mother_child(X, Y).
parent_child(X, Y) :-
    father_child(X, Y).

mother_child(trude, sally).

father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).



list_price(widget, 100).
list_price(gadget, 250).
list_price(gizmo, 400).

price(Item, Price) :-
    list_price(Item, Price).



echo_actor :-
    receive({
        echo(From, Msg) ->
            From ! echo(Msg),
            echo_actor
    }).
    
count_actor(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_actor(Count) ;
        stop ->
            true
    }).


% Shared database used by example 13 shared-database.xml.

shared_fact(browser_shared_db).

% The statechart datamodel defines local_label/1 too.  Its local definition
% shadows this shared one while the chart is running.
local_label(browser_shared_db).

shared_transition_enabled.
