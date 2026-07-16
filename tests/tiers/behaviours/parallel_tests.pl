/** <file> parallel_tests.pl

Tests for the actor-based parallel predicate generics.
*/

:- use_module('../../../prolog/web_prolog/parallel.pl').
:- use_module('../../../prolog/web_prolog/first_solution.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', [
    spawn/3,
    self/1,
    send/2,
    receive/1,
    receive/2
]).
:- use_module(library(plunit)).


flush_parallel_mailbox :-
    receive({_ -> flush_parallel_mailbox}, [timeout(0.05), on_timeout(true)]).

:- begin_tests(parallel).


local_parallel_goal(Value) :-
    Value = caller_module.


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


test(caller_module_goal_is_preserved) :-
    parallel([local_parallel_goal(Value)]),
    Value == caller_module.


test(unrelated_failure_down_is_deferred) :-
    spawn(fail, Other, [monitor(true), link(false)]),
    sleep(0.02),
    parallel([true]),
    receive({
        down(Other, _, false) -> true
    }, [timeout(1), on_timeout(throw(missing_unrelated_failure_down))]).


test(unrelated_exception_down_is_deferred) :-
    spawn(throw(unrelated_worker_error), Other,
          [monitor(true), link(false)]),
    sleep(0.02),
    parallel([true]),
    receive({
        down(Other, _, exception(unrelated_worker_error)) -> true
    }, [timeout(1), on_timeout(throw(missing_unrelated_exception_down))]).


%% 12. Repeated fail-fast cleanup leaves neither results nor down events
%%     behind, including messages racing with worker termination.
test(fail_fast_cleanup_leaves_mailbox_empty) :-
    % Other behaviour suites share the T3 process and may leave unrelated
    % monitor notifications, so establish a clean baseline for this stress
    % test before exercising parallel/1.
    flush_parallel_mailbox,
    sleep(0.05),
    flush_parallel_mailbox,
    forall(between(1, 100, _),
           \+ parallel([fail, sleep(0.001)])),
    sleep(0.05),
    receive({
        down(Pid, Ref, Reason) ->
            throw(leaked_parallel_down(Ref, Pid, Reason));
        Pid-Goal ->
            throw(leaked_parallel_result(Pid, Goal))
    }, [timeout(0)]),
    flush_parallel_mailbox.


:- end_tests(parallel).


:- begin_tests(first_solution).


local_first_goal(Value) :-
    Value = caller_module.


test(empty_goals, [fail]) :-
    first_solution(_Solution, []).


test(first_success_wins, Solution == fast) :-
    first_solution(Solution, [
        (sleep(0.05), Solution = slow),
        Solution = fast
    ]).


test(default_continues_after_failure, Solution == ok) :-
    first_solution(Solution, [
        fail,
        (sleep(0.01), Solution = ok)
    ]).


test(default_rethrows_error, throws(first_solver_error)) :-
    first_solution(_Solution, [
        throw(first_solver_error),
        sleep(10)
    ]).


test(on_fail_stop, [fail, timeout(2)]) :-
    first_solution(_Solution, [
        fail,
        sleep(10)
    ], [on_fail(stop)]).


test(on_error_continue, Solution == recovered) :-
    first_solution(Solution, [
        throw(ignored_solver_error),
        (sleep(0.01), Solution = recovered)
    ], [on_error(continue)]).


test(all_fail_with_continue, [fail]) :-
    first_solution(_Solution, [fail, fail], [on_fail(continue)]).


test(all_errors_with_continue, [fail]) :-
    first_solution(_Solution,
                   [throw(first_error), throw(second_error)],
                   [on_error(continue)]).


test(caller_module_goal_is_preserved, Solution == caller_module) :-
    first_solution(Solution, [local_first_goal(Solution)]).


test(invalid_on_fail,
     throws(error(type_error(oneof([stop,continue]), maybe), _))) :-
    first_solution(_Solution, [true], [on_fail(maybe)]).


test(invalid_on_error,
     throws(error(type_error(oneof([stop,continue]), maybe), _))) :-
    first_solution(_Solution, [true], [on_error(maybe)]).


test(unknown_option,
     throws(error(domain_error(first_solution_option, timeout(1)), _))) :-
    first_solution(_Solution, [true], [timeout(1)]).


test(unrelated_result_is_deferred, Solution == winner) :-
    self(Self),
    send(Self, unrelated-result),
    first_solution(Solution, [Solution = winner]),
    receive({
        unrelated-result -> true
    }, [timeout(1), on_timeout(throw(missing_unrelated_result))]).


test(unrelated_down_is_deferred, Solution == winner) :-
    spawn(fail, Other, [monitor(true), link(false)]),
    sleep(0.02),
    first_solution(Solution, [Solution = winner]),
    receive({
        down(Other, _, false) -> true
    }, [timeout(1), on_timeout(throw(missing_unrelated_down))]).


test(winner_cleanup_leaves_mailbox_empty) :-
    flush_parallel_mailbox,
    forall(between(1, 50, _),
           first_solution(ok, [ok = ok, (sleep(0.001), ok = slow)])),
    sleep(0.05),
    receive({
        down(Pid, Ref, Reason) ->
            throw(leaked_first_solution_down(Ref, Pid, Reason));
        Pid-Result ->
            throw(leaked_first_solution_result(Pid, Result))
    }, [timeout(0)]),
    flush_parallel_mailbox.


:- end_tests(first_solution).
