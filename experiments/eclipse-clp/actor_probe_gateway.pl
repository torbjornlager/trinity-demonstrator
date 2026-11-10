/** Trusted loopback WebSocket transport for the ECLiPSe actor probes. */

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/websocket)).
:- use_module(library(time)).

:- http_handler(root('eclipse/ws'), actor_probe_ws, []).
:- http_handler(root(probe_ping), actor_probe_ping, [method(post)]).
:- http_handler(root(probe_result), actor_probe_result, [method(post)]).
:- http_handler(root(probe_reverse_spawn), actor_probe_reverse_spawn, [method(post)]).
:- http_handler(root(probe_reverse_concurrent_prompts), actor_probe_reverse_concurrent_prompts,
                [method(post)]).
:- dynamic probe_endpoints/3.
:- thread_local probe_child/2.
:- initialization(main, main).

main([]) :-
    assertz(probe_endpoints('http://127.0.0.1:8094/actor_probe',
                            'http://127.0.0.1:8095',
                            'http://127.0.0.1:8096/eclipse')),
    http_server(http_dispatch, [port('127.0.0.1':8096)]),
    writeln('ECLiPSe echo WebSocket at ws://127.0.0.1:8096/eclipse/ws'),
    thread_get_message(stop).

actor_probe_ws(Request) :-
    % Spawn runs native ECLiPSe goals. Reject browser WebSocket requests.
    ( memberchk(origin(_), Request) -> throw(http_reply(forbidden('eclipse/ws')))
    ; true
    ),
    http_upgrade_to_websocket(probe_ws_connection,
        [subprotocols(['web-prolog-sync-spawn-v1','web-prolog-sync-v1'])], Request).

probe_ws_connection(Socket) :-
    setup_call_cleanup(true, probe_ws_loop(Socket), cleanup_probe_children).

probe_ws_loop(Socket) :-
    stream_pair(Socket, Input, _),
    ( probe_child(_, running) -> Timeout = 0.05 ; Timeout = infinite ),
    wait_for_input([Input], Ready, Timeout),
    (   Ready == []
    ->  publish_probe_events(Socket),
        probe_ws_loop(Socket)
    ;   ws_receive(Socket, Frame, [format(json)]),
        (   Frame.opcode == close
        ->  true
        ;   Dict = Frame.data,
            (   get_dict(command, Dict, "probe_disconnect")
            ->  true
            ;   catch(probe_ws_command(Socket, Dict), Error,
                      probe_ws_error(Socket, Dict, Error)),
                publish_probe_events(Socket),
                probe_ws_loop(Socket)
            )
        )
    ).

probe_ws_command(Socket, Dict) :-
    (   _{command:"send", pid:"eclipse_echo", message:Text} :< Dict
    ->  format(user_error, 'WebSocket -> ECLiPSe: ~s~n', [Text]),
        eclipse_request(_{action:"deliver", message:Text}, Event),
        route_event(Event)
    ;   _{command:"send", pid:Child, message:Message} :< Dict
    ->  require_probe_child(send, Child, State),
        ( State == running ->
            wire_field_string(Message, Text),
            eclipse_request(_{action:"send", child:Child, message:Text}, Sent),
            ( Sent.type == "received" -> true
            ; throw(error(domain_error(eclipse_send_reply, Sent), probe_ws_command/2))
            )
        ; true
        )
    ;   _{command:"spawn", goal:GoalField, options:Options, request_id:Request} :< Dict
    ->  wire_field_string(GoalField, Goal),
        probe_spawn_request(Goal, Options, Spawn),
        probe_endpoints(_, Peer, _),
        atom_string(Peer, PeerText),
        eclipse_request(Spawn.put(peer, PeerText), Event),
        (   _{type:"spawned", pid:Child} :< Event
        ->  assertz(probe_child(Child, running)),
            ws_send(Socket, json(_{type:"spawned", pid:Child, request_id:Request}))
        ;   Event.type == "error"
        ->  ws_send(Socket, json(Event.put(request_id, Request)))
        ;   throw(error(domain_error(eclipse_spawn_reply, Event), probe_ws_command/2))
        )
    ;   _{command:"exit", pid:Child, reason:Reason} :< Dict
    ->  require_probe_child(exit, Child, State),
        ( State == running ->
            eclipse_request(_{action:"exit", child:Child, reason:Reason}, Exit),
            ( Exit.type == "exiting" -> true
            ; throw(error(domain_error(eclipse_exit_reply, Exit), probe_ws_command/2))
            )
        ; true
        )
    ;   _{command:"probe_prompt_frame", pid:Child, prompt_ref:Ref} :< Dict
    ->  require_probe_child(send, Child, running),
        ws_send(Socket, json(_{type:"prompt", pid:Child, data:"invalid_prompt_frame", prompt_ref:Ref}))
    ;   throw(error(domain_error(actor_probe_command, Dict), actor_probe_ws/1))
    ).

require_probe_child(Operation, Child, State) :-
    ( probe_child(Child, State) -> true
    ; throw(error(permission_error(Operation, websocket_actor, Child), probe_ws_command/2))
    ).

% SWI's JSON writer encodes the wire atoms true, false and null as literals.
wire_field_string(Field, Text) :-
    atom_string(Atom, Field),
    atom_string(Atom, Text).

probe_spawn_request(Goal, OptionsText, Request) :-
    term_string(Options, OptionsText, [double_quotes(string)]),
    Spawn = _{action:"spawn", goal:Goal},
    (   Options == []
    ->  Request = Spawn
    ;   ground(Options), Options = [src_text(Source)],
        ( atom(Source) ; string(Source) )
    ->  text_to_string(Source, Text),
        Request = Spawn.put(src_text, Text)
    ;   throw(error(domain_error(actor_probe_spawn_options, Options), probe_spawn_request/3))
    ).

probe_ws_error(Socket, Dict, Error) :-
    print_message(error, Error),
    term_string(Error, Text),
    Reply = _{type:"error", data:Text},
    ( get_dict(request_id, Dict, Request) ->
        put_dict(request_id, Reply, Request, Wire)
    ; Wire = Reply ),
    ws_send(Socket, json(Wire)).

publish_probe_events(Socket) :-
    forall(probe_child(Child, running),
           ( eclipse_request(_{action:"events", child:Child}, Status),
             maplist(publish_probe_event(Socket, Child), Status.messages),
             ( _{type:"down", reason:Reason} :< Status ->
                 ws_send(Socket, json(_{type:"down", pid:Child, reason:Reason})),
                 retract(probe_child(Child, running)),
                 assertz(probe_child(Child, down))
             ; Status.type == "running" -> true
             ; throw(error(domain_error(eclipse_child_status, Status), publish_probe_events/1))
             )
           )).

publish_probe_event(Socket, Child, Event) :-
    ( _{type:Type, pid:Child, data:Text} :< Event,
      memberchk(Type, ["output", "prompt"]), string(Text) ->
        ws_send(Socket, json(Event))
    ; route_event(Event)
    ).

cleanup_probe_children :-
    forall(retract(probe_child(Child, _)),
           catch(disconnect_probe_child(Child), Error, print_message(error, Error))).

disconnect_probe_child(Child) :-
    eclipse_request(_{action:"disconnect", child:Child}, Report),
    ( Report.type == "disconnected" -> true
    ; throw(error(domain_error(eclipse_disconnect_report, Report), disconnect_probe_child/1))
    ).

actor_probe_ping(Request) :-
    http_read_json_dict(Request, Dict),
    probe_endpoints(_, Peer, Self),
    format(string(From), 'eclipse_echo@~q', [Self]),
    format(string(Target), 'swi_echo@~q', [Peer]),
    eclipse_request(_{action:"start", from:From, target:Target, ref:Dict.ref}, Event),
    route_event(Event),
    reply_json_dict(_{type:"sent"}).

actor_probe_result(Request) :-
    http_read_json_dict(Request, Dict),
    eclipse_request(_{action:"result", ref:Dict.ref}, Event),
    reply_json_dict(Event).

actor_probe_reverse_spawn(Request) :-
    ( memberchk(origin(_), Request) -> throw(http_reply(forbidden(probe_reverse_spawn)))
    ; true
    ),
    catch(run_reverse_spawn_request(Request), Error,
          ( print_message(error, Error), throw(Error) )).

run_reverse_spawn_request(Request) :-
    http_read_json_dict(Request, Dict),
    reverse_probe_request(Dict, Spawn, Probe),
    probe_endpoints(_, Peer, _),
    atom_string(Peer, Node),
    eclipse_request(Spawn.put(node, Node), Start),
    expect_probe_event(_{type:"spawn", parent:Parent, goal:_}, Start),
    setup_call_cleanup(
        true,
        reverse_spawn_on_swi(Start, Probe, Result),
        eclipse_request(_{action:"reverse_cancel", parent:Parent}, _)
    ),
    reply_json_dict(Result).

actor_probe_reverse_concurrent_prompts(Request) :-
    ( memberchk(origin(_), Request) -> throw(http_reply(forbidden(probe_reverse_concurrent_prompts)))
    ; true
    ),
    catch(run_reverse_concurrent_prompts(Request), Error,
          ( print_message(error, Error), throw(Error) )).

run_reverse_concurrent_prompts(Request) :-
    http_read_json_dict(Request, Dict),
    ( get_dict(scenario, Dict, Scenario) ->
        ( memberchk(Scenario, ["late_reply", "parent_exit", "mixed_parent_exit", "detached_pair", "watcher_exit"]) -> true
        ; throw(http_reply(bad_request('Unknown prompt scenario')))
        )
    ; Scenario = "out_of_order"
    ),
    ( Scenario == "detached_pair" ->
        Link = false,
        reverse_watcher_address(Address),
        format(string(Goal),
               "receive({probe_prompt_now -> true}), input(follow_up, answer(Value), [target(~s), correlate(true)]), writeln(got(Value))",
               [Address])
    ; Scenario == "watcher_exit" ->
        Link = false,
        Goal = "receive({probe_watch(Target) -> true}), input(follow_up, answer(Value), [target(Target), correlate(true)]), writeln(got(Value))"
    ; Link = true, Goal = "input(shared, answer(Value), [correlate(true)]), writeln(got(Value))"
    ),
    probe_endpoints(_, Peer, _),
    atom_string(Peer, Node),
    eclipse_request(_{action:"reverse_start", node:Node, goal:Goal, link:Link}, Start),
    expect_probe_event(_{type:"spawn", parent:Parent, goal:_}, Start),
    First = _{parent:Parent},
    Second = First.put(next, true),
    setup_call_cleanup(
        true,
        setup_call_cleanup(
            open_reverse_socket(Socket),
            reverse_concurrent_prompts(Socket, Start, Goal, First, Second, Scenario, Result),
            cleanup_reverse_socket(Socket, Parent)),
        ( eclipse_request(Second.put(action, "reverse_cancel"), _),
          eclipse_request(First.put(action, "reverse_cancel"), _)
        )),
    reply_json_dict(Result).

reverse_concurrent_prompts(Socket, Start, _, First, _, "watcher_exit", Result) :- !,
    negotiate_reverse_reply_route(Socket),
    spawn_concurrent_child(Socket, Start.goal, "watcher_exit_child", First, Child, []),
    eclipse_request(First.put(action, "reverse_detach_parent"), Released),
    expect_probe_event(_{type:"released", parent_reason:"true"}, Released),
    eclipse_request(First.put(action, "reverse_open_retiring_watcher"), Watcher),
    expect_probe_event(_{type:"watcher", address:Address}, Watcher),
    format(string(StartPrompt), "probe_watch(~s)", [Address]),
    ws_send(Socket, json(_{command:"send", pid:Child.child, message:StartPrompt})),
    watcher_prompt_frame(Socket, Child, Original, Target, Message),
    eclipse_request(First.put(_{action:"reverse_retire_prompt_watcher", target:Target, message:Message}), Down),
    expect_probe_event(_{type:"watcher_down", reason:"true"}, Down),
    eclipse_request(Original.put(action, "reverse_retarget_prompt"), Retarget),
    expect_probe_event(_{type:"send", child:Child.child, message:Wire}, Retarget),
    ws_send(Socket, json(_{command:"send", pid:Child.child, message:Wire})),
    receive_concurrent_follow_up(Socket, Original, Replacement),
    ws_send(Socket, json(_{command:"send", pid:Child.child, message:Wire})),
    concurrent_prompt_reply(Original, "answer(99)", Stale),
    ws_send(Socket, json(Stale)),
    concurrent_prompt_reply(Replacement, "answer(8)", Reply),
    ws_send(Socket, json(Reply)),
    check_concurrent_prompt_result(Socket, Replacement, "got(8)", ChildResult),
    Result = _{parent_reason:Released.parent_reason, watcher_reason:Down.reason,
               old_ref:Original.prompt_ref, child:ChildResult}.
reverse_concurrent_prompts(Socket, Start, Goal, First, Second, "detached_pair", Result) :- !,
    negotiate_reverse_reply_route(Socket),
    spawn_concurrent_child(Socket, Start.goal, "first_prompt_child", First, FirstChild, []),
    eclipse_request(Second.put(_{action:"reverse_start_next", goal:Goal, link:false}), Next),
    expect_probe_event(_{type:"spawn", parent:First.parent, goal:_}, Next),
    spawn_concurrent_child(Socket, Next.goal, "second_prompt_child", Second, SecondChild, []),
    eclipse_request(First.put(action, "reverse_detach_parent_pair"), Released),
    expect_probe_event(_{type:"released", parent_reason:"true"}, Released),
    ws_send(Socket, json(_{command:"send", pid:FirstChild.child, message:"probe_prompt_now"})),
    receive_watcher_prompt(Socket, FirstChild, FirstPrompt),
    ws_send(Socket, json(_{command:"send", pid:SecondChild.child, message:"probe_prompt_now"})),
    receive_watcher_prompt(Socket, SecondChild, SecondPrompt),
    concurrent_prompt_reply(SecondPrompt, "answer(8)", SecondReply),
    ws_send(Socket, json(SecondReply)),
    check_concurrent_prompt_result(Socket, SecondPrompt, "got(8)", SecondResult),
    concurrent_prompt_reply(FirstPrompt, "answer(21)", FirstReply),
    ws_send(Socket, json(FirstReply)),
    check_concurrent_prompt_result(Socket, FirstPrompt, "got(21)", FirstResult),
    Result = _{first:FirstResult, second:SecondResult, parent_reason:Released.parent_reason}.
reverse_concurrent_prompts(Socket, Start, Goal, First, Second, Scenario, Result) :-
    % Queue both prompts in the same ECLiPSe mailbox before asking it to reply.
    queue_concurrent_prompt(Socket, Start.goal, "first_prompt_child", First, FirstPrompt),
    ( Scenario == "mixed_parent_exit" ->
        SecondLink = false,
        negotiate_reverse_reply_route(Socket),
        reverse_watcher_address(Address),
        format(string(SecondGoal),
               "input(shared, answer(A), [correlate(true)]), input(follow_up, answer(B), [target(~s), correlate(true)]), writeln(answers(A,B))",
               [Address])
    ; SecondLink = true, SecondGoal = Goal
    ),
    eclipse_request(Second.put(_{action:"reverse_start_next", goal:SecondGoal, link:SecondLink}), Next),
    expect_probe_event(_{type:"spawn", parent:First.parent, goal:_}, Next),
    queue_concurrent_prompt(Socket, Next.goal, "second_prompt_child", Second, SecondPrompt),
    complete_concurrent_prompts(Scenario, Socket, FirstPrompt, SecondPrompt, Result).

complete_concurrent_prompts("parent_exit", Socket, FirstPrompt, SecondPrompt, Result) :- !,
    First = FirstPrompt.child,
    Second = SecondPrompt.child,
    eclipse_request(_{action:"reverse_release_pair", parent:FirstPrompt.parent}, Exit),
    expect_probe_event(_{type:"exit_pair", first:First, second:Second, reason:"kill",
                         parent_reason:"true"}, Exit),
    ws_send(Socket, json(_{command:"exit", pid:First, reason:Exit.reason})),
    ws_send(Socket, json(_{command:"exit", pid:Second, reason:Exit.reason})),
    read_probe_frame(Socket, child_down, Down1),
    read_probe_frame(Socket, child_down, Down2),
    expect_probe_event(_{type:"down", pid:Pid1, reason:Exit.reason}, Down1),
    expect_probe_event(_{type:"down", pid:Pid2, reason:Exit.reason}, Down2),
    msort([First, Second], Expected),
    msort([Pid1, Pid2], Observed),
    expect_probe_event(_{children:Expected}, _{children:Observed}),
    report_concurrent_prompt_down(FirstPrompt, Exit.reason),
    report_concurrent_prompt_down(SecondPrompt, Exit.reason),
    FirstResult = _{pid:First, prompt_ref:FirstPrompt.prompt_ref, reason:Exit.reason},
    SecondResult = _{pid:Second, prompt_ref:SecondPrompt.prompt_ref, reason:Exit.reason},
    Result = _{first:FirstResult, second:SecondResult, parent_reason:Exit.parent_reason}.
complete_concurrent_prompts("mixed_parent_exit", Socket, FirstPrompt, SecondPrompt, Result) :- !,
    First = FirstPrompt.child,
    % Hold the parent's reply until both the parent and the linked child are down.
    concurrent_prompt_reply(FirstPrompt, "answer(21)", LateReply),
    eclipse_request(_{action:"reverse_release_mixed_pair", parent:FirstPrompt.parent}, Exit),
    expect_probe_event(_{type:"exit", child:First, reason:"kill", parent_reason:"true"}, Exit),
    ws_send(Socket, json(_{command:"exit", pid:First, reason:Exit.reason})),
    read_probe_frame(Socket, child_down, Down),
    expect_probe_event(_{type:"down", pid:First, reason:Exit.reason}, Down),
    report_concurrent_prompt_down(FirstPrompt, Down.reason),
    check_late_prompt_reply_rejected(Socket, LateReply),
    % Retarget the late reply without changing the exited child's reference.
    ws_send(Socket, json(LateReply.put(pid, SecondPrompt.child))),
    concurrent_prompt_reply(SecondPrompt, "answer(8)", Reply),
    ws_send(Socket, json(Reply)),
    receive_concurrent_follow_up(Socket, SecondPrompt, FollowUp),
    ws_send(Socket, json(Reply)),
    concurrent_prompt_reply(FollowUp, "answer(13)", FollowUpReply),
    ws_send(Socket, json(FollowUpReply)),
    check_concurrent_prompt_result(Socket, SecondPrompt, "answers(8,13)", SecondResult),
    FirstResult = _{pid:First, prompt_ref:FirstPrompt.prompt_ref, reason:Down.reason},
    Result = _{first:FirstResult, second:SecondResult, parent_reason:Exit.parent_reason}.
complete_concurrent_prompts(Scenario, Socket, FirstPrompt, SecondPrompt, Result) :-
    exchange_concurrent_prompt_replies(Scenario, Socket, FirstPrompt, SecondPrompt,
                                       FirstResult, SecondResult),
    eclipse_request(_{action:"reverse_finish", parent:FirstPrompt.parent}, Finished),
    expect_probe_event(_{type:"released", parent_reason:"true"}, Finished),
    Result = _{first:FirstResult, second:SecondResult, parent_reason:Finished.parent_reason}.

exchange_concurrent_prompt_replies("out_of_order", Socket, FirstPrompt, SecondPrompt,
                                   FirstResult, SecondResult) :-
    concurrent_prompt_reply(SecondPrompt, "answer(8)", SecondReply),
    % Deliver the same correlated reply to the wrong child first.
    ws_send(Socket, json(SecondReply.put(pid, FirstPrompt.child))),
    ws_send(Socket, json(SecondReply)),
    check_concurrent_prompt_result(Socket, SecondPrompt, "got(8)", SecondResult),
    concurrent_prompt_reply(FirstPrompt, "answer(21)", FirstReply),
    ws_send(Socket, json(FirstReply)),
    check_concurrent_prompt_result(Socket, FirstPrompt, "got(21)", FirstResult).
exchange_concurrent_prompt_replies("late_reply", Socket, FirstPrompt, SecondPrompt,
                                   FirstResult, SecondResult) :-
    % Capture the parent's real reply while the route still exists. Hold it until down.
    concurrent_prompt_reply(FirstPrompt, "answer(21)", LateReply),
    Child = FirstPrompt.child,
    reverse_stop_child(explicit("pending_prompt_exit"), Socket, FirstPrompt.parent, Child, Down),
    report_concurrent_prompt_down(FirstPrompt, Down.reason),
    check_late_prompt_reply_rejected(Socket, LateReply),
    ws_send(Socket, json(LateReply.put(pid, SecondPrompt.child))),
    concurrent_prompt_reply(SecondPrompt, "answer(8)", SecondReply),
    ws_send(Socket, json(SecondReply)),
    check_concurrent_prompt_result(Socket, SecondPrompt, "got(8)", SecondResult),
    FirstResult = _{pid:Child, prompt_ref:FirstPrompt.prompt_ref, reason:Down.reason}.

check_late_prompt_reply_rejected(Socket, LateReply) :-
    RequestId = "late_prompt_reply",
    ws_send(Socket, json(LateReply.put(request_id, RequestId))),
    read_probe_frame(Socket, late_prompt_reply, Rejected),
    format(string(Denied), "Not authorized to access actor ~w", [LateReply.pid]),
    expect_probe_event(_{type:"error", request_id:RequestId, data:Denied}, Rejected).

queue_concurrent_prompt(Socket, Goal, Request, Slot, Prompt) :-
    spawn_concurrent_child(Socket, Goal, Request, Slot, ChildSlot, Pending),
    next_reverse_frame(Socket, child_prompt, Pending, [], Frame),
    Child = ChildSlot.child,
    expect_probe_event(_{type:"prompt", pid:Child, data:"shared", prompt_ref:Ref}, Frame),
    Prompt = ChildSlot.put(_{prompt:Frame.data, prompt_ref:Ref}),
    eclipse_request(Prompt.put(action, "reverse_queue_prompt"), Queued),
    expect_probe_event(_{type:"queued", child:Child}, Queued).

spawn_concurrent_child(Socket, Goal, Request, Slot, ChildSlot, Pending) :-
    ws_send(Socket, json(_{command:"spawn", goal:Goal, options:"[]", request_id:Request})),
    read_reverse_spawn_reply(Socket, Request, 1, Pending, Ack),
    expect_probe_event(_{type:"spawned", pid:Child}, Ack),
    eclipse_request(Slot.put(_{action:"reverse_ack", child:Child}), Monitoring),
    expect_probe_event(_{type:"monitoring", child:Child}, Monitoring),
    ChildSlot = Slot.put(child, Child).

concurrent_prompt_reply(Prompt, Reply, Command) :-
    Child = Prompt.child,
    eclipse_request(Prompt.put(_{action:"reverse_answer_prompt", reply:Reply}), Event),
    expect_probe_event(_{type:"send", child:Child, message:Wire}, Event),
    Command = _{command:"send", pid:Child, message:Wire}.

receive_concurrent_follow_up(Socket, Prompt, FollowUp) :-
    receive_watcher_prompt(Socket, Prompt, FollowUp),
    ( FollowUp.prompt_ref \== Prompt.prompt_ref -> true
    ; throw(error(domain_error(fresh_watcher_prompt, FollowUp), _))
    ).

reverse_watcher_address(Address) :-
    eclipse_request(_{action:"reverse_watcher_address"}, Watcher),
    expect_probe_event(_{type:"watcher", address:Address}, Watcher).

receive_watcher_prompt(Socket, Prompt, FollowUp) :-
    watcher_prompt_frame(Socket, Prompt, FollowUp, Target, Message),
    eclipse_request(Prompt.put(_{action:"reverse_reply", target:Target,
                                 message:Message, expected:Message}), Delivered),
    expect_probe_event(_{type:"delivered"}, Delivered).

watcher_prompt_frame(Socket, Prompt, FollowUp, Target, Message) :-
    read_probe_frame(Socket, watcher_prompt, Frame),
    expect_probe_event(_{type:"actor_message", target:Target, message:Message}, Frame),
    wire_text:wire_text_to_term(Message, Term),
    Child = Prompt.child,
    probe_endpoints(_, Peer, _),
    ( ground(Term), Term = prompt(Child@Peer, prompt_ref(Ref, follow_up)) -> true
    ; throw(error(domain_error(watcher_prompt, Term), _))
    ),
    distribution:term_to_wire_atom(Ref, RefAtom),
    atom_string(RefAtom, RefText),
    FollowUp = Prompt.put(_{prompt:"follow_up", prompt_ref:RefText}).

check_concurrent_prompt_result(Socket, Prompt, Expected, Result) :-
    Child = Prompt.child,
    read_probe_frame(Socket, child_output, Output),
    expect_probe_event(_{type:"output", pid:Child, data:Expected}, Output),
    read_probe_frame(Socket, child_down, Down),
    expect_probe_event(_{type:"down", pid:Child, reason:"true"}, Down),
    report_concurrent_prompt_down(Prompt, Down.reason),
    Result = _{pid:Child, prompt_ref:Prompt.prompt_ref, output:Output.data, reason:Down.reason}.

report_concurrent_prompt_down(Prompt, Reason) :-
    eclipse_request(Prompt.put(_{action:"reverse_down", reason:Reason}), Report),
    expect_probe_event(_{type:"monitored_down", child:Prompt.child, reason:Reason}, Report).

% A readiness marker lets the probe act while the child is waiting.
reverse_probe_request(Dict, Spawn, probe(ExpectedOutput, Interaction, Termination, MonitorMode)) :-
    (   dict_pairs(Dict, _, [])
    ->  SpawnOptions = _{action:"reverse_start"},
        ExpectedOutput = "reverse_probe_ready"
    ;   _{goal:Goal} :< Dict, string(Goal),
        ( get_dict(ready, Dict, ExpectedOutput) -> string(ExpectedOutput)
        ; ExpectedOutput = none
        )
    ->  Base = _{action:"reverse_start", goal:Goal},
        (   get_dict(src_text, Dict, Source)
        ->  ( string(Source) -> SpawnOptions = Base.put(src_text, Source)
            ; throw(http_reply(bad_request('Expected src_text to be a string')))
            )
        ;   SpawnOptions = Base
        )
    ;   throw(http_reply(bad_request('Expected a goal string and optional ready string')))
    ),
    (   get_dict(exchange, Dict, Spec)
    ->  ( string(ExpectedOutput), is_dict(Spec),
          get_dict(message, Spec, Message), string(Message),
          reverse_reply_spec(Spec, ReplySpec)
        -> Exchange = exchange(Message, ReplySpec)
        ;  throw(http_reply(bad_request('Expected ready, exchange.message, and reply, reply_term or reply_terms')))
        )
    ;   Exchange = none
    ),
    (   get_dict(link, Dict, Link)
    ->  ( memberchk(Link, [true, false]) -> true
        ; throw(http_reply(bad_request('Expected link to be a boolean')))
        )
    ;   Link = true
    ),
    (   get_dict(monitor, Dict, Monitor)
    ->  ( memberchk(Monitor, [true, false]) -> true
        ; throw(http_reply(bad_request('Expected monitor to be a boolean')))
        )
    ;   Monitor = false
    ),
    reverse_probe_termination(Dict, Link, ExpectedOutput, Termination),
    reverse_probe_monitor(Dict, Monitor, Termination, MonitorMode),
    Start = SpawnOptions.put(_{link:Link, monitor:Monitor}),
    (   get_dict(startup_replies, Dict, Replies)
    ->  ( ExpectedOutput == none, Termination == natural, Exchange == none,
          is_list(Replies), Replies = [_|_], maplist(string, Replies)
        -> Interaction = startup(Replies), Spawn = Start.put(reply_in_goal, true)
        ;  throw(http_reply(bad_request('startup_replies requires a list of reply terms and natural completion')))
        )
    ;   get_dict(prompt_exchange, Dict, PromptSpec)
    ->  ( ExpectedOutput == none, Termination == natural, Exchange == none,
          is_dict(PromptSpec), _{prompts:Prompts, output:Output} :< PromptSpec,
          is_list(Prompts), Prompts = [_|_], maplist(valid_reverse_prompt, Prompts),
          string(Output),
          ( get_dict(correlate, PromptSpec, Correlate) -> memberchk(Correlate, [true, false])
          ; Correlate = false
          )
        -> Interaction = prompts(Prompts, Output, Correlate), Spawn = Start
        ;  throw(http_reply(bad_request('prompt_exchange requires prompt and reply strings, output and natural completion')))
        )
    ;   get_dict(disconnect_prompt, Dict, Prompt)
    ->  ( Termination = disconnect(_), Exchange == none, string(Prompt) ->
            Interaction = disconnect_prompt(Prompt, _), Spawn = Start
        ; throw(http_reply(bad_request('disconnect_prompt requires a prompt string and disconnect')))
        )
    ;   Interaction = Exchange, Spawn = Start
    ).

valid_reverse_prompt(Spec) :-
    is_dict(Spec), _{prompt:Prompt, reply:Reply} :< Spec,
    string(Prompt), string(Reply).

reverse_probe_monitor(Dict, Monitor, Termination, Mode) :-
    (   get_dict(demonitor, Dict, Phase)
    ->  ( Monitor == true, memberchk(Phase, ["before", "after"]),
          reverse_parent_waits(Termination)
        -> Mode = demonitor(Phase)
        ;  throw(http_reply(bad_request('demonitor requires monitor(true), before or after, and a live parent')))
        )
    ;   Mode = Monitor
    ).

reverse_probe_termination(Dict, Link, ExpectedOutput, Termination) :-
    (   get_dict(await_down, Dict, Await)
    ->  ( memberchk(Await, [true, false]) -> true
        ; throw(http_reply(bad_request('Expected await_down to be a boolean')))
        )
    ;   Await = false
    ),
    (   get_dict(disconnect, Dict, Disconnect)
    ->  ( memberchk(Disconnect, [true, false]) -> true
        ; throw(http_reply(bad_request('Expected disconnect to be a boolean')))
        )
    ;   Disconnect = false
    ),
    (   Disconnect == true
    ->  ( string(ExpectedOutput), Await == false, \+ get_dict(exit_reason, Dict, _)
        -> Termination = disconnect(Link)
        ;  throw(http_reply(bad_request('disconnect requires ready and no exit_reason or await_down')))
        )
    ;   Await == true
    ->  ( Link == true, \+ get_dict(exit_reason, Dict, _) -> Termination = natural
        ; throw(http_reply(bad_request('await_down requires link(true) and no exit_reason')))
        )
    ;   Link == false
    ->  ( string(ExpectedOutput), get_dict(exit_reason, Dict, Reason), string(Reason)
        -> Termination = detached(Reason)
        ;  throw(http_reply(bad_request('Expected ready and exit_reason strings for link(false)')))
        )
    ;   get_dict(exit_reason, Dict, Reason)
    ->  ( string(ExpectedOutput), string(Reason) -> Termination = explicit(Reason)
        ; throw(http_reply(bad_request('Expected ready and exit_reason strings')))
        )
    ;   ExpectedOutput == none -> Termination = natural
    ;   Termination = linked
    ).

reverse_reply_spec(Spec, ReplySpec) :-
    ( get_dict(reply_terms, Spec, Replies) ->
        is_list(Replies), Replies = [_|_], maplist(string, Replies),
        ReplySpec = mailbox_batch(Replies)
    ; get_dict(reply_term, Spec, Reply) ->
        string(Reply), ReplySpec = mailbox(Reply)
    ; get_dict(reply, Spec, Reply),
      string(Reply), ReplySpec = output(Reply)
    ).

reverse_spawn_on_swi(Start, Probe, Result) :-
    setup_call_cleanup(
        open_reverse_socket(Socket),
        reverse_spawn_on_socket(Socket, Start, Probe, Result),
        cleanup_reverse_socket(Socket, Start.parent)
    ).

open_reverse_socket(Socket) :-
    probe_endpoints(_, Peer, _),
    distribution:node_url_to_ws_endpoint(Peer, URL),
    http_open_websocket(URL, Socket,
                        [timeout(3), subprotocols(['web-prolog-sync-spawn-v1'])]).

cleanup_reverse_socket(Socket, Parent) :-
    ( is_stream(Socket) ->
        catch(call_with_time_limit(1, ws_close(Socket, 1000, "")),
              Error, print_message(warning, Error))
    ; true
    ),
    report_reverse_disconnect(Parent, _).

report_reverse_disconnect(Parent, Report) :-
    eclipse_request(_{action:"reverse_disconnect", parent:Parent}, Report),
    ( memberchk(Report.type, ["disconnected", "monitored_down"]) -> true
    ; throw(error(domain_error(reverse_disconnect_report, Report), report_reverse_disconnect/2))
    ).

reverse_spawn_on_socket(Socket, Start, Probe, Result) :-
    Request = "reverse_probe",
    ( Probe = probe(_, startup(Replies), _, _) ->
        negotiate_reverse_reply_route(Socket),
        length(Replies, Count),
        EarlyLimit is Count + 1
    ; EarlyLimit = 1
    ),
    (   get_dict(src_text, Start, Source)
    ->  atom_string(SourceAtom, Source),
        distribution:term_to_wire_atom([src_text(SourceAtom)], OptionsAtom),
        atom_string(OptionsAtom, Options)
    ;   Options = "[]"
    ),
    ws_send(Socket, json(_{command:"spawn", goal:Start.goal, options:Options, request_id:Request})),
    read_reverse_spawn_reply(Socket, Request, EarlyLimit, Pending, Reply),
    (   _{type:"error", data:Reason} :< Reply
    ->  eclipse_request(_{action:"reverse_reject", parent:Start.parent, reason:Reason}, Rejected),
        expect_probe_event(_{type:"rejected"}, Rejected),
        Result = _{type:"error", data:Reason}
    ;   check_reverse_child(Socket, Start.parent, Reply, Pending, Probe, Result)
    ).

% Actor messages and down may race the spawn reply. Bound the buffer by
% the expected events and preserve their order until the PID is registered.
read_reverse_spawn_reply(Socket, Request, Limit, Pending, Reply) :-
    read_probe_frame(Socket, spawn_reply, Frame),
    (   memberchk(Frame.type, ["spawned", "error"]),
        get_dict(request_id, Frame, Request)
    ->  Pending = [], Reply = Frame
    ;   Limit > 0, memberchk(Frame.type, ["output", "prompt", "actor_message", "down"])
    ->  Pending = [Frame|Rest],
        Remaining is Limit - 1,
        read_reverse_spawn_reply(Socket, Request, Remaining, Rest, Reply)
    ;   throw(error(domain_error(reverse_spawn_reply, Frame), read_reverse_spawn_reply/5))
    ).

check_reverse_child(Socket, Parent, Ack, Pending, Probe, Result) :-
    Probe = probe(ExpectedOutput, Interaction, Termination, MonitorMode),
    expect_probe_event(_{type:"spawned", pid:Child}, Ack),
    eclipse_request(_{action:"reverse_ack", parent:Parent, child:Child}, Monitoring),
    expect_probe_event(_{type:"monitoring", child:Child}, Monitoring),
    ( MonitorMode = demonitor(Phase) ->
        eclipse_request(_{action:"reverse_prepare_demonitor", parent:Parent, phase:Phase}, Prepared),
        expect_probe_event(_{type:"demonitor_prepared"}, Prepared)
    ; true
    ),
    ( Interaction = startup(ExpectedReplies) ->
        read_reverse_startup_replies(ExpectedReplies, Socket, Parent, Pending, Rest, Replies),
        next_reverse_frame(Socket, child_down, Rest, [], Observed),
        expect_probe_event(_{type:"down", pid:Child, reason:_}, Observed),
        Reply = _{replies:Replies}
    ; Interaction = prompts(Prompts, Output, Correlate) ->
        read_reverse_prompts(Prompts, Socket, Parent, Child, Pending, Correlate, none),
        read_probe_frame(Socket, child_output, Observed),
        expect_probe_event(_{type:"output", pid:Child, data:Output}, Observed),
        Reply = _{output:Observed.data}
    ; ( ExpectedOutput == none -> Expected = _{type:"down", pid:Child, reason:_}
      ; Expected = _{type:"output", pid:Child, data:ExpectedOutput}
      ),
      next_reverse_frame(Socket, child_event, Pending, [], Observed),
      expect_probe_event(Expected, Observed),
      ( Interaction = disconnect_prompt(ExpectedPrompt, DisconnectRef) ->
          ws_send(Socket, json(_{command:"send", pid:Child, message:"probe_prompt_now"})),
          read_probe_frame(Socket, disconnect_prompt, PromptFrame),
          expect_probe_event(_{type:"prompt", pid:Child, data:ExpectedPrompt, prompt_ref:DisconnectRef}, PromptFrame)
      ; true
      ),
      ( ( Termination = detached(_) ; Termination == disconnect(false) ) ->
          eclipse_request(_{action:"reverse_detach_parent", parent:Parent}, Released),
          expect_probe_event(_{type:"released", parent_reason:"true"}, Released)
      ; true
      ),
      reverse_exchange(Interaction, Socket, Parent, Child, Reply)
    ),
    report_reverse_child_end(Termination, Socket, Parent, Child, Observed, Reason),
    ( reverse_parent_waits(Termination) ->
        Finish = _{action:"reverse_finish", parent:Parent},
        ( MonitorMode \== false -> Release = Finish.put(monitor_reason, Reason)
        ; Release = Finish
        ),
        eclipse_request(Release, Finished),
        expect_probe_event(_{type:"released", parent_reason:"true"}, Finished)
    ; true
    ),
    Exit = _{type:"down", pid:Child, reason:Reason, parent_reason:"true"},
    ( ExpectedOutput == none -> put_dict(Reply, Exit, Result)
    ; put_dict(Reply, Exit.put(output, ExpectedOutput), Result)
    ).

next_reverse_frame(_, _, [Frame|Pending], Pending, Frame) :- !.
next_reverse_frame(Socket, Stage, [], [], Frame) :-
    read_probe_frame(Socket, Stage, Frame).

read_reverse_startup_replies([], _, _, Pending, Pending, []).
read_reverse_startup_replies([Expected|More], Socket, Parent, Pending, Rest, [Reply|Replies]) :-
    next_reverse_frame(Socket, startup_message, Pending, Remaining, Frame),
    deliver_reverse_mailbox_reply(Parent, Expected, Frame, Reply),
    read_reverse_startup_replies(More, Socket, Parent, Remaining, Rest, Replies).

read_reverse_prompts([], _, _, _, [], _, _).
read_reverse_prompts([Spec|More], Socket, Parent, Child, Pending, Correlate, Previous) :-
    next_reverse_frame(Socket, child_prompt, Pending, Remaining, Frame),
    expect_probe_event(_{type:"prompt", pid:Child, data:PromptText}, Frame),
    check_reverse_prompt_data(Spec, PromptText),
    Base = _{action:"reverse_prompt", parent:Parent, prompt:Frame.data, reply:Spec.reply},
    ( Correlate == true ->
        expect_probe_event(_{prompt_ref:RefText}, Frame),
        wire_text:wire_text_to_term(RefText, Ref),
        ( Previous = previous(OldRef, StaleWire) ->
            ( Ref \== OldRef -> true
            ; throw(error(domain_error(fresh_prompt_reference, Ref), read_reverse_prompts/7))
            ),
            ws_send(Socket, json(_{command:"send", pid:Child, message:StaleWire}))
        ; true
        ),
        ( get_dict(stale_ref, Spec, PreviousConnectionRef) ->
            wire_text:wire_text_to_term(PreviousConnectionRef, OldConnectionRef),
            ( Ref \== OldConnectionRef -> true ; throw(error(domain_error(fresh_prompt_reference, Ref), _)) ),
            distribution:term_to_wire_atom('$input'(probe, OldConnectionRef, answer(99)), OldReply),
            ws_send(Socket, json(_{command:"send", pid:Child, message:OldReply}))
        ; true
        ),
        Command = Base.put(prompt_ref, RefText)
    ; ( get_dict(prompt_ref, Frame, Unexpected) ->
          throw(error(domain_error(legacy_prompt_reference, Unexpected), _))
      ; true
      ),
      Ref = none, Command = Base
    ),
    ( Correlate == true, Previous == none ->
        forall(member(BadRef, [42, "", "ref(", "ref(_)", "ref(1). ref(2)"]),
               ( eclipse_request(Command.put(_{action:"reverse_queue_prompt", prompt_ref:BadRef}), Rejected),
                 expect_probe_event(_{type:"error"}, Rejected)
               )),
        ws_send(Socket, json(_{command:"send", pid:Child, message:"'$input'(probe, answer(99))"})),
        ws_send(Socket, json(_{command:"send", pid:Child, message:"'$input'(probe, _, answer(99))"})),
        format(string(WrongShape), "'$input'(probe, ~s, wrong_shape)", [RefText]),
        ws_send(Socket, json(_{command:"send", pid:Child, message:WrongShape}))
    ; Correlate == false, Previous == none ->
        ws_send(Socket, json(_{command:"send", pid:Child, message:"'$input'(probe, ref(0), amount([99]))"}))
    ; true
    ),
    ( get_dict(race, Spec, true), Correlate == true ->
        eclipse_request(Command.put(action, "reverse_race_prompt"), Event),
        expect_probe_event(_{type:"send_pair", child:Child, messages:[Wire, OtherWire]}, Event),
        ws_send(Socket, json(_{command:"send", pid:Child, message:Wire})),
        ws_send(Socket, json(_{command:"send", pid:Child, message:OtherWire}))
    ; eclipse_request(Command, Event),
      expect_probe_event(_{type:"send", child:Child, message:Wire}, Event),
      ws_send(Socket, json(_{command:"send", pid:Child, message:Wire}))
    ),
    read_reverse_prompts(More, Socket, Parent, Child, Remaining, Correlate, previous(Ref, Wire)).

check_reverse_prompt_data(Spec, Text) :-
    ( get_dict(term_prompt, Spec, true) ->
        wire_text:wire_text_to_term(Spec.prompt, Expected),
        wire_text:wire_text_to_term(Text, Actual),
        expect_probe_event(_{data:Expected}, _{data:Actual})
    ; expect_probe_event(_{data:Spec.prompt}, _{data:Text})
    ).

reverse_parent_waits(natural).
reverse_parent_waits(explicit(_)).
reverse_parent_waits(disconnect(true)).

report_reverse_child_end(disconnect(_), Socket, Parent, Child, _, "connection_closed") :- !,
    close(Socket, [force(true)]),
    report_reverse_disconnect(Parent, Report),
    expect_probe_event(_{type:"monitored_down", child:Child, reason:"connection_closed"}, Report).
report_reverse_child_end(Termination, Socket, Parent, Child, Observed, Reason) :-
    ( Termination == natural ->
        ( Observed.type == "down" -> Down = Observed
        ; read_probe_frame(Socket, child_down, Down),
          expect_probe_event(_{type:"down", pid:Child, reason:_}, Down)
        )
    ; reverse_stop_child(Termination, Socket, Parent, Child, Down)
    ),
    Reason = Down.reason,
    eclipse_request(_{action:"reverse_down", parent:Parent, child:Child, reason:Reason}, Report),
    expect_probe_event(_{type:"monitored_down", child:Child, reason:Reason}, Report).

reverse_exchange(none, _, _, _, _{}).
reverse_exchange(disconnect_prompt(_, Ref), _, _, _, _{prompt_ref:Ref}).
reverse_exchange(exchange(Message, ReplySpec), Socket, Parent, Child, Replies) :-
    Send = _{action:"reverse_message", parent:Parent, message:Message},
    ( ReplySpec = output(_) -> Command = Send
    ;
        negotiate_reverse_reply_route(Socket),
        Command = Send.put(mailbox, true)
    ),
    eclipse_request(Command, Event),
    expect_probe_event(_{type:"send", child:Child, message:Wire}, Event),
    ws_send(Socket, json(_{command:"send", pid:Child, message:Wire})),
    reverse_exchange_replies(ReplySpec, Socket, Parent, Child, Replies).

negotiate_reverse_reply_route(Socket) :-
    ws_send(Socket, json(_{command:"transport_hello", version:1, browser_pids:true})),
    read_probe_frame(Socket, reply_route, Welcome),
    expect_probe_event(_{type:"transport_welcome", browser_pids:true}, Welcome).

reverse_exchange_replies(output(Expected), Socket, _, Child, _{reply:Reply}) :-
    read_probe_frame(Socket, child_reply, Response),
    expect_probe_event(_{type:"output", pid:Child, data:Expected}, Response),
    Reply = Response.data.
reverse_exchange_replies(mailbox(Expected), Socket, Parent, _, _{reply:Reply}) :-
    read_reverse_mailbox_reply(Socket, Parent, Expected, Reply).
reverse_exchange_replies(mailbox_batch(Expected), Socket, Parent, _, _{replies:Replies}) :-
    maplist(read_reverse_mailbox_reply(Socket, Parent), Expected, Replies).

read_reverse_mailbox_reply(Socket, Parent, Expected, Reply) :-
    read_probe_frame(Socket, child_reply, Response),
    deliver_reverse_mailbox_reply(Parent, Expected, Response, Reply).

deliver_reverse_mailbox_reply(Parent, Expected, Response, Reply) :-
    expect_probe_event(_{type:"actor_message", target:Target, message:Message}, Response),
    eclipse_request(_{action:"reverse_reply", parent:Parent, target:Target,
                      message:Message, expected:Expected}, Delivered),
    expect_probe_event(_{type:"delivered", message:Reply}, Delivered).

reverse_stop_child(Termination, Socket, Parent, Child, Down) :-
    reverse_exit_request(Termination, Parent, Child, Reason),
    ws_send(Socket, json(_{command:"exit", pid:Child, reason:Reason})),
    read_probe_frame(Socket, child_down, Down),
    expect_probe_event(_{type:"down", pid:Child, reason:Actual}, Down),
    wire_text:wire_text_to_term(Reason, ExpectedTerm),
    wire_text:wire_text_to_term(Actual, ActualTerm),
    ( ExpectedTerm =@= ActualTerm -> true
    ; throw(error(domain_error(reverse_exit_reason, ActualTerm),
                  context(reverse_stop_child/5, ExpectedTerm)))
    ).

reverse_exit_request(linked, Parent, Child, "kill") :-
    eclipse_request(_{action:"reverse_release", parent:Parent, child:Child}, Exit),
    expect_probe_event(_{type:"exit", child:Child, reason:"kill", parent_reason:"true"}, Exit).
reverse_exit_request(Termination, Parent, Child, Reason) :-
    ( Termination = explicit(Text) ; Termination = detached(Text) ),
    eclipse_request(_{action:"reverse_exit", parent:Parent, reason:Text}, Exit),
    expect_probe_event(_{type:"exit", child:Child, reason:Reason}, Exit).

read_probe_frame(Socket, Stage, Event) :-
    catch(call_with_time_limit(3, ws_receive(Socket, Frame, [format(json)])),
          Error, throw(error(reverse_probe_receive(Stage, Error), read_probe_frame/3))),
    ( Frame.opcode == text, is_dict(Frame.data) -> Event = Frame.data
    ; throw(error(domain_error(reverse_probe_frame, Frame), read_probe_frame/3))
    ).

expect_probe_event(Expected, Event) :-
    ( Expected :< Event -> true
    ; throw(error(domain_error(reverse_probe_event, Event), context(reverse_spawn, Expected)))
    ).

eclipse_request(Dict, Event) :-
    probe_endpoints(Endpoint, _, _),
    http_post(Endpoint, json(Dict), Event,
              [json_object(dict), timeout(3)]).

route_event(Event) :-
    (   Event.type == "received"
    ->  true
    ;   _{type:"send", pid:Pid, node:Node, message:Message} :< Event,
        ( integer(Pid) ; Pid == "swi_echo" ),
        probe_endpoints(_, Peer, _),
        atom_string(Peer, Node)
    ->  format(user_error, 'ECLiPSe -> WebSocket: ~s~n', [Message]),
        distribution:remote_send_command(Peer,
            json{command:send, pid:Pid, message:Message})
    ;   throw(error(domain_error(actor_probe_event, Event), route_event/1))
    ).
