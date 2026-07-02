% Read-only knowledge copied into each SWI-WASM actor.

list_price(widget, 100).
list_price(gadget, 250).
list_price(gizmo, 400).

price(Item, Price) :-
    list_price(Item, Price).
