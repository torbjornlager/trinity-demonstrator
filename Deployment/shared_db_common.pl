% Common shared database loaded by all deployment nodes.


ancestor_descendant(X, Y) :- parent_child(X, Y).
ancestor_descendant(X, Z) :- parent_child(X, Y), ancestor_descendant(Y, Z).

parent_child(X, Y) :- mother_child(X, Y).
parent_child(X, Y) :- father_child(X, Y).

mother_child(trude, sally).

father_child(tom, sally).
father_child(tom, erica).
father_child(mike, tom).


:- dynamic human/1.

prove(true, true) :- !.
prove(rpc(URI, A), Proof) :- !,
    prove(rpc(URI, A, []), Proof).
prove(rpc(URI, A, Options), Query@URI/Proof) :- !,
    rpc(URI, prove(A, Query/Proof), [
        load_predicates([prove/2])
      | Options
    ]).
prove((A, B), (ProofA, ProofB)) :- !,
    prove(A, ProofA),
    prove(B, ProofB).
prove(A, A/Proof) :-
    clause(A, B),
    prove(B, Proof).