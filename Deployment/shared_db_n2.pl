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

% Owner-curated contract, surfaced via /node_info (harvested by a discovery hub).
provides(human/1).
provides(mortal/1).
provides(ancestor/2).
provides(descendant/2).
provides(family_member/1).
