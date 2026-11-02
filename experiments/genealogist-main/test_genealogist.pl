:- begin_tests(genealogist).
:- consult(genealogist).

restore_sample :-
    retractall(mother_child(_, _)), retractall(father_child(_, _)),
    assertz(mother_child(trude, sally)),
    assertz(father_child(tom, sally)), assertz(father_child(tom, erica)),
    assertz(father_child(mike, tom)).

test(original_ancestors, set(Who == [erica,sally,tom])) :- ancestor_descendant(mike, Who).
test(siblings_without_duplicates, all(X-Y == [erica-sally])) :- siblings(X, Y).
test(update_reaches_recursive_queries, [setup(restore_sample),cleanup(restore_sample)]) :-
    add_relationship(mother, erica, alex), once(ancestor_descendant(mike, alex)),
    remove_relationship(mother, erica, alex), \+ ancestor_descendant(mike, alex).
test(duplicate_is_idempotent, [setup(restore_sample),cleanup(restore_sample)]) :-
    add_relationship(father, tom, sally), findall(1, father_child(tom,sally), [1]).
test(cycle_rejected, [throws(error(domain_error(acyclic_family,_),_))]) :- add_relationship(father, sally, mike).
test(self_parent_rejected, [throws(error(domain_error(acyclic_family,_),_))]) :- add_relationship(mother, erica, erica).
test(invalid_name_rejected, [throws(error(domain_error(person_name,_),_))]) :- add_relationship(father, 'not a name', alex).
test(variable_name_rejected, [throws(error(domain_error(person_name,_),_))]) :- add_relationship(father, _, alex).
test(invalid_role_rejected, [throws(error(domain_error(parent_role,_),_))]) :- add_relationship(other, tom, alex).
:- end_tests(genealogist).
