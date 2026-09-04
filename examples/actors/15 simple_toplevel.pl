%%  mytoplevel(-Pid)
%
%   A hand-built Prolog toplevel, one step up from the raw backtracking
%   kernel (see "14 backtracking.pl"). That example showed a single goal
%   whose search could be driven one solution at a time by `next`
%   messages. Here that idea is wrapped in a small, reusable PROTOCOL --
%   the seed of the behaviour that powers the real Prolog Web toplevel.
%
%   The spawned session actor understands three messages: '$call'(Template,
%   Goal) starts a goal and reports the first solution; '$next' asks for
%   the following solution (its receive body fails, which backtracks the
%   goal exactly as in the kernel example); '$stop' abandons the search.
%   The trick that makes it reusable is a doubly nested loop: an inner
%   failure-driven loop enumerates one goal's solutions, and an outer
%   recursive loop returns the actor to idle afterwards, ready for the
%   next '$call'. call_cleanup/2 is used to detect whether a solution was
%   the last one (no choice points remain), so the client can be told.
%
%   mytoplevel_call/3, _next/1 and _stop/1 wrap the message protocol
%   behind ordinary predicates, the same API-hiding technique as the
%   fridge. Real programs use the built-in toplevel actors, which are far
%   more capable; this is here to show how such a thing is built.
%
%	@param	Pid - the pid of the spawned toplevel actor.
%	@author A hand-built toplevel sketch, in Web Prolog.


mytoplevel(Pid) :-
    mytoplevel(Pid, []).

mytoplevel(Pid, Options) :-
    self(Self),
    spawn(session(Pid, Self), Pid, Options).

session(Pid, Parent) :-
    receive({
        '$call'(Template, Goal) ->
            (   call_cleanup(Goal, Det=true),
                (   var(Det)
                ->  Parent ! success(Pid, Template, true),
                    receive({
                        '$next' -> fail ;
                        '$stop' -> true
                    }),
                    !
                ;   Parent ! success(Pid, Template, false)
                )
            ;   Parent ! failure(Pid)
            )
    }),
    session(Pid, Parent).


mytoplevel_call(Pid, Template, Goal) :-
    Pid ! '$call'(Template, Goal).

mytoplevel_next(Pid) :-
    Pid ! '$next'.

mytoplevel_stop(Pid) :-
    Pid ! '$stop'.


/** <examples>

% Spawn the toplevel actor. Only session/2 runs inside it.

?- mytoplevel(Pid, [
       src_predicates([session/2])
   ]).

% Start a goal and collect the first solution (X = a). The success
% message also says whether more solutions remain.

?- mytoplevel_call($Pid, X, member(X, [a,b,c])),
   receive({Msg -> true}).

% Ask for the next solution (X = b); each '$next' drives one step of
% backtracking inside the actor. Repeat to reach X = c.

?- mytoplevel_next($Pid),
   receive({Msg -> true}).

% Abandon the search. The actor loops back to idle, ready for another
% '$call'.

?- mytoplevel_stop($Pid).

*/
