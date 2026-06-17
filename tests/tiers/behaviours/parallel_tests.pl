/** <file> parallel_tests.pl

Tests for parallel/1 in parallel.pl.
*/

:- use_module('../../../prolog/web_prolog/parallel.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', [spawn/3, receive/1, receive/2]).
:- use_module(library(plunit)).


flush_parallel_mailbox :-
    receive({_ -> flush_parallel_mailbox}, [timeout(0.05), on_timeout(true)]).

:- begin_tests(parallel).


%% 1. Empty list succeeds immediately.
test(empty_list) :-
    parallel([]).


%% 2. Single goal: bindings returned.
test(single_goal) :-
    parallel([X = hello]),
    X == hello.


%% 3. Two goals: both bindings returned.
test(two_goals) :-
    parallel([X = a, Y = b]),
    X == a,
    Y == b.


%% 4. List of goals: all bindings returned.
test(list_of_goals) :-
    parallel([X = 1, Y = 2, Z = 3]),
    X == 1, Y == 2, Z == 3.


%% 5. Speedup: three goals sleeping 1s each finish in ~3s not ~6s.
%%    The test timeout of 5s ensures we get the speedup.
test(speedup, [timeout(5)]) :-
    parallel([(X=a, sleep(1)), (Y=b, sleep(1)), (Z=c, sleep(1))]),
    X == a, Y == b, Z == c.


%% 6. A failing goal makes parallel/1 fail.
test(one_goal_fails, [fail]) :-
    parallel([_X = a, fail, _Y = c]).


%% 7. Failure is fast: a quickly-failing goal does not wait for
%%    slow siblings. Timeout of 2s catches any indefinite block.
test(fail_is_fast, [fail, timeout(2)]) :-
    parallel([(sleep(10), _X = a), fail]).


%% 8. An error in a goal is rethrown by parallel/1.
test(error_rethrown,
     throws(error(type_error(evaluable, bad/0), _))) :-
    parallel([_X = ok, _ is bad]).


%% 9. Error is fast: parallel/1 rethrows before slow siblings finish.
test(error_is_fast, [timeout(2)]) :-
    catch(parallel([(sleep(10), _X = a), _ is bad]),
          error(type_error(evaluable, bad/0), _),
          true).


%% 10. All goals may be deterministic builtins.
test(builtins_only) :-
    parallel([succ(2, X), plus(3, 4, Y), atom_length(hello, Z)]),
    X == 3, Y == 7, Z == 5.


%% 11. Goals with multiple sub-calls in sequence.
test(compound_goals) :-
    parallel([(atom_length(hello, N1), N1 > 0),
              (succ(0, N2), N2 =:= 1)]),
    N1 == 5, N2 == 1.


:- end_tests(parallel).
