%%  myparallel(+Goals)
%
%   Two small combinators that use actors and monitors to run ordinary
%   Prolog goals concurrently -- putting the failure and monitoring
%   machinery of the earlier examples to work as a control abstraction.
%
%   myparallel/1 spawns one monitored actor per goal (monitor(true)),
%   then waits. If every goal succeeds it succeeds; if any goal fails or
%   throws, that outcome arrives as a down/3 message and myparallel/1
%   immediately kills the remaining actors and fails or rethrows. This is
%   the point of monitors: a parent observes how its children ended --
%   normal success (true), logical failure (false), or exception(E) --
%   and reacts, without sharing state with them.
%
%   This is teaching code, and honestly flawed: it races on the shared
%   mailbox and does not perfectly tidy up in every interleaving. The
%   Web Prolog book develops a correct version. It is included because
%   the SHAPE of the solution -- spawn, monitor, collect down/3, clean up
%   -- is exactly what a robust parallel combinator looks like.
%
%	@param	Goals - the goals to run concurrently.
%	@author Torbjörn Lager

myparallel(Goals) :-
    maplist(par_solve, Goals, Pids),
    maplist(par_yield(Pids), Pids, Goals).

par_solve(Goal, Pid) :-
    self(Self),
    spawn((call(Goal), Self ! Pid-Goal), Pid, [
        monitor(true)
    ]).

par_yield(Pids, Pid, Goal) :-
    receive({
        Pid-Goal ->
            receive({
                down(Pid, _, true) ->
                    true
            }) ;
        down(_, _, false) ->
            tidy_up_all(Pids),
            fail ;
        down(_, _, exception(E)) ->
            tidy_up_all(Pids),
            throw(E)
    }).
    
    
%%  myfirst_solution(-Solution, +Goals)
%
%   A racing combinator: run all Goals in parallel and keep the result of
%   whichever finishes first, discarding the rest. Where myparallel/1
%   waits for ALL goals, this waits for the FIRST and then tears the
%   losers down.
%
%   Each goal runs in its own monitored actor that sends its result back
%   on success. wait_first/2 takes the first result to arrive, kills the
%   still-running actors (exit/2) and drains their pending messages;
%   goals that merely fail are dropped, while an exception from any goal
%   is propagated. It is the natural pattern for "try several strategies,
%   take the quickest answer".
%
%	@param	Solution - unified with the first successful result.
%	@param	Goals    - the goals to race against each other.
%	@author Torbjörn Lager

myfirst_solution(Solution, Goals) :-
    maplist(first_solve(Solution), Goals, Pids),
    wait_first(Pids, Solution).

first_solve(Solution, Goal, Pid) :-
    self(Self),
    spawn((call(Goal), Self ! Pid-Solution), Pid, [
        monitor(true)
    ]).

wait_first([], _) :- !, fail.
wait_first(Pids, Solution) :-
    receive({
        _ - Solution ->
            tidy_up_all(Pids) ;
        down(Pid, _, false) ->
            select(Pid, Pids, Rest),
            wait_first(Rest, Solution) ;
        down(_, _, exception(Error)) ->
            tidy_up_all(Pids),
            throw(Error)
    }).


%%  Utility predicate
%

tidy_up_all(Pids) :-
    maplist(tidy_up, Pids).

tidy_up(Pid) :-
    demonitor(Pid),
    exit(Pid, kill),
    drain_mailbox(Pid).

drain_mailbox(Pid) :-
    receive({
        Msg if arg(1, Msg, Pid) ->
            drain_mailbox(Pid)
    }, [
        timeout(0)
    ]).


/** <examples>

% All three goals succeed. time/1 shows the whole thing takes about as
% long as the SLOWEST goal, not their sum -- they really did run at once.

?- time(myparallel([(X=a,sleep(1)),(Y=b,sleep(3)),(Z=c,sleep(2))])).

% One goal fails: myparallel/1 fails fast, killing the others rather than
% waiting for them.

?- time(myparallel([(X=a,sleep(1)),(Y=b,fail),(Z=c,sleep(2))])).

% One goal throws (sleep(a) is a type error): the exception propagates
% out, again after tearing the siblings down.

?- time(myparallel([(X=a,sleep(1)),(Y=b,sleep(a)),(Z=c,sleep(2))])).

% Race two goals; the faster one (1s) wins and binds X=b, the slower is
% cancelled.

?- time(myfirst_solution(X, [(sleep(2),X=a),(sleep(1),X=b)])).

*/
