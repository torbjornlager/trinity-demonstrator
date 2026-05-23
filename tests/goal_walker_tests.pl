/** <file> goal_walker_tests.pl

Tests for goal_walker:walk_goal/2.
*/

:- use_module('../src/goal_walker.pl').
:- use_module(library(plunit)).


accept_non_fail(Goal) :-
    Goal \= fail.


:- begin_tests(goal_walker).


test(compound_leaf_failure_propagates, [fail]) :-
    walk_goal(accept_non_fail, (true, fail)).


:- end_tests(goal_walker).
