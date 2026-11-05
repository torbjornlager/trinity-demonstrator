:- begin_tests(iso_dcg).
:- use_module(iso_dcg).

% Case identifiers follow the public phrase/2 and phrase/3 comparison.
% The runner compares all solutions, including their order, or the exception.
test(numbered, [forall(numbered(Id, Template, Query, Expected))]) :-
    catch(findall(Template, Query, Solutions), error(Formal, _),
          Outcome = error(Formal)),
    (   var(Outcome)
    ->  Outcome = solutions(Solutions)
    ;   true
    ),
    assertion(case(Id, Outcome) =@= case(Id, Expected)).

numbered(1, L, iso_phrase(=, L), solutions([[]])).
numbered(2, ok, iso_phrase(1, _), error(type_error(callable, 1))).
numbered(3, L, iso_phrase(!, L), solutions([[]])).
numbered(4, L, iso_phrase([a], L), solutions([[a]])).
numbered(5, ok, iso_phrase([a|b], _), error(type_error(list, [a|b]))).
numbered(6, ok, iso_phrase([a|_L], _K), error(instantiation_error)).
numbered(7, ok, iso_phrase([a|_L], [a,b]), error(instantiation_error)).
numbered(8, ok, iso_phrase([a|_L], []), error(instantiation_error)).
numbered(9, ok, iso_phrase(([a], []), [a]), solutions([ok])).
numbered(11, ok, iso_phrase(({!,fail}; []), _), solutions([])).
numbered(12, ok, iso_phrase('|'([], [a]), [a]), solutions([ok])).
numbered(13, ok, iso_phrase(({fail}, 1), _), error(type_error(callable, 1))).
numbered(14, L, iso_phrase(([a]; []), L), solutions([[a], []])).
numbered(17, ok, iso_phrase(({L=[]}, [a|L]), [a]), error(instantiation_error)).
numbered(18, ok, (iso_phrase([a|L], _K), L=[b]), error(instantiation_error)).
numbered(19, ok, iso_phrase(([a|_L], 1), []), error(instantiation_error)).
numbered(20, ok, iso_phrase((1, [a|_L]), []), error(type_error(callable, 1))).
numbered(21, ok, iso_phrase((1, [a|b]), []), error(type_error(callable, 1))).
numbered(22, L, iso_phrase('|'(([x]->[y]), [z]), L), solutions([[x,y]])).
numbered(23, L, iso_phrase((([x]->[y]); [z]), L), solutions([[x,y]])).
numbered(27, ok, iso_phrase(\+[a], []), solutions([ok])).
numbered(28, ok, iso_phrase(\+1, _L), error(type_error(callable, 1))).
numbered(29, ok, iso_phrase(([a], \+1), []), solutions([])).
numbered(30, ok, iso_phrase(([a], \+1; []), []), solutions([ok])).
numbered(33, ok, (L=[], iso_phrase([a|L], [b])), solutions([])).
numbered(34, ok, iso_phrase([a], [b]), solutions([])).
numbered(35, L, (iso_phrase(!, [_]); L=1), solutions([1])).
numbered(36, L, (L=[], iso_phrase([a|L], [a])), solutions([[]])).
numbered(38, ok, iso_phrase([a|L], L), error(instantiation_error)).
numbered(39, ok, iso_phrase(_K, _L), error(instantiation_error)).
numbered(40, K-L, (K=[], iso_phrase(K, L)), solutions([[]-[]])).
numbered(41, ok, iso_phrase([], non_list), solutions([])).
numbered(42, ok, iso_phrase([], [a|non_list]), solutions([])).
numbered(43, L, iso_phrase([], L, non_list), solutions([non_list])).
numbered(44, L, iso_phrase([], L, [a|non_list]), solutions([[a|non_list]])).
numbered(45, ok, iso_phrase(([a], phrase(2)), []), solutions([])).
numbered(46, ok, iso_phrase((1, {2}), []), error(type_error(callable, 1))).
numbered(47, ok, iso_phrase(({2}, 1), []), error(type_error(callable, 1))).
numbered(48, ok, iso_phrase((1, (2, [_|_], 3), 4), []),
         error(type_error(callable, 1))).

test(10, [error(type_error(callable, (_ = _, 1, _ = _)))]) :-
    iso_phrase(([a], {1}), []).
test(15, [error(type_error(callable, ((fail,1), _ = _)))]) :-
    iso_phrase({fail,1}, _).
test(16, [throws(h)]) :-
    iso_phrase({throw(h)}, [a]).
% These three cases exercise SWI's handling of the raw (-->)/2 term.
% Record host behavior and remove the test clause before the other probes.
test(host_25, [fail]) :-
    clause((a-->b), _).
test(host_26, [error(existence_error(procedure, _:(-->)/2))]) :-
    call((a-->b)).
test(host_24, [cleanup(abolish((-->)/2))]) :-
    asserta((a-->b)).
test(31, [error(existence_error(procedure, _:phrase/4))]) :-
    iso_phrase(phrase(phrase, []), _).
test(32, [error(existence_error(procedure, _:[]/2))]) :-
    iso_phrase(call([]), []).
test(37, [error(type_error(callable, ((!, _ = _), _ = _, 1, _ = _)))]) :-
    iso_phrase((!, [a], {1}), []).

token --> [a].
test(caller_module) :-
    iso_phrase((token, phrase(token), \+token), [a,a]).
test(variable_body) :-
    iso_phrase(({Body = token}, Body), [a]).
test(cyclic_terminals, [error(type_error(list, _))]) :-
    List = [a|List],
    iso_phrase(List, _).

:- end_tests(iso_dcg).
