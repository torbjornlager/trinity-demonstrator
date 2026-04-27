% Common shared database loaded by all deployment nodes.


ancestor_descendant(X, Y) :- parent_child(X, Y).
ancestor_descendant(X, Z) :- parent_child(X, Y), ancestor_descendant(Y, Z).

parent_child(X, Y) :- mother_child(X, Y).
parent_child(X, Y) :- father_child(X, Y).

mother_child(trude, sally).

father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).
