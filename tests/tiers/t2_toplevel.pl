/*  Tier T2: actors + isolation + toplevel_actors, with the glue.

    The demonstrator's toplevel_actor_tests.pl `toplevels` suite is
    entirely local, so it carries over near-verbatim (imports aside —
    and all pid-shape assumptions were already absent).  Adds layer
    honesty and a default-hook check: a toplevel spawn naming a remote
    node without the distribution layer raises.
*/

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/isolation.pl').
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module(library(plunit)).

%  Composition glue (same single chain the umbrella will define).
actors:hook_start_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
    isolation:spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner).

run_tier :-
    layer_honesty,
    run_tests([ t2_toplevels,
                t2_hooks,
                t2_programs,
                t2_shell_io
              ]),
    ensure_mailbox_empty.

layer_honesty :-
    forall(member(M, [ distribution,
                       node,
                       actor,                 % legacy src/actor.pl
                       toplevel_actor,        % legacy src/toplevel_actor.pl
                       node_controller,
                       remote_protocol,
                       pid_utils,
                       public_goal_guard,
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


:- begin_tests(t2_toplevels, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

%  Flushing races the asynchronous `down` printout from a monitored
%  child: a single flush can run before the shell has buffered it. Poll
%  flush until the expected output appears (as ws_flush_until_output does
%  in the node suite), so the test asserts the eventual state rather than
%  one fixed interleaving.
flush_until_down_output(Pid, Text) :-
   flush_until_down_output(Pid, 50, Text).

flush_until_down_output(_, 0, _) :-
   !,
   throw(flush_no_down_output).
flush_until_down_output(Pid, Attempts, Text) :-
   toplevel_call(Pid, flush, [template(true)]),
   receive({
       terminal_output(Pid, T) -> FlushOut = output(T) ;
       success(Pid, [true], false) -> FlushOut = empty
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   (   FlushOut = output(_)
   ->  receive({
           success(Pid, [true], false) -> true
       }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ])
   ;   true
   ),
   (   FlushOut = output(Got),
       sub_string(Got, _, _, _, "Shell got down(")
   ->  Text = Got
   ;   sleep(0.02),
       Attempts1 is Attempts - 1,
       flush_until_down_output(Pid, Attempts1, Text)
   ).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   flush_until_down_output(Pid, Text),
   assertion(sub_string(Text, _, _, _, "Shell got down(")),
   assertion(sub_string(Text, _, _, _, "true")),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, [true], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, [true], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_call(Pid, important(Messages), [
       template(Messages)
   ]),
   receive({
       success(Pid, [Messages], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   catch(exit(Pid, kill), _, true),
   receive({
       down(_, Pid, kill) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) ->
           true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_next(Pid),
   receive({
       success(Pid, [6,7,8,9,10], true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_next(Pid, [
       limit(6)
   ]),
   receive({
       success(Pid, [5,6,7,8,9,10], true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_next(Pid),
   receive({
       success(Pid, Results, false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, [3,4,5,6,7], true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, [8,9,10,11,12], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, Result) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_call(Pid, true, [
       template(.)
   ]),
   receive({
       success(Pid, [.], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_call(Pid, true),
   receive({
       success(Pid, [true], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   toplevel_call(Pid, fail),
   receive({
       failure(Pid) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   exit(Pid, kill),
   receive({
       down(_, Pid, Results) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

test(halt_idle, true((Reply == true, Down == true))) :-
   toplevel_spawn(Pid, [
       session(true),
       monitor(true)
   ]),
   toplevel_halt(Pid, Reply),
   receive({
       down(_, Pid, Down) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

test(failure, Result = failure) :-
   toplevel_spawn(Pid, [
       session(false),
       monitor(true)
   ]),
   toplevel_call(Pid, fail),
   receive({
       failure(Pid) ->
          Result = failure
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

test(exception, Error = error(existence_error(procedure, _:unknown/0),_)) :-
   toplevel_spawn(Pid, [
       session(false)
   ]),
   toplevel_call(Pid, unknown),
   receive({
       error(Pid, Error) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, Results, false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       output(Pid, b) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, true) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

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
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       output(Pid, hello) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       success(Pid, [.], false) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]),
   receive({
       down(_, Pid, Results) -> true
   }, [ timeout(20), on_timeout(throw(shell_receive_timeout)) ]).

test(toplevel_call_does_not_share_goal_variables_with_caller,
     [Result == ok]) :-
    %  Pin: variables in the Goal passed to toplevel_call/3 are
    %  independent from the caller's perspective.  This relies on
    %  thread_send_message/2 placing a copy of the message into the
    %  receiver's mailbox; if a future port to another Prolog
    %  system uses a queue that shares term storage, the
    %  toplevel_call/3 path would need to re-introduce an explicit
    %  copy_term/2 before send/2.  This test is the canary.
    toplevel_spawn(Pid, [session(false), monitor(true)]),
    toplevel_call(Pid, member(X, [a, b, c]), [template(X)]),
    %  X must be unbound from the caller's view even after the
    %  receiver runs the goal and binds its copy.
    receive({ success(Pid, _Results, _More) -> true }),
    assertion(var(X)),
    receive({ down(_, Pid, _) -> true }),
    Result = ok.

:- end_tests(t2_toplevels).


:- begin_tests(t2_hooks, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

%  Without the distribution layer, a toplevel spawn naming a remote
%  node falls through to the local path, whose spawn/3 then raises
%  because no hook_spawn/3 claims the node option.
test(toplevel_spawn_remote_without_distribution_raises,
     true(Error = error(existence_error(procedure, _), _))) :-
   catch(toplevel_spawn(_Pid, [node('http://example.org')]),
         Error,
         true),
   nonvar(Error).

:- end_tests(t2_hooks).


%  The toplevel half of the demonstrator's actor_tests.pl `programs`
%  group: myfindall/3 collects a goal's solutions through a one-shot
%  toplevel query actor (the success/failure/error reply protocol).
%  Ported verbatim — it needs toplevel_spawn/2 + toplevel_call/3, so it
%  belongs here rather than in T0 with program1..7.

myfindall(Template, Goal, Solutions) :-
    toplevel_spawn(Pid, [
        session(false)
    ]),
    toplevel_call(Pid, Goal, [
        template(Template)
    ]),
    receive({
        success(Pid, Solutions, false) ->
            true ;
        failure(Pid) ->
            Solutions = [] ;
        error(Pid, Error) ->
            throw(Error)
    }).

:- begin_tests(t2_programs, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(program8_myfindall_1, Results == [1,2,3]) :-
    myfindall(N, between(1,3,N), Results).

test(program8_myfindall_2, Results == []) :-
    myfindall(_N, fail, Results).

test(program8_myfindall_3, Error = error(_,_)) :-
    catch(myfindall(N, N is 1/0, _Results), Error, true).

:- end_tests(t2_programs).


%  Two shell-side I/O cases from the demonstrator's actor_tests.pl that
%  need the toplevel layer: an injected program that itself spawns a
%  toplevel query actor, and the shell's flush/0 preserving both the
%  output/1 and terminal_output wrappers in its printout.  Ported
%  verbatim.

wait_for_injected_toplevel_success_and_down(Pid) :-
   wait_for_injected_toplevel_success_and_down(Pid, false, false).

wait_for_injected_toplevel_success_and_down(_Pid, true, true) :-
   !.
wait_for_injected_toplevel_success_and_down(Pid, GotSuccess0, GotDown0) :-
   receive({
       success(_ToplevelPid, [true], false) ->
           GotSuccess = true,
           GotDown = GotDown0 ;
       down(_, Pid, true) ->
           GotSuccess = GotSuccess0,
           GotDown = true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   wait_for_injected_toplevel_success_and_down(Pid, GotSuccess, GotDown).

:- begin_tests(t2_shell_io, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(injected_program_calls_toplevel_spawn, Result == true) :-
   self(Self),
   spawn(run_toplevel(Self), Pid, [
       monitor(true),
       load_list([
           (run_toplevel(Parent) :-
               toplevel_spawn(ToplevelPid, [target(Parent), link(false)]),
               toplevel_call(ToplevelPid, true, [template(true), limit(1)]))
       ])
   ]),
   wait_for_injected_toplevel_success_and_down(Pid),
   Result = true.

test(flush_preserves_child_output_and_terminal_output_wrappers) :-
   spawn((output(hi), writeln(line)), _Pid, [link(false)]),
   sleep(0.1),
   with_output_to(string(Output), flush),
   sub_string(Output, _, _, _, "Shell got output("),
   sub_string(Output, _, _, _, ",hi)"),
   sub_string(Output, _, _, _, "Shell got terminal_output("),
   sub_string(Output, _, _, _, ",line)"),
   !.

:- end_tests(t2_shell_io).
