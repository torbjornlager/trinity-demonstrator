% Read-only knowledge copied into each SWI-WASM actor.

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

% Shared database used by example 13 shared-database.xml.

shared_fact(browser_shared_db).

% The statechart datamodel defines local_label/1 too.  Its local definition
% shadows this shared one while the chart is running.
local_label(browser_shared_db).

shared_transition_enabled.
