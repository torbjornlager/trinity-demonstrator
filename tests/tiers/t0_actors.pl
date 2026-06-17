/*  Tier T0: layer-0 actors.pl, stand-alone.

    Loads ONLY prolog/web_prolog/actors.pl and verifies:

      - layer honesty: no isolation/toplevel/distribution/node modules
        (and no legacy src/ modules, no websocket client) are loaded;
      - the local actor semantics adapted from the demonstrator's
        actor_tests.pl (receive, exit, links, monitors, registration,
        delayed send) — with all pid-shape assertions removed, per
        LAYERED_REAL_NODE_PLAN.md §2.4: below T4 pids are opaque;
      - the §2.4 post-mortem guarantees: monitors and exit reasons keyed
        by pid survive actor death, and pids are never reused;
      - the hook contracts: with no hook clauses the defaults apply,
        and a hook clause takes the documented effect.
*/

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module(library(plunit)).

run_tier :-
    layer_honesty,
    run_tests([ t0_receive,
                t0_actors,
                t0_postmortem,
                t0_hooks,
                t0_programs
              ]),
    ensure_mailbox_empty.

%!  layer_honesty is det.
%
%   The mechanical guarantee that layer 0 stands alone: none of the
%   upper layers, none of the legacy src/ modules, and no WebSocket
%   client may be loaded as a side effect of using actors.pl.
layer_honesty :-
    forall(member(M, [ isolation,
                       toplevel_actors,
                       distribution,
                       node,
                       actor,                 % legacy src/actor.pl
                       node_controller,
                       remote_protocol,
                       pid_utils,
                       websocket
                     ]),
           (   current_module(M)
           ->  throw(layer_violation(module_loaded(M)))
           ;   true
           )).

ensure_mailbox_empty :-
    receive({
        Msg ->
            throw(error(unexpected_message_in_shell(Msg),
                       context(ensure_mailbox_empty/0,
                               'shell mailbox not empty after tests')))
    },[
        timeout(0)
    ]).

flush_shell_mailbox :-
    receive({
        _ ->
            flush_shell_mailbox
    },[
        timeout(0),
        on_timeout(true)
    ]).

actor_test_p(a). actor_test_p(b). actor_test_p(c).


                /*******************************
                *           RECEIVE            *
                *******************************/

:- begin_tests(t0_receive, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(receive1, X == bar) :-
   self(Self),
   Self ! foo(bar),
   receive({
       foo(X) -> true
   }).

test(receive2, X == baz) :-
   self(Self),
   Self ! not_matching,
   Self ! foo(bar),
   % The catch-all clause consumes the first mailbox entry, so the later
   % foo(bar) message is handled by the second receive/2 below.
   receive({
       foo(X) -> true;
       _ -> X = baz
   }),
   receive({
       foo(_) -> true
   }).

test(receive3, X == baz) :-
   receive({
       foo(X) -> true
   },[
       timeout(1),
       on_timeout(X = baz)
   ]).

test(receive4, X == baz) :-
   receive({
       foo(X) -> true
   },[
       timeout(0),
       on_timeout(X = baz)
   ]).

test(receive5, Result == [hello, goodbye]) :-
   self(S),
   S ! hello,
   S ! goodbye,
   receive({A -> true}),
   receive({B -> true}),
   Result = [A,B].

test(receive6, X == baz) :-
   self(S),
   S ! foo(baz),
   receive({
       foo(X) if true, true ->
           true
   }).

test(receive7, X == a) :-
   self(S),
   S ! foo,
   receive({
       foo if actor_test_p(X) ->
           true
   }).

test(receive8, X == b) :-
   self(S),
   S ! foo(b),
   receive({
       foo(X) if actor_test_p(Y), X=Y ->
           true
   }).

test(receive9, Result = done) :-
   receive({}, [timeout(1)]),
   Result = done.

test(receive10, Result == done) :-
   self(Self),
   Self ! done,
   receive({
       Result -> true ;
       unreachable ->
           Result = wrong
   }).

test(receive11, Result == done) :-
   self(Self),
   (   true
   ;   Self ! foo(stop),
       receive({
          foo(X) ->
             Self ! X
       })
   ),
   receive({
      stop -> true
   }, [
       timeout(0),
       on_timeout(fail)
   ]),
   Result = done.

:- end_tests(t0_receive).


                /*******************************
                *            ACTORS            *
                *******************************/

:- begin_tests(t0_actors, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(exit_self_reason, Reason == reason) :-
   spawn(exit(reason), Pid, [
       monitor(true)
   ]),
   receive({
       down(_, Pid, Reason) -> true
   }).

test(exit_other_reason, Reason == reason) :-
   spawn((repeat, fail), Pid, [
       monitor(true)
   ]),
   exit(Pid, reason),
   receive({
       down(_, Pid, Reason) -> true
   }).

test(nested_spawn_exit_does_not_abort_parent, Result == true) :-
   self(Self),
   spawn(( spawn(exit(kill)),
           send(Self, ready),
           receive({})
         ),
         Pid,
         [monitor(true)]),
   receive({
       ready -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   exit(Pid, kill),
   receive({
       down(_, Pid, kill) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   Result = true.

test(register_send_by_name, Msg == hello) :-
   self(Pid),
   register(test, Pid),
   test ! hello,
   unregister(test),
   receive({
       Msg -> true
   }).

test(register_cleared_on_exit, Reason == reason) :-
   spawn((repeat, fail), Pid, [
      monitor(true)
   ]),
   register(test2, Pid),
   whereis(test2, Pid2),
   exit(Pid2, reason),
   whereis(test2, undefined),
   unregister(test2),
   receive({
       down(_, Pid2, Reason) -> true
   }).

test(send_to_unknown_name_raises,
     true(Error = error(existence_error(actor_name, noname), _))) :-
   catch(send(noname, msg), Error, true),
   nonvar(Error).

test(service_registry_is_separate,
     [ cleanup(catch(unregister_service(test_service), _, true)),
       true((Visible == undefined, ServicePid == Self, Missing == undefined,
             Error = error(existence_error(actor_name, test_service), _)))
     ]) :-
   self(Self),
   register_service(test_service, Self),
   whereis(test_service, Visible),
   unregister(test_service),
   send(test_service, hello),
   receive({
       hello -> true
   }),
   whereis_service(test_service, ServicePid),
   unregister_service(test_service),
   whereis_service(test_service, Missing),
   catch(send(test_service, hello2), Error, true),
   nonvar(Error).

test(link_kills_children, Result == true) :-
   self(Self),
   spawn(( spawn(( send(Self, child_up),
                   receive({})
                 ), Child, [link(true)]),
           send(Self, spawned(Child)),
           receive({})
         ),
         Parent,
         [link(false)]),
   receive({ child_up -> true }, [timeout(1), on_timeout(fail)]),
   receive({ spawned(Child) -> true }, [timeout(1), on_timeout(fail)]),
   spawn(( monitor(Child, _),
           send(Self, watching),
           receive({
               down(_, Child, _) -> send(Self, child_down)
           })
         ), _Watcher, [link(false)]),
   receive({ watching -> true }, [timeout(1), on_timeout(fail)]),
   exit(Parent, kill),
   receive({
       child_down -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   Result = true.

test(send_with_delay_and_cancel, Result == timeout) :-
   self(Self),
   ID = t0_cancel_id,
   send(Self, delayed(ID), [
       delay(0.4),
       id(ID)
   ]),
   cancel(ID),
   receive({
       delayed(ID) -> Result = delivered
   }, [
       timeout(0.6),
       on_timeout(Result = timeout)
   ]).

test(send_with_delay_delivers, Value == ok) :-
   self(Self),
   send(Self, delayed_value(ok), [
       delay(0.05)
   ]),
   receive({
       delayed_value(Value) -> true
   }, [
       timeout(1),
       on_timeout(Value = timeout)
   ]).

%  cancel/1 cancels *every* pending delayed send sharing the id, not
%  just the first (ported from actor_tests.pl; make_id/1 -> make_ref/1).
test(cancel_all_delayed_sends_with_same_id, Result == timeout) :-
   self(Self),
   make_ref(ID),
   send(Self, delayed(one, ID), [
       delay(0.4),
       id(ID)
   ]),
   send(Self, delayed(two, ID), [
       delay(0.4),
       id(ID)
   ]),
   cancel(ID),
   receive({
       delayed(_, ID) -> Result = delivered
   }, [
       timeout(0.6),
       on_timeout(Result = timeout)
   ]).

test(demonitor_flush_discards_down, Result == clean) :-
   spawn(receive({}), Pid, []),
   monitor(Pid, Ref),
   exit(Pid, kill),
   % Give the down message time to arrive, then flush it away.
   receive({ nothing -> true }, [timeout(0.2), on_timeout(true)]),
   demonitor(Ref, [flush]),
   receive({
       down(Ref, _, _) -> Result = leaked
   }, [
       timeout(0),
       on_timeout(Result = clean)
   ]).

test(spawned_child_inherits_io_target, Data == hello_io) :-
   self(Self),
   message_queue_create(Queue),
   with_io_target(Queue,
                  ( spawn(terminal_output(hello_io), _Pid, [link(false)]),
                    thread_get_message(Queue, terminal_output(_, Data),
                                       [timeout(1)])
                  )),
   message_queue_destroy(Queue).

:- end_tests(t0_actors).


                /*******************************
                *     POST-MORTEM (§2.4)       *
                *******************************/

:- begin_tests(t0_postmortem, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

%  The monitor table is keyed by pid; delivery must work even when the
%  monitor fires well after the actor's thread has died and been
%  reclaimed (this is what forbids recycled pid representations).
test(down_reason_survives_thread_death, Reason == custom_reason) :-
   spawn(exit(custom_reason), Pid, [
       monitor(true)
   ]),
   receive({
       down(_, Pid, Reason) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(pids_are_never_reused, Result == all_distinct) :-
   findall(Pid,
           ( between(1, 20, _),
             spawn(true, Pid, [link(false)])
           ),
           Pids),
   sort(Pids, Sorted),
   length(Pids, N),
   length(Sorted, N),
   Result = all_distinct.

test(send_to_dead_pid_is_silent, Result == ok) :-
   self(Self),
   spawn(send(Self, done), Pid, [link(false)]),
   receive({ done -> true }, [timeout(1), on_timeout(fail)]),
   % Let the actor finish dying, then send into the void.
   receive({ nothing -> true }, [timeout(0.2), on_timeout(true)]),
   send(Pid, into_the_void),
   Result = ok.

test(exit_dead_pid_is_silent, Result == ok) :-
   self(Self),
   spawn(send(Self, done), Pid, [link(false)]),
   receive({ done -> true }, [timeout(1), on_timeout(fail)]),
   receive({ nothing -> true }, [timeout(0.2), on_timeout(true)]),
   exit(Pid, kill),
   Result = ok.

:- end_tests(t0_postmortem).


                /*******************************
                *         HOOK CONTRACTS       *
                *******************************/

:- begin_tests(t0_hooks, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

%  With no hook clauses, a node(N) spawn option for a non-local node
%  must raise: there is no distribution layer to take it.
test(spawn_remote_without_distribution_raises,
     true(Error = error(existence_error(procedure, _), _))) :-
   catch(spawn(true, _Pid, [node('http://example.org')]), Error, true),
   nonvar(Error).

%  node(localhost) is the documented default and stays local.
test(spawn_node_localhost_is_local, Msg == from_local) :-
   self(Self),
   spawn(send(Self, from_local), _Pid, [node(localhost), link(false)]),
   receive({
       from_local -> Msg = from_local
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

%  Hook implementations are static multifile clauses (as the real
%  layers define them), gated here by dynamic test flags so each test
%  controls when its clause is live.

:- dynamic t0_mint_override/1.
:- dynamic t0_admit_cap/1.
:- dynamic t0_thread_opts/1.

actors:hook_send(divert(Target), Message) :-
   actors:send(Target, diverted(Message)).

actors:hook_make_pid(Pid) :-
   t0_mint_override(Pid).

actors:hook_admit_spawn(LiveCount, _Options) :-
   t0_admit_cap(Max),
   LiveCount >= Max,
   throw(error(resource_error(actors), context(t0, over_cap))).

actors:hook_thread_options(Opts) :-
   t0_thread_opts(Opts).

%  hook_send takeover: a clause that claims a pid shape diverts
%  delivery before any local resolution happens.
test(hook_send_takeover, true(Got == diverted(hello))) :-
   self(Self),
   send(divert(Self), hello),
   receive({
       diverted(X) -> Got = diverted(X)
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

%  hook_make_pid takeover: the distribution layer mints pids through
%  this hook; verify a custom minting clause is honored and the actor
%  is fully functional under the foreign pid.
test(hook_make_pid_takeover, [
        true(Pid == my_pid_1),
        setup(assertz(t0_mint_override(my_pid_1))),
        cleanup(retractall(t0_mint_override(_)))
     ]) :-
   self(Self),
   spawn(send(Self, minted), Pid, [link(false)]),
   receive({
       minted -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

%  hook_admit_spawn: a clause that throws once the live-actor count
%  reaches a cap rejects the spawn (the node's global concurrency
%  cap). With the cap set absurdly low, the very next spawn is denied.
test(hook_admit_spawn_rejects_over_cap, [
        true(Error = error(resource_error(actors), _)),
        setup(assertz(t0_admit_cap(1))),
        cleanup(retractall(t0_admit_cap(_)))
     ]) :-
   catch(spawn(true, _Pid, [link(false)]), Error, true),
   nonvar(Error).

%  Without the cap clause active, spawning is unbounded (default).
test(spawn_unbounded_without_admit_cap, Msg == ok) :-
   self(Self),
   spawn(send(Self, ok), _Pid, [link(false)]),
   receive({ ok -> Msg = ok }, [timeout(1), on_timeout(fail)]).

%  hook_thread_options: a tiny stack_limit passed through to the
%  actor thread makes a memory-hungry goal die with resource_error,
%  while the rest of the node is unaffected — the per-actor memory
%  ceiling, in miniature.
test(hook_thread_options_caps_actor_memory, [
        setup(assertz(t0_thread_opts([stack_limit(1000000)]))),
        cleanup(retractall(t0_thread_opts(_)))
     ]) :-
   spawn(length(_, 100000000), Pid, [monitor(true), link(false)]),
   receive({
       down(_, Pid, Reason) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]),
   assertion(Reason = exception(error(resource_error(_), _))).

:- end_tests(t0_hooks).


                /*******************************
                *           PROGRAMS           *
                *******************************/

%  The demonstrator's actor_tests.pl `programs` group: small end-to-end
%  actor programs (echo/count servers, priority receive, a fridge, a
%  generic server, a process ring, ping-pong) that exercise the actor
%  core in combination.  Ported verbatim except for the make_id/1 ->
%  make_ref/1 rename in rpc_synch/3 (the layer-0 monitor-reference
%  primitive was renamed in prolog/web_prolog/actors.pl).  program8
%  (myfindall) needs the toplevel layer and lives in T2.

program_echo_server  :-
   receive({
      echo(Pid, Msg) ->
         Pid ! Msg,
         program_echo_server
   }).

program_count_server(Count0) :-
   receive({
      count(From) ->
         Count is Count0 + 1,
         From ! Count,
         program_count_server(Count);
      stop ->
         true
   }).

important(Messages) :-
   receive({
      Priority-Message if Priority > 10 ->
         Messages = [Message|MoreMessages],
         important(MoreMessages)
   },[ timeout(0),
       on_timeout(normal(Messages))
   ]).

normal(Messages) :-
   receive({
      _-Message ->
         Messages = [Message|MoreMessages],
         normal(MoreMessages)
   },[ timeout(0),
       on_timeout(Messages=[])
   ]).

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

server(Pred, State0) :-
    receive({
        rpc(From, Ref, Request) ->
            call(Pred, Request, State0, Response, State),
            From ! Ref-Response,
            server(Pred, State);
        upgrade(Pred1) ->
            server(Pred1, State0);
        terminate ->
            true
    }).

fridge(store(Food), FoodList, ok, [Food|FoodList]).
fridge(take(Food), FoodList, ok(Food), FoodListRest) :-
    select(Food, FoodList, FoodListRest), !.
fridge(take(_Food), FoodList, not_found, FoodList).

rpc_synch(To, Request, Response) :-
    self(Self),
    make_ref(Ref),
    To ! rpc(Self, Ref, Request),
    receive({
        Ref-Response -> true
    }).

ring(NumberProcesses, Message) :-
   spawn(create(NumberProcesses, Message)).

create(NumberProcesses, Message) :-
   self(Self),
   create(NumberProcesses, Self, Message).

create(1, NextProcess, Message) :- !,
   self(Self),
   format("Process ~p connected with ~p~n", [Self, NextProcess]),
   format("Process ~p injects message ~p~n", [Self, Message]),
   NextProcess ! Message.
create(NumberProcesses, NextProcess, Message) :-
   spawn(loop(NextProcess), Prev, [
       link(true)
   ]),
   format("Process ~p created and connected with ~p~n", [Prev, NextProcess]),
   NumberProcesses1 is NumberProcesses - 1,
   create(NumberProcesses1, Prev, Message).

loop(NextProcess) :-
   receive({
      Msg ->
         format("Got message ~p, passing it to ~p~n", [Msg, NextProcess]),
         NextProcess ! Msg
    }).

ping(0, Pong_Pid) :-
    Pong_Pid ! finished,
    format('Ping finished~n',[]).
ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong ->
            format('Ping received pong~n',[])
    }),
    N1 is N - 1,
    ping(N1, Pong_Pid).

pong :-
    receive({
        finished ->
            format('Pong finished~n',[]);
        ping(Ping_Pid) ->
            format('Pong received ping~n',[]),
            Ping_Pid ! pong,
            pong
    }).

ping_pong :-
    spawn(pong, Pong_Pid, [
        monitor(true)
    ]),
    spawn(ping(3, Pong_Pid), Ping_Pid, [
        monitor(true)
    ]),
    receive({
       down(_, Ping_Pid, true) ->
          true
    }),
    receive({
       down(_, Pong_Pid, true) ->
          true
    }).

:- begin_tests(t0_programs, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(program1, Msg == hello) :-
   spawn(program_echo_server, Pid, [
      monitor(true)
   ]),
   self(Self),
   Pid ! echo(Self, hello),
   receive({Msg -> true}),
   Pid ! echo(Self, hello),
   receive({Msg -> true}),
   exit(Pid, kill),
   receive({
       down(_, Pid, kill) -> true
   }).

test(program2, Count == 3) :-
   spawn(program_count_server(0), Pid, [
      monitor(true)
   ]),
   self(Self),
   Pid ! count(Self),
   receive({Count1 -> true}),
   Pid ! count(Self),
   receive({Count2 -> true}),
   Count is Count1 + Count2,
   Pid ! stop,
   receive({
       down(_, Pid, true) -> true
   }).

test(program3, Messages == [high,high,low,low]) :-
    self(S),
    S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high,
    important(Messages),
    S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high,
    important(Messages).

test(program4, Response == ok(cheese)) :-
   spawn(fridge([]), Pid, [
       monitor(true)
   ]),
   store(Pid, cheese, ok),
   take(Pid, cheese, Response),
   Pid ! terminate,
   receive({
       down(_, Pid, true) -> true
   }).

test(program5, Response == ok(meat)) :-
   spawn(server(fridge, []), Pid, [
       monitor(true)
   ]),
   rpc_synch(Pid, store(meat), ok),
   rpc_synch(Pid, take(meat), Response),
   Pid ! upgrade(fridge),
   rpc_synch(Pid, store(meat), ok),
   rpc_synch(Pid, take(meat), Response),
   Pid ! terminate,
   receive({
       down(_, Pid, true) -> true
   }).

test(program6, Done == true) :-
   ring(12, hello),
   sleep(0.1),
   Done = true.

test(program7, Done == true) :-
    ping_pong,
    sleep(0.05),
    flush_shell_mailbox,
    Done = true.

:- end_tests(t0_programs).
