%%  ping_pong/0 is nondet.
%
%	@author https://www.erlang.org/doc/system/conc_prog.html


ping(0, Pong_Pid) :-
    Pong_Pid ! finished,
    format('Ping finished.~n',[]).
ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong ->
            format('Ping received pong.~n',[])
    }),
    N1 is N - 1,
    ping(N1, Pong_Pid).

pong :-
    receive({
        finished ->
            format('Pong finished.~n',[]) ;
        ping(Ping_Pid) ->
            format('Pong received ping.~n',[]),
            Ping_Pid ! pong,
            pong
    }).

ping_pong :-
    spawn(pong, Pong_Pid, [
        load_predicates([pong/0])
    ]),
    spawn(ping(3, Pong_Pid), _, [
        load_predicates([ping/2])
    ]).


/** <examples>

?- ping_pong.
   
*/