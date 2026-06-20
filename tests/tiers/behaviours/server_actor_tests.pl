/** <file> server_actor_tests.pl

Tests for the server behaviour in server_actor.pl.

Loaded into user space (no module declaration) so that callback
predicates defined here are directly accessible when the server loop
calls them -- matching how the interactive examples in the book work.
*/

:- use_module('../../../prolog/web_prolog/server_actor.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', [spawn/3, receive/1, receive/2,
                               monitor/2, self/1]).
:- use_module(library(plunit)).


%% -------------------------------------------------------------------
%% Callback predicates (in user space, accessible from server loop)
%% -------------------------------------------------------------------

%% test_fridge/4 — basic fridge callback used by the generic server tests.
test_fridge(store(Food), FoodList, ok, [Food|FoodList]).
test_fridge(take(Food), FoodList, ok(Food), FoodListRest) :-
    select(Food, FoodList, FoodListRest),
    !.
test_fridge(take(_Food), FoodList, not_found, FoodList).

%% fridge2/4 — upgraded fridge with different response tags.
fridge2(store(Food), FoodList, stored(Food), [Food|FoodList]).
fridge2(take(Food),  FoodList, taken(Food),  Rest) :-
    select(Food, FoodList, Rest), !.
fridge2(take(_Food), FoodList, not_found,    FoodList).

%% counter/4 — simple integer counter.
counter(inc,   N, ok,    N1) :- N1 is N + 1.
counter(dec,   N, ok,    N1) :- N1 is N - 1.
counter(get,   N, val(N), N).
counter(reset, _, ok,    0).

%% crasher_cb/4 — always throws, simulating a buggy callback.
crasher_cb(_, _, _, _) :- throw(crash).

%% echo/4 — echoes the request back, state unchanged.
echo(Request, State, Request, State).

%% blocking_cb/4 — blocks indefinitely (for timeout tests).
blocking_cb(_, State, _, State) :- sleep(3600).


%% -------------------------------------------------------------------
%% Tests
%% -------------------------------------------------------------------

:- begin_tests(server_actor).


%% 1. Basic spawn and single request.
test(basic_spawn_and_request) :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), R),
    R == ok,
    server_halt(Pid, _).


%% 2. State is threaded correctly across multiple requests.
test(state_threading) :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), R1),
    server_request(Pid, store(eggs), R2),
    server_request(Pid, take(milk),  R3),
    server_request(Pid, take(eggs),  R4),
    R1 == ok,
    R2 == ok,
    R3 == ok(milk),
    R4 == ok(eggs),
    server_halt(Pid, _).


%% 3. Missing item returns not_found.
test(take_missing_item) :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, take(bread), R),
    R == not_found,
    server_halt(Pid, _).


%% 4. Initial state is respected.
test(initial_state) :-
    server_spawn(test_fridge, [milk, eggs], Pid),
    server_request(Pid, take(milk), R1),
    server_request(Pid, take(eggs), R2),
    R1 == ok(milk),
    R2 == ok(eggs),
    server_halt(Pid, _).


%% 5. Counter with numeric state.
test(counter_state) :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, _),
    server_request(Pid, inc, _),
    server_request(Pid, inc, _),
    server_request(Pid, dec, _),
    server_request(Pid, get, R),
    R == val(2),
    server_halt(Pid, _).


%% 6. Counter reset.
test(counter_reset) :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, _),
    server_request(Pid, inc, _),
    server_request(Pid, reset, _),
    server_request(Pid, get, R),
    R == val(0),
    server_halt(Pid, _).


%% 7. server_halt returns the acknowledged reply.
test(server_halt_reply) :-
    server_spawn(test_fridge, [], Pid),
    server_halt(Pid, Reply),
    Reply == true.


%% 8. Hot code swap: state preserved, new callback used for subsequent requests.
test(hot_code_swap) :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, store(milk), R1),
    R1 == ok,
    server_upgrade(Pid, fridge2),
    server_request(Pid, take(milk), R2),
    R2 == taken(milk),
    server_halt(Pid, _).


%% 9. Upgrade preserves accumulated state.
test(upgrade_preserves_state) :-
    server_spawn(counter, 0, Pid),
    server_request(Pid, inc, _),
    server_request(Pid, inc, _),
    server_request(Pid, inc, _),
    server_upgrade(Pid, echo),
    %% echo/4 returns the request as the response; state (3) is unchanged.
    server_request(Pid, get, R),
    R == get,
    server_halt(Pid, _).


%% 10. Multiple upgrades in sequence.
test(multiple_upgrades) :-
    server_spawn(test_fridge, [milk], Pid),
    server_upgrade(Pid, fridge2),
    server_upgrade(Pid, test_fridge),
    server_request(Pid, take(milk), R),
    R == ok(milk),
    server_halt(Pid, _).


%% 11. Async: server_promise/server_yield round-trip.
test(async_promise_yield) :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(meat), Ref),
    server_yield(Ref, Response),
    Response == ok,
    server_halt(Pid, _).


%% 12. Multiple outstanding async requests resolve independently.
test(multiple_async_promises) :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(milk), Ref1),
    server_promise(Pid, store(eggs), Ref2),
    server_yield(Ref1, R1),
    server_yield(Ref2, R2),
    R1 == ok,
    R2 == ok,
    server_halt(Pid, _).


%% 13. server_promise/4 and server_yield/4 (fail-fast) complete normally.
test(fail_fast_normal) :-
    server_spawn(test_fridge, [], Pid),
    server_promise(Pid, store(milk), Ref, MonRef),
    server_yield(Ref, MonRef, Response, []),
    Response == ok,
    server_halt(Pid, _).


%% 14. Fail-fast: crashed server raises server_down exception.
test(fail_fast_server_crash,
     throws(server_down(_))) :-
    server_spawn(crasher_cb, [], Pid),
    server_request(Pid, anything, _).


%% 15. A callback with no matching clause is also a crash.  The
%% explicit exit(false) in server_loop/2 must notify the request monitor
%% rather than leaving its caller blocked indefinitely.
test(fail_fast_callback_failure,
     throws(server_down(false))) :-
    server_spawn(test_fridge, [], Pid),
    server_request(Pid, unknown_request, _).


%% 16. server_request/4 with timeout: completes promptly when server is slow.
%%     receive/2 calls the on_timeout goal (default: true) and succeeds;
%%     the request returns with Response unbound after the deadline.
test(request_timeout, [timeout(2)]) :-
    server_spawn(blocking_cb, [], Pid),
    server_request(Pid, anything, Response, [timeout(0.05)]),
    \+ ground(Response).


%% 16. Spawn with name option: server accessible by registered name.
test(named_server) :-
    server_spawn(test_fridge, [], _Pid, [name(test_named_fridge)]),
    server_request(test_named_fridge, store(butter), R),
    R == ok,
    server_halt(test_named_fridge, _).


%% 17. Echo server: response mirrors request.
test(echo_server) :-
    server_spawn(echo, state, Pid),
    server_request(Pid, hello, R),
    R == hello,
    server_halt(Pid, _).


:- end_tests(server_actor).
