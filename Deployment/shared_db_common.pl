% Common shared database loaded by every deployment node.
% Holds the family relations used in the tutorial's local and distributed
% Prolog sections.

ancestor_descendant(X, Y) :- parent_child(X, Y).
ancestor_descendant(X, Z) :-
    parent_child(X, Y),
    ancestor_descendant(Y, Z).

parent_child(X, Y) :- mother_child(X, Y).
parent_child(X, Y) :- father_child(X, Y).

mother_child(trude, sally).

father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).

% Owner-curated contract, surfaced via /node_info (harvested by a discovery hub).
provides(ancestor_descendant/2).
provides(parent_child/2).
