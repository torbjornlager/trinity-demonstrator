:- module(receive_probe).
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(findnsols_probe).
:- import exit/1 from actors.
:- export run/0.

:- dynamic private_accept/2.
private_accept(beta, private_beta).

run :-
    record_create(Inbox),
    record_create(Reports),
    engine_create(Receiver, [thread]),
    engine_create(Sender, [thread]),
    record_wait_append(Inbox, msg(alpha,1), 1, 16),
    record_wait_append(Inbox, msg(alpha,2), 1, 16),
    engine_resume_thread(Receiver, receiver(Inbox, Reports)),
    report_is(Reports, waiting),
    ( engine_join(Receiver, 0.2, Early) ->
        fail_probe(receiver_stopped_early(Early))
    ;
        writeln(pass(waiting_for_guard_match))
    ),
    engine_resume_thread(Sender, record_wait_append(Inbox, msg(beta,3), 1, 16)),
    engine_join(Sender, 2, SenderStatus),
    check(sender, SenderStatus, true),
    report_is(Reports, selected(beta,3,private_beta)),
    report_is(Reports, selected(alpha,1,private_alpha)),
    report_is(Reports, selected(alpha,2,private_alpha)),
    report_is(Reports, body_failed),
    report_is(Reports, empty_after_failure),
    report_is(Reports, one_sided_match),
    engine_join(Receiver, 2, ReceiverStatus),
    check(receiver, ReceiverStatus, true),
    writeln(eclipse_actor_receive_probe_passed),
    actor_api_probe,
    writeln(eclipse_actor_api_probe_passed),
    monitor_probe,
    writeln(eclipse_actor_monitor_probe_passed),
    exit_probe,
    writeln(eclipse_actor_exit_probe_passed),
    source_probe,
    writeln(eclipse_actor_source_probe_passed),
    toplevel_probe,
    writeln(eclipse_toplevel_probe_passed),
    toplevel_control_probe,
    writeln(eclipse_toplevel_control_probe_passed),
    toplevel_io_probe,
    writeln(eclipse_toplevel_io_probe_passed),
    run_findnsols_probe.

actor_api_probe :-
    start_actor_runtime,
    self(Main),
    check(root_pid, Main, main),
    spawn(echo_actor(Main), Echo, [link(false)]),
    receive({ echo_ready(Echo) -> true },
            [timeout(3), on_timeout(fail_probe(echo_not_ready))]),
    ( is_handle(Echo) -> fail_probe(public_pid_is_engine_handle) ; true ),
    Echo ! request(hello),
    receive({ echo_reply(Echo, private_alpha, hello) -> true },
            [timeout(3), on_timeout(fail_probe(echo_reply_missing))]),
    writeln(pass(public_spawn_self_and_send)),
    record_create(Reports),
    spawn(parent_actor(Main, Reports), Parent),
    receive({ linked_child(Parent, Child) -> true },
            [timeout(3), on_timeout(fail_probe(linked_child_not_ready))]),
    ( Parent == Child -> fail_probe(reused_pid) ; true ),
    ( record_wait_remove(Reports, ChildEngine, 2) -> true
    ; fail_probe(child_engine_missing)
    ),
    ( engine_join(ChildEngine, 0.2, Early) -> fail_probe(child_stopped_early(Early))
    ; true
    ),
    monitor(Child, ChildRef),
    send(Parent, finish),
    ( engine_join(ChildEngine, 3, Exited) ->
        check(linked_child_exit, Exited, exited(0))
    ;
        fail_probe(linked_child_survived_parent)
    ),
    expect_down(Child, ChildRef, kill).

monitor_probe :-
    spawn(true, Immediate, [monitor(true)]),
    expect_down(Immediate, Immediate, true),
    expect_no_down(Immediate),
    spawn(fail, ImmediateFailure, [monitor(true)]),
    expect_down(ImmediateFailure, ImmediateFailure, false),
    expect_no_down(ImmediateFailure),
    writeln(pass(spawn_monitor_fast_completion)),

    spawn(wait_to_finish, Target),
    monitor(Target, Cancelled),
    monitor(Target, Deferred),
    monitor(Target, Barrier),
    demonitor(Cancelled),
    send(Target, finish),
    % Waiting for the later ref makes the earlier DOWN pass through the
    % deferred queue. Flushing it must leave other traffic in place.
    send(main, unrelated),
    expect_down(Target, Barrier, true),
    demonitor(Deferred, [flush]),
    expect_no_down(Cancelled),
    expect_no_down(Deferred),
    expect_no_down(Barrier),
    receive({ unrelated -> true },
            [timeout(0), on_timeout(fail_probe(unrelated_message_lost))]),
    writeln(pass(demonitor_live_and_flush_deferred)),

    monitor(Target, Missing),
    expect_down(Target, Missing, no_process),
    expect_no_down(Missing),
    monitor(Target, InInbox),
    demonitor(InInbox, [flush]),
    expect_no_down(InInbox),
    writeln(pass(missing_target_and_flush_inbox)),

    spawn(fail, Failed),
    monitor(Failed, FailedRef),
    % This actor can exit before monitor/2 wins the lifecycle mutex.
    expect_down(Failed, FailedRef, FailedReason),
    ( ( FailedReason == false ; FailedReason == no_process ) -> true
    ; fail_probe(unexpected_failure_reason(FailedReason))
    ),
    expect_no_down(FailedRef),

    spawn(wait_to_throw, Throws),
    monitor(Throws, ThrowsRef),
    send(Throws, finish),
    expect_down(Throws, ThrowsRef, exception(probe_error)),
    expect_no_down(ThrowsRef),
    writeln(pass(exception_down)),

    monitor_exit_races(20),
    writeln(pass(twenty_monitor_exit_races)).

wait_to_finish :-
    receive({ finish -> true }).

wait_to_throw :-
    receive({ finish -> throw(probe_error) }).

monitor_exit_races(0) :- !.
monitor_exit_races(N) :-
    spawn(wait_to_finish, Pid),
    send(Pid, finish),
    monitor(Pid, Ref),
    expect_down(Pid, Ref, Reason),
    ( ( Reason == true ; Reason == no_process ) -> true
    ; fail_probe(unexpected_race_reason(Reason))
    ),
    expect_no_down(Ref),
    Next is N - 1,
    monitor_exit_races(Next).

expect_down(Pid, Ref, Reason) :-
    receive({ down(Pid, Ref, Reason) -> true },
            [timeout(3), on_timeout(fail_probe(missing_down(Pid, Ref, Reason)))]).

expect_no_down(Ref) :-
    receive({ down(Pid, Ref, Reason) -> fail_probe(unexpected_down(Pid, Ref, Reason)) },
            [timeout(0)]).

exit_probe :-
    self(Main),
    spawn(self_exiting_actor(Main), SelfExit),
    monitor(SelfExit, SelfRef),
    send(SelfExit, finish),
    expect_down(SelfExit, SelfRef, self_stopped(detail)),
    expect_no_down(SelfRef),
    expect_no_exit_continuation,
    writeln(pass(self_exit_reason)),

    spawn(blocked_actor(Main), Blocked),
    expect_exit_ready(Blocked),
    monitor(Blocked, BlockedRef),
    exit(Blocked, first_reason),
    exit(Blocked, second_reason),
    expect_down(Blocked, BlockedRef, first_reason),
    expect_no_down(BlockedRef),
    expect_no_exit_continuation,
    writeln(pass(first_exit_reason_wins)),

    spawn(blocked_actor(Main), Raced),
    expect_exit_ready(Raced),
    monitor(Raced, RaceRef),
    spawn(exit_requester(Raced, left), Left),
    spawn(exit_requester(Raced, right), Right),
    monitor(Left, LeftRef),
    monitor(Right, RightRef),
    send(Left, finish),
    send(Right, finish),
    expect_down(Left, LeftRef, true),
    expect_down(Right, RightRef, true),
    expect_down(Raced, RaceRef, Winner),
    ( ( Winner == left ; Winner == right ) -> true
    ; fail_probe(unexpected_exit_race_reason(Winner))
    ),
    expect_no_down(RaceRef),
    expect_no_exit_continuation,
    writeln(pass(competing_exit_requests, Winner)),

    spawn(exit_parent(Main), Parent),
    receive({ exit_family(Parent, Child, Detached) -> true },
            [timeout(3), on_timeout(fail_probe(exit_family_missing))]),
    receive({ exit_grandchild(Child, Grandchild) -> true },
            [timeout(3), on_timeout(fail_probe(exit_grandchild_missing))]),
    monitor(Parent, ParentRef),
    monitor(Child, ChildRef),
    monitor(Grandchild, GrandchildRef),
    monitor(Detached, DetachedRef),
    exit(Parent, parent_stopped),
    expect_down(Parent, ParentRef, parent_stopped),
    expect_down(Child, ChildRef, kill),
    expect_down(Grandchild, GrandchildRef, kill),
    expect_no_down(ParentRef),
    expect_no_down(ChildRef),
    expect_no_down(GrandchildRef),
    expect_no_down(DetachedRef),
    send(Detached, ping),
    receive({ detached_pong(Detached) -> true },
            [timeout(3), on_timeout(fail_probe(detached_child_did_not_survive))]),
    expect_down(Detached, DetachedRef, true),
    expect_no_exit_continuation,
    writeln(pass(linked_subtree_terminated_and_detached_child_survived)).

self_exiting_actor(Main) :-
    receive({ finish -> exit(self_stopped(detail)) }),
    send(Main, exit_continued).

blocked_actor(Main) :-
    self(Me),
    send(Main, exit_ready(Me)),
    receive({ never_sent -> send(Main, exit_continued) }).

exit_requester(Pid, Reason) :-
    receive({ finish -> exit(Pid, Reason) }).

expect_exit_ready(Pid) :-
    receive({ exit_ready(Pid) -> true },
            [timeout(3), on_timeout(fail_probe(exit_ready_missing(Pid)))]).

expect_no_exit_continuation :-
    receive({ exit_continued -> fail_probe(exited_goal_continued) }, [timeout(0)]).

exit_parent(Main) :-
    self(Me),
    spawn(exit_child(Main), Child),
    spawn(detached_actor(Main), Detached, [link(false)]),
    send(Main, exit_family(Me, Child, Detached)),
    receive({ never_sent -> send(Main, exit_continued) }).

exit_child(Main) :-
    self(Me),
    spawn(blocked_actor(Main), Grandchild),
    send(Main, exit_grandchild(Me, Grandchild)),
    receive({ never_sent -> send(Main, exit_continued) }).

detached_actor(Main) :-
    self(Me),
    receive({ ping -> send(Main, detached_pong(Me)) }).

source_probe :-
    self(Main),
    spawn(source_loop(Main), A, [src_text(":- dynamic local_value/1. local_value(alpha). source_loop(Owner) :- self(Me), receive({ set(Value) -> retractall(local_value(_)), assertz(local_value(Value)), source_loop(Owner) ; get -> local_value(Value), send(Owner, value(Me,Value)), source_loop(Owner) ; stop -> true }).")]),
    spawn(source_loop(Main), B, [link(false), src_text(":- dynamic local_value/1. local_value(beta). source_loop(Owner) :- self(Me), receive({ get -> local_value(Value), send(Owner, value(Me,Value)), source_loop(Owner) ; stop -> true }).")]),
    source_module(A, ModuleA),
    source_module(B, ModuleB),
    ( current_module(ModuleA), current_module(ModuleB) -> true
    ; fail_probe(private_module_not_ready_at_spawn_return)
    ),
    monitor(A, RefA),
    monitor(B, RefB),
    send(A, get),
    send(B, get),
    expect_source_value(A, alpha),
    expect_source_value(B, beta),
    send(A, set(updated)),
    send(A, get),
    send(B, get),
    expect_source_value(A, updated),
    expect_source_value(B, beta),
    send(A, stop),
    expect_down(A, RefA, true),
    expect_source_module_gone(ModuleA),
    send(B, get),
    expect_source_value(B, beta),
    exit(B, source_stopped),
    expect_down(B, RefB, source_stopped),
    expect_source_module_gone(ModuleB),
    writeln(pass(private_source_isolation_and_reclamation)),

    private_modules(Before),
    expect_spawn_source_error(":- module(escaped_source)."),
    expect_spawn_source_error("value( ."),
    private_modules(After),
    check(no_failed_startup_module_leak, After, Before),
    ( current_module(escaped_source) -> fail_probe(module_directive_escaped)
    ; true
    ).

source_module(Pid, Module) :-
    concat_atom(['$web_prolog_actor_', Pid], Module).

expect_source_value(Pid, Value) :-
    receive({ value(Pid, Value) -> true },
            [timeout(3), on_timeout(fail_probe(missing_source_value(Pid, Value)))]).

expect_source_module_gone(Module) :-
    ( current_module(Module) -> fail_probe(private_module_leaked(Module))
    ; true
    ).

expect_spawn_source_error(Text) :-
    catch(
        ( spawn(true, _, [src_text(Text)]) -> Result = succeeded
        ; Result = failed
        ),
        Error,
        Result = exception(Error)
    ),
    ( Result = exception(_) -> true
    ; fail_probe(invalid_source_did_not_throw(Result))
    ).

private_modules(Modules) :-
    string_list("$web_prolog_actor_", Prefix),
    findall(Module,
            ( current_module(Module),
              atom_string(Module, Name),
              string_list(Name, Codes),
              append(Prefix, _, Codes)
            ), Unsorted),
    sort(Unsorted, Modules).

toplevel_probe :-
    toplevel_spawn(A, [session(true), src_text("item(a). item(b). item(c). :- dynamic stored/1. stored(initial).")]),
    toplevel_spawn(B, [session(true), src_text("item(other).")]),
    monitor(A, RefA),
    monitor(B, RefB),
    toplevel_next(A),  % Stale command, sent before the new call.
    toplevel_call(A, item(X), [template(X), limit(1)]),
    toplevel_call(B, item(Y), [template(Y)]),
    expect_toplevel(success(A,[a],true)),
    expect_toplevel(success(B,[other],false)),
    ( var(X), var(Y) -> true ; fail_probe(caller_query_variables_bound) ),
    receive({ success(A, _, _) -> fail_probe(stale_next_was_used) }, [timeout(0.05)]),
    toplevel_next(A, [limit(3)]),
    expect_toplevel(success(A,[b,c],false)),
    writeln(pass(toplevel_interleaved_sessions_and_paging)),

    toplevel_call(A, item(Z), [template(Z), offset(1), limit(1), once(true)]),
    expect_toplevel(success(A,[b],false)),
    toplevel_call(A, (retract(stored(initial)), assertz(stored(updated))), [template(ok)]),
    expect_toplevel(success(A,[ok],false)),
    toplevel_call(A, stored(Value), [template(Value)]),
    expect_toplevel(success(A,[updated],false)),
    toplevel_call(A, fail),
    expect_toplevel(failure(A)),
    writeln(pass(toplevel_reuse_state_offset_and_once)),

    toplevel_call(A, (Partial = answer ; throw(later_error)), [template(Partial), limit(2)]),
    expect_toplevel(success(A,[answer],true)),
    toplevel_next(A),
    expect_toplevel(error(A,later_error)),
    toplevel_call(A, stored(Again), [template(Again)]),
    expect_toplevel(success(A,[updated],false)),
    writeln(pass(toplevel_partial_page_and_error_recovery)),

    exit(A, cleanup),
    exit(B, cleanup),
    expect_down(A, RefA, cleanup),
    expect_down(B, RefB, cleanup),
    toplevel_spawn(Ephemeral),
    toplevel_call(Ephemeral, true),
    expect_toplevel(success(Ephemeral,[true],false)),
    monitor(Ephemeral, RefE),
    expect_down(Ephemeral, RefE, Reason),
    ( ( Reason == true ; Reason == no_process ) -> true
    ; fail_probe(ephemeral_toplevel_exit(Reason))
    ).

toplevel_control_probe :-
    toplevel_spawn(Pid, [session(true),
        src_text("item(a). item(b). :- dynamic stored/1. stored(initial).")]),
    monitor(Pid, Ref),

    toplevel_call(Pid, (item(X), assertz(stored(X))), [template(X), limit(1)]),
    expect_toplevel(success(Pid,[a],true)),
    toplevel_stop(Pid),
    toplevel_call(Pid, stored(AfterStop), [template(AfterStop)]),
    expect_toplevel(success(Pid,[initial,a],false)),
    writeln(pass(toplevel_stop_discards_alternatives)),

    toplevel_call(Pid, (Partial = answer ; throw(discarded_error)),
                  [template(Partial), limit(2)]),
    expect_toplevel(success(Pid,[answer],true)),
    self(Main),
    toplevel_stop(Pid, Main),
    expect_toplevel(stop(Pid)),
    toplevel_call(Pid, true),
    expect_toplevel(success(Pid,[true],false)),
    expect_no_toplevel_error(Pid),
    writeln(pass(toplevel_stop_discards_pending_error)),

    toplevel_call(Pid, (item(Y), assertz(stored(suspended(Y)))),
                  [template(Y), limit(1)]),
    expect_toplevel(success(Pid,[a],true)),
    toplevel_abort(Pid),
    expect_toplevel(abort(Pid)),
    toplevel_call(Pid, stored(AfterSuspend), [template(AfterSuspend)]),
    expect_toplevel(success(Pid,[initial,a,suspended(a)],false)),
    expect_no_toplevel_error(Pid),
    writeln(pass(toplevel_abort_suspended_query)),

    toplevel_call(Pid, (assertz(stored(loop_started)),
                       send(Main, loop_started(Pid)), repeat, fail)),
    expect_toplevel(loop_started(Pid)),
    toplevel_abort(Pid),
    expect_toplevel(abort(Pid)),
    toplevel_call(Pid, stored(AfterAbort), [template(AfterAbort)]),
    expect_toplevel(success(Pid,[initial,a,suspended(a),loop_started],false)),
    expect_no_toplevel_error(Pid),
    expect_no_down(Ref),
    writeln(pass(toplevel_abort_running_query_preserves_database)),

    toplevel_abort(Pid),
    expect_toplevel(abort(Pid)),
    toplevel_call(Pid, true),
    expect_toplevel(success(Pid,[true],false)),
    writeln(pass(toplevel_abort_idle_session)),
    exit(Pid, cleanup),
    expect_down(Pid, Ref, cleanup).

toplevel_io_probe :-
    toplevel_spawn(Pid, [session(true), src_text(":- dynamic page_seen/1.")]),
    monitor(Pid, Mon),
    toplevel_call(Pid, (output(before), input(question(term), Value), output(after(Value))),
                  [template(Value)]),
    expect_toplevel(output(Pid,before)),
    expect_toplevel(prompt(Pid,question(term))),
    respond(Pid, answer(42)),
    expect_toplevel(output(Pid,after(answer(42)))),
    expect_toplevel(success(Pid,[answer(42)],false)),
    writeln(pass(toplevel_output_and_legacy_input)),

    toplevel_call(Pid, input(first_prompt, First, [correlate(true)]), [template(First)]),
    expect_toplevel(prompt(Pid,prompt_ref(FirstRef,first_prompt))),
    toplevel_abort(Pid),
    expect_toplevel(abort(Pid)),
    expect_no_toplevel_error(Pid),
    expect_no_down(Mon),

    toplevel_call(Pid, input(fresh_prompt, Fresh, [correlate(true)]), [template(Fresh)]),
    expect_toplevel(prompt(Pid,prompt_ref(FreshRef,fresh_prompt))),
    ( FirstRef == FreshRef -> fail_probe(prompt_reference_reused) ; true ),
    % Deliberately reply after the fresh prompt is active. Simply draining
    % stale commands at the start of the call could not pass this check.
    respond(Pid, FirstRef, late),
    respond(Pid, uncorrelated_late),
    receive({ success(Pid, Answers, _) -> fail_probe(stale_input_accepted(Answers)) },
            [timeout(0.1)]),
    respond(Pid, FreshRef, fresh),
    expect_toplevel(success(Pid,[fresh],false)),
    writeln(pass(toplevel_abort_input_and_reject_late_replies)),

    toplevel_call(Pid, input(final_prompt, Last), [template(Last)]),
    expect_toplevel(prompt(Pid,final_prompt)),
    respond(Pid, final),
    expect_toplevel(success(Pid,[final],false)),

    toplevel_call(Pid,
                  ( self(Actor),
                    ( assertz(page_seen(first)), Row = first
                    ; page_seen(first),
                      input(second_page, Reply, [correlate(true)]),
                      Row = second(Reply)
                    )
                  ), [template(row(Actor,Row)), limit(1)]),
    expect_toplevel(success(Pid,[row(Pid,first)],true)),
    toplevel_next(Pid, [limit(2)]),
    expect_toplevel(prompt(Pid,prompt_ref(PageRef,second_page))),
    respond(Pid, PageRef, continued),
    expect_toplevel(success(Pid,[row(Pid,second(continued))],false)),
    writeln(pass(toplevel_prompt_and_private_state_across_pages)),
    exit(Pid, cleanup),
    expect_down(Pid, Mon, cleanup).

expect_no_toplevel_error(Pid) :-
    receive({ error(Pid, Error) -> fail_probe(unexpected_toplevel_error(Error)) },
            [timeout(0)]).

expect_toplevel(Answer) :-
    receive({ Answer -> true },
            [timeout(3), on_timeout(fail_probe(missing_toplevel_answer(Answer)))]).

echo_actor(Main) :-
    self(Me),
    send(Main, echo_ready(Me)),
    receive({ request(Value) ->
        private_accept(alpha, Reply),
        send(Main, echo_reply(Me, Reply, Value))
    }, [timeout(3), on_timeout(fail_probe(echo_request_missing))]).

parent_actor(Main, Reports) :-
    self(Parent),
    spawn(linked_child_actor(Main, Parent, Reports), _),
    receive({ finish -> true }).

linked_child_actor(Main, Parent, Reports) :-
    self(Me),
    engine_self(Engine),
    record_wait_append(Reports, Engine, 1, 16),
    send(Main, linked_child(Parent, Me)),
    receive({ never_sent -> fail_probe(linked_receive_returned) }).

receiver(Inbox, Reports) :-
    attach_mailbox(Inbox),
    record_wait_append(Reports, waiting, 1, 16),
    guarded_receive(Reports),
    retractall(private_accept(_, _)),
    assertz(private_accept(alpha, private_alpha)),
    guarded_receive(Reports),
    guarded_receive(Reports),
    record_wait_append(Inbox, consume_me, 1, 16),
    ( receive({consume_me -> fail}, [timeout(0)]) ->
        fail_probe(receive_succeeded_after_body_failure)
    ;
        record_wait_append(Reports, body_failed, 1, 16)
    ),
    receive({ _ -> fail_probe(message_survived_failed_body) },
            [timeout(0), on_timeout(record_wait_append(Reports, empty_after_failure, 1, 16))]),
    record_wait_append(Inbox, payload(_), 1, 16),
    receive({
        payload(concrete) -> fail_probe(pattern_instantiated_message)
    ;
        payload(Value) ->
            ( var(Value) -> record_wait_append(Reports, one_sided_match, 1, 16)
            ; fail_probe(message_variable_was_bound)
            )
    }, [timeout(0), on_timeout(fail_probe(missing_variable_message))]).

guarded_receive(Reports) :-
    receive({
        if(msg(Key,Id), throw(rejected_guard)) -> fail_probe(throwing_guard_selected)
    ;
        if(msg(Key,Id), private_accept(Key,Reply)) ->
            record_wait_append(Reports, selected(Key,Id,Reply), 1, 16)
    }, [timeout(4), on_timeout(fail_probe(receive_timed_out))]).

report_is(Reports, Expected) :-
    ( record_wait_remove(Reports, Actual, 5) ->
        check(report, Actual, Expected)
    ;
        fail_probe(missing(Expected))
    ).

check(Label, Actual, Expected) :-
    ( Actual == Expected -> writeln(pass(Label, Actual))
    ; fail_probe(mismatch(Label, expected(Expected), actual(Actual)))
    ).

fail_probe(Reason) :-
    writeln(failed(Reason)),
    flush(output),
    eclipse_language:exit(1).
