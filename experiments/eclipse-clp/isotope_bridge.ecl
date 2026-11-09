:- module(isotope_bridge).
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(isotope_rpc).
:- ensure_loaded(server_behaviours).
:- ensure_loaded(demo_services).
:- import init_linda/0 from demo_services.
:- import exit/1, exit/2 from actors.
:- lib(json).
:- lib(prolog_extras).
:- export run/0.
:- local store(http_sessions).
:- local store(probe_children).
:- local op(200, xfx, @).

% The root routes requests and is the only writer to the JSON pipe.
% Each relay owns a toplevel child and waits on its PTCP mailbox.
run :-
    start_actor_runtime,
    init_egress,
    init_linda,
    get_stream(output, Replies),
    set_stream(output, error),
    self(Main),
    spawn(read_requests(Main), _),
    spawn(probe_echo(none), Echo),
    store_set(http_sessions, probe_echo, Echo),
    get_flag(version_as_list, VersionParts),
    sprintf(Version, "%d.%d.%d", VersionParts),
    reply(Replies, {[type:ready, version:Version]}),
    serve(Replies).

read_requests(Main) :-
    setup_call_cleanup(true, read_lines(Main), send(Main, http_closed)).

read_lines(Main) :-
    ( read_string(input, end_of_line, _, Line) ->
        setup_call_cleanup(
            open(string(Line), read, Stream),
            json_read(Stream, {Fields}, [names_as_atoms]),
            close(Stream)
        ),
        memberchk(request_id:Request, Fields),
        memberchk(command:Command, Fields),
        ( memberchk(pid:Id, Fields) -> true ; Id = none ),
        send(Main, http_request(Request, Command, Id, Fields)),
        read_lines(Main)
    ; true
    ).

serve(Replies) :-
    receive({
        http_request(Request, Command, Id, Fields) ->
            route_request(Request, Command, Id, Fields),
            serve(Replies)
    ;
        http_opened(Request, Id, Relay) ->
            store_set(http_sessions, Id, Relay),
            write_response(Replies, Request, {[type:spawned, pid:Id]}),
            serve(Replies)
    ;
        http_reply(Request, Event) ->
            close_if_finished(Event),
            write_response(Replies, Request, Event),
            serve(Replies)
    ;
        http_egress(Key, Id, Operation, Url, Params) ->
            reply(Replies, {[type:egress, egress_id:Key, actor_id:Id,
                             operation:Operation, url:Url, params:Params]}),
            serve(Replies)
    ;
        browser_child_output(actor(Id), Text) ->
            ( store_get(http_sessions, Id, _) ->
                reply(Replies, {[type:browser_child_output, pid:Id, data:Text]})
            ; true ),
            serve(Replies)
    ;
        browser_child_trace(actor(Id), actor(Chart), Text) ->
            ( store_get(http_sessions, Id, _) ->
                reply(Replies, {[type:browser_child_output, pid:Id, actor_id:Chart,
                                 kind:statechart_trace, data:Text]})
            ; true ),
            serve(Replies)
    ;
        http_closed -> true
    }).

route_request(Request, "spawn", _, Fields) :- !,
    self(Router),
    spawn(open_session(Router, Request, Fields), _).
route_request(Request, "stateless", _, Fields) :- !,
    self(Router),
    spawn(stateless_request(response(Router, Request), Fields), _).
route_request(Request, "actor_probe", _, Fields) :- !,
    self(Router),
    store_get(http_sessions, probe_echo, Echo),
    send(Echo, probe_request(response(Router, Request), Fields)).
route_request(Key, "egress_result", Id, Fields) :- !,
    memberchk(status:Status, Fields),
    memberchk(body:Body, Fields),
    send(actor(Id), http_egress_result(Key, Status, Body)).
route_request(Request, Command, Id, Fields) :-
    ( store_get(http_sessions, Id, Relay) ->
        send(Relay, http_request(Request, Command, Id, Fields))
    ;
        self(Router),
        reply_to(response(Router, Request),
                 {[type:error, pid:Id, data:"Unknown toplevel session"]})
    ).

% A resident ECLiPSe actor handles the probe messages. The loopback gateway
% translates only the resulting outbound action into a WebSocket send.
probe_echo(Last) :-
    receive({
        probe_request(Context, Fields) ->
            catch(
                ( probe_action(Fields, Last, Next, Event) -> true
                ; Next = Last, Event = {[type:error, data:"Invalid actor probe message"]}
                ),
                Error,
                ( Next = Last, term_string(Error, Text), Event = {[type:error, data:Text]} )
            ),
            reply_to(Context, Event),
            probe_echo(Next)
    ;
        down(actor(Id), Ref, Reason) if \+ store_get(probe_children, retained_down(Ref), _) ->
            ( store_get(probe_children, Id, child(_, Output, Outbox)) ->
                store_set(probe_children, Id, child(down(Reason), Output, Outbox))
            ; true ),
            probe_echo(Last)
    ;
        output(actor(Id), Term) ->
            ( store_get(probe_children, Id, child(Status, _, Outbox)) ->
                probe_term_text(Term, Text),
                recordz(Outbox, {[type:output, pid:Id, data:Text]}),
                store_set(probe_children, Id, child(Status, Text, Outbox))
            ; true ),
            probe_echo(Last)
    ;
        prompt(actor(Id), Prompt) ->
            record_probe_prompt(Id, plain, Prompt),
            probe_echo(Last)
    ;
        '$input_prompt'(actor(Id), Mode, Prompt) ->
            record_probe_prompt(Id, Mode, Prompt),
            probe_echo(Last)
    ;
        remote_send_from(actor(Id), Target, Message) ->
            ( store_get(probe_children, Id, child(_, _, Outbox)),
              probe_send(Target, Message, Event) ->
                recordz(Outbox, Event)
            ; true ),
            probe_echo(Last)
    }).

probe_action(Fields, Last, Next, Event) :-
    memberchk(action:Action, Fields),
    probe_action(Action, Fields, Last, Next, Event).

probe_action("deliver", Fields, Last, Next, Event) :-
    memberchk(message:Text, Fields),
    parse_goal(Text, isotope_bridge, Message, _),
    ground(Message),
    ( Message = ping(From, Ref) ->
        probe_send(From, pong(Ref), Event),
        Next = Last
    ; Message = pong(Ref) ->
        sprintf(RefText, "%Qw", [Ref]),
        Event = {[type:received]},
        Next = RefText
    ).
probe_action("start", Fields, _, none, Event) :-
    memberchk(from:FromText, Fields),
    memberchk(target:TargetText, Fields),
    memberchk(ref:RefText, Fields),
    parse_goal(FromText, isotope_bridge, From, _),
    parse_goal(TargetText, isotope_bridge, Target, _),
    parse_goal(RefText, isotope_bridge, Ref, _),
    ground(From-Target-Ref),
    probe_send(Target, ping(From, Ref), Event).
probe_action("result", Fields, Last, Last, {[type:result, received:Received]}) :-
    memberchk(ref:Ref, Fields),
    ( Ref == Last -> Received = true ; Received = false ).
probe_action("reverse_start", Fields, Last, Last, Event) :-
    ( memberchk(goal:_, Fields) ->
        probe_spawn_goal(Fields, Goal, Bindings)
    ; Goal = (writeln(reverse_probe_ready), receive({ probe_stop -> true })),
      Bindings = []
    ),
    ( memberchk(reply_in_goal:true, Fields) ->
        ( memberchk('ReplyTo'=Address, Bindings) -> ReplyTarget = bind(Address)
        ; throw(error(existence_error(goal_variable, 'ReplyTo'), spawn/3))
        )
    ; ReplyTarget = none
    ),
    probe_source_options(Fields, Options),
    ( memberchk(link:Link, Fields) -> ( Link == true ; Link == false )
    ; Link = true
    ),
    ( memberchk(monitor:Monitor, Fields) -> ( Monitor == true ; Monitor == false )
    ; Monitor = false
    ),
    memberchk(node:NodeText, Fields),
    atom_string(Node, NodeText),
    self(Owner),
    spawn(reverse_parent(Owner, Node, Goal, ReplyTarget, [link(Link), monitor(Monitor)|Options]), Parent),
    Parent = actor(Id),
    monitor(Parent, ParentRef),
    catch(register_reverse_spawn(Id, reverse(Id), Node, ParentRef, Event), Error,
          ( demonitor(ParentRef, [flush]), exit(Parent, gateway_closed), throw(Error) )).
probe_action("reverse_start_next", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id), reverse(Node, ParentRef, _, _, watching(_, _, parent))),
    probe_spawn_goal(Fields, Goal),
    ( memberchk(link:false, Fields) -> Link = false ; Link = true ),
    self(Owner),
    send(actor(Id), reverse_parent_start_next(Owner, Node, Goal, Link)),
    register_reverse_spawn(Id, reverse_next(Id), Node, ParentRef, Event).
probe_action("reverse_watcher_address", _, Last, Last, {[type:watcher, address:Text]}) :-
    reverse_reply_address(watcher, _, _, Address),
    probe_term_text(Address, Text).
probe_action("reverse_open_retiring_watcher", Fields, Last, Last, {[type:watcher, address:Text]}) :-
    memberchk(parent:Id, Fields),
    self(Owner),
    spawn(retiring_prompt_watcher(Owner), Watcher, [monitor(true)]),
    store_set(probe_children, retiring_watcher(Id), Watcher),
    Watcher = actor(WatcherId),
    reverse_reply_address(parent, WatcherId, _, Address),
    probe_term_text(Address, Text).
probe_action("reverse_retire_prompt_watcher", Fields, Last, Last, {[type:watcher_down, reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    memberchk(target:TargetText, Fields),
    memberchk(message:MessageText, Fields),
    store_get(probe_children, retiring_watcher(Id), Watcher),
    Watcher = actor(WatcherId),
    reverse_reply_address(parent, WatcherId, _, Address),
    parse_goal(TargetText, isotope_bridge, Target, _),
    Target == Address,
    parse_goal(MessageText, isotope_bridge, Message, _),
    send(Watcher, Message),
    receive({ retiring_prompt_seen(Watcher, Seen) -> Seen == Message },
            [timeout(2), on_timeout(throw(missing_original_prompt))]),
    reverse_expect_down(Watcher, Watcher, true),
    store_delete(probe_children, retiring_watcher(Id)).
probe_action("reverse_retarget_prompt", Fields, Last, Last, {[type:send, child:Child, message:Wire]}) :-
    reverse_prompt_fields(Fields, Id, Pid, prompt_ref(Ref, _), watcher),
    Pid = Child@_,
    reverse_reply_address(watcher, Id, _, Address),
    retarget_prompt(Pid, Ref, Address),
    receive({ remote_send(Pid, Outgoing) -> probe_term_text(Outgoing, Wire) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]).
probe_action("reverse_ack", Fields, Last, Last, {[type:monitoring, child:Returned]}) :-
    memberchk(parent:Id, Fields),
    memberchk(child:Child, Fields),
    reverse_spawn_key(Fields, Id, Key),
    store_get(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, pending)),
    Pid = Child@Node,
    acknowledge_remote_spawn(Proxy, Pid),
    monitor(Pid, Ref),
    store_set(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, watching(Child, Ref, parent))),
    receive({ reverse_parent_spawned(actor(Id), Returned@Node) -> true },
            [timeout(2), on_timeout(throw(reverse_spawn_reply_timeout(Id)))]),
    ( Returned == Child -> true ; throw(reverse_spawn_pid_mismatch(Child, Returned)) ).
probe_action("reverse_prepare_demonitor", Fields, Last, Last, {[type:demonitor_prepared]}) :-
    memberchk(parent:Id, Fields),
    memberchk(phase:Phase, Fields),
    store_get(probe_children, reverse(Id), reverse(_, _, _, _, watching(_, _, parent))),
    self(Owner),
    send(actor(Id), reverse_parent_prepare_demonitor(Owner, Phase)),
    receive({ reverse_parent_demonitor_prepared(actor(Id)) -> true },
            [timeout(2), on_timeout(throw(reverse_demonitor_timeout(Id)))]).
probe_action("reverse_detach_parent", Fields, Last, Last, {[type:released, parent_reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    prepare_reverse_watcher(reverse(Id), ParentRef),
    send(actor(Id), reverse_parent_release),
    reverse_expect_down(actor(Id), ParentRef, true).
probe_action("reverse_detach_parent_pair", Fields, Last, Last, {[type:released, parent_reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    prepare_reverse_watcher(reverse(Id), ParentRef),
    prepare_reverse_watcher(reverse_next(Id), ParentRef),
    send(actor(Id), reverse_parent_release),
    reverse_expect_down(actor(Id), ParentRef, true).
probe_action("reverse_message", Fields, Last, Last, {[type:send, child:Child, message:Wire]}) :-
    memberchk(parent:Id, Fields),
    memberchk(message:Text, Fields),
    store_get(probe_children, reverse(Id), reverse(Node, _, _, _, watching(Child, _, Sender))),
    parse_goal(Text, isotope_bridge, Message, _),
    ( memberchk(mailbox:true, Fields) ->
        reverse_reply_address(Sender, Id, _, Address),
        Outbound = request(Address, Message)
    ; Outbound = Message
    ),
    ( Sender == parent -> send(actor(Id), reverse_parent_send(Outbound))
    ; send(Child@Node, Outbound)
    ),
    receive({ remote_send(Child@Node, Outgoing) -> probe_term_text(Outgoing, Wire) },
            [timeout(2), on_timeout(throw(reverse_message_timeout(Id)))]).
probe_action("reverse_reply", Fields, Last, Last, {[type:delivered, message:Wire]}) :-
    memberchk(parent:Id, Fields),
    memberchk(target:Target, Fields),
    memberchk(message:Text, Fields),
    memberchk(expected:ExpectedText, Fields),
    reverse_spawn_key(Fields, Id, Key),
    store_get(probe_children, Key, reverse(_, _, _, _, watching(_, _, Sender))),
    reverse_reply_address(Sender, Id, Watcher, Address),
    parse_goal(Target, isotope_bridge, ActualAddress, _),
    ActualAddress == Address,
    parse_goal(Text, isotope_bridge, Message, _),
    parse_goal(ExpectedText, isotope_bridge, Expected, _),
    variant(Message, Expected),
    ( Sender == parent ->
        self(Owner),
        send(Watcher, reverse_parent_expect_reply(Owner, Expected)),
        send(Watcher, Message),
        receive({ reverse_parent_reply(Watcher, Delivered) -> true },
                [timeout(2), on_timeout(throw(reverse_parent_reply_timeout(Id)))])
    ; send(Watcher, Message),
      await_reverse_reply(Expected, Delivered)
    ),
    probe_term_text(Delivered, Wire).
probe_action("reverse_prompt", Fields, Last, Last, {[type:send, child:Child, message:Wire]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, parent),
    Pid = Child@_,
    send(actor(Id), prompt(Pid, Payload)),
    answer_reverse_prompt(Fields, Id, Pid, Payload, parent, Wire).
probe_action("reverse_race_prompt", Fields, Last, Last, {[type:send_pair, child:Child, messages:[First,Second]]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, parent),
    Pid = Child@_,
    Payload = prompt_ref(Ref, _),
    send(actor(Id), prompt(Pid, Payload)),
    send(actor(Id), reverse_parent_answer_prompt(Pid, Payload, answer(21))),
    spawn(respond(Pid, Ref, answer(42)), _),
    receive({ remote_send(Pid, Reply1) -> probe_term_text(Reply1, First) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]),
    receive({ remote_send(Pid, Reply2) -> probe_term_text(Reply2, Second) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]).
probe_action("reverse_queue_prompt", Fields, Last, Last, {[type:queued, child:Child]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, parent),
    Pid = Child@_,
    send(actor(Id), prompt(Pid, Payload)).
probe_action("reverse_answer_prompt", Fields, Last, Last, {[type:send, child:Child, message:Wire]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, Sender),
    Pid = Child@_,
    answer_reverse_prompt(Fields, Id, Pid, Payload, Sender, Wire).
probe_action("reverse_exit", Fields, Last, Last, {[type:exit, child:Child, reason:Wire]}) :-
    memberchk(parent:Id, Fields),
    memberchk(reason:Text, Fields),
    store_get(probe_children, reverse(Id), reverse(Node, _, _, _, watching(Child, _, Sender))),
    parse_goal(Text, isotope_bridge, Reason, _),
    nonvar(Reason),
    ( Sender == parent -> send(actor(Id), reverse_parent_exit(Reason))
    ; exit(Child@Node, Reason)
    ),
    receive({ remote_exit(Child@Node, Outgoing) -> probe_term_text(Outgoing, Wire) },
            [timeout(2), on_timeout(throw(reverse_exit_timeout(Id)))]).
probe_action("reverse_release", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id), reverse(_, ParentRef, Proxy, ProxyRef, watching(Child, _, parent))),
    send(actor(Id), reverse_parent_release),
    reverse_expect_down(actor(Id), ParentRef, true),
    reverse_expect_down(Proxy, ProxyRef, kill),
    Event = {[type:exit, child:Child, reason:"kill", parent_reason:"true"]}.
probe_action("reverse_release_pair", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id),
              reverse(_, ParentRef, FirstProxy, FirstRef, watching(First, _, parent))),
    store_get(probe_children, reverse_next(Id),
              reverse(_, ParentRef, SecondProxy, SecondRef, watching(Second, _, parent))),
    send(actor(Id), reverse_parent_release),
    reverse_expect_down(actor(Id), ParentRef, true),
    reverse_expect_down(FirstProxy, FirstRef, kill),
    reverse_expect_down(SecondProxy, SecondRef, kill),
    Event = {[type:exit_pair, first:First, second:Second, reason:"kill", parent_reason:"true"]}.
probe_action("reverse_release_mixed_pair", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    prepare_reverse_watcher(reverse_next(Id), _),
    probe_action("reverse_release", Fields, Last, Last, Event).
probe_action("reverse_down", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    memberchk(child:Child, Fields),
    memberchk(reason:Text, Fields),
    reverse_spawn_key(Fields, Id, Key),
    report_reverse_down(Key, Child, Text, Event).
probe_action("reverse_disconnect", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    ( store_get(probe_children, reverse(Id), reverse(_, _, _, _, watching(Child, _, _))) ->
        report_reverse_down(reverse(Id), Child, "connection_closed", Event)
    ; Event = {[type:disconnected]}
    ).
probe_action("reverse_finish", Fields, Last, Last, {[type:released, parent_reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id), reverse(_, ParentRef, _, _, down)),
    ( memberchk(monitor_reason:Text, Fields) ->
        parse_goal(Text, isotope_bridge, Reason, _),
        send(actor(Id), reverse_parent_release_after_down(Reason))
    ; send(actor(Id), reverse_parent_release)
    ),
    reverse_expect_down(actor(Id), ParentRef, true).
probe_action("reverse_reject", Fields, Last, Last, {[type:rejected]}) :-
    memberchk(parent:Id, Fields),
    memberchk(reason:Reason, Fields),
    store_get(probe_children, reverse(Id), reverse(_, _, Proxy, _, pending)),
    send(Proxy, remote_spawn_reply(error(Reason))),
    receive({
        reverse_parent_spawn_error(actor(Id), error(remote_spawn_failed(Reason), _)) -> true
    }, [timeout(2), on_timeout(throw(reverse_spawn_rejection_timeout(Id)))]).
probe_action("reverse_cancel", Fields, Last, Last, {[type:cancelled]}) :-
    memberchk(parent:Id, Fields),
    ( store_get(probe_children, retiring_watcher(Id), Watcher) ->
        store_delete(probe_children, retiring_watcher(Id)),
        demonitor(Watcher, [flush]), exit(Watcher, gateway_closed)
    ; true ),
    reverse_spawn_key(Fields, Id, Key),
    ( store_get(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, Status)) ->
        store_delete(probe_children, Key),
        demonitor(ParentRef, [flush]),
        demonitor(ProxyRef, [flush]),
        ( store_get(probe_children, retained_down(ProxyRef), _) ->
            store_delete(probe_children, retained_down(ProxyRef))
        ; true ),
        ( Status = watching(Child, Ref, _) ->
            demonitor(Ref, [flush]),
            remote_actor_down(Proxy, Child@Node, connection_closed)
        ; true ),
        exit(actor(Id), gateway_closed)
    ; true ).

probe_action("spawn", Fields, Last, Last, {[type:spawned, pid:Id]}) :-
    probe_spawn_goal(Fields, Goal),
    probe_source_options(Fields, Options),
    self(Transport),
    ( memberchk(peer:PeerText, Fields) ->
        atom_string(Peer, PeerText),
        Start = (set_peer_send_transport(Peer, Transport), Goal)
    ; Start = Goal
    ),
    spawn(receive({ probe_run -> (set_prompt_relay(Transport), Start) }),
          actor(Id), [monitor(true)|Options]),
    record_create(Outbox),
    store_set(probe_children, Id, child(running, null, Outbox)),
    send(actor(Id), probe_run).
probe_action("send", Fields, Last, Last, {[type:received]}) :-
    memberchk(child:Id, Fields),
    memberchk(message:Text, Fields),
    store_get(probe_children, Id, child(Status, _, _)),
    ( Status == running ->
        parse_goal(Text, isotope_bridge, Message, _),
        send(actor(Id), Message)
    ; true
    ).
probe_action("exit", Fields, Last, Last, {[type:exiting]}) :-
    memberchk(child:Id, Fields),
    memberchk(reason:Text, Fields),
    parse_goal(Text, isotope_bridge, Reason, _),
    ground(Reason),
    store_get(probe_children, Id, _),
    exit(actor(Id), Reason).
probe_action("status", Fields, Last, Last, {Event}) :-
    memberchk(child:Id, Fields),
    store_get(probe_children, Id, child(Status, Output, _)),
    probe_child_status(Status, Id, Output, Event).
probe_action("events", Fields, Last, Last, {[messages:Messages|Event]}) :-
    memberchk(child:Id, Fields),
    store_get(probe_children, Id, child(Status, Output, Outbox)),
    probe_child_status(Status, Id, Output, Event),
    drain_probe_outbox(Outbox, Messages).
probe_action("watch_disconnect", Fields, Last, Last, {[type:watching]}) :-
    memberchk(child:Id, Fields),
    store_get(probe_children, Id, child(running, _, _)),
    store_set(probe_children, watch_disconnect(Id), true).
probe_action("disconnect", Fields, Last, Last, {[type:disconnected]}) :-
    memberchk(child:Id, Fields),
    ( store_get(probe_children, Id, child(Status, Output, Outbox)) ->
        disconnect_probe_actor(Id, Status, Reason),
        ( store_get(probe_children, watch_disconnect(Id), _) ->
            store_set(probe_children, Id, child(down(Reason), Output, Outbox))
        ; store_delete(probe_children, Id)
        )
    ; true ).
probe_action("forget", Fields, Last, Last, {[type:forgotten]}) :-
    memberchk(child:Id, Fields),
    ( store_get(probe_children, watch_disconnect(Id), _) ->
        store_delete(probe_children, watch_disconnect(Id))
    ; true ),
    ( store_get(probe_children, Id, _) -> store_delete(probe_children, Id) ; true ).

% Reclaim a connection-owned child before clearing its gateway state.
disconnect_probe_actor(_, down(Reason), Reason).
disconnect_probe_actor(Id, running, Reason) :-
    Pid = actor(Id),
    exit(Pid, gateway_closed),
    receive({ down(Pid, Pid, Reason) -> true },
            [timeout(2), on_timeout(throw(disconnect_child_timeout(Id)))]).

reverse_spawn_key(Fields, Id, Key) :-
    ( memberchk(next:true, Fields) -> Key = reverse_next(Id) ; Key = reverse(Id) ).

retiring_prompt_watcher(Owner) :-
    receive({ prompt(Child, Payload) ->
                  self(Watcher), send(Owner, retiring_prompt_seen(Watcher, prompt(Child, Payload))) }).

prepare_reverse_watcher(Key, ParentRef) :-
    store_get(probe_children, Key,
              reverse(Node, ParentRef, Proxy, ProxyRef, watching(Child, Ref, parent))),
    % Keep the proxy's down event until the watcher can verify its reason.
    store_set(probe_children, retained_down(ProxyRef), true),
    store_set(probe_children, Key,
              reverse(Node, ParentRef, Proxy, ProxyRef, watching(Child, Ref, watcher))).

register_reverse_spawn(Id, Key, Node, ParentRef, Event) :-
    receive({ remote_spawn(actor(Id), Proxy, Node, RemoteGoal, Source) -> true },
            [timeout(2), on_timeout(throw(reverse_spawn_timeout))]),
    probe_term_text(RemoteGoal, Text),
    monitor(Proxy, ProxyRef),
    store_set(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, pending)),
    ( Source = text(SourceText) -> SourceFields = [src_text:SourceText]
    ; SourceFields = []
    ),
    Event = {[type:spawn, parent:Id, goal:Text|SourceFields]}.

reverse_prompt_fields(Fields, Id, Child@Node, Payload, Sender) :-
    memberchk(parent:Id, Fields),
    memberchk(prompt:PromptText, Fields),
    reverse_spawn_key(Fields, Id, Key),
    store_get(probe_children, Key, reverse(Node, _, _, _, watching(Child, _, Sender))),
    atom_string(Prompt, PromptText),
    ( memberchk(prompt_ref:RefText, Fields) ->
        string(RefText),
        parse_goal(RefText, isotope_bridge, Ref, _),
        ground(Ref),
        Payload = prompt_ref(Ref, Prompt)
    ; Payload = Prompt
    ).

answer_reverse_prompt(Fields, Id, Pid, Payload, Sender, Wire) :-
    memberchk(reply:ReplyText, Fields),
    parse_goal(ReplyText, isotope_bridge, Reply, _),
    ( Sender == parent -> send(actor(Id), reverse_parent_answer_prompt(Pid, Payload, Reply))
    ; respond_to_reverse_prompt(Pid, Payload, Reply)
    ),
    receive({ remote_send(Pid, Outgoing) -> probe_term_text(Outgoing, Wire) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]).

report_reverse_down(Key, Child, Text, {[type:monitored_down, child:Child, reason:Text]}) :-
    store_get(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, watching(Child, Ref, Sender))),
    parse_goal(Text, isotope_bridge, Reason, _),
    Pid = Child@Node,
    remote_actor_down(Proxy, Pid, Reason),
    store_set(probe_children, Key, reverse(Node, ParentRef, Proxy, ProxyRef, down)),
    reverse_expect_down(Pid, Ref, Reason),
    ( Sender == watcher -> reverse_expect_down(Proxy, ProxyRef, Reason)
    ; true ),
    monitor(Pid, LateRef),
    reverse_expect_down(Pid, LateRef, no_process).

probe_child_status(down(Reason), Id, Output, [type:down, pid:Id, reason:Text, output:Output]) :-
    sprintf(Text, "%Qw", [Reason]).
probe_child_status(running, Id, Output, [type:running, pid:Id, output:Output]).

drain_probe_outbox(Outbox, Messages) :-
    ( record_wait_remove(Outbox, Message, 0) ->
        Messages = [Message|Rest],
        drain_probe_outbox(Outbox, Rest)
    ; Messages = []
    ).

probe_spawn_goal(Fields, Goal) :-
    probe_spawn_goal(Fields, Goal, _).

probe_spawn_goal(Fields, Goal, Bindings) :-
    memberchk(goal:Text, Fields),
    string(Text),
    parse_goal(Text, isotope_bridge, Goal, Bindings),
    ( nonvar(Goal), callable(Goal) -> true
    ; throw(error(type_error(callable, Goal), spawn/3))
    ).

probe_source_options(Fields, Options) :-
    ( memberchk(src_text:Source, Fields) ->
        string(Source),
        Options = [src_text(Source)]
    ; Options = []
    ).

eclipse_probe_wait :-
    receive({ probe_stop -> true }).

reverse_parent(Owner, Node, Goal, ReplyTarget, Options) :-
    self(Parent),
    ( ReplyTarget = bind(Address) ->
        Parent = actor(Id),
        reverse_reply_address(parent, Id, Parent, Address)
    ; true
    ),
    set_linked_spawn_transport(Node, Owner),
    catch(spawn(Goal, Child, [node(Node)|Options]), Error,
          ( send(Owner, reverse_parent_spawn_error(Parent, Error)), throw(Error) )),
    send(Owner, reverse_parent_spawned(Parent, Child)),
    reverse_parent_loop(Child, none).

reverse_parent_loop(Child, Demonitor) :-
    receive({
        reverse_parent_send(Message) -> send(Child, Message), reverse_parent_loop(Child, Demonitor)
    ;
        reverse_parent_exit(Reason) -> exit(Child, Reason), reverse_parent_loop(Child, Demonitor)
    ;
        reverse_parent_expect_reply(Owner, Expected) ->
            await_reverse_reply(Expected, Reply),
            self(Parent),
            send(Owner, reverse_parent_reply(Parent, Reply)),
            reverse_parent_loop(Child, Demonitor)
    ;
        reverse_parent_start_next(Owner, Node, Goal, Link) ->
            self(Parent),
            spawn(Goal, Next, [node(Node), link(Link)]),
            send(Owner, reverse_parent_spawned(Parent, Next)),
            reverse_parent_loop(Child, Demonitor)
    ;
        reverse_parent_answer_prompt(Pid, Expected, Reply) ->
            receive({ prompt(Pid, Prompt) ->
                        ( Prompt == Expected -> respond_to_reverse_prompt(Pid, Prompt, Reply)
                        ; throw(unexpected_reverse_prompt(Prompt))
                        )
                    }, [timeout(2), on_timeout(throw(missing_reverse_prompt(Pid)))]),
            reverse_parent_loop(Child, Demonitor)
    ;
        reverse_parent_prepare_demonitor(Owner, Phase) ->
            prepare_spawn_demonitor(Phase, Child, Mode),
            self(Parent),
            send(Owner, reverse_parent_demonitor_prepared(Parent)),
            reverse_parent_loop(Child, Mode)
    ;
        reverse_parent_release -> true
    ;
        reverse_parent_release_after_down(Reason) -> verify_spawn_monitor(Demonitor, Child, Reason)
    }).

respond_to_reverse_prompt(Child, prompt_ref(Ref, _), Reply) :- !,
    respond(Child, Ref, Reply).
respond_to_reverse_prompt(Child, _, Reply) :-
    respond(Child, Reply).

prepare_spawn_demonitor("before", Child, before) :-
    demonitor(Child, [flush]).
prepare_spawn_demonitor("after", Child, after(Barrier)) :-
    monitor(Child, Barrier).

verify_spawn_monitor(none, Child, Reason) :-
    reverse_expect_down(Child, Child, Reason).
verify_spawn_monitor(before, Child, _) :-
    reverse_expect_no_spawn_down(Child).
verify_spawn_monitor(after(Barrier), Child, Reason) :-
    % Waiting on the later monitor puts the spawn monitor's down in the
    % deferred queue before demonitor/2 flushes it.
    reverse_expect_down(Child, Barrier, Reason),
    demonitor(Child, [flush]),
    reverse_expect_no_spawn_down(Child).

reverse_expect_no_spawn_down(Child) :-
    receive({ down(Child, Child, Reason) -> throw(unexpected_spawn_down(Child, Reason)) },
            [timeout(0), on_timeout(true)]).

% SWI imports this address as a virtual recipient scoped to the gateway's
% WebSocket. Its numeric component identifies the actual ECLiPSe watcher.
reverse_reply_address(Sender, ParentId, Watcher, WireId@localhost) :-
    ( Sender == parent -> Watcher = actor(ParentId) ; self(Watcher) ),
    Watcher = actor(Id),
    WireId is 1000000000 + Id,
    WireId =< 9999999999.

await_reverse_reply(Expected, Reply) :-
    receive({ Message if variant(Message, Expected) -> Reply = Message },
            [timeout(2), on_timeout(throw(reverse_reply_timeout(Expected)))]).

probe_term_text(Term, Text) :-
    setup_call_cleanup(
        open(string(""), write, Stream),
        ( write_term(Stream, Term, [quoted(true), portable(true)]),
          get_stream_info(Stream, name, Text)
        ),
        close(Stream)
    ).

probe_prompt_text(Prompt, Text) :-
    ( is_list(Prompt), maplist(probe_prompt_character, Prompt, Codes) ->
        string_list(Text, Codes)
    ; event_text(Prompt, Text)
    ).

record_probe_prompt(Id, Mode, Prompt) :-
    ( store_get(probe_children, Id, child(_, _, Outbox)) ->
        probe_prompt_event(Id, Mode, Prompt, Event),
        recordz(Outbox, Event)
    ; true ).

probe_prompt_event(Id, Mode, Prompt, {[type:prompt, pid:Id, data:Text|Fields]}) :-
    ( Mode = correlated(Ref) ->
        probe_term_text(Ref, RefText),
        Fields = [prompt_ref:RefText]
    ; Fields = []
    ),
    probe_prompt_text(Prompt, Text).

probe_prompt_character(Character, Code) :-
    atom(Character),
    atom_string(Character, Text),
    string_list(Text, [Code]).

reverse_expect_down(Pid, Ref, Expected) :-
    receive({
        down(Pid, Ref, Reason) ->
            ( variant(Reason, Expected) -> true ; throw(reverse_exit_reason(Pid, Reason)) )
    }, [timeout(2), on_timeout(throw(reverse_down_timeout(Pid)))]).

probe_send(Address@Node, Message, {[type:send, pid:Pid, node:NodeText, message:Text]}) :-
    atom(Node),
    ( integer(Address) -> Pid = Address ; atom(Address), atom_string(Address, Pid) ),
    atom_string(Node, NodeText),
    probe_term_text(Message, Text).

% Every offset request gets a fresh toplevel. The relay's exit also
% terminates a child suspended at a page boundary.
stateless_request(Context, Fields) :-
    catch(
        ( stateless_answer(Fields, Answer) -> true
        ; Answer = error(invalid_stateless_query)
        ),
        Error,
        Answer = error(Error)
    ),
    ( memberchk(format:"json", Fields) ->
        stateless_event(Answer, Event),
        reply_to(Context, {[type:stateless, event:Event]})
    ;
        sprintf(Body, "%Qw.%n", [Answer]),
        reply_to(Context, {[type:stateless, body:Body]})
    ).

stateless_event(success(Answers, More), {[type:success, data:Data, more:More]}) :-
    maplist(answer_row, Answers, Data).
stateless_event(failure, {[type:failure]}).
stateless_event(error(Error), {[type:error, data:Text]}) :-
    term_string(Error, Text).

stateless_answer(Fields, Answer) :-
    memberchk(goal:GoalText, Fields),
    memberchk(src_text:Source, Fields),
    memberchk(offset:Offset, Fields),
    memberchk(limit:Limit, Fields),
    memberchk(once:Once, Fields),
    setup_call_cleanup(
        toplevel_spawn(Pid, [src_text(Source)]),
        stateless_page(Pid, GoalText, Fields, Offset, Limit, Once, Answer),
        exit(Pid, query_finished)
    ).

stateless_page(Pid, GoalText, Fields, Offset, Limit, Once, Answer) :-
    actor_module(Pid, Module),
    ( memberchk(format:"json", Fields) ->
        parse_goal(GoalText, Module, Goal, Template)
    ;
        memberchk(template:TemplateText, Fields),
        concat_string(["rpc_query((", GoalText, "),(", TemplateText, "))"], Query),
        parse_goal(Query, Module, rpc_query(Goal, Template), _)
    ),
    call_page(Pid, Goal, Template, Offset, Limit, Once, Answer).

open_session(Router, Request, Fields) :-
    Context = response(Router, Request),
    request_event("spawn", Fields, Context, Event),
    ( Event = {[type:spawned, pid:Id]} ->
        self(Relay),
        ( memberchk(browser_options:_, Fields) ->
            engine_self(Engine),
            get_engine_property(Engine, store, Store),
            store_set(Store, browser_event_timeout, 15)
        ; true ),
        send(Router, http_opened(Request, Id, Relay)),
        serve_session(Router)
    ;
        reply_to(Context, Event)
    ).

serve_session(Router) :-
    receive({
        http_request(Request, Command, _, Fields) ->
            Context = response(Router, Request),
            request_event(Command, Fields, Context, Event),
            ( Event == already_sent -> true ; reply_to(Context, Event) ),
            serve_session(Router)
    ;
        http_close -> true
    }).

close_if_finished({Fields}) :-
    ( ( memberchk(type:halted, Fields) ; memberchk(retired:true, Fields) ),
      memberchk(pid:Id, Fields),
      store_get(http_sessions, Id, Relay) ->
        store_delete(http_sessions, Id),
        send(Relay, http_close)
    ;
        true
    ).

request_event(Command, Fields, Context, Event) :-
    catch(
        ( dispatch(Command, Fields, Context, Event) -> true
        ; Event = {[type:error, data:"Invalid request or goal"]}
        ),
        Error,
        ( term_string(Error, Text), Event = {[type:error, data:Text]} )
    ).

reply_to(response(Router, Request), Event) :-
    send(Router, http_reply(Request, Event)).

write_response(Stream, Request, {Fields}) :-
    reply(Stream, {[request_id:Request|Fields]}).

reply(Stream, Event) :-
    json_write(Stream, Event, [indent(0)]),
    nl(Stream),
    flush(Stream).

dispatch("spawn", Fields, _, {[type:spawned, pid:Id]}) :-
    ( memberchk(browser_options:Text, Fields) ->
        parse_goal(Text, isotope_bridge, Options, _),
        browser_spawn_source(Options, Fields, Source),
        toplevel_spawn_browser(actor(Id), [session(true)|Source])
    ; probe_source_options(Fields, Source),
      toplevel_spawn(actor(Id), [session(true)|Source])
    ).
dispatch("call", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    memberchk(goal:Text, Fields),
    memberchk(limit:Limit, Fields),
    actor_module(actor(Id), Module),
    parse_goal(Text, Module, RawGoal, Bindings),
    ( memberchk(browser_options:OptionsText, Fields) ->
        memberchk(browser_origin:OriginText, Fields),
        atom_string(Origin, OriginText),
        relay_browser_origin(Origin),
        parse_goal(OptionsText, Module, Options, _),
        ( is_list(Options), maplist(browser_call_option, Options) -> true
        ; throw(error(domain_error(browser_call_options, Options), toplevel_call/3)) ),
        import_browser_term(RawGoal, Origin, Imported),
        interactive_goal(Imported, Interactive),
        browser_goal(Interactive, Goal),
        append(Options, [limit(Limit)], PageOptions)
    ; interactive_goal(RawGoal, Goal), PageOptions = [limit(Limit)]
    ),
    Pid = actor(Id),
    self(Relay),
    toplevel_call(Pid, (send(Relay, http_started(Pid)), Goal),
                  [template(Bindings)|PageOptions]),
    % A pending Abort must interrupt this call, even if it arrived before
    % the actor had picked the call out of its mailbox.
    receive({ http_started(Pid) -> await_event(Id, Context, Event) },
            [timeout(3), on_timeout(retire(Id, "Query did not start", Event))]).
dispatch("next", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    toplevel_next(actor(Id)),
    await_event(Id, Context, Event).
dispatch("poll", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    await_event(Id, Context, Event).
dispatch("browser_ack", Fields, _, {[type:acknowledged, pid:Id]}) :-
    memberchk(pid:Id, Fields),
    send(actor(Id), '$browser_ack').
dispatch("respond", Fields, _, {[type:responded, pid:Id]}) :-
    memberchk(pid:Id, Fields),
    memberchk(prompt_ref:Ref, Fields),
    memberchk(input:Text, Fields),
    actor_module(actor(Id), Module),
    parse_goal(Text, Module, Value, _),
    respond(actor(Id), ref(Ref), Value).
dispatch("stop", Fields, _, Event) :-
    memberchk(pid:Id, Fields),
    Pid = actor(Id),
    self(Relay),
    toplevel_stop(Pid, Relay),
    receive({ stop(Pid) -> Event = {[type:stop, pid:Id]} },
            [timeout(3), on_timeout(retire(Id, "Stop acknowledgement timed out", Event))]).
dispatch("abort", Fields, _, Event) :-
    memberchk(pid:Id, Fields),
    abort_session(Id, Event).

dispatch("halt", Fields, _, {[type:halted, pid:Id, reply:"true"]}) :-
    memberchk(pid:Id, Fields),
    Pid = actor(Id),
    monitor(Pid, Ref),
    exit(Pid, http_session_closed),
    receive({ down(Pid, Ref, _) -> true },
            [timeout(2), on_timeout(throw(halt_timeout(Id)))]).

abort_session(Id, Event) :-
    Pid = actor(Id),
    toplevel_abort(Pid),
    receive({ abort(Pid) ->
                discard_deferred(query_event(Pid)),
                Event = {[type:abort, pid:Id]}
            },
            [timeout(3), on_timeout(retire(Id, "Abort acknowledgement timed out", Event))]).

parse_goal(Text, Module, Goal, Bindings) :-
    concat_string([Text, "\n.\n"], Source),
    setup_call_cleanup(
        open(string(Source), read, Stream),
        ( read_term(Stream, Goal, [variable_names(Names)])@Module,
          read(Stream, end_of_file)@Module,
          at_eof(Stream)
        ),
        close(Stream)
    ),
    named_bindings(Names, Bindings).

named_bindings([], []).
named_bindings([Name=Value|Names], Bindings) :-
    ( Name == '_' -> Bindings = Rest ; Bindings = [Name=Value|Rest] ),
    named_bindings(Names, Rest).

% Rewrite executable positions in submitted goals. Leave data terms intact.
interactive_goal(Goal, Goal) :- var(Goal), !.
interactive_goal(read(Value), input('|:', Value, [correlate(true)])) :- !.
interactive_goal(input(Prompt, Value), input(Prompt, Value, [correlate(true)])) :- !.
interactive_goal(input(Prompt, Value, Options),
                 input(Prompt, Value, [correlate(true)|Options])) :- !.
interactive_goal((A,B), (X,Y)) :- !, interactive_goal(A, X), interactive_goal(B, Y).
interactive_goal((A;B), (X;Y)) :- !, interactive_goal(A, X), interactive_goal(B, Y).
interactive_goal((A->B), (X->Y)) :- !, interactive_goal(A, X), interactive_goal(B, Y).
interactive_goal(Goal, Goal).

browser_spawn_source(Options, Fields, Source) :-
    ( is_list(Options), maplist(browser_spawn_option, Options) -> true
    ; throw(error(domain_error(browser_spawn_options, Options), toplevel_spawn/2)) ),
    ( memberchk(src_list(Clauses), Options) ->
        \+ memberchk(src_text(_), Options), \+ memberchk(src_text:_, Fields),
        maplist(browser_source_clause, Clauses, Lines),
        concat_string(Lines, Text), Source = [src_text(Text)]
    ; memberchk(src_text(Text), Options) ->
        \+ memberchk(src_text:_, Fields), Source = [src_text(Text)]
    ; probe_source_options(Fields, Source)
    ).

browser_spawn_option(Option) :-
    nonvar(Option),
    ( Option == session(true)
    ; Option = src_list(Clauses), is_list(Clauses)
    ; Option = src_text(Text), (atom(Text) ; string(Text))
    ).

browser_source_clause(Clause, Line) :-
    probe_term_text(Clause, Text),
    concat_string([Text, ".\n"], Line).

browser_call_option(Option) :-
    nonvar(Option),
    ( Option = limit(N), integer(N), N >= 1, N =< 100
    ; Option = offset(N), integer(N), N >= 0
    ; Option = once(Value), (Value == true ; Value == false)
    ).

relay_browser_origin(Origin) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    ( var(Origin) -> store_get(Store, browser_origin, Origin)
    ; store_set(Store, browser_origin, Origin)
    ).

import_browser_term(Term, _, Term) :- var(Term), !.
import_browser_term(Wire@Node, Origin, actor(Id)) :-
    Node == Origin, integer(Wire), Wire >= 1000000000, Wire =< 9999999999, !,
    Id is Wire - 1000000000.
import_browser_term(Term, Origin, Imported) :-
    compound(Term), !,
    Term =.. [Name|Args],
    ( foreach(Arg, Args), foreach(Value, Values), param(Origin) do
        import_browser_term(Arg, Origin, Value) ),
    Imported =.. [Name|Values].
import_browser_term(Term, _, Term).

query_event(Pid, success(Pid, _, _)).
query_event(Pid, failure(Pid)).
query_event(Pid, error(Pid, _)).
query_event(Pid, output(Pid, _)).
query_event(Pid, browser_output(Pid, _)).
query_event(Pid, prompt(Pid, _)).

await_event(Id, Context, Event) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    ( store_get(Store, browser_event_timeout, Wait) -> true ; Wait = 3 ),
    Pid = actor(Id),
    receive({
        http_request(AbortRequest, "abort", Id, Fields) ->
            Context = response(Router, _),
            AbortContext = response(Router, AbortRequest),
            request_event("abort", Fields, AbortContext, Abort),
            reply_to(Context, Abort),
            reply_to(AbortContext, Abort),
            Event = already_sent
    ;
        http_request(HaltRequest, "halt", Id, Fields) ->
            Context = response(Router, _),
            HaltContext = response(Router, HaltRequest),
            request_event("halt", Fields, HaltContext, Halt),
            ( Halt = {[type:halted|_]} ->
                Interrupted = {[type:error, pid:Id, code:session_lost, data:"Toplevel session halted"]}
            ;
                Interrupted = Halt
            ),
            reply_to(Context, Interrupted),
            reply_to(HaltContext, Halt),
            Event = already_sent
    ;
        success(Pid, Answers, More) ->
            maplist(answer_row, Answers, Data),
            Event = {[type:success, pid:Id, data:Data, more:More]}
    ;
        failure(Pid) ->
            Event = {[type:failure, pid:Id]}
    ;
        error(Pid, Error) ->
            term_string(Error, Text),
            Event = {[type:error, pid:Id, data:Text]}
    ;
        browser_output(Pid, Text) ->
            Event = {[type:output, pid:Id, data:Text, browser_ack:true]}
    ;
        output(Pid, Value) ->
            event_text(Value, Text),
            Event = {[type:output, pid:Id, data:Text]}
    ;
        prompt(Pid, prompt_ref(ref(Ref), Prompt)) ->
            event_text(Prompt, Text),
            Event = {[type:prompt, pid:Id, data:Text, prompt_ref:Ref]}
    ;
        prompt(Pid, _) ->
            retire(Id, "HTTP prompts require correlation", Event)
    }, [timeout(Wait), on_timeout(retire(Id, "Query event timed out", Event))]).

event_text(Value, Text) :-
    ( string(Value) -> Text = Value
    ; atom(Value) -> atom_string(Value, Text)
    ; term_string(Value, Text)
    ).

answer_row([], {}).
answer_row([Binding|Bindings], {Fields}) :-
    maplist(binding_field, [Binding|Bindings], Fields).

binding_field(Name=Value, Name:Text) :-
    ( relay_browser_origin(Origin) ->
        browser_binding_text(Value, Origin, Text)
    ; term_string(Value, Text)
    ).

browser_binding_text(Value, Origin, Text) :-
    ( nonvar(Value), Value = actor(Id), integer(Id) ->
        Wire is 1000000000 + Id,
        probe_term_text(Origin, Node),
        sprintf(Text, "%d@%s", [Wire, Node])
    ; setup_call_cleanup(
          open(string(""), write, Stream),
          ( write_term(Stream, Value, [quoted(true), compact(true)]),
            get_stream_info(Stream, name, Text) ),
          close(Stream)
      )
    ).

retire(Id, Text, {[type:error, pid:Id, retired:true, data:Text]}) :-
    exit(actor(Id), http_session_closed).
