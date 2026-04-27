/*  Top-level actor tests extracted from actor_tests.pl */

:- use_module('../actor.pl').
:- use_module('../toplevel_actor.pl').

:- use_module(library(plunit)).


:- begin_tests(toplevels).

sample_wife(socrates, xantippa).
sample_wife(aristotle, pythias).

test(simple, Results == [a,b,c]) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_call(Pid, member(X, [a,b,c]), [
       template(X)
   ]),
   receive({
       success(Pid, Results, false) ->
           true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(simple_load_list, Results == [1,2]) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true),
       load_list([ta(1),ta(2)])
   ]),
   toplevel_call(Pid, ta(X), [
       template(X)
   ]),
   receive({
       success(Pid, Results, false) ->
           true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(session_exposes_actor_primitives) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid, self(Self), [
       template(Self)
   ]),
   receive({
       success(Pid, [Self0], false) ->
           assertion(nonvar(Self0))
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(session_spawn_monitor_receive_down) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid,
                 ( spawn(2 > 1, Child, [monitor(true)]),
                   receive({down(_, Child, Reason) -> true})
                 ),
                 [template(Child-Reason)]),
   receive({
       success(Pid, [Child0-Reason0], false) ->
           assertion(nonvar(Child0)),
           assertion(Reason0 == true)
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(session_spawn_monitor_flush_output) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid, spawn(2 > 1, Child, [monitor(true)]), [
       template(Child)
   ]),
   receive({
       success(Pid, [Child0], false) ->
           assertion(nonvar(Child0))
   }),
   toplevel_call(Pid, flush, [
       template(true)
   ]),
   receive({
       terminal_output(Pid, Text) ->
           assertion(sub_string(Text, _, _, _, "Shell got down(")),
           assertion(sub_string(Text, _, _, _, "true"))
   }),
   receive({
       success(Pid, [true], false) -> true
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(session_link_default_child_dies_with_parent) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid,
                 ( self(Self),
                   spawn((spawn(receive({ping(From) -> From ! pong}), Child),
                          Self ! child(Child)), _Parent),
                   receive({child(Child) -> true}),
                   sleep(0.2),
                   Child ! ping(Self),
                   receive({
                       pong -> writeln('Unexpected pong.')
                   }, [
                       timeout(0.2),
                       on_timeout(writeln('No pong arrived.'))
                   ])
                 ),
                 [template(true)]),
   receive({
       terminal_output(Pid, Text) ->
           assertion(sub_string(Text, _, _, _, "No pong arrived."))
   }),
   receive({
       success(Pid, [true], false) -> true
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(session_link_false_child_survives_parent) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid,
                 ( self(Self),
                   spawn((spawn(receive({ping(From) -> From ! pong}), Child, [link(false)]),
                          Self ! child(Child)), _Parent),
                   receive({child(Child) -> true}),
                   sleep(0.2),
                   Child ! ping(Self),
                   receive({
                       pong -> writeln('Child survived the parent.')
                   }, [
                       timeout(0.2),
                       on_timeout(writeln('No pong arrived.'))
                   ]),
                   exit(Child, cleanup)
                 ),
                 [template(true)]),
   receive({
       terminal_output(Pid, Text) ->
           assertion(sub_string(Text, _, _, _, "Child survived the parent."))
   }),
   receive({
       success(Pid, [true], false) -> true
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(session_spawn_load_text_priority_queue_persists_across_calls,
     Messages == [high,high,low,low]) :-
   atomics_to_string([
       "important(Messages) :-\n",
       "   receive({\n",
       "      Priority-Message if Priority > 10 ->\n",
       "         Messages = [Message|MoreMessages],\n",
       "         important(MoreMessages)\n",
       "   },[ timeout(0),\n",
       "       on_timeout(normal(Messages))\n",
       "   ]).\n\n",
       "normal(Messages) :-\n",
       "   receive({\n",
       "      _-Message ->\n",
       "         Messages = [Message|MoreMessages],\n",
       "         normal(MoreMessages)\n",
       "   },[ timeout(0),\n",
       "       on_timeout(Messages=[])\n",
       "   ])."
   ], Text),
   toplevel_spawn(Pid, [
       session(true),
       monitor(true),
       load_text(Text)
   ]),
   toplevel_call(Pid,
                 ( self(S),
                   S ! 15-high,
                   S ! 7-low,
                   S ! 1-low,
                   S ! 17-high
                 ),
                 [template(true)]),
   receive({
       success(Pid, [true], false) -> true
   }),
   toplevel_call(Pid, important(Messages), [
       template(Messages)
   ]),
   receive({
       success(Pid, [Messages], false) -> true
   }),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }).

test(name_option_registers_toplevel_pid) :-
   setup_call_cleanup(
       toplevel_spawn(Pid, [
           session(true),
           name(test_named_toplevel)
       ]),
       (
           whereis(test_named_toplevel, Visible),
           assertion(Pid =@= Visible)
       ),
       (
           unregister(test_named_toplevel),
           catch(exit(Pid, kill), _, true)
       )
   ).

test(simple_load_list_next, Results == [2]) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true),
       load_list([ta(1),ta(2)])
   ]),
   toplevel_call(Pid, ta(X), [
       limit(1),
       template(X)
   ]),
   receive({
       success(Pid, [1], true) ->
           true
   }),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) ->
           true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(load_predicates_from_caller_module,
     Results == [socrates-xantippa, aristotle-pythias]) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true),
       load_predicates([sample_wife/2])
   ]),
   toplevel_call(Pid, sample_wife(X, Y), [
       template(X-Y)
   ]),
   receive({
       success(Pid, Results, false) -> true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(next_1, Results == [11,12]) :-
   toplevel_spawn(Pid, [
       session(false)
   ]),
   toplevel_call(Pid, between(1,12,N), [
       limit(5),
       template(N)
   ]),
   receive({
       success(Pid, [1,2,3,4,5], true) -> true
   }),
   toplevel_next(Pid),
   receive({
       success(Pid, [6,7,8,9,10], true) -> true
   }),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) -> true
   }).


test(next_2, Results == [11,12]) :-
   toplevel_spawn(Pid, [
       session(false)
   ]),
   toplevel_call(Pid, between(1,12,N), [
       offset(2),
       limit(2),
       template(N)
   ]),
   receive({
       success(Pid, [3,4], true) -> true
   }),
   toplevel_next(Pid, [
       limit(6)
   ]),
   receive({
       success(Pid, [5,6,7,8,9,10], true) -> true
   }),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) -> true
   }).

test(next_wrong_order, Result == true) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_next(Pid,[
       limit(5)
   ]),
   toplevel_next(Pid,[
       limit(5)
   ]),
   toplevel_call(Pid, between(1,12,N), [
       limit(2),
       template(N)
   ]),
   receive({
       success(Pid, [1,2], true) -> true
   }),
   receive({
       success(Pid, [3,4,5,6,7], true) -> true
   }),
   receive({
       success(Pid, [8,9,10,11,12], false) -> true
   }),
   receive({
       down(_, Pid, Result) -> true
   }).

test(once_true, Result == true) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid, between(1,3,N), [
       limit(1),
       template(N),
       once(true)
   ]),
   receive({
       success(Pid, [1], false) -> true
   }),
   toplevel_next(Pid),
   receive({
       success(Pid, _, _) ->
           Result = false
   }, [
       timeout(1),
       on_timeout(Result = true)
   ]),
   exit(Pid, kill),
   receive({
       down(_, Pid, kill) -> true
   }).

test(exit_false, Results == kill) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_call(Pid, (X = a ; X = b), [
       limit(5),
       template(X)
   ]),
   receive({
       success(Pid, [a,b], false) -> true
   }),
   toplevel_call(Pid, true, [
       template(.)
   ]),
   receive({
       success(Pid, [.], false) -> true
   }),
   toplevel_call(Pid, true),
   receive({
       success(Pid, [true], false) -> true
   }),
   toplevel_call(Pid, fail),
   receive({
       failure(Pid) -> true
   }),
   exit(Pid, kill),
   receive({
       down(_, Pid, Results) -> true
   }).

test(stop, Results = [a]) :-
   toplevel_spawn(Pid, [
       session(false)
   ]),
   toplevel_call(Pid, member(X, [a,b,c]), [
       limit(1),
       template(X)
   ]),
   toplevel_stop(Pid),
   receive({
       success(Pid, Results, true) -> true
   }).

test(halt_idle, true((Reply == true, Down == true))) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_halt(Pid, Reply),
   receive({
       down(_, Pid, Down) -> true
   }).

test(failure, Result = failure) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_call(Pid, fail),
   receive({
       failure(Pid) ->
          Result = failure
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(exception, Error = error(existence_error(procedure, _:unknown/0),_)) :-
   toplevel_spawn(Pid, [
       session(false)
   ]),
   toplevel_call(Pid, unknown),
   receive({
       error(Pid, Error) -> true
   }).

test(output, Results = [.]) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_call(Pid, (output(a), output(b)), [
       template(.)
   ]),
   receive({
       output(Pid, a) -> true
   }),
   receive({
       success(Pid, Results, false) -> true
   }),
   receive({
       output(Pid, b) -> true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(input, Results == true) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_call(Pid, (input(prompt, In), output(In)), [
       template(.)
   ]),
   receive({
       prompt(Pid, prompt) ->
           respond(Pid, hello)
   }),
   receive({
       output(Pid, hello) -> true
   }),
   receive({
       success(Pid, [.], false) -> true
   }),
   receive({
       down(_, Pid, Results) -> true
   }).

:- end_tests(toplevels).
