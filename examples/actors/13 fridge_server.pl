%%  fridge_server.pl
%
%   A single-node demonstration of the generic server behaviour
%   (server_actor.pl) supervised by supervisor_actor.pl. All queries
%   in the <examples> block are intended to be run from one toplevel,
%   on whichever node the file has been loaded into.
%
%   Two callback predicates are provided:
%
%     - fridge/4   -- original implementation; crashes on unknown
%                     requests.
%     - fridge2/4  -- defensive replacement; same state shape and same
%                     behaviour for valid requests, plus a catch-all
%                     clause that returns an error response instead of
%                     crashing.
%
%   The example shows fail-fast crash + supervisor recovery with the
%   original fridge/4, then hot-upgrades the running server to
%   fridge2/4 to make the bug go away without losing state.

%%  fridge(+Request, +OldState, -Response, -NewState)
%
%   Original implementation. The state is a list of food items;
%   multiple copies of the same food are represented as multiple list
%   elements. Unknown requests have no matching clause and crash the
%   server.

fridge(store(Food), List, ok, [Food|List]).
fridge(take(Food),  List, ok(Food), Rest) :-
    select(Food, List, Rest), !.
fridge(take(_Food), List, not_found, List).


%%  fridge2(+Request, +OldState, -Response, -NewState)
%
%   Defensive replacement. Identical to fridge/4 for valid requests,
%   plus a final catch-all clause that returns error(unknown_request)
%   instead of crashing.

fridge2(store(Food), List, ok, [Food|List]).
fridge2(take(Food),  List, ok(Food), Rest) :-
    select(Food, List, Rest), !.
fridge2(take(_Food), List, not_found, List).
fridge2(_Other,      List, error(unknown_request), List).


/** <examples>

% --- Scene 1: bring up a supervised fridge server. --------------------
%
% The supervisor runs in this toplevel's session. With restart(permanent)
% it will respawn the server (with the empty initial_state) if it
% crashes. The server is registered under the name `fridge`; in this
% single-node setup that is enough for ordinary sends to find it.

?- supervisor_spawn([
       child(fridge, [
           start(server(fridge, [initial_state([])])),
           restart(permanent)
       ])
   ], Sup, [
       load_predicates([fridge/4])
   ]).


% --- Scene 2: synchronous client calls. -------------------------------

?- server_request(fridge, store(milk), Response).

?- server_request(fridge, take(milk), Response).


% --- Scene 3: asynchronous promise / yield. ---------------------------
%
% Between server_promise/3 and server_yield/2 the client is free to do
% other work; the response is collected later via Ref.

?- server_promise(fridge, store(meat), Ref).

?- server_yield($Ref, Response).


% --- Scene 4: fail-fast + supervisor recovery. ------------------------
%
% sore/1 is not a valid request; fridge/4 has no clause for it, so
% the server crashes. server_request/3 installs a monitor under the
% hood, so instead of blocking forever the client surfaces the death
% as the toplevel message
%
%     Unknown message: server_down(false)
%
% Behind the scenes, the supervisor immediately respawns the server
% under the same registered name `fridge`, with state reset to the
% initial empty list -- durable state would need an external store.
% The follow-up server_request goes to the freshly spawned server.

?- server_request(fridge, sore(milk), Response).

?- server_request(fridge, store(eggs), Response).


% --- Scene 5: hot code swap to a defensive callback. ------------------
%
% The bug in fridge/4 is its lack of a catch-all clause. fridge2/4
% adds one that returns error(unknown_request) instead of crashing.
% server_upgrade/3 copies and swaps the callback in place, preserving the
% server's pid, registered name, and current state. The same bad
% request that previously crashed the server now returns an error.

?- server_upgrade(fridge, fridge2, [
       load_predicates([fridge2/4])
   ]).

?- server_request(fridge, sore(milk), Response).

?- server_request(fridge, store(butter), Response).


% --- Scene 6: tear everything down. -----------------------------------

?- supervisor_halt($Sup).

*/
