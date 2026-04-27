% n4 is the second public actor-demo node.

deployment_node(n4).

service(counter, meta(actor, protocol(count_v1))).
service(pubsub_service, meta(actor, protocol(pubsub_v1))).

echo_server :-
    echo_actor.

echo_actor :-
    receive({
        echo(From, Msg) ->
            From ! echo(Msg),
            echo_actor
    }).

:- dynamic human/1.

human(plato).
human(aristotle).

count_actor(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_actor(Count) ;
        stop ->
            true
    }).

alarm :-
    receive({
        ring ->
            writeln('Alarm ringing!'),
            alarm;
        stop ->
            true
    }).

fridge(FoodList0) :-
    receive({
        store(From, Food) ->
            self(Self),
            From ! Self-ok,
            fridge([Food|FoodList0]);
        take(From, Food) ->
            self(Self),
            (   select(Food, FoodList0, FoodList)
            ->  From ! Self-ok(Food),
                fridge(FoodList)
            ;   From ! Self-not_found,
                fridge(FoodList0)
            );
        terminate ->
            true
    }).

%% Server-behaviour callbacks used by the "The server behaviour"
%% section of the tutorial. fridge/4 crashes on unknown requests;
%% fridge2/4 is the defensive replacement that returns an error.

fridge(store(Food), List, ok, [Food|List]).
fridge(take(Food),  List, ok(Food), Rest) :-
    select(Food, List, Rest), !.
fridge(take(_Food), List, not_found, List).

fridge2(store(Food), List, ok, [Food|List]).
fridge2(take(Food),  List, ok(Food), Rest) :-
    select(Food, List, Rest), !.
fridge2(take(_Food), List, not_found, List).
fridge2(_Other,      List, error(unknown_request), List).

store(Pid, Food, Response) :-
    self(Self),
    Pid ! store(Self, Food),
    receive({
        Pid-Response -> true
    }).

take(Pid, Food, Response) :-
    self(Self),
    Pid ! take(Self, Food),
    receive({
        Pid-Response -> true
    }).

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
    spawn(pong, Pong_Pid),
    spawn(ping(3, Pong_Pid)).
