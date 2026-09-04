%%  Selective receive, deferral, and guards.
%
%   receive/1-2 scans the mailbox for the OLDEST message matching any of
%   its clauses. A message that matches no clause is not an error: it is
%   DEFERRED -- left in the mailbox for a later receive to pick up. A
%   clause head may also carry a guard, written `Pattern if Goal`.
%
%   Here Web Prolog parts company with Erlang. An Erlang guard (`when`)
%   is a test: message x state -> boolean. A Web Prolog guard is an
%   ordinary Prolog goal, proved in the actor's logical environment, so
%   it may not merely TEST the message but REASON about it -- binding
%   fresh variables that never appear in the pattern and letting them
%   flow into the clause body. That is why we write `if`, not `when`.
%
%	@author Torbjörn Lager

%%  greeter/0
%
%   A guarded receive loop. The relational guard husband/2 looks up a
%   guest's husband and passes it to the action; a guest with no known
%   husband falls through to the plain clause.

greeter :-
    receive({
        hello(W) if husband(W, H) ->
            format("Hello ~w, say hello to ~w!~n", [W, H]),
            greeter ;
        hello(W) ->
            format("Hello ~w!~n", [W]),
            greeter ;
        stop ->
            true
    }).

%%  husband(?Wife, ?Husband)
%
%   A tiny knowledge base, shipped into the greeter's private module via
%   src_predicates so the receive guard can consult it.

husband(xantippa, socrates).
husband(calpurnia, caesar).


/** <examples>

% --- Guards that reason ------------------------------------------------
% The pattern binds W; the guard proves husband(W, H), binding H, which
% the action then uses. `plato` has no husband, so the plain clause runs.

?- spawn(greeter, Pid, [
       src_predicates([greeter/0, husband/2])
   ]).

?- $Pid ! hello(xantippa).

?- $Pid ! hello(plato).

?- $Pid ! stop.


% --- Deferral: matching is by pattern, not by arrival order ------------
% goodbye("Bob") is the oldest message but matches neither clause of the
% first receive, so it is deferred and the second receive collects it.

% Each receive uses its OWN pattern variable (Name1, Name2). Reusing one
% name across the two receives would bind it in the first and leave the
% second waiting on an already-ground pattern that never arrives.

?- self(S),
   S ! goodbye("Bob"),
   S ! hello("Alice"),
   receive({ hello(Name1)   -> format("Hello, ~s!~n", [Name1]) }),
   receive({ goodbye(Name2) -> format("Goodbye, ~s!~n", [Name2]) }).


% --- Guards as ordinary tests -----------------------------------------
% A guard can of course still be a plain test over values already bound
% by the pattern. Again each receive gets its own variable (N1, N2).

?- self(S), S ! number(42), S ! number(-7),
   receive({ number(N1) if N1 > 0  -> format("Positive: ~w~n", [N1]) }),
   receive({ number(N2) if N2 =< 0 -> format("Non-positive: ~w~n", [N2]) }).

*/
