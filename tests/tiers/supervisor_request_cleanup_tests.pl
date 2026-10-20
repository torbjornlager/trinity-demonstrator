:- module(test_supervisor_request_cleanup, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).
:- use_module(library(time)).

:- thread_local send_error/2.
:- multifile actors:hook_check_send/2.
actors:hook_check_send(Pid, '$sup'(_, _, which_children)) :-
    test_supervisor_request_cleanup:send_error(Pid, Error), throw(Error).

:- meta_predicate with_peer(0,-,-,0).
with_peer(Goal, Pid, AppRef, Test) :-
    setup_call_cleanup(
        (spawn(Goal, Pid, [link(false)]), monitor(Pid, AppRef)),
        Test,
        (demonitor(AppRef, [flush]), stop_peer(Pid))).

stop_peer(Pid) :-
    monitor(Pid, Ref), exit(Pid, kill),
    receive({down(Pid, Ref, _) -> true},
            [timeout(2), on_timeout(throw(peer_cleanup_timeout))]).

monitor_refs(Pid, Refs) :-
    self(Self), findall(Ref, actors:monitor(Self, Pid, Ref), Refs).

assert_only_application_monitor(Pid, AppRef) :-
    monitor_refs(Pid, Refs), assertion(Refs == [AppRef]).

reply_peer :-
    receive({'$sup'(From, Ref, which_children) -> From ! Ref-[]}),
    receive({finish -> true}).

timeout_peer :-
    receive({'$sup'(From, Ref, which_children) ->
        receive({release_reply -> From ! Ref-late_reply})}),
    receive({finish -> true}).

:- begin_tests(supervisor_request_cleanup).

test(success_keeps_reply_and_unrelated_state) :-
    with_peer(reply_peer, Pid, AppRef,
      (self(Self), send(Self, unrelated_supervisor_message),
       supervisor_which_children(Pid, Reply), assertion(Reply == []),
       assert_only_application_monitor(Pid, AppRef),
       receive({unrelated_supervisor_message -> true}, [timeout(0), on_timeout(fail)]))).

test(output_mismatch_fails_and_removes_private_monitor) :-
    with_peer(reply_peer, Pid, AppRef,
      (\+ supervisor_which_children(Pid, conflicting_output),
       assert_only_application_monitor(Pid, AppRef),
       receive({_ - [] -> fail}, [timeout(0)]))).

test(send_exception_preserves_original_and_application_monitor) :-
    with_peer(receive({}), Pid, AppRef,
      (Expected = error(test_supervisor_send, context(test_transport, original)),
       setup_call_cleanup(asserta(test_supervisor_request_cleanup:send_error(Pid, Expected), Row),
           catch(supervisor_which_children(Pid, _), Error, true), erase(Row)),
       assertion(Error == Expected), assert_only_application_monitor(Pid, AppRef))).

test(missing_name_flushes_private_down_only) :-
    gensym(missing_supervisor_, Name), self(Self),
    send(Self, down(unrelated_supervisor, unrelated_ref, unrelated_reason)),
    catch(supervisor_which_children(Name, _), Error, true),
    assertion(Error == error(existence_error(actor_name, Name),
                            context(actor:send/2, 'no actor registered under name'))),
    monitor_refs(Name, Refs), assertion(Refs == []),
    receive({down(Name, _, _) -> fail}, [timeout(0)]),
    receive({down(unrelated_supervisor, unrelated_ref, unrelated_reason) -> true},
            [timeout(0), on_timeout(fail)]).

test(wait_interruption_preserves_original_and_application_monitor) :-
    with_peer(receive({}), Pid, AppRef,
      (setup_call_cleanup(
           alarm(0.02, throw(supervisor_wait_interrupted), Alarm, []),
           catch(supervisor_which_children(Pid, _), Error, true),
           remove_alarm(Alarm)),
       assertion(Error == supervisor_wait_interrupted),
       assert_only_application_monitor(Pid, AppRef))).

test(supervisor_death_keeps_application_down) :-
    with_peer(receive({'$sup'(_, _, which_children) -> exit(request_peer_crashed)}), Pid, AppRef,
      (catch(supervisor_which_children(Pid, _), Error, true),
       assertion(Error == supervisor_down(request_peer_crashed)),
       monitor_refs(Pid, Refs), assertion(Refs == []),
       receive({down(Pid, AppRef, request_peer_crashed) -> true},
               [timeout(2), on_timeout(fail)]),
       receive({down(Pid, _, _) -> fail}, [timeout(0)]))).

test(ten_second_timeout_keeps_late_reply_and_application_monitor) :-
    with_peer(timeout_peer, Pid, AppRef,
      (get_time(Start),
       catch(supervisor_which_children(Pid, _), Error, true),
       get_time(End), Elapsed is End - Start,
       assertion(Error == supervisor_call_timeout(Pid, which_children)),
       assertion(Elapsed >= 9.8),
       assert_only_application_monitor(Pid, AppRef),
       send(Pid, release_reply),
       receive({_Ref-late_reply -> true}, [timeout(2), on_timeout(fail)]))).

:- end_tests(supervisor_request_cleanup).
