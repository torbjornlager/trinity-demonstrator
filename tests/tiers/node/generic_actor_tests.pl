/** <file> generic_actor_tests.pl

Profile, sandbox, and actor-module visibility tests for predicate generics.
*/

:- use_module('../../../prolog/web_prolog/isolation.pl').
:- use_module('../../../prolog/web_prolog/node_profile_policy.pl').
:- use_module('../../../prolog/web_prolog/node_sandbox.pl').
:- use_module('../../../prolog/web_prolog/node_execution_context.pl', [
    with_public_execution_profile/2,
    current_public_execution_profile/1
]).
:- use_module('../../../prolog/web_prolog/parallel.pl', [parallel/1]).
:- use_module('../../../prolog/web_prolog/first_solution.pl', [
    first_solution/2
]).
:- use_module(library(plunit)).


:- begin_tests(generic_actor_api).


test(actor_profile_accepts_generics) :-
    profile_check_goal(actor, parallel([true])),
    profile_check_goal(actor, first_solution(_Solution1, [true])),
    profile_check_goal(actor, first_solution(_Solution2, [true], [
        on_fail(continue),
        on_error(stop)
    ])).


test(lower_profile_rejects_parallel,
     throws(error(profile_violation(isobase, goal(parallel([true]))), _))) :-
    profile_check_goal(isobase, parallel([true])).


test(lower_profile_rejects_first_solution,
     throws(error(profile_violation(isobase,
                                    goal(first_solution(Solution, [true]))),
                  _))) :-
    profile_check_goal(isobase, first_solution(Solution, [true])).


test(sandbox_accepts_actor_generics) :-
    sandbox_check_goal_with_options(actor, user, parallel([true]), []),
    sandbox_check_goal_with_options(
        actor, user, first_solution(_Solution, [true], []), []).


test(prepared_actor_imports_generics) :-
    Module = generic_actor_import_test,
    isolation:prepare_actor_module(Module, user, []),
    predicate_property(Module:parallel(_), imported_from(parallel)),
    predicate_property(Module:first_solution(_, _),
                       imported_from(first_solution)),
    predicate_property(Module:first_solution(_, _, _),
                       imported_from(first_solution)).


test(blacklist_runtime_accepts_parallel_compound_goals,
     true([X, Y, Z] == [a, b, c])) :-
    with_public_execution_profile(actor,
        parallel([
            (X = a, sleep(0.01)),
            (Y = b, sleep(0.03)),
            (Z = c, sleep(0.02))
        ])),
    \+ current_public_execution_profile(_).


test(blacklist_runtime_accepts_first_solution_compound_goals,
     Solution == fast) :-
    with_public_execution_profile(actor,
        first_solution(Solution, [
            (sleep(0.03), Solution = slow),
            (sleep(0.01), Solution = fast)
        ])).


:- end_tests(generic_actor_api).
