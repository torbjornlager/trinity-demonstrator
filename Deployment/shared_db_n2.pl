% n2 is the richer isotope node.

deployment_node(n2).

mortal(X) :-
    human(X).

human(socrates).
human(X) :-
    rpc('https://n1.elfenbenstornet.se', human(X)).

ancestor(X, Y) :-
    ancestor_descendant(X, Y).

descendant(X, Y) :-
    ancestor_descendant(Y, X).

family_member(X) :-
    parent_child(X, _).
family_member(X) :-
    parent_child(_, X).
