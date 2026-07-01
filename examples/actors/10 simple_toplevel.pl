%%  mytoplevel(+Pid)
%
%   Spawns a simple toplevel actor that accepts '$call'/2, '$next', and '$stop'
%   messages. The built-in toplevel actor is a lot more powerful with a lot of 
%   options. The purpose of this implementation is just to give an idea how it
%   can be implemented.
%
%	@param	Pid - unified with the pid of the spawned toplevel actor
%	@author


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

?- mytoplevel(Pid, [
       load_predicates([session/2])
   ]).
    
?- mytoplevel_call($Pid, X, member(X, [a,b,c])),
   receive({Msg -> true}).
    
?- mytoplevel_next($Pid),
   receive({Msg -> true}).
    
?- mytoplevel_stop($Pid).
    
*/
