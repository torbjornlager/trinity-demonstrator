% The Genealogist — browser-local knowledge and rules.
% Inspired by Torbjörn Lager's Pengines tutorial; executed by swi-wasm-node.
% All updates belong to this browser session, not a shared server database.
:- dynamic mother_child/2, father_child/2.

parent_child(Parent, Child) :- mother_child(Parent, Child).
parent_child(Parent, Child) :- father_child(Parent, Child).

ancestor_descendant(Ancestor, Descendant) :- parent_child(Ancestor, Descendant).
ancestor_descendant(Ancestor, Descendant) :-
    parent_child(Ancestor, Intermediate),
    ancestor_descendant(Intermediate, Descendant).

sibling_pair(X, Y) :- parent_child(P, X), parent_child(P, Y), X @< Y.
siblings(X, Y) :- setof(A-B, sibling_pair(A, B), Pairs), member(X-Y, Pairs).

relationship(mother, Parent, Child) :- mother_child(Parent, Child).
relationship(father, Parent, Child) :- father_child(Parent, Child).

% The form calls these wrappers rather than constructing assert/retract goals.
% Names are deliberately simple Prolog atoms: a-z followed by a-z, 0-9 or _.
family_name(Name) :-
    atom(Name), atom_codes(Name, [First|Rest]),
    length([First|Rest], Length), Length =< 32,
    between(0'a, 0'z, First), maplist(family_name_code, Rest), !.
family_name(Name) :- throw(error(domain_error(person_name, Name), _)).
family_name_code(C) :- between(0'a, 0'z, C), !.
family_name_code(C) :- between(0'0, 0'9, C), !.
family_name_code(0'_).

family_role(mother) :- !.
family_role(father) :- !.
family_role(Role) :- throw(error(domain_error(parent_role, Role), _)).

add_relationship(Role, Parent, Child) :-
    family_role(Role), family_name(Parent), family_name(Child),
    ( (Parent == Child ; ancestor_descendant(Child, Parent))
    -> throw(error(domain_error(acyclic_family, Parent-Child), _))
    ; relationship(Role, Parent, Child) -> true
    ; findall(1, relationship(_, _, _), Facts), length(Facts, Count),
      ( Count >= 200 -> throw(error(resource_error(family_size), _))
      ; Role == mother -> assertz(mother_child(Parent, Child))
      ; assertz(father_child(Parent, Child))
      )
    ).

remove_relationship(Role, Parent, Child) :-
    family_role(Role), family_name(Parent), family_name(Child),
    ( Role == mother -> retractall(mother_child(Parent, Child))
    ; retractall(father_child(Parent, Child))
    ).

% Sample facts — the original tutorial's small family.
mother_child(trude, sally).
father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).
