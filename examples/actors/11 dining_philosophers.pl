%%  dining is det.
%
%   Dijkstra's Dining Philosophers, the textbook stress test for
%   concurrency, solved with actors. Five philosophers sit around a
%   table, each needing the two forks beside them to eat; naively
%   grabbing forks invites deadlock (everyone holds one, waits for the
%   other) and starvation. This is a larger, more realistic example than
%   ping-pong: several kinds of actor cooperating through messages.
%
%   Deadlock is avoided by introducing arbiters rather than letting
%   philosophers grab forks directly. A `forks` actor owns the forks and
%   answers whether a given pair is free; a `waiter` actor serialises
%   access, seating at most two eaters at once and only when their forks
%   are available. Each philosopher is its own actor cycling through
%   think / hungry / eat, asking the waiter for permission and releasing
%   its forks when done. Registered names (register/2) let the actors
%   address `forks` and `waiter` without passing pids around. When every
%   philosopher has finished its lifespan, the waiter dismisses the forks
%   and the table closes.
%
%   Because the fork accounting lives inside a single arbiter actor
%   rather than in shared, lockable memory, there are no locks anywhere
%   in the program -- mutual exclusion falls out of message ordering.
%
%	@author Ported from a Rosetta Code Erlang program:
%	        https://github.com/acmeism/RosettaCodeData/blob/master/Task/Dining-philosophers/


sleep :-
    Time is random_float/10,
    sleep(Time).

doForks(ForkList) :-
    receive({
        {grabforks, {Left, Right}} ->
            subtract(ForkList, [Left,Right], ForkList1),
            doForks(ForkList1);
        {releaseforks, {Left, Right}} ->
            doForks([Left, Right| ForkList]);
        {available, {Left, Right}, Sender} ->
            (   member(Left, ForkList),
                member(Right, ForkList)
            ->  Bool = true
            ;   Bool = false
            ),
            Sender ! {areAvailable, Bool},
            doForks(ForkList);
        {die} ->
            format("Forks put away.~n")
    }).

areAvailable(Forks, Have) :-
    self(Self),
    forks ! {available, Forks, Self},
    receive({
        {areAvailable, false} ->
            Have = false;
        {areAvailable, true} ->
            Have = true
    }).

processWaitList([], false).
processWaitList([H|T], Result) :-
    {Client, Forks} = H,
    areAvailable(Forks, Have),
    (   Have == true
    ->  Client ! {served},
        Result = true
    ;   Have == false
    ->  processWaitList(T, Result)
    ).

doWaiter([], 0, 0, false) :-
    forks ! {die},
    format("Waiter is leaving.~n"),
    diningRoom ! {allgone}.
doWaiter(WaitList, ClientCount, EatingCount, Busy) :-
    receive({
        {waiting, Client} ->
            WaitList1 = [Client|WaitList],
            (   Busy == false,
                EatingCount < 2
            ->  processWaitList(WaitList1, Busy1)
            ;   Busy1 = Busy
            ),
            doWaiter(WaitList1, ClientCount, EatingCount, Busy1);
        {eating, Client} ->
            subtract(WaitList, [Client], WaitList1),
            EatingCount1 is EatingCount+1,
            doWaiter(WaitList1, ClientCount, EatingCount1, false);
        {finished} ->
            processWaitList(WaitList, R1),
            EatingCount1 is EatingCount-1,
            doWaiter(WaitList, ClientCount, EatingCount1, R1) ;
        {leaving} ->
            ClientCount1 is ClientCount - 1,
            flag(left_received, N, N+1),
            doWaiter(WaitList, ClientCount1, EatingCount, Busy)
    }).

philosopher(Name, _Forks, 0) :-
    format("~s is leaving.~n", [Name]),
    waiter ! {leaving},
    flag(left, N, N+1).
philosopher(Name, Forks, Cycle) :-
    self(Self),
    format("~s is thinking (cycle ~w).~n", [Name, Cycle]),
    sleep,
    format("~s is hungry (cycle ~w).~n", [Name, Cycle]),
    waiter ! {waiting, {Self, Forks}},
    receive({
        {served} ->
            forks ! {grabforks, Forks},
            waiter ! {eating, {Self, Forks}},
            format("~s is eating (cycle ~w).~n", [Name, Cycle])
    }),
    sleep,
    forks ! {releaseforks, Forks},
    waiter ! {finished},
    Cycle1 is Cycle - 1,
    philosopher(Name, Forks, Cycle1).

dining :-
    AllForks = [1, 2, 3, 4, 5],
    Clients = 5,
    self(Self),
    register(diningRoom, Self),
    spawn(doForks(AllForks), ForksPid, [
        src_predicates([doForks/1])
    ]),
    register(forks, ForksPid),
    spawn(doWaiter([], Clients, 0, false), WaiterPid, [
        src_predicates([doWaiter/4, processWaitList/2, areAvailable/2])
    ]),
    register(waiter, WaiterPid),
    Life_span = 20,
    PhilosopherOptions = [
        src_predicates([philosopher/3, sleep/0])
    ],
    spawn(philosopher('Aristotle', {5, 1}, Life_span), _, PhilosopherOptions),
    spawn(philosopher('Kant', {1, 2}, Life_span), _, PhilosopherOptions),
    spawn(philosopher('Spinoza', {2, 3}, Life_span), _, PhilosopherOptions),
    spawn(philosopher('Marx', {3, 4}, Life_span), _, PhilosopherOptions),
    spawn(philosopher('Russel', {4, 5}, Life_span), _, PhilosopherOptions),
    receive({
        {allgone} ->
            format("Dining room closed.~n")
    }),
    unregister(diningRoom).


/** <examples>

% Run the whole table. The philosophers narrate their thinking, hunger
% and eating as the run proceeds; it ends with "Dining room closed." and
% no philosopher ever deadlocks or starves.

?- dining.

*/
