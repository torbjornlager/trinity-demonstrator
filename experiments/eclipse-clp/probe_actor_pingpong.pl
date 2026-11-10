:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json), [json_write_dict/3]).
:- use_module(library(http/websocket)).
:- use_module(library(gensym)).
:- use_module(library(settings)).
:- initialization(main, main).

main(Args) :-
    set_setting(http:public_host, '127.0.0.1'),
    set_setting(http:public_port, 8095),
    node(8095, [profile(actor), auth(dev)]),
    self(Parent),
    spawn(swi_probe_actor(Parent), Actor),
    setup_call_cleanup(
        register_service(swi_echo, Actor),
        run_actor_probes(Args),
        ( unregister_service(swi_echo), exit(Actor, probe_complete) )
    ).

run_actor_probes(['--prompt-probes'|Selectors]) :- !,
    Selectors = [_|_],
    maplist(run_prompt_probe, Selectors, Statuses),
    maplist(=("pass"), Statuses).
run_actor_probes(Args) :-
    memberchk(Args, [[], ['--remote-spawn']]),
    run_pingpong,
    ( Args == ['--remote-spawn'] ->
        run_linked_spawn, run_detached_spawn, check_forward_startup_output,
        check_legacy_prompt_probe(check_forward_prompt_exchange), check_forward_correlated_prompts,
        check_forward_concurrent_prompts,
        with_forward_prompt_pair(check_forward_late_prompt_reply),
        check_forward_parent_exit_with_pending_prompts,
        check_forward_parent_exit_with_detached_prompt,
        check_forward_detached_watcher_pair,
        check_forward_disconnect,
        check_forward_connection_isolation, run_reverse_linked_spawn
    ; true
    ),
    writeln(swi_eclipse_actor_pingpong_probe_passed).

% Modern SWI nodes require a reference. Exercise PID-only prompts with the
% legacy loader and the explicit legacy selectors.
check_legacy_prompt_probe(Goal) :-
    ( current_predicate(respond/2) -> call(Goal) ; true ).

run_prompt_probe(Selector, Status) :-
    catch(( prompt_probe(Selector, Goal) ->
              ( once(Goal) -> Result = _{status:"pass"}
              ; Result = _{status:"fail", detail:"probe failed"}
              )
          ; Result = _{status:"error", detail:"unknown fixture selector"}
          ), Error,
          ( message_to_string(Error, Detail), Result = _{status:"fail", detail:Detail} )),
    write('PROMPT_PROBE '),
    json_write_dict(current_output, Result.put(selector, Selector), [width(0)]),
    nl,
    flush_output,
    Status = Result.status.

prompt_probe('swi-to-eclipse/legacy', check_forward_prompt_exchange).
prompt_probe('eclipse-to-swi/legacy', check_reverse_prompt_exchange).
prompt_probe('swi-to-eclipse/correlated', check_forward_correlated_prompts).
prompt_probe('eclipse-to-swi/correlated', check_reverse_correlated_prompts).
prompt_probe('swi-to-eclipse/concurrent', check_forward_concurrent_prompts).
prompt_probe('eclipse-to-swi/concurrent', check_reverse_concurrent_prompts).
prompt_probe('swi-to-eclipse/late', with_forward_prompt_pair(check_forward_late_prompt_reply)).
prompt_probe('eclipse-to-swi/late', check_reverse_late_prompt_reply).
prompt_probe('swi-to-eclipse/linked-exit', check_forward_parent_exit_with_pending_prompts).
prompt_probe('eclipse-to-swi/linked-exit', check_reverse_parent_exit_with_pending_prompts).
prompt_probe('swi-to-eclipse/mixed-exit', check_forward_parent_exit_with_detached_prompt).
prompt_probe('eclipse-to-swi/mixed-exit', check_reverse_parent_exit_with_detached_prompt).
prompt_probe('swi-to-eclipse/detached-pair', check_forward_detached_watcher_pair).
prompt_probe('eclipse-to-swi/detached-pair', check_reverse_detached_watcher_pair).
prompt_probe('swi-to-eclipse/disconnect', (check_forward_disconnect, check_forward_connection_isolation)).
prompt_probe('eclipse-to-swi/disconnect', check_reverse_prompt_reconnect).
prompt_probe('swi-to-eclipse/racing-replies', check_forward_racing_replies).
prompt_probe('eclipse-to-swi/racing-replies', check_reverse_racing_replies).
prompt_probe('swi-to-eclipse/literal-prompt', check_forward_literal_prompt).
prompt_probe('eclipse-to-swi/literal-prompt', check_reverse_literal_prompt).
prompt_probe('swi-to-eclipse/watcher-exit', check_forward_watcher_exit).
prompt_probe('eclipse-to-swi/watcher-exit', check_reverse_watcher_exit).

check_forward_watcher_exit :-
    self(Owner),
    setup_call_cleanup(
        spawn(forward_retiring_watcher(Owner), Watcher, [monitor(true)]),
        setup_call_cleanup(
            spawn(forward_watcher_exit_parent(Owner, Watcher), Parent, [monitor(true)]),
            check_forward_watcher_handoff(Parent, Watcher, Owner),
            exit(Parent, probe_complete)),
        exit(Watcher, probe_complete)).

forward_retiring_watcher(Owner) :-
    receive({ prompt(Child, prompt_ref(Ref, follow_up)) ->
                  self(Watcher), Owner ! retiring_watcher_prompt(Watcher, Child, Ref) }).

forward_watcher_exit_parent(Owner, Watcher) :-
    Goal = (receive({probe_prompt_now -> true}),
            input(follow_up, answer(Value), [target(Watcher), correlate(true)]), output(got(Value))),
    spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), link(false)]),
    self(Parent),
    Owner ! watcher_exit_child(Parent, Child),
    receive({release_probe_parent -> true}).

check_forward_watcher_handoff(Parent, Watcher, Owner) :-
    receive({watcher_exit_child(Parent, Child) -> true}, [timeout(5), on_timeout(throw(missing_detached_child))]),
    setup_call_cleanup(
        monitor(Child, ChildRef),
        ( Parent ! release_probe_parent,
          await_probe_down(Parent, Parent, true),
          Child ! probe_prompt_now,
          Child = Id@_,
          receive({retiring_watcher_prompt(Watcher, Id, OldRef) -> true},
                  [timeout(3), on_timeout(throw(missing_original_prompt))]),
          await_probe_down(Watcher, Watcher, true),
          retarget_prompt(Child, OldRef, Owner),
          await_forward_watcher_prompt(Child, Ref),
          ( Ref \== OldRef -> true ; throw(error(domain_error(fresh_prompt_reference, Ref), _)) ),
          retarget_prompt(Child, OldRef, Owner),
          respond(Child, OldRef, answer(99)),
          respond(Child, Ref, answer(8)),
          check_forward_detached_prompt_result(Child, ChildRef, got(8))
        ),
        ( demonitor(ChildRef, [flush]), exit(Child, probe_complete) )).

check_reverse_watcher_exit :-
    reverse_prompt_pair(_{scenario:"watcher_exit"}, Result),
    ( _{parent_reason:"true", watcher_reason:"true", old_ref:Old, child:Child} :< Result,
      _{output:"got(8)", reason:"true", prompt_ref:New} :< Child,
      Old \== New -> true
    ; throw(error(domain_error(reverse_watcher_exit, Result), _))
    ).

check_forward_literal_prompt :-
    ( current_predicate(respond/2) -> Mode = legacy ; Mode = correlated ),
    Literal = prompt_ref(ref(999), question),
    ( Mode == legacy -> Input = input(Literal, answer(A))
    ; Input = input(Literal, answer(A), [correlate(true)])
    ),
    setup_call_cleanup(
        spawn((Input, output(got(A))), Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
        ( forward_literal_reply(Mode, Child, Literal),
          await_forward_output_event(Child, got(8)),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)).

forward_literal_reply(legacy, Child, Literal) :-
    await_forward_io_event(Child, prompt(Child, Data)),
    check_literal_prompt_data(Data, Literal),
    respond(Child, answer(8)).
forward_literal_reply(correlated, Child, Literal) :-
    await_forward_io_event(Child, prompt(Child, prompt_ref(Ref, Data))),
    check_literal_prompt_data(Data, Literal),
    respond(Child, ref(999), answer(99)),
    respond(Child, Ref, answer(8)).

check_literal_prompt_data(Data, Expected) :-
    ( atom(Data), term_string(Actual, Data), Actual == Expected -> true
    ; throw(error(domain_error(literal_prompt_data, Data), _))
    ).

check_reverse_literal_prompt :-
    Prompt = _{prompt:"prompt_ref(ref(999),question)", term_prompt:true, reply:"answer(8)"},
    ( current_predicate(respond/2) ->
        check_reverse_literal_prompt("input(prompt_ref(ref(999),question),answer(A))", Prompt, false)
    ; check_reverse_literal_prompt("input(prompt_ref(ref(999),question),answer(A))",
                                   Prompt.put(stale_ref, "ref(999)"), true)
    ).

check_reverse_literal_prompt(Input, Prompt, Correlate) :-
    format(string(Goal), "~s, writeln(got(A))", [Input]),
    Exchange = _{prompts:[Prompt], output:"got(8)", correlate:Correlate},
    reverse_spawn_probe(_{goal:Goal, prompt_exchange:Exchange, monitor:true}, Result),
    ( _{type:"down", output:"got(8)", reason:"true", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_literal_prompt, Result), _))
    ).

check_forward_racing_replies :-
    Goal = (input(first, answer(First), [correlate(true)]), memberchk(First, [21, 42]),
            input(second, answer(Second), [correlate(true)]), output(got(Second))),
    setup_call_cleanup(
        spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
        ( await_forward_io_event(Child, prompt(Child, prompt_ref(Ref, first))),
          spawn(receive({go -> respond(Child, Ref, answer(21))}), A, [monitor(true)]),
          spawn(receive({go -> respond(Child, Ref, answer(42))}), B, [monitor(true)]),
          A ! go,
          B ! go,
          await_probe_down(A, A, true),
          await_probe_down(B, B, true),
          await_forward_io_event(Child, prompt(Child, prompt_ref(SecondRef, second))),
          ( Ref \== SecondRef -> true ; throw(error(domain_error(fresh_prompt_reference, SecondRef), _)) ),
          respond(Child, SecondRef, answer(8)),
          await_forward_output_event(Child, got(8)),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)).

check_reverse_racing_replies :-
    Goal = "input(first, answer(A), [correlate(true)]), memberchk(A, [21,42]),
        input(second, answer(B), [correlate(true)]), writeln(got(B))",
    Prompts = [_{prompt:"first", reply:"answer(21)", race:true},
               _{prompt:"second", reply:"answer(8)"}],
    Exchange = _{prompts:Prompts, output:"got(8)", correlate:true},
    reverse_spawn_probe(_{goal:Goal, prompt_exchange:Exchange, monitor:true}, Result),
    ( _{type:"down", output:"got(8)", reason:"true", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_racing_replies, Result), _))
    ).

run_linked_spawn :-
    check_short_lived_child,
    gensym(linked_ref_, Token),
    Goal = (N is 6*7, output(linked_ready(Token, N)), receive({ probe_stop -> true })),
    check_linked_spawn(Goal, [], Token),
    writeln(swi_to_eclipse_linked_spawn_probe_passed),
    gensym(linked_source_ref_, SourceToken),
    Source = "caller_linked_goal(Token) :-
        caller_factor('base factor', Factor),
        N is Factor*7,
        output(linked_ready(Token, N)),
        receive({ probe_stop -> true }).
        caller_factor('base factor', 6).",
    check_linked_spawn(caller_linked_goal(SourceToken), [src_text(Source)], SourceToken),
    writeln(swi_to_eclipse_linked_spawn_src_text_probe_passed).

run_detached_spawn :-
    spawn((check_detached_exchange, check_final_replies), Watcher, [monitor(true)]),
    await_probe_down(Watcher, Watcher, true),
    writeln(swi_to_eclipse_detached_send_probe_passed).

check_detached_exchange :-
    self(Watcher),
    gensym(detached_ref_, Token),
    Goal = receive({ ping(From, Token, 'from swi', N) ->
        Reply is N*2,
        send(From, detached_reply(Token, Reply)),
        receive({ probe_stop -> true })
    }),
    setup_call_cleanup(
        spawn(forward_probe_parent(Watcher, Goal, [link(false)]), Parent),
        check_detached_child(Parent, Token),
        exit(Parent, probe_complete)
    ).

check_detached_child(Parent, Token) :-
    await_forward_spawn(Child),
    setup_call_cleanup(
        monitor(Child, ChildRef),
        ( setup_call_cleanup(
              monitor(Parent, ParentRef),
              ( Parent ! release_probe_parent, await_probe_down(Parent, ParentRef, true) ),
              demonitor(ParentRef, [flush])
          ),
          self(Watcher),
          Child ! ping(Watcher, Token, 'from swi', 21),
          receive({ detached_reply(Token, 42) -> true },
                  [timeout(3), on_timeout(throw(error(timeout_error(receive, detached_reply(Token)), _)))]),
          exit(Child, detached_probe_complete),
          check_forward_down(Child, ChildRef, detached_probe_complete)
        ),
        ( demonitor(ChildRef, [flush]), exit(Child, probe_complete) )
    ).

check_final_replies :-
    self(Watcher),
    gensym(final_reply_ref_, Token),
    Goal = receive({ ping(From, Token) ->
        send(From, final_reply(Token, first)),
        send(From, final_reply(Token, second))
    }),
    setup_call_cleanup(
        spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
        ( Child ! ping(Watcher, Token),
          await_final_reply(Token, first),
          await_final_reply(Token, second),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)
    ),
    writeln(swi_to_eclipse_final_replies_probe_passed).

await_final_reply(Token, Expected) :-
    receive({
        final_reply(Token, Reply) ->
            ( Reply == Expected -> true
            ; throw(error(domain_error(final_reply_order, Reply), await_final_reply/2))
            )
    }, [timeout(3), on_timeout(throw(error(timeout_error(receive, final_reply(Token, Expected)), _)))]).

check_forward_startup_output :-
    gensym(startup_output_ref_, Token),
    First = startup(Token, 'quoted value'),
    Second = startup(Token, ready),
    Goal = (output(First), output(Second)),
    spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
    await_forward_output_event(Child, First),
    await_forward_output_event(Child, Second),
    check_forward_down(Child, Child, true),
    writeln(swi_to_eclipse_startup_output_probe_passed).

await_forward_output_event(Child, Expected) :-
    await_forward_io_event(Child, output(Child, Expected)).

check_forward_prompt_exchange :-
    Goal = (input('Enter amount', amount(N)),
            input([o,k], confirm('go ahead')),
            Total is N*2,
            output(total(Total))),
    setup_call_cleanup(
        spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
        ( await_forward_io_event(Child, prompt(Child, 'Enter amount')),
          send(Child, '$input'(probe, unused_ref, amount(99))),
          respond(Child, amount(21)),
          await_forward_io_event(Child, prompt(Child, ok)),
          respond(Child, confirm('go ahead')),
          await_forward_output_event(Child, total(42)),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)
    ),
    writeln(swi_to_eclipse_prompt_exchange_probe_passed).

check_forward_correlated_prompts :-
    Goal = (input(first, answer(A), [correlate(true)]),
            input(second, answer(B), [correlate(true)]),
            output(answers(A, B))),
    setup_call_cleanup(
        spawn(Goal, Child, [node('http://127.0.0.1:8096/eclipse'), monitor(true)]),
        ( await_forward_io_event(Child, prompt(Child, prompt_ref(FirstRef, first))),
          Child = Id@Node,
          forall(member(BadRef, [42, "", "ref(", "ref(_)", "ref(1). ref(2)"]),
                 distribution:remote_send_command(Node, json{command:"probe_prompt_frame",
                                                               pid:Id, prompt_ref:BadRef})),
          send(Child, '$input'(probe, answer(99))),
          send(Child, '$input'(probe, _, answer(99))),
          respond(Child, FirstRef, wrong_shape),
          respond(Child, FirstRef, answer(21)),
          await_forward_io_event(Child, prompt(Child, prompt_ref(SecondRef, second))),
          ( FirstRef \== SecondRef -> true
          ; throw(error(domain_error(fresh_prompt_reference, SecondRef), check_forward_correlated_prompts/0))
          ),
          respond(Child, FirstRef, answer(21)),
          respond(Child, SecondRef, answer(8)),
          await_forward_output_event(Child, answers(21, 8)),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)
    ),
    writeln(swi_to_eclipse_correlated_prompts_probe_passed).

check_forward_concurrent_prompts :-
    with_forward_prompt_pair(check_forward_out_of_order_replies),
    writeln(swi_to_eclipse_concurrent_prompts_probe_passed),
    writeln(swi_to_eclipse_wrong_child_prompt_reply_probe_passed).

with_forward_prompt_pair(Check) :-
    Options = [node('http://127.0.0.1:8096/eclipse'), monitor(true)],
    Goal = (input(shared, answer(Value), [correlate(true)]), output(got(Value))),
    setup_call_cleanup(
        spawn(Goal, First, Options),
        ( await_forward_io_event(First, prompt(First, prompt_ref(FirstRef, shared))),
          setup_call_cleanup(
              spawn(Goal, Second, Options),
              ( await_forward_io_event(Second, prompt(Second, prompt_ref(SecondRef, shared))),
                verify_distinct_prompts(First-FirstRef, Second-SecondRef),
                call(Check, First-FirstRef, Second-SecondRef)
              ),
              exit(Second, probe_complete))
        ),
        exit(First, probe_complete)).

check_forward_out_of_order_replies(First-FirstRef, Second-SecondRef) :-
    respond(First, SecondRef, answer(8)),
    respond(Second, SecondRef, answer(8)),
    await_forward_output_event(Second, got(8)),
    check_forward_down(Second, Second, true),
    respond(First, FirstRef, answer(21)),
    await_forward_output_event(First, got(21)),
    check_forward_down(First, First, true).

check_forward_late_prompt_reply(First-FirstRef, Second-SecondRef) :-
    exit(First, pending_prompt_exit),
    await_probe_down(First, First, pending_prompt_exit),
    respond(First, FirstRef, answer(21)),
    respond(Second, FirstRef, answer(21)),
    respond(Second, SecondRef, answer(8)),
    await_forward_output_event(Second, got(8)),
    check_forward_down(Second, Second, true),
    check_eclipse_down(First, pending_prompt_exit),
    writeln(swi_to_eclipse_late_prompt_reply_probe_passed).

check_forward_parent_exit_with_pending_prompts :-
    check_forward_parent_exit_with_prompt_pair(true),
    writeln(swi_to_eclipse_parent_exit_pending_prompts_probe_passed).

check_forward_parent_exit_with_detached_prompt :-
    check_forward_parent_exit_with_prompt_pair(false),
    writeln(swi_to_eclipse_parent_exit_detached_prompt_probe_passed),
    writeln(swi_to_eclipse_parent_exit_late_reply_probe_passed),
    writeln(swi_to_eclipse_parent_exit_wrong_ref_probe_passed),
    writeln(swi_to_eclipse_detached_follow_up_prompt_probe_passed).

check_forward_parent_exit_with_prompt_pair(SecondLink) :-
    self(Watcher),
    setup_call_cleanup(
        spawn(forward_pending_prompt_parent(Watcher, SecondLink), Parent, [monitor(true)]),
        ( receive({ probe_pending_prompts(Parent, First-FirstPromptRef, Second-SecondPromptRef) -> true },
                  [timeout(8), on_timeout(throw(error(timeout_error(receive, pending_prompts(Parent)), _)))]),
          setup_call_cleanup(
              monitor(First, FirstRef),
              setup_call_cleanup(
                  monitor(Second, SecondRef),
                  ( Parent ! release_probe_parent,
                    await_probe_down(Parent, Parent, true),
                    check_forward_down(First, FirstRef, kill),
                    finish_forward_pending_prompt(SecondLink, First-FirstPromptRef,
                                                  Second-SecondPromptRef, SecondRef)
                  ),
                  ( demonitor(SecondRef, [flush]), exit(Second, probe_complete) )),
              demonitor(FirstRef, [flush]))
        ),
        exit(Parent, probe_complete)).

forward_pending_prompt_parent(Watcher, SecondLink) :-
    Node = 'http://127.0.0.1:8096/eclipse',
    Goal = (input(shared, answer(Value), [correlate(true)]), output(got(Value))),
    spawn(Goal, First, [node(Node), link(true)]),
    await_forward_io_event(First, prompt(First, prompt_ref(FirstRef, shared))),
    ( SecondLink == true -> SecondGoal = Goal
    ; SecondGoal = (input(shared, answer(A), [correlate(true)]),
                    input(follow_up, answer(B), [target(Watcher), correlate(true)]),
                    output(answers(A, B)))
    ),
    spawn(SecondGoal, Second, [node(Node), link(SecondLink)]),
    await_forward_io_event(Second, prompt(Second, prompt_ref(SecondRef, shared))),
    verify_distinct_prompts(First-FirstRef, Second-SecondRef),
    self(Parent),
    Watcher ! probe_pending_prompts(Parent, First-FirstRef, Second-SecondRef),
    receive({ release_probe_parent -> true }).

finish_forward_pending_prompt(true, _, Child-_, Ref) :-
    check_forward_down(Child, Ref, kill).
finish_forward_pending_prompt(false, Linked-LinkedPromptRef, Child-PromptRef, Ref) :-
    respond(Linked, LinkedPromptRef, answer(21)),
    respond(Child, LinkedPromptRef, answer(21)),
    respond(Child, PromptRef, answer(8)),
    await_forward_watcher_prompt(Child, FollowRef),
    ( FollowRef \== PromptRef -> true
    ; throw(error(domain_error(fresh_prompt_reference, FollowRef), _))
    ),
    respond(Child, PromptRef, answer(8)),
    respond(Child, FollowRef, answer(13)),
    check_forward_detached_prompt_result(Child, Ref, answers(8, 13)).

await_forward_watcher_prompt(Child, PromptRef) :-
    Child = Id@_,
    receive({ prompt(Id, prompt_ref(PromptRef, follow_up)) -> true },
            [timeout(3), on_timeout(throw(error(timeout_error(receive, follow_up(Child)), _)))]),
    must_be(ground, PromptRef).

check_forward_detached_prompt_result(Child, Ref, Expected) :-
    await_probe_down(Child, Ref, true),
    check_eclipse_down(Child, true, State),
    ( term_string(Outcome, State.output), Outcome == Expected -> true
    ; throw(error(domain_error(detached_prompt_output, State), context(Child, Expected)))
    ).

check_forward_detached_watcher_pair :-
    self(Watcher),
    setup_call_cleanup(
        spawn(forward_detached_watcher_parent(Watcher), Parent, [monitor(true)]),
        ( receive({ probe_detached_children(Parent, First, Second) -> true },
                  [timeout(8), on_timeout(throw(error(timeout_error(receive, detached_children(Parent)), _)))]),
          setup_call_cleanup(
              ( monitor(First, FirstRef), monitor(Second, SecondRef) ),
              ( Parent ! release_probe_parent,
                await_probe_down(Parent, Parent, true),
                First ! probe_prompt_now,
                await_forward_watcher_prompt(First, FirstPromptRef),
                Second ! probe_prompt_now,
                await_forward_watcher_prompt(Second, SecondPromptRef),
                verify_distinct_prompts(First-FirstPromptRef, Second-SecondPromptRef),
                respond(Second, SecondPromptRef, answer(8)),
                check_forward_detached_prompt_result(Second, SecondRef, got(8)),
                respond(First, FirstPromptRef, answer(21)),
                check_forward_detached_prompt_result(First, FirstRef, got(21))
              ),
              ( demonitor(FirstRef, [flush]), demonitor(SecondRef, [flush]),
                exit(First, probe_complete), exit(Second, probe_complete) ))
        ),
        exit(Parent, probe_complete)),
    writeln(swi_to_eclipse_detached_watcher_out_of_order_probe_passed).

forward_detached_watcher_parent(Watcher) :-
    Goal = (receive({ probe_prompt_now -> true }),
            input(follow_up, answer(Value), [target(Watcher), correlate(true)]),
            output(got(Value))),
    Options = [node('http://127.0.0.1:8096/eclipse'), link(false)],
    spawn(Goal, First, Options),
    spawn(Goal, Second, Options),
    self(Parent),
    Watcher ! probe_detached_children(Parent, First, Second),
    receive({ release_probe_parent -> true }).

verify_distinct_prompts(First-FirstRef, Second-SecondRef) :-
    ( First \== Second, FirstRef \== SecondRef -> true
    ; throw(error(domain_error(distinct_child_prompts, [First-FirstRef, Second-SecondRef]), _))
    ).

await_forward_io_event(Child, Expected) :-
    receive({
        output(Child, Term) -> Event = output(Child, Term)
    ;
        prompt(Child, Prompt) -> Event = prompt(Child, Prompt)
    ;
        down(Child, Child, Reason) ->
            throw(error(domain_error(io_before_down, Reason),
                        context(await_forward_io_event/2, Expected)))
    }, [timeout(3), on_timeout(throw(error(timeout_error(receive, Expected), _)))]),
    ( subsumes_term(Expected, Event), Expected = Event -> true
    ; throw(error(domain_error(forward_io_event, Event), context(await_forward_io_event/2, Expected)))
    ).

check_forward_disconnect :-
    Node = 'http://127.0.0.1:8096/eclipse',
    Goal = input(disconnect_ready, _, [correlate(true)]),
    spawn(Goal, Linked, [node(Node), link(true), monitor(true)]),
    spawn(Goal, Detached, [node(Node), link(false), monitor(true)]),
    watch_forward_disconnect(Linked, OldRef),
    watch_forward_disconnect(Detached, _),
    distribution:remote_send_command(Node, json{command:probe_disconnect}),
    maplist(check_forward_disconnected, [Linked, Detached]),
    check_forward_prompt_reconnect(Node, OldRef),
    writeln(swi_to_eclipse_connection_closed_probe_passed).

watch_forward_disconnect(Child, Ref) :-
    await_forward_io_event(Child, prompt(Child, prompt_ref(Ref, disconnect_ready))),
    watch_eclipse_disconnect(Child).

check_forward_prompt_reconnect(Node, OldRef) :-
    Goal = (input(reconnected, answer(Value), [correlate(true)]), output(got(Value))),
    setup_call_cleanup(
        spawn(Goal, Child, [node(Node), monitor(true)]),
        ( await_forward_io_event(Child, prompt(Child, prompt_ref(Ref, reconnected))),
          ( Ref \== OldRef -> true ; throw(error(domain_error(fresh_prompt_reference, Ref), _)) ),
          respond(Child, OldRef, answer(99)),
          respond(Child, Ref, answer(8)),
          await_forward_output_event(Child, got(8)),
          check_forward_down(Child, Child, true)
        ),
        exit(Child, probe_complete)).

watch_eclipse_disconnect(Child) :-
    Child = Id@_,
    child_request(_{action:"watch_disconnect", child:Id}, Reply),
    ( Reply.type == "watching" -> true
    ; throw(error(domain_error(watch_disconnect_reply, Reply), watch_eclipse_disconnect/1))
    ).

check_forward_disconnected(Child) :-
    await_probe_down(Child, Child, connection_closed),
    check_eclipse_down(Child, gateway_closed).

check_forward_connection_isolation :-
    setup_call_cleanup(
        open_isolation_socket(First),
        setup_call_cleanup(
            open_isolation_socket(Second),
            check_isolated_connections(First, Second),
            close_isolation_socket(Second)
        ),
        close_isolation_socket(First)
    ),
    writeln(swi_to_eclipse_connection_isolation_probe_passed).

open_isolation_socket(Socket) :-
    http_open_websocket('ws://127.0.0.1:8096/eclipse/ws', Socket,
                        [timeout(3), subprotocols(['web-prolog-sync-spawn-v1'])]).

close_isolation_socket(Socket) :-
    ( is_stream(Socket) -> close(Socket, [force(true)]) ; true ).

check_isolated_connections(First, Second) :-
    Node = 'http://127.0.0.1:8096/eclipse',
    Source = 'isolation_actor :- receive({
        probe(foreign) -> exit(foreign_send_delivered)
        ; probe(Value) -> output(connection_value(Value)), isolation_actor
    }).',
    distribution:term_to_wire_atom([src_text(Source)], Options),
    Spawn = _{command:"spawn", goal:"isolation_actor", options:Options, request_id:"isolation_spawn"},
    ws_send(First, json(Spawn)),
    ws_send(Second, json(Spawn)),
    isolation_event(First, _{type:"spawned", pid:FirstId, request_id:"isolation_spawn"}),
    isolation_event(Second, _{type:"spawned", pid:SecondId, request_id:"isolation_spawn"}),
    ( FirstId \== SecondId -> true
    ; throw(error(domain_error(distinct_actor_pids, FirstId), check_isolated_connections/2))
    ),
    check_foreign_commands(First, SecondId),
    check_foreign_commands(Second, FirstId),
    send_isolation_probe(First, FirstId, first_owner),
    send_isolation_probe(Second, SecondId, second_owner),
    watch_eclipse_disconnect(FirstId@Node),
    ws_close(First, 1000, "isolation probe complete"),
    check_eclipse_down(FirstId@Node, gateway_closed),
    send_isolation_probe(Second, SecondId, after_peer_close),
    ws_send(Second, json(_{command:"exit", pid:SecondId, reason:"isolation_complete"})),
    isolation_event(Second, _{type:"down", pid:SecondId, reason:"isolation_complete"}),
    check_eclipse_down(SecondId@Node, isolation_complete).

check_foreign_commands(Socket, Id) :-
    ws_send(Socket, json(_{command:"send", pid:Id, message:"probe(foreign)", request_id:"foreign_send"})),
    isolation_event(Socket, _{type:"error", request_id:"foreign_send", data:SendError}),
    term_string(error(permission_error(send, websocket_actor, Id), _), SendError),
    ws_send(Socket, json(_{command:"exit", pid:Id, reason:"kill", request_id:"foreign_exit"})),
    isolation_event(Socket, _{type:"error", request_id:"foreign_exit", data:ExitError}),
    term_string(error(permission_error(exit, websocket_actor, Id), _), ExitError).

send_isolation_probe(Socket, Id, Value) :-
    term_string(probe(Value), Message),
    ws_send(Socket, json(_{command:"send", pid:Id, message:Message})),
    isolation_event(Socket, _{type:"output", pid:Id, data:Text}),
    term_string(connection_value(Value), Text).

isolation_event(Socket, Expected) :-
    ws_receive(Socket, Frame, [format(json)]),
    ( Frame.opcode == text, Expected :< Frame.data -> true
    ; throw(error(domain_error(isolation_event, Frame), context(isolation_event/2, Expected)))
    ).

run_reverse_linked_spawn :-
    check_reverse_linked_spawn(_{}, "reverse_probe_ready"),
    writeln(eclipse_to_swi_linked_spawn_probe_passed),
    Goal = "Number is 6*7, writeln(Number), receive({ probe_stop -> true })",
    check_reverse_linked_spawn(_{goal:Goal, ready:"42"}, "42"),
    writeln(eclipse_to_swi_linked_spawn_goal_probe_passed),
    reverse_spawn_probe(_{goal:"true", ready:"unused", src_text:"bad_clause( ."}, Rejected),
    ( Rejected.type == "error" -> true
    ; throw(error(domain_error(reverse_spawn_rejection, Rejected), run_reverse_linked_spawn/0))
    ),
    Source = "reverse_caller_goal :-
        reverse_factor('base factor', Factor),
        Number is Factor*7,
        writeln(Number),
        receive({ probe_stop -> true }).
        reverse_factor('base factor', 8).",
    check_reverse_linked_spawn(_{goal:"reverse_caller_goal", src_text:Source, ready:"56"}, "56"),
    writeln(eclipse_to_swi_linked_spawn_src_text_probe_passed),
    check_reverse_monitor("true", true),
    check_reverse_monitor("throw(probe_child_exception)", exception(probe_child_exception)),
    writeln(eclipse_to_swi_remote_monitor_probe_passed),
    writeln(eclipse_to_swi_spawn_monitor_probe_passed),
    check_reverse_demonitor("before"),
    check_reverse_demonitor("after"),
    writeln(eclipse_to_swi_demonitor_probe_passed),
    check_reverse_send,
    writeln(eclipse_to_swi_remote_send_probe_passed),
    check_reverse_exit,
    writeln(eclipse_to_swi_remote_exit_probe_passed),
    check_reverse_detached,
    writeln(eclipse_to_swi_detached_spawn_probe_passed),
    writeln(eclipse_to_swi_mailbox_reply_probe_passed),
    check_reverse_final_replies,
    writeln(eclipse_to_swi_final_replies_probe_passed),
    check_reverse_disconnect(true),
    check_reverse_disconnect(false),
    writeln(eclipse_to_swi_connection_closed_probe_passed),
    check_reverse_connection_isolation,
    writeln(eclipse_to_swi_connection_isolation_probe_passed),
    check_reverse_startup_replies,
    writeln(eclipse_to_swi_startup_replies_probe_passed),
    check_legacy_prompt_probe(check_reverse_prompt_exchange),
    check_reverse_correlated_prompts,
    writeln(eclipse_to_swi_correlated_prompts_probe_passed),
    check_reverse_concurrent_prompts,
    check_reverse_late_prompt_reply,
    check_reverse_parent_exit_with_pending_prompts,
    check_reverse_parent_exit_with_detached_prompt,
    check_reverse_detached_watcher_pair.

check_reverse_concurrent_prompts :-
    reverse_prompt_pair(_{}, Result),
    ( _{first:First, second:Second, parent_reason:"true"} :< Result,
      _{pid:FirstPid, prompt_ref:FirstRef, output:"got(21)", reason:"true"} :< First,
      _{pid:SecondPid, prompt_ref:SecondRef, output:"got(8)", reason:"true"} :< Second
    -> verify_distinct_prompts(FirstPid-FirstRef, SecondPid-SecondRef)
    ; throw(error(domain_error(reverse_concurrent_prompts, Result), _))
    ),
    writeln(eclipse_to_swi_concurrent_prompts_probe_passed),
    writeln(eclipse_to_swi_wrong_child_prompt_reply_probe_passed).

check_reverse_late_prompt_reply :-
    reverse_prompt_pair(_{scenario:"late_reply"}, Result),
    ( _{first:First, second:Second, parent_reason:"true"} :< Result,
      _{pid:FirstPid, prompt_ref:FirstRef, reason:"pending_prompt_exit"} :< First,
      _{pid:SecondPid, prompt_ref:SecondRef, output:"got(8)", reason:"true"} :< Second
    -> verify_distinct_prompts(FirstPid-FirstRef, SecondPid-SecondRef)
    ; throw(error(domain_error(reverse_late_prompt_reply, Result), _))
    ),
    writeln(eclipse_to_swi_late_prompt_reply_probe_passed).

check_reverse_parent_exit_with_pending_prompts :-
    reverse_prompt_pair(_{scenario:"parent_exit"}, Result),
    ( _{first:First, second:Second, parent_reason:"true"} :< Result,
      _{pid:FirstPid, prompt_ref:FirstRef, reason:"kill"} :< First,
      _{pid:SecondPid, prompt_ref:SecondRef, reason:"kill"} :< Second
    -> verify_distinct_prompts(FirstPid-FirstRef, SecondPid-SecondRef)
    ; throw(error(domain_error(reverse_parent_exit_pending_prompts, Result), _))
    ),
    writeln(eclipse_to_swi_parent_exit_pending_prompts_probe_passed).

check_reverse_parent_exit_with_detached_prompt :-
    reverse_prompt_pair(_{scenario:"mixed_parent_exit"}, Result),
    ( _{first:First, second:Second, parent_reason:"true"} :< Result,
      _{pid:FirstPid, prompt_ref:FirstRef, reason:"kill"} :< First,
      _{pid:SecondPid, prompt_ref:SecondRef, output:"answers(8,13)", reason:"true"} :< Second
    -> verify_distinct_prompts(FirstPid-FirstRef, SecondPid-SecondRef)
    ; throw(error(domain_error(reverse_parent_exit_detached_prompt, Result), _))
    ),
    writeln(eclipse_to_swi_parent_exit_detached_prompt_probe_passed),
    writeln(eclipse_to_swi_parent_exit_late_reply_probe_passed),
    writeln(eclipse_to_swi_parent_exit_wrong_ref_probe_passed),
    writeln(eclipse_to_swi_detached_follow_up_prompt_probe_passed).

check_reverse_detached_watcher_pair :-
    reverse_prompt_pair(_{scenario:"detached_pair"}, Result),
    ( _{first:First, second:Second, parent_reason:"true"} :< Result,
      _{pid:FirstPid, prompt_ref:FirstRef, output:"got(21)", reason:"true"} :< First,
      _{pid:SecondPid, prompt_ref:SecondRef, output:"got(8)", reason:"true"} :< Second
    -> verify_distinct_prompts(FirstPid-FirstRef, SecondPid-SecondRef)
    ; throw(error(domain_error(reverse_detached_watcher_pair, Result), _))
    ),
    writeln(eclipse_to_swi_detached_watcher_out_of_order_probe_passed).

reverse_prompt_pair(Request, Result) :-
    http_post('http://127.0.0.1:8096/probe_reverse_concurrent_prompts', json(Request), Result,
              [json_object(dict), timeout(12)]).

check_reverse_prompt_exchange :-
    Goal = "input('Enter amount', amount([N])),
        input([o,k], confirm('go ahead')),
        Total is N*2,
        writeln(total(Total))",
    Prompts = [_{prompt:"Enter amount", reply:"amount([21])"},
               _{prompt:"ok", reply:"confirm('go ahead')"}],
    Exchange = _{prompts:Prompts, output:"total(42)"},
    reverse_spawn_probe(_{goal:Goal, prompt_exchange:Exchange, monitor:true}, Result),
    ( _{type:"down", output:"total(42)", reason:"true", parent_reason:"true"} :< Result
    -> true
    ; throw(error(domain_error(reverse_prompt_exchange, Result), check_reverse_prompt_exchange/0))
    ).

check_reverse_correlated_prompts :-
    Goal = "input(first, answer(A), [correlate(true)]),
        input(second, answer(B), [correlate(true)]),
        writeln(answers(A, B))",
    Prompts = [_{prompt:"first", reply:"answer(21)"},
               _{prompt:"second", reply:"answer(8)"}],
    Exchange = _{prompts:Prompts, output:"answers(21,8)", correlate:true},
    reverse_spawn_probe(_{goal:Goal, prompt_exchange:Exchange, monitor:true}, Result),
    ( _{type:"down", output:"answers(21,8)", reason:"true", parent_reason:"true"} :< Result
    -> true
    ; throw(error(domain_error(reverse_correlated_prompts, Result), check_reverse_correlated_prompts/0))
    ).

check_reverse_startup_replies :-
    Goal = "send(ReplyTo, startup(first)), send(ReplyTo, startup(second))",
    Replies = ["startup(first)", "startup(second)"],
    reverse_spawn_probe(_{goal:Goal, startup_replies:Replies, monitor:true}, Result),
    ( _{type:"down", replies:Replies, reason:"true", parent_reason:"true"} :< Result
    -> true
    ; throw(error(domain_error(reverse_startup_replies, Result), check_reverse_startup_replies/0))
    ).

check_reverse_disconnect(Link) :-
    check_reverse_disconnect(Link, _).

check_reverse_disconnect(Link, PromptRef) :-
    Goal = "self(Child),
        send(swi_echo@'http://127.0.0.1:8095', watch_disconnect(Child)),
        receive({ disconnect_watched -> true }),
        writeln(waiting_for_disconnect),
        receive({ probe_prompt_now -> true }),
        input(disconnect_ready, _, [correlate(true)])",
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_disconnect", monitor:true,
                          link:Link, disconnect:true, disconnect_prompt:"disconnect_ready"}, Result),
    ( _{type:"down", pid:Id, reason:"connection_closed", parent_reason:"true", prompt_ref:PromptRef} :< Result -> true
    ; throw(error(domain_error(reverse_disconnect, Result), check_reverse_disconnect/1))
    ),
    await_swi_child_down(Id@'http://127.0.0.1:8095', kill).

check_reverse_prompt_reconnect :-
    check_reverse_disconnect(true, OldRef),
    check_reverse_disconnect(false),
    Goal = "input(reconnected, answer(Value), [correlate(true)]), writeln(got(Value))",
    Prompts = [_{prompt:"reconnected", reply:"answer(8)", stale_ref:OldRef}],
    Exchange = _{prompts:Prompts, output:"got(8)", correlate:true},
    reverse_spawn_probe(_{goal:Goal, prompt_exchange:Exchange, monitor:true}, Result),
    ( _{type:"down", output:"got(8)", reason:"true", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_prompt_reconnect, Result), _))
    ),
    check_reverse_connection_isolation.

await_swi_child_down(Child, Expected) :-
    receive({
        probe_swi_child_down(Child, Reason) ->
            ( Reason == Expected -> true
            ; throw(error(domain_error(probe_swi_child_exit, Reason), context(await_swi_child_down/2, Child)))
            )
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, probe_swi_child_down(Child)), _)))]).

check_reverse_connection_isolation :-
    gensym(reverse_isolation_, Token),
    reverse_isolation_requests(Token, FirstRequest, SecondRequest),
    thread_self(Watcher),
    setup_call_cleanup(
        thread_create(run_isolation_request(Watcher, Token, first, FirstRequest), FirstThread, []),
        setup_call_cleanup(
            thread_create(run_isolation_request(Watcher, Token, second, SecondRequest), SecondThread, []),
            check_overlapping_reverse_spawns(Token, SecondRequest.exchange.reply_term),
            thread_join(SecondThread, _)
        ),
        thread_join(FirstThread, _)
    ).

reverse_isolation_requests(Token, First, Second) :-
    reverse_isolation_goal(Token, first, receive({ probe_stop -> true }), FirstGoal),
    LastGoal = receive({ request(From, finish(Token)) -> send(From, reply(Token)) }),
    reverse_isolation_goal(Token, second, LastGoal, SecondGoal),
    term_string(finish(Token), Message),
    term_string(reply(Token), Reply),
    First = _{goal:FirstGoal, ready:"waiting_for_isolation", monitor:true, disconnect:true},
    Second = _{goal:SecondGoal, ready:"waiting_for_isolation", monitor:true, await_down:true,
               exchange:_{message:Message, reply_term:Reply}}.

reverse_isolation_goal(Token, Role, Tail, Text) :-
    Goal = (self(Child),
            send(swi_echo@'http://127.0.0.1:8095', watch_isolation(Token, Role, Child)),
            receive({ isolation_go(Token, Role) -> true }),
            writeln(waiting_for_isolation),
            Tail),
    distribution:term_to_wire_atom(Goal, Wire),
    atom_string(Wire, Text).

run_isolation_request(Watcher, Token, Role, Request) :-
    catch(
        ( reverse_spawn_probe(Request, Result),
          thread_send_message(Watcher, reverse_isolation_result(Token, Role, Result))
        ),
        Error,
        thread_send_message(Watcher, reverse_isolation_error(Token, Error))
    ).

check_overlapping_reverse_spawns(Token, ExpectedReply) :-
    await_reverse_isolation_ready(Token, first, First),
    await_reverse_isolation_ready(Token, second, Second),
    ( First \== Second -> true
    ; throw(error(domain_error(distinct_actor_pids, First), check_overlapping_reverse_spawns/2))
    ),
    First ! isolation_go(Token, first),
    First = FirstId@_,
    await_reverse_isolation_result(Token, first,
        _{type:"down", pid:FirstId, reason:"connection_closed", parent_reason:"true"}),
    await_swi_child_down(First, kill),
    Second ! isolation_go(Token, second),
    Second = SecondId@_,
    await_reverse_isolation_result(Token, second,
        _{type:"down", pid:SecondId, reply:ExpectedReply, reason:"true", parent_reason:"true"}),
    await_swi_child_down(Second, true).

await_reverse_isolation_ready(Token, Role, Child) :-
    receive({
        reverse_isolation_ready(Token, Role, Child) -> true
    ;
        reverse_isolation_error(Token, Error) -> throw(Error)
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, isolation_ready(Role)), _)))]).

await_reverse_isolation_result(Token, Role, Expected) :-
    receive({
        reverse_isolation_result(Token, Role, Result) ->
            ( Expected :< Result -> true
            ; throw(error(domain_error(reverse_isolation_result, Result),
                          context(await_reverse_isolation_result/3, Role)))
            )
    ;
        reverse_isolation_error(Token, Error) -> throw(Error)
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, isolation_result(Role)), _)))]).

check_reverse_final_replies :-
    Goal = "writeln(waiting_for_final_request),
        receive({ request(From, finish) ->
            send(From, reply(first)), send(From, reply(second))
        })",
    Expected = ["reply(first)", "reply(second)"],
    Exchange = _{message:"finish", reply_terms:Expected},
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_final_request",
                          exchange:Exchange, await_down:true}, Result),
    ( _{type:"down", replies:Expected, reason:"true", parent_reason:"true"} :< Result
    -> true
    ; throw(error(domain_error(reverse_final_replies, Result), check_reverse_final_replies/0))
    ).

check_reverse_detached :-
    reverse_message_goal(Goal, Exchange),
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_message", exchange:Exchange,
                          link:false, exit_reason:"detached_probe_complete"}, Result),
    ( _{type:"down", reply:"reply(42)", reason:"detached_probe_complete", parent_reason:"true"} :< Result
    -> true
    ; throw(error(domain_error(reverse_detached_result, Result), check_reverse_detached/0))
    ).

check_reverse_exit :-
    Goal = "writeln(waiting_for_exit), receive({ probe_stop -> true })",
    Reason = stopped('caller request'),
    term_string(Reason, Text, [quoted(true)]),
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_exit", exit_reason:Text}, Result),
    ( _{type:"down", reason:Down, parent_reason:"true"} :< Result,
      term_string(Reason, Down) -> true
    ; throw(error(domain_error(reverse_exit_result, Result), check_reverse_exit/0))
    ).

check_reverse_send :-
    reverse_message_goal(Goal, Exchange),
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_message", exchange:Exchange}, Result),
    ( _{type:"down", reply:"reply(42)", reason:"kill", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_send_result, Result), check_reverse_send/0))
    ).

reverse_message_goal(Goal, Exchange) :-
    Goal = "writeln(waiting_for_message),
        receive({ request(From, ping('from eclipse', N)) ->
            Reply is N*2, send(From, reply(Reply)), receive({ probe_stop -> true })
        })",
    Exchange = _{message:"ping('from eclipse', 21)", reply_term:"reply(42)"}.

check_reverse_monitor(Goal, Reason) :-
    reverse_spawn_probe(_{goal:Goal, monitor:true}, Completed),
    ( _{type:"down", reason:Text, parent_reason:"true"} :< Completed,
      term_string(Reason, Text) -> true
    ; throw(error(domain_error(reverse_spawn_completion, Completed), check_reverse_monitor/2))
    ).

check_reverse_demonitor(Phase) :-
    Goal = "writeln(waiting_for_demonitor), receive({ probe_stop -> true })",
    reverse_spawn_probe(_{goal:Goal, ready:"waiting_for_demonitor", monitor:true,
                          demonitor:Phase, exit_reason:"demonitor_probe_complete"}, Result),
    ( _{type:"down", reason:"demonitor_probe_complete", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_demonitor, Result), context(check_reverse_demonitor/1, Phase)))
    ).

check_reverse_linked_spawn(Request, Output) :-
    reverse_spawn_probe(Request, Result),
    ( _{type:"down", output:Output, reason:"kill", parent_reason:"true"} :< Result -> true
    ; throw(error(domain_error(reverse_linked_child_exit, Result), check_reverse_linked_spawn/2))
    ).

reverse_spawn_probe(Request, Result) :-
    http_post('http://127.0.0.1:8096/probe_reverse_spawn', json(Request), Result,
              [json_object(dict), timeout(12)]).

check_linked_spawn(Goal, Options, Token) :-
    self(Watcher),
    setup_call_cleanup(
        spawn(forward_probe_parent(Watcher, Goal, [link(true)|Options]), Parent),
        check_linked_child(Parent, Token),
        exit(Parent, probe_complete)
    ).

check_short_lived_child :-
    spawn(true, Child,
          [node('http://127.0.0.1:8096/eclipse'), link(true), monitor(true)]),
    receive({
        down(Child, Child, Reason) ->
            ( Reason == true -> true
            ; throw(error(domain_error(successful_child_exit, Reason), _))
            )
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, down(Child)), _)))]).

forward_probe_parent(Watcher, Goal, Options) :-
    catch(
        ( spawn(Goal, Child,
                [node('http://127.0.0.1:8096/eclipse')|Options]),
          Watcher ! probe_spawned(Child),
          receive({ release_probe_parent -> true })
        ),
        Error,
        Watcher ! probe_spawn_error(Error)
    ).

check_linked_child(Parent, Token) :-
    await_forward_spawn(Child),
    await_forward_output(Child, linked_ready(Token, 42)),
    setup_call_cleanup(
        monitor(Child, Ref),
        ( Parent ! release_probe_parent, check_forward_down(Child, Ref, kill) ),
        demonitor(Ref, [flush])
    ).

await_forward_spawn(Child) :-
    receive({
        probe_spawned(Child) -> true
    ;
        probe_spawn_error(Error) -> throw(Error)
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, remote_spawn), _)))]).

check_forward_down(Child, Ref, Reason) :-
    await_probe_down(Child, Ref, Reason),
    check_eclipse_down(Child, Reason).

check_eclipse_down(Child, Reason) :-
    check_eclipse_down(Child, Reason, _).

check_eclipse_down(Child, Reason, State) :-
    Child = Id@_,
    child_request(_{action:"status", child:Id}, State),
    ( _{type:"down", reason:Text} :< State, term_string(Reason, Text) -> true
    ; throw(error(domain_error(forward_child_exit, State), check_eclipse_down/2))
    ),
    child_request(_{action:"forget", child:Id}, _).

await_probe_down(Pid, Ref, Expected) :-
    receive({
        down(Pid, Ref, Reason) ->
            ( Reason == Expected -> true
            ; throw(error(domain_error(probe_exit_reason, Reason), context(await_probe_down/3, Pid)))
            )
    }, [timeout(5), on_timeout(throw(error(timeout_error(receive, down(Pid)), _)))]).

await_forward_output(Id@_, Expected) :-
    get_time(Now),
    Deadline is Now + 3,
    await_forward_output(Id, Expected, Deadline).

await_forward_output(Id, Expected, Deadline) :-
    child_request(_{action:"status", child:Id}, Status),
    (   _{type:"running", output:Text} :< Status,
        string(Text),
        term_string(Expected, Text)
    ->  true
    ;   Status.type == "running", get_time(Now), Now < Deadline
    ->  sleep(0.05), await_forward_output(Id, Expected, Deadline)
    ;   throw(error(domain_error(forward_child_output, Status), context(await_forward_output/3, Expected)))
    ).

child_request(Dict, Event) :-
    http_post('http://127.0.0.1:8094/actor_probe', json(Dict), Event,
              [json_object(dict), timeout(3)]).

run_pingpong :-
    gensym(swi_ref_, Forward),
    Ping = ping(swi_echo@'http://127.0.0.1:8095', Forward),
    check_eclipse_echo(Ping, Forward),
    eclipse_echo@'http://127.0.0.1:8096/eclipse' ! Ping,
    receive({
        probe_pong(Forward) -> true
    }, [timeout(3), on_timeout(throw(error(timeout_error(receive, pong(Forward)), run_pingpong/0)))]),
    writeln('SWI-Prolog sent ping and received ECLiPSe pong'),
    gensym(eclipse_ref_, Reverse),
    atom_string(Reverse, Text),
    http_post('http://127.0.0.1:8096/probe_ping', json(_{ref:Text}), Sent,
              [json_object(dict), timeout(3)]),
    Sent.type == "sent",
    receive({
        probe_ping(Reverse) -> true
    }, [timeout(3), on_timeout(throw(error(timeout_error(receive, ping(Reverse)), run_pingpong/0)))]),
    get_time(Now),
    Deadline is Now + 3,
    await_eclipse_pong(Text, Deadline),
    writeln('ECLiPSe sent ping and received SWI-Prolog pong').

check_eclipse_echo(Ping, Ref) :-
    distribution:term_to_wire_atom(Ping, Text),
    http_post('http://127.0.0.1:8094/actor_probe',
              json(_{action:"deliver", message:Text}), Event,
              [json_object(dict), timeout(3)]),
    (   _{type:"send", pid:"swi_echo", node:"http://127.0.0.1:8095",
          message:Reply} :< Event,
        term_string(pong(Ref), Reply)
    ->  writeln('ECLiPSe resident echo passed its direct transport preflight')
    ;   throw(error(domain_error(eclipse_echo_reply, Event), check_eclipse_echo/2))
    ).

swi_probe_actor(Parent) :-
    receive({
        ping(From, Ref) ->
            From ! pong(Ref),
            Parent ! probe_ping(Ref)
    ;
        pong(Ref) ->
            Parent ! probe_pong(Ref)
    ;
        watch_disconnect(Child) ->
            monitor(Child, _),
            Child ! disconnect_watched
    ;
        watch_isolation(Token, Role, Child) ->
            monitor(Child, _),
            Parent ! reverse_isolation_ready(Token, Role, Child)
    ;
        down(Child, _, Reason) ->
            Parent ! probe_swi_child_down(Child, Reason)
    }),
    swi_probe_actor(Parent).

await_eclipse_pong(Ref, Deadline) :-
    http_post('http://127.0.0.1:8096/probe_result', json(_{ref:Ref}), Result,
              [json_object(dict), timeout(3)]),
    (   Result.received == true
    ->  true
    ;   get_time(Now), Now < Deadline
    ->  sleep(0.05), await_eclipse_pong(Ref, Deadline)
    ;   throw(error(timeout_error(receive, pong(Ref)), await_eclipse_pong/2))
    ).
