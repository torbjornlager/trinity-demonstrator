/** <module> The Genealogist's browser-local facts and rules

Inspired by Torbjörn Lager's Pengines tutorial and executed by swi-wasm-node.
Both interfaces use this same domain program. Changes belong to the current
browser session, rather than to a shared server database.
*/

:- dynamic mother_child/2, father_child/2.

% Kinship rules. The two parent roles share the same recursive ancestor rule.
parent_child(Parent, Child) :-
    mother_child(Parent, Child).
parent_child(Parent, Child) :-
    father_child(Parent, Child).

ancestor_descendant(Ancestor, Descendant) :-
    parent_child(Ancestor, Descendant).
ancestor_descendant(Ancestor, Descendant) :-
    parent_child(Ancestor, Intermediate),
    ancestor_descendant(Intermediate, Descendant).

% A shared parent may produce duplicates. Order each pair, then deduplicate it.
sibling_pair(X, Y) :-
    parent_child(Parent, X),
    parent_child(Parent, Y),
    X @< Y.

siblings(X, Y) :-
    setof(A-B, sibling_pair(A, B), Pairs),
    member(X-Y, Pairs).

% A common view for the diagram, relationship list and saved facts.
relationship(mother, Parent, Child) :-
    mother_child(Parent, Child).
relationship(father, Parent, Child) :-
    father_child(Parent, Child).

% Forms use these validated wrappers. The query box remains ordinary Prolog
% and can deliberately bypass them, so this is not a sandbox boundary.
family_name(Name) :-
    atom(Name),
    atom_codes(Name, [First|Rest]),
    length([First|Rest], Length),
    Length =< 32,
    between(0'a, 0'z, First),
    maplist(family_name_code, Rest),
    !.
family_name(Name) :-
    throw(error(domain_error(person_name, Name), _)).

family_name_code(Code) :-
    between(0'a, 0'z, Code),
    !.
family_name_code(Code) :-
    between(0'0, 0'9, Code),
    !.
family_name_code(0'_).

family_role(mother) :- !.
family_role(father) :- !.
family_role(Role) :-
    throw(error(domain_error(parent_role, Role), _)).

%% add_relationship(+Role, +Parent, +Child) is det.
%
% Reject self-parenting and ancestry cycles before asserting a new fact.
% Repeated additions are idempotent; the size limit bounds normal UI updates.
add_relationship(Role, Parent, Child) :-
    family_role(Role),
    family_name(Parent),
    family_name(Child),
    (   (Parent == Child ; ancestor_descendant(Child, Parent))
    ->  throw(error(domain_error(acyclic_family, Parent-Child), _))
    ;   relationship(Role, Parent, Child)
    ->  true
    ;   findall(1, relationship(_, _, _), Facts),
        length(Facts, Count),
        (   Count >= 200
        ->  throw(error(resource_error(family_size), _))
        ;   Role == mother
        ->  assertz(mother_child(Parent, Child))
        ;   assertz(father_child(Parent, Child))
        )
    ).

%% remove_relationship(+Role, +Parent, +Child) is det.
%
% Remove every matching fact, including duplicates introduced by raw queries.
remove_relationship(Role, Parent, Child) :-
    family_role(Role),
    family_name(Parent),
    family_name(Child),
    (   Role == mother
    ->  retractall(mother_child(Parent, Child))
    ;   retractall(father_child(Parent, Child))
    ).

% Sample facts — the original tutorial's small family.
% The download bridge uses this marker to keep the rules above and replace
% the initial facts with the current browser session's facts.
mother_child(trude, sally).
father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).
