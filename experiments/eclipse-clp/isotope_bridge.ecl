:- module(isotope_bridge).
:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(isotope_rpc).
:- ensure_loaded(server_behaviours).
:- ensure_loaded(demo_services).
:- ensure_loaded(n5_shared_db).
:- import init_linda/0 from demo_services.
:- import exit/1, exit/2 from actors.
:- import goal_template_texts/4 from stateless_rpc.
:- lib(json).
:- lib(prolog_extras).
:- export run/0.
:- local store(http_sessions).
:- local store(probe_children).
:- local store(peer_actors).
:- local store(ws_actors).
:- local op(200, xfx, @).

% The root routes requests and is the only writer to the JSON pipe.
% Each relay owns a toplevel child and waits on its PTCP mailbox.
run :-
    % ECLiPSe 7.2.13 can segfault in ecl_mark_engine while compiling
    % actor source concurrently. Keep stack GC on and avoid dictionary GC.
    set_flag(gc_interval_dict, 0),
    start_actor_runtime,
    init_egress,
    init_linda,
    get_stream(output, Replies),
    set_stream(output, error),
    set_stream(warning_output, error),
    self(Main),
    spawn(read_requests(Main), _),
    spawn(probe_echo(none), Echo),
    store_set(http_sessions, probe_echo, Echo),
    store_set(http_sessions, stateless_cache, []),
    store_set(ws_actors, subscribers, []),
    get_flag(version_as_list, VersionParts),
    sprintf(Version, "%d.%d.%d", VersionParts),
    reply(Replies, {[type:ready, version:Version, stateless_whitelist:true]}),
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
        ws_actor_opened(Request, Id, Relay) ->
            store_set(ws_actors, Id, Relay),
            write_response(Replies, Request, {[type:spawned, pid:Id]}),
            serve(Replies)
    ;
        ws_actor_event(Id, Event) ->
            ( Event = {[type:down|_]} ->
                store_delete(ws_actors, Id),
                ws_unsubscribe(Id)
            ; true ),
            reply(Replies, {[type:ws_actor_event, pid:Id, event:Event]}),
            serve(Replies)
    ;
        http_reply(Request, Event) ->
            close_if_finished(Event),
            write_response(Replies, Request, Event),
            serve(Replies)
    ;
        http_cache_page(Request, Event, Key, Offset, Relay) ->
            cache_stateless_page(Key, Offset, Relay),
            write_response(Replies, Request, Event),
            serve(Replies)
    ;
        http_egress(Key, Id, Operation, Url, Params) ->
            reply(Replies, {[type:egress, egress_id:Key, actor_id:Id,
                             operation:Operation, url:Url, params:Params]}),
            serve(Replies)
    ;
        remote_spawn(Parent, Proxy, Node, Goal, Source) ->
            start_peer_actor(Replies, Parent, Proxy, Node, Goal, Source),
            serve(Replies)
    ;
        remote_send_from(Sender, Pid, Message) ->
            peer_actor_send(Replies, Sender, Pid, Message),
            serve(Replies)
    ;
        remote_exit(Pid, Reason) ->
            peer_actor_command(Replies, Pid, "exit", reason, Reason),
            serve(Replies)
    ;
        down(_, Ref, _) if store_get(peer_actors, monitor(Ref), _) ->
            store_get(peer_actors, monitor(Ref), Proxy),
            reply(Replies, {[type:actor_peer_close, proxy:Proxy]}),
            serve(Replies)
    ;
        browser_child_output(Id, Text) ->
            ( store_get(http_sessions, Id, _) ->
                reply(Replies, {[type:browser_child_output, pid:Id, data:Text, stdout:Text]})
            ; true ),
            serve(Replies)
    ;
        browser_child_trace(Id, Chart, Text) ->
            ( store_get(http_sessions, Id, _) ->
                reply(Replies, {[type:browser_child_output, pid:Id, actor_id:Chart,
                                 kind:statechart_trace, data:Text]})
            ; true ),
            serve(Replies)
    ;
        http_closed -> true
    }).

% Monitor the proxy before opening a wire connection. This covers state
% owners that disappear before the peer publishes a PID.
start_peer_actor(Replies, Parent, Proxy, Node, Goal, Source) :-
    monitor(Proxy, Ref),
    store_set(peer_actors, monitor(Ref), Proxy),
    ( nonvar(Goal), Goal = '$peer_toplevel'(SpawnOptions) ->
        Kind = "toplevel_spawn", GoalText = ""
    ; Kind = "spawn", SpawnOptions = [],
      goal_template_texts(Goal, Goal, GoalText, _) ),
    store_set(peer_actors, Proxy, peer(Parent, Node, Ref, pending, Kind)),
    ( Source = text(Text) -> atom_string(Atom, Text), Options = [src_text(Atom)|SpawnOptions]
    ; Options = SpawnOptions ),
    goal_template_texts(Options, Options, OptionsText, _),
    atom_string(Node, Url),
    reply(Replies, {[type:actor_peer_start, proxy:Proxy, url:Url,
                     command:Kind, goal:GoalText, options:OptionsText]}).

peer_actor_command(Replies, Pid, Command, Field, Value) :-
    ( store_get(peer_actors, pid(Pid), Proxy) ->
        goal_template_texts(Value, Value, Text, _),
        reply(Replies, {[type:actor_peer_command, proxy:Proxy,
                         command:Command, Field:Text]})
    ; true ).

% A local sender in the spawning browser session can supply its own
% PID as the first argument to receive replies over the peer connection.
peer_actor_send(Replies, Sender, Pid, Message) :-
    ( store_get(peer_actors, pid(Pid), Proxy) ->
        store_get(peer_actors, Proxy, peer(Parent, _, _, active(Pid), Kind)),
        ( Kind == "toplevel_spawn", nonvar(Message),
          peer_sync_command(Sender, Message, Fields) -> true
        ; Kind == "toplevel_spawn", nonvar(Message), peer_toplevel_command(Message, Fields) ->
            true
        ; goal_template_texts(Message, Message, Text, _),
          ( actor_browser_session(Parent, Session), actor_browser_session(Sender, Session),
            compound(Message), arg(1, Message, From), From == Sender ->
              sprintf(FromText, "%d", [Sender]),
              Return = [browser_from:FromText]
          ; Return = [] ),
          Fields = [command:"send", message:Text|Return] ),
        reply(Replies, {[type:actor_peer_command, proxy:Proxy|Fields]})
    ; true ).

% SWI imports this virtual target on the same socket. Keep the reference and
% serialize the goal and its template together, just as for a local call.
peer_sync_command(Sender, Command, [command:"send", message:Text, reply_target:Target, sync_ref:Ref]) :-
    ( Command = '$call'(Goal, Options) -> Wire = '$call'(Goal, WireOptions)
    ; Command = '$next'(Options), Wire = '$next'(WireOptions) ),
    select('$request_ref'(Ref), Options, AfterRef), integer(Ref),
    select(target(Caller), AfterRef, Query), Caller == Sender,
    WireOptions = ['$request_ref'(Ref), target(Sender@localhost)|Query],
    goal_template_texts(Wire, Wire, Text, _),
    sprintf(Target, "%d@localhost", [Sender]).

peer_toplevel_command('$call'(Goal, Options), [command:"toplevel_call", goal:Text, options:Wire]) :-
    goal_template_texts(Goal, [format(prolog)|Options], Text, Wire).
peer_toplevel_command('$next'(Options), [command:"toplevel_next"|Fields]) :-
    ( memberchk(limit(Limit), Options) -> Fields = [limit:Limit] ; Fields = [] ).
peer_toplevel_command('$stop', [command:"toplevel_stop"]).
peer_toplevel_command('$abort', [command:"toplevel_abort"]).

peer_actor_event(Proxy, Fields) :-
    ( store_get(peer_actors, Proxy, peer(Parent, Node, Ref, Status, Kind)) ->
        memberchk(event:Event, Fields),
        ( Event == "spawned", Status == pending, memberchk(child:Id, Fields),
          Pid = Id@Node, acknowledge_remote_spawn(Proxy, Pid) ->
            store_set(peer_actors, pid(Pid), Proxy),
            store_set(peer_actors, Proxy, peer(Parent, Node, Ref, active(Pid), Kind))
        ; Event == "answer", Kind == "toplevel_spawn", Status = active(Pid) ->
            peer_toplevel_answer(Pid, Fields, Answer),
            send(Parent, Answer)
        ; Event == "output", Status = active(Pid), memberchk(data:Text, Fields) ->
            ( catch(parse_goal(Text, isotope_bridge, Term, _), _, fail) -> Value = Term
            ; Value = Text ),
            send(Parent, output(Pid, Value))
        ; Event == "stdout", Status = active(_), memberchk(data:Text, Fields) ->
            ( actor_browser_session(Parent, Session) ->
                send(main, browser_child_output(Session, Text))
            ; true )
        ; Event == "message", Status = active(Pid), memberchk(target:Target, Fields),
          number_string(Recipient, Target), integer(Recipient),
          actor_browser_session(Parent, Session), actor_browser_session(Recipient, Session),
          memberchk(data:Text, Fields),
          catch(parse_goal(Text, isotope_bridge, Message, _), _, fail) ->
            ( Kind == "toplevel_spawn", nonvar(Message), Message = '$toplevel_reply'(Ref, Reply) ->
                ( ground(Ref), peer_wire_answer(Pid, Reply, Answer) ->
                    send(Recipient, '$toplevel_reply'(Ref, Answer))
                ; true )
            ; Kind == "toplevel_spawn", peer_wire_answer(Pid, Message, Answer) ->
                send(Recipient, Answer)
            ; send(Recipient, Message) )
        ; Event == "sync_unsupported", Kind == "toplevel_spawn", Status = active(Pid),
          memberchk(target:Target, Fields), number_string(Recipient, Target),
          memberchk(ref:Ref, Fields) ->
            send(Recipient, '$toplevel_reply'(Ref, '$sync_unsupported'(Pid)))
        ; Event == "closed", memberchk(reason:Text, Fields) ->
            store_delete(peer_actors, Proxy),
            store_delete(peer_actors, monitor(Ref)),
            demonitor(Ref, [flush]),
            ( Status = active(Pid) ->
                store_delete(peer_actors, pid(Pid)),
                ( catch(parse_goal(Text, isotope_bridge, Why, _), _, fail), ground(Why) ->
                    Reason = Why
                ; Reason = connection_closed ),
                remote_actor_down(Proxy, Pid, Reason)
            ; send(Proxy, remote_spawn_reply(error(Text))) )
        ; true )
    ; true ).

peer_wire_answer(Pid, Reply, Answer) :-
    nonvar(Reply),
    ( Reply = success(Wire, Rows, More), Answer = success(Pid, Rows, More)
    ; Reply = failure(Wire), Answer = failure(Pid)
    ; Reply = error(Wire, Error), Answer = error(Pid, Error) ),
    Pid = Id@_,
    ( Wire == Id ; nonvar(Wire), Wire = WireId@_, WireId == Id ), !.

peer_toplevel_answer(Pid, Fields, Answer) :-
    memberchk(kind:Kind, Fields),
    ( Kind == "success", memberchk(more:More, Fields), memberchk(data:Text, Fields),
      catch(parse_goal(Text, isotope_bridge, Rows, _), _, fail), is_list(Rows) ->
        Answer = success(Pid, Rows, More)
    ; Kind == "failure" -> Answer = failure(Pid)
    ; Kind == "stop" -> Answer = stop(Pid)
    ; Kind == "abort" -> Answer = abort(Pid)
    ; Kind == "error", memberchk(data:Text, Fields) ->
        ( catch(parse_goal(Text, isotope_bridge, Error, _), _, fail) -> true ; Error = Text ),
        Answer = error(Pid, Error)
    ; Answer = error(Pid, invalid_remote_toplevel_answer) ).

route_request(Request, "spawn", _, Fields) :- !,
    self(Router),
    spawn(open_session(Router, Request, Fields), _).
route_request(Request, "ws_actor_spawn", _, Fields) :- !,
    self(Router),
    spawn(open_ws_actor(Router, Request, Fields), _).
route_request(Request, "ws_actor_pubsub", _, Fields) :- !,
    self(Router),
    Context = response(Router, Request),
    request_event("ws_actor_pubsub", Fields, Context, Event),
    reply_to(Context, Event).
route_request(Request, Command, _, Fields) :-
    memberchk(Command, ["ws_actor_start", "ws_actor_send", "ws_actor_exit"]), !,
    ( memberchk(actor:Id, Fields), store_get(ws_actors, Id, Relay) ->
        send(Relay, http_request(Request, Command, Id, Fields))
    ; self(Router),
      reply_to(response(Router, Request), {[type:error, data:"Unknown actor"]}) ).
route_request(Request, "stateless", _, Fields) :- !,
    self(Router),
    Context = response(Router, Request),
    stateless_key(Fields, Key),
    memberchk(offset:Offset, Fields),
    ( take_stateless_page(Key, Offset, Relay) ->
        send(Relay, stateless_next(Context, Fields))
    ;
        spawn(stateless_request(Context, "stateless", Fields), _)
    ).
route_request(Request, "stateless_whitelist", _, Fields) :- !,
    self(Router),
    spawn(stateless_request(response(Router, Request), "stateless_whitelist", Fields), _).
route_request(Request, "actor_probe", _, Fields) :- !,
    self(Router),
    store_get(http_sessions, probe_echo, Echo),
    send(Echo, probe_request(response(Router, Request), Fields)).
route_request(_, "actor_peer_event", Proxy, Fields) :- !,
    peer_actor_event(Proxy, Fields).
route_request(Key, "egress_result", Id, Fields) :- !,
    memberchk(status:Status, Fields),
    memberchk(body:Body, Fields),
    send(Id, http_egress_result(Key, Status, Body)).
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
        down(Id, Ref, Reason) if (integer(Id), \+ store_get(probe_children, retained_down(Ref), _)) ->
            ( store_get(probe_children, Id, child(_, Output, Outbox)) ->
                store_set(probe_children, Id, child(down(Reason), Output, Outbox))
            ; true ),
            probe_echo(Last)
    ;
        output(Id, Term) if integer(Id) ->
            ( store_get(probe_children, Id, child(Status, _, Outbox)) ->
                probe_term_text(Term, Text),
                recordz(Outbox, {[type:output, pid:Id, data:Text]}),
                store_set(probe_children, Id, child(Status, Text, Outbox))
            ; true ),
            probe_echo(Last)
    ;
        prompt(Id, Prompt) if integer(Id) ->
            record_probe_prompt(Id, plain, Prompt),
            probe_echo(Last)
    ;
        '$input_prompt'(Id, Mode, Prompt) if integer(Id) ->
            record_probe_prompt(Id, Mode, Prompt),
            probe_echo(Last)
    ;
        remote_send_from(Id, Target, Message) if integer(Id) ->
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
    spawn(reverse_parent(Owner, Node, Goal, ReplyTarget, [link(Link), monitor(Monitor)|Options]), Id),
    monitor(Id, ParentRef),
    catch(register_reverse_spawn(Id, reverse(Id), Node, ParentRef, Event), Error,
          ( demonitor(ParentRef, [flush]), exit(Id, gateway_closed), throw(Error) )).
probe_action("reverse_start_next", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id), reverse(Node, ParentRef, _, _, watching(_, _, parent))),
    probe_spawn_goal(Fields, Goal),
    ( memberchk(link:false, Fields) -> Link = false ; Link = true ),
    self(Owner),
    send(Id, reverse_parent_start_next(Owner, Node, Goal, Link)),
    register_reverse_spawn(Id, reverse_next(Id), Node, ParentRef, Event).
probe_action("reverse_watcher_address", _, Last, Last, {[type:watcher, address:Text]}) :-
    reverse_reply_address(watcher, _, _, Address),
    probe_term_text(Address, Text).
probe_action("reverse_open_retiring_watcher", Fields, Last, Last, {[type:watcher, address:Text]}) :-
    memberchk(parent:Id, Fields),
    self(Owner),
    spawn(retiring_prompt_watcher(Owner), Watcher, [monitor(true)]),
    store_set(probe_children, retiring_watcher(Id), Watcher),
    reverse_reply_address(parent, Watcher, _, Address),
    probe_term_text(Address, Text).
probe_action("reverse_retire_prompt_watcher", Fields, Last, Last, {[type:watcher_down, reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    memberchk(target:TargetText, Fields),
    memberchk(message:MessageText, Fields),
    store_get(probe_children, retiring_watcher(Id), Watcher),
    reverse_reply_address(parent, Watcher, _, Address),
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
    receive({ reverse_parent_spawned(Id, Returned@Node) -> true },
            [timeout(2), on_timeout(throw(reverse_spawn_reply_timeout(Id)))]),
    ( Returned == Child -> true ; throw(reverse_spawn_pid_mismatch(Child, Returned)) ).
probe_action("reverse_prepare_demonitor", Fields, Last, Last, {[type:demonitor_prepared]}) :-
    memberchk(parent:Id, Fields),
    memberchk(phase:Phase, Fields),
    store_get(probe_children, reverse(Id), reverse(_, _, _, _, watching(_, _, parent))),
    self(Owner),
    send(Id, reverse_parent_prepare_demonitor(Owner, Phase)),
    receive({ reverse_parent_demonitor_prepared(Id) -> true },
            [timeout(2), on_timeout(throw(reverse_demonitor_timeout(Id)))]).
probe_action("reverse_detach_parent", Fields, Last, Last, {[type:released, parent_reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    prepare_reverse_watcher(reverse(Id), ParentRef),
    send(Id, reverse_parent_release),
    reverse_expect_down(Id, ParentRef, true).
probe_action("reverse_detach_parent_pair", Fields, Last, Last, {[type:released, parent_reason:"true"]}) :-
    memberchk(parent:Id, Fields),
    prepare_reverse_watcher(reverse(Id), ParentRef),
    prepare_reverse_watcher(reverse_next(Id), ParentRef),
    send(Id, reverse_parent_release),
    reverse_expect_down(Id, ParentRef, true).
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
    ( Sender == parent -> send(Id, reverse_parent_send(Outbound))
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
    send(Id, prompt(Pid, Payload)),
    answer_reverse_prompt(Fields, Id, Pid, Payload, parent, Wire).
probe_action("reverse_race_prompt", Fields, Last, Last, {[type:send_pair, child:Child, messages:[First,Second]]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, parent),
    Pid = Child@_,
    Payload = prompt_ref(Ref, _),
    send(Id, prompt(Pid, Payload)),
    send(Id, reverse_parent_answer_prompt(Pid, Payload, answer(21))),
    spawn(respond(Pid, Ref, answer(42)), _),
    receive({ remote_send(Pid, Reply1) -> probe_term_text(Reply1, First) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]),
    receive({ remote_send(Pid, Reply2) -> probe_term_text(Reply2, Second) },
            [timeout(2), on_timeout(throw(reverse_prompt_timeout(Id)))]).
probe_action("reverse_queue_prompt", Fields, Last, Last, {[type:queued, child:Child]}) :-
    reverse_prompt_fields(Fields, Id, Pid, Payload, parent),
    Pid = Child@_,
    send(Id, prompt(Pid, Payload)).
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
    ( Sender == parent -> send(Id, reverse_parent_exit(Reason))
    ; exit(Child@Node, Reason)
    ),
    receive({ remote_exit(Child@Node, Outgoing) -> probe_term_text(Outgoing, Wire) },
            [timeout(2), on_timeout(throw(reverse_exit_timeout(Id)))]).
probe_action("reverse_release", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id), reverse(_, ParentRef, Proxy, ProxyRef, watching(Child, _, parent))),
    send(Id, reverse_parent_release),
    reverse_expect_down(Id, ParentRef, true),
    reverse_expect_down(Proxy, ProxyRef, kill),
    Event = {[type:exit, child:Child, reason:"kill", parent_reason:"true"]}.
probe_action("reverse_release_pair", Fields, Last, Last, Event) :-
    memberchk(parent:Id, Fields),
    store_get(probe_children, reverse(Id),
              reverse(_, ParentRef, FirstProxy, FirstRef, watching(First, _, parent))),
    store_get(probe_children, reverse_next(Id),
              reverse(_, ParentRef, SecondProxy, SecondRef, watching(Second, _, parent))),
    send(Id, reverse_parent_release),
    reverse_expect_down(Id, ParentRef, true),
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
        send(Id, reverse_parent_release_after_down(Reason))
    ; send(Id, reverse_parent_release)
    ),
    reverse_expect_down(Id, ParentRef, true).
probe_action("reverse_reject", Fields, Last, Last, {[type:rejected]}) :-
    memberchk(parent:Id, Fields),
    memberchk(reason:Reason, Fields),
    store_get(probe_children, reverse(Id), reverse(_, _, Proxy, _, pending)),
    send(Proxy, remote_spawn_reply(error(Reason))),
    receive({
        reverse_parent_spawn_error(Id, error(remote_spawn_failed(Reason), _)) -> true
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
        exit(Id, gateway_closed)
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
          Id, [monitor(true)|Options]),
    record_create(Outbox),
    store_set(probe_children, Id, child(running, null, Outbox)),
    send(Id, probe_run).
probe_action("send", Fields, Last, Last, {[type:received]}) :-
    memberchk(child:Id, Fields),
    memberchk(message:Text, Fields),
    store_get(probe_children, Id, child(Status, _, _)),
    ( Status == running ->
        parse_goal(Text, isotope_bridge, Message, _),
        send(Id, Message)
    ; true
    ).
probe_action("exit", Fields, Last, Last, {[type:exiting]}) :-
    memberchk(child:Id, Fields),
    memberchk(reason:Text, Fields),
    parse_goal(Text, isotope_bridge, Reason, _),
    ground(Reason),
    store_get(probe_children, Id, _),
    exit(Id, Reason).
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
    exit(Id, gateway_closed),
    receive({ down(Id, Id, Reason) -> true },
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
    receive({ remote_spawn(Id, Proxy, Node, RemoteGoal, Source) -> true },
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
    ( Sender == parent -> send(Id, reverse_parent_answer_prompt(Pid, Payload, Reply))
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
        reverse_reply_address(parent, Parent, Parent, Address)
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
reverse_reply_address(Sender, ParentId, Watcher, Watcher@localhost) :-
    ( Sender == parent -> Watcher = ParentId ; self(Watcher) ).

await_reverse_reply(Expected, Reply) :-
    receive({ Message if variant(Message, Expected) -> Reply = Message },
            [timeout(2), on_timeout(throw(reverse_reply_timeout(Expected)))]).

probe_term_text(Term, Text) :-
    setup_call_cleanup(
        open(string(""), write, Stream),
        ( write_term(Stream, Term, [quoted(true), portable(true), max_depth(0)]),
          get_stream_info(Stream, name, Text)
        ),
        close(Stream)
    ).

probe_prompt_text(Prompt, Text) :-
    ( text_string(Prompt, Text) -> true
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

% The root owns the cache. Each entry keeps its original relay and child
% together so subsequent pages and any query I/O reach the same mailbox.
stateless_key(Fields, query(Format, Goal, Template, Source, Once, Timeout)) :-
    memberchk(format:Format, Fields),
    memberchk(goal:Goal, Fields),
    ( Format == "json" -> Template = bindings ; memberchk(template:Template, Fields) ),
    memberchk(src_text:Source, Fields),
    memberchk(once:Once, Fields),
    stateless_timeout(Fields, Timeout).

stateless_timeout(Fields, Timeout) :-
    ( memberchk(timeout:Requested, Fields) -> Timeout = Requested ; Timeout = none ).

take_stateless_page(Key, Offset, Relay) :-
    store_get(http_sessions, stateless_cache, Entries),
    select(cached(Key, Offset, Relay), Entries, Rest), !,
    store_set(http_sessions, stateless_cache, Rest).

cache_stateless_page(Key, Offset, Relay) :-
    store_get(http_sessions, stateless_cache, Entries),
    % Keep at most four idle continuations on the owner adapter.
    ( length(Entries, 4) ->
        Entries = [cached(_, _, Oldest)|Kept],
        send(Oldest, http_close)
    ; Kept = Entries ),
    append(Kept, [cached(Key, Offset, Relay)], Updated),
    store_set(http_sessions, stateless_cache, Updated).

stateless_request(Context, Command, Fields) :-
    catch(
        ( stateless_query(Context, Command, Fields) -> true
        ; stateless_reply(Context, Fields, error(invalid_stateless_query))
        ),
        Error,
        stateless_reply(Context, Fields, error(Error))
    ),
    !.

stateless_reply(Context, Fields, Answer) :-
    stateless_response(Fields, Answer, Response),
    reply_to(Context, Response).

stateless_response(Fields, Answer, Response) :-
    ( memberchk(format:"json", Fields) ->
        stateless_event(Answer, Event),
        Response = {[type:stateless, event:Event]}
    ;
        sprintf(Body, "%Qw.%n", [Answer]),
        Response = {[type:stateless, body:Body]}
    ).

stateless_event(success(Answers, More), {[type:success, data:Data, more:More]}) :-
    maplist(answer_row, Answers, Data).
stateless_event(failure, {[type:failure]}).
stateless_event(error(Error), {[type:error, data:Text]}) :-
    term_string(Error, Text).

stateless_query(Context, Command, Fields) :-
    memberchk(src_text:Source, Fields),
    memberchk(offset:Offset, Fields),
    ( Command == "stateless_whitelist" ->
        ( Source == "" -> true ; stateless_denied(load, src_text) ),
        ( Offset =< 1000 -> true
        ; throw(error(domain_error(stateless_preview_offset, Offset), stateless_whitelist)) )
    ; true ),
    stateless_timeout(Fields, Timeout),
    stateless_spawn_options(Source, Timeout, Options),
    setup_call_cleanup(
        toplevel_spawn(Pid, Options),
        serve_stateless_page(Context, Command, Fields, Pid, initial),
        exit(Pid, query_finished)
    ).

serve_stateless_page(Context, Command, Fields, Pid, Phase) :-
    catch(
        ( ( stateless_page(Phase, Command, Pid, Fields, Answer) -> true
          ; Answer = error(invalid_stateless_query) ),
          finish_stateless_page(Context, Command, Fields, Answer, Cached)
        ),
        Error,
        ( stateless_reply(Context, Fields, error(Error)), Cached = false )
    ),
    ( Cached == true ->
        receive({ stateless_next(NextContext, NextFields) -> Action = next
                ; http_close -> Action = close }),
        ( Action == next -> serve_stateless_page(NextContext, Command, NextFields, Pid, next)
        ; true )
    ; true ).

finish_stateless_page(Context, "stateless", Fields, Answer, true) :-
    Answer = success(Rows, true), !,
    stateless_response(Fields, Answer, Response),
    stateless_key(Fields, Key),
    memberchk(offset:Offset, Fields),
    length(Rows, Count),
    NextOffset is Offset + Count,
    Context = response(Router, Request),
    self(Relay),
    send(Router, http_cache_page(Request, Response, Key, NextOffset, Relay)).
finish_stateless_page(Context, _, Fields, Answer, false) :-
    stateless_reply(Context, Fields, Answer).

stateless_page(next, _, Pid, Fields, Answer) :-
    memberchk(limit:Limit, Fields),
    toplevel_next(Pid, [limit(Limit)]),
    await_call_page(Pid, Answer).
stateless_page(initial, Command, Pid, Fields, Answer) :-
    memberchk(goal:GoalText, Fields),
    memberchk(offset:Offset, Fields),
    memberchk(limit:Limit, Fields),
    memberchk(once:Once, Fields),
    actor_module(Pid, Module),
    ( memberchk(format:"json", Fields) ->
        parse_goal(GoalText, Module, Goal, Template)
    ;
        memberchk(template:TemplateText, Fields),
        concat_string(["rpc_query((", GoalText, "),(", TemplateText, "))"], Query),
        parse_goal(Query, Module, rpc_query(Goal, Template), _)
    ),
    ( Command == "stateless_whitelist" ->
        check_stateless_goal(Goal),
        Executable = (Goal, (acyclic_term(Template) -> true
                      ; throw(error(representation_error(cyclic_term), stateless_whitelist))))
    ; Executable = Goal ),
    call_page(Pid, Executable, Template, Offset, Limit, Once, Answer).

% Check executable positions in the parsed term before calling it. With no
% source loading, the allowed indicators resolve only to installed predicates.
% Arithmetic evaluation can invoke native predicates in ECLiPSe, so is/2
% and arithmetic comparisons require a separate expression policy.
check_stateless_goal(Goal) :-
    ( var(Goal) -> stateless_denied(call, variable_goal)
    ; functor(Goal, Name, Arity),
      Indicator = Name/Arity,
      ( stateless_primitive(Indicator) -> true
      ; stateless_meta(Indicator, Positions) ->
          ( foreach(Position, Positions), param(Goal) do
              arg(Position, Goal, Nested),
              check_stateless_goal(Nested)
          )
      ; stateless_denied(call, Indicator)
      )
    ).

stateless_denied(Action, Target) :-
    throw(error(permission_error(Action, sandboxed, Target), stateless_whitelist)).

stateless_primitive(Indicator) :-
    memberchk(Indicator, [true/0, fail/0, sleep/1, (=)/2, (==)/2, (\==)/2,
                          var/1, nonvar/1, ground/1, atom/1, integer/1, number/1,
                          member/2, memberchk/2, append/3, length/2, select/3,
                          nth0/3, nth0/4, nth1/3, nth1/4, between/3, succ/2,
                          runtime_property/1]).

stateless_meta((',')/2, [1,2]).
stateless_meta((';')/2, [1,2]).
stateless_meta((->)/2, [1,2]).
stateless_meta((\+)/1, [1]).
stateless_meta(call/1, [1]).
stateless_meta(once/1, [1]).
stateless_meta(findall/3, [2]).
stateless_meta(forall/2, [1,2]).
stateless_meta(call_nth/2, [1]).
stateless_meta(countall/2, [1]).

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

open_ws_actor(Router, Request, Fields) :-
    Context = response(Router, Request),
    request_event("ws_actor_spawn", Fields, Context, Event),
    ( Event = {[type:spawned, pid:Id]} ->
        self(Relay),
        send(Router, ws_actor_opened(Request, Id, Relay)),
        serve_ws_actor(Router, Id)
    ; reply_to(Context, Event) ).

% The router serializes publications and subscription changes. The adapter
% supplies the calling socket's actor IDs separately from the message term.
ws_pubsub(subscribe(Id), Owned) :-
    ws_check_subscriber(Id, Owned),
    store_get(ws_actors, subscribers, Subscribers),
    ( memberchk(Id, Subscribers) -> true
    ; store_set(ws_actors, subscribers, [Id|Subscribers]) ).
ws_pubsub(unsubscribe(Id), Owned) :-
    ws_check_subscriber(Id, Owned),
    ws_unsubscribe(Id).
ws_pubsub(publish(Value), _) :-
    store_get(ws_actors, subscribers, Subscribers),
    ( foreach(Id, Subscribers), param(Value) do send(Id, msg(Value)) ).

ws_check_subscriber(Id, Owned) :-
    ( integer(Id), memberchk(Id, Owned), store_get(ws_actors, Id, _) -> true
    ; throw(error(permission_error(subscribe, ws_actor, Id), pubsub_service)) ).

ws_unsubscribe(Id) :-
    store_get(ws_actors, subscribers, Subscribers),
    ( select(Id, Subscribers, Rest) -> store_set(ws_actors, subscribers, Rest)
    ; true ).

serve_ws_actor(Router, Id) :-
    receive({
        http_request(Request, Command, Id, Fields) ->
            Context = response(Router, Request),
            request_event(Command, Fields, Context, Event),
            reply_to(Context, Event),
            serve_ws_actor(Router, Id)
    ;
        output(Id, Value) ->
            event_text(Value, Text),
            send(Router, ws_actor_event(Id, {[type:output, pid:Id, data:Text]})),
            serve_ws_actor(Router, Id)
    ;
        terminal_io_output(Id, Value) ->
            event_text(Value, Text),
            send(Router, ws_actor_event(Id, {[type:output, pid:Id, data:Text, stdout:Text]})),
            serve_ws_actor(Router, Id)
    ;
        down(Id, Id, Reason) ->
            probe_term_text(Reason, Text),
            send(Router, ws_actor_event(Id, {[type:down, pid:Id, ref:Id, reason:Text]}))
    }).

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

dispatch("ws_actor_spawn", Fields, _, {[type:spawned, pid:Id]}) :-
    memberchk(goal:GoalText, Fields),
    parse_goal(GoalText, isotope_bridge, Goal, _),
    memberchk(options:OptionsText, Fields),
    parse_goal(OptionsText, isotope_bridge, Options, _),
    ( Options == [] ; Options = [Option], nonvar(Option),
      ( Option = src_text(_) ; Option = src_list(_) ) ),
    browser_spawn_source(Options, Fields, Source),
    self(Relay),
    % Wait until the socket has announced the PID before running the goal.
    spawn((receive({ '$ws_actor_start' -> true }), Goal), Id,
          [monitor(true), io_target(Relay), src_text("")|Source]).
dispatch("ws_actor_start", Fields, _, {[type:accepted]}) :-
    memberchk(actor:Id, Fields),
    send(Id, '$ws_actor_start').
dispatch("ws_actor_send", Fields, _, {[type:accepted]}) :-
    memberchk(actor:Id, Fields),
    memberchk(message:Text, Fields),
    parse_goal(Text, isotope_bridge, Message, _),
    send(Id, Message).
dispatch("ws_actor_exit", Fields, _, {[type:accepted]}) :-
    memberchk(actor:Id, Fields),
    memberchk(reason:Text, Fields),
    parse_goal(Text, isotope_bridge, Reason, _),
    exit(Id, Reason).
dispatch("ws_actor_pubsub", Fields, _, {[type:accepted]}) :-
    memberchk(message:Text, Fields),
    memberchk(owned:Owned, Fields),
    parse_goal(Text, isotope_bridge, Message, _),
    nonvar(Message),
    ws_pubsub(Message, Owned).

dispatch("spawn", Fields, _, {[type:spawned, pid:Id]}) :-
    ( memberchk(browser_options:Text, Fields) ->
        parse_goal(Text, isotope_bridge, Options, _),
        browser_spawn_source(Options, Fields, Source),
        toplevel_spawn_browser(Id, [session(true)|Source])
    ; probe_source_options(Fields, Source),
      toplevel_spawn(Id, [session(true)|Source])
    ).
dispatch("call", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    memberchk(goal:Text, Fields),
    memberchk(limit:Limit, Fields),
    actor_module(Id, Module),
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
    session_reply_mode(browser),
    start_session_call(Id, Goal, [template(Bindings)|PageOptions], Context, Event).
dispatch("next", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    ( session_reply_mode_current(wire(_, _)) -> session_reply_mode(wire(none, ""))
    ; true ),
    toplevel_next(Id),
    await_event(Id, Context, Event).
dispatch("ws_toplevel_query", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    memberchk(message:Text, Fields),
    memberchk(wire_state:State, Fields),
    memberchk(browser_origin:OriginText, Fields),
    atom_string(Origin, OriginText),
    actor_module(Id, Module),
    parse_goal(Text, Module, Command, _),
    nonvar(Command),
    ( Command = '$call'(RawGoal, Options), State == "idle" ->
        wire_query_options(Options, call, "", Query, Mode),
        import_browser_term(RawGoal-Query, Origin, Imported-ImportedOptions),
        interactive_goal(Imported, Interactive),
        browser_goal(Interactive, Goal),
        % Preserve the supplied goal as the default template before rewriting.
        ( memberchk(template(_), ImportedOptions) -> PageOptions = ImportedOptions
        ; PageOptions = [template(Imported)|ImportedOptions] ),
        relay_browser_origin(Origin),
        session_reply_mode(Mode),
        start_session_call(Id, Goal, PageOptions, Context, Event)
    ; Command = '$next'(Options), State == "next" ->
        ( session_reply_mode_current(wire(_, PreviousTarget)) -> true ; PreviousTarget = "" ),
        wire_query_options(Options, next, PreviousTarget, Query, Mode),
        relay_browser_origin(Origin),
        session_reply_mode(Mode),
        toplevel_next(Id, Query),
        await_event(Id, Context, Event)
    ; throw(error(domain_error(toplevel_wire_command, Command), toplevel_call/3))
    ).
dispatch("poll", Fields, Context, Event) :-
    memberchk(pid:Id, Fields),
    await_event(Id, Context, Event).
dispatch("browser_ack", Fields, _, {[type:acknowledged, pid:Id]}) :-
    memberchk(pid:Id, Fields),
    send(Id, '$browser_ack').
dispatch("respond", Fields, _, {[type:responded, pid:Id]}) :-
    memberchk(pid:Id, Fields),
    memberchk(prompt_ref:Ref, Fields),
    memberchk(input:Text, Fields),
    actor_module(Id, Module),
    parse_goal(Text, Module, Value, _),
    respond(Id, Ref, Value).
dispatch("stop", Fields, _, Event) :-
    memberchk(pid:Id, Fields),
    self(Relay),
    toplevel_stop(Id, Relay),
    receive({ stop(Id) -> Event = {[type:stop, pid:Id]} },
            [timeout(3), on_timeout(retire(Id, "Stop acknowledgement timed out", Event))]).
dispatch("abort", Fields, _, Event) :-
    memberchk(pid:Id, Fields),
    abort_session(Id, Event).

dispatch("halt", Fields, _, {[type:halted, pid:Id, reply:"true"]}) :-
    memberchk(pid:Id, Fields),
    monitor(Id, Ref),
    exit(Id, http_session_closed),
    receive({ down(Id, Ref, _) -> true },
            [timeout(2), on_timeout(throw(halt_timeout(Id)))]).

abort_session(Id, Event) :-
    toplevel_abort(Id),
    receive({ abort(Id) ->
                discard_deferred(query_event(Id)),
                Event = {[type:abort, pid:Id]}
            },
            [timeout(3), on_timeout(retire(Id, "Abort acknowledgement timed out", Event))]).

start_session_call(Id, Goal, Options, Context, Event) :-
    self(Relay),
    toplevel_call(Id, (send(Relay, http_started(Id)), Goal), Options),
    % A pending Abort must interrupt this call, even if it arrived before
    % the actor had picked the call out of its mailbox.
    receive({ http_started(Id) -> await_event(Id, Context, Event) },
            [timeout(3), on_timeout(retire(Id, "Query did not start", Event))]).

session_reply_mode(Mode) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    store_set(Store, ws_reply_mode, Mode).

session_reply_mode_current(Mode) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    store_get(Store, ws_reply_mode, Mode).

wire_query_options(Options, Kind, DefaultTarget, Query, wire(Ref, Target)) :-
    ( is_list(Options),
      wire_query_options(Options, Kind, Query, none, Ref, none, Selected) ->
        ( Selected == none -> Target = DefaultTarget ; Target = Selected )
    ; throw(error(domain_error(toplevel_wire_options, Options), toplevel_call/3)) ).

wire_query_options([], _, [], Ref, Ref, Target, Target).
wire_query_options([Option|Options], Kind, Query, Ref0, Ref, Target0, Target) :-
    nonvar(Option),
    ( Option = '$request_ref'(Request), Ref0 == none, ground(Request), Request \== none ->
        Ref1 = Request, Target1 = Target0, Query = Rest
    ; Option = target(Address), Target0 == none, wire_query_target(Address, WireTarget) ->
        Ref1 = Ref0, Target1 = WireTarget, Query = Rest
    ; Option == format(prolog) ->
        Ref1 = Ref0, Target1 = Target0, Query = Rest
    ; ( Kind == call, ( Option = template(_) ; browser_call_option(Option) )
      ; Kind == next, Option = limit(N), integer(N), N >= 1, N =< 100 ) ->
        Ref1 = Ref0, Target1 = Target0, Query = [Option|Rest]
    ),
    wire_query_options(Options, Kind, Rest, Ref1, Ref, Target1, Target).

% Only this connection's browser return addresses are accepted here.
wire_query_target(Address, Text) :-
    nonvar(Address), Address = Id@Node, Node == localhost,
    ( Id == main -> Text = "main@localhost"
    ; integer(Id), Id >= 1000000000, Id =< 9999999999,
      sprintf(Text, "%d@localhost", [Id]) ).

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
    ; Option = src_text(Text), text_string(Text, _)
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
import_browser_term(Id@Node, Origin, Id) :-
    Node == Origin, integer(Id), Id >= 1000000000, Id =< 9999999999, !.
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
    receive({
        http_request(AbortRequest, "abort", Id, Fields) ->
            Context = response(Router, _),
            AbortContext = response(Router, AbortRequest),
            request_event("abort", Fields, AbortContext, Abort),
            ( memberchk(browser_abort:true, Fields), Abort = {AbortFields} ->
                reply_to(Context, {[ws_silent:true|AbortFields]})
            ; reply_to(Context, Abort) ),
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
        success(Id, Answers, More) ->
            session_answer(success(Id, Answers, More), Event)
    ;
        failure(Id) ->
            session_answer(failure(Id), Event)
    ;
        error(Id, Error) ->
            session_answer(error(Id, Error), Event)
    ;
        browser_output(Id, Text) ->
            Event = {[type:output, pid:Id, data:Text, stdout:Text, browser_ack:true]}
    ;
        output(Id, Value) ->
            event_text(Value, Text),
            Event = {[type:output, pid:Id, data:Text]}
    ;
        prompt(Id, prompt_ref(Ref, Prompt)) ->
            ( relay_browser_origin(_), \+ text_string(Prompt, _) ->
                browser_term_text(Prompt, Text)
            ; probe_prompt_text(Prompt, Text)
            ),
            Event = {[type:prompt, pid:Id, data:Text, prompt_ref:Ref]}
    ;
        prompt(Id, _) ->
            retire(Id, "HTTP prompts require correlation", Event)
    }, [timeout(Wait), on_timeout(retire(Id, "Query event timed out", Event))]).

session_answer(Answer, {Fields}) :-
    ( session_reply_mode_current(wire(Ref, Target)) ->
        wire_answer(Answer, Qualified, Payload),
        ( Ref == none -> Tagged = Qualified, Correlation = []
        ; Tagged = '$toplevel_reply'(Ref, Qualified),
          probe_term_text(Ref, RefText), Correlation = [toplevel_correlation:RefText] ),
        ( Target == "" -> Routed = []
        ; probe_term_text(Tagged, Message), Routed = [wire_message:Message] ),
        append([wire_target:Target|Payload], Correlation, TaggedFields),
        append(TaggedFields, Routed, Fields)
    ; browser_answer(Answer, Fields) ).

browser_answer(success(Id, Answers, More), [type:success, pid:Id, data:Data, more:More]) :-
    maplist(answer_row, Answers, Data).
browser_answer(failure(Id), [type:failure, pid:Id]).
browser_answer(error(Id, Error), [type:error, pid:Id, data:Text]) :-
    term_string(Error, Text).

wire_answer(success(Id, Answers, More), success(Id@Origin, Answers, More),
            [type:success, pid:Id, data:Data, more:More, term:Term]) :-
    relay_browser_origin(Origin),
    maplist(probe_term_text, Answers, Data),
    probe_term_text(Answers, Term).
wire_answer(failure(Id), failure(Id@Origin), [type:failure, pid:Id]) :-
    relay_browser_origin(Origin).
wire_answer(error(Id, Error), error(Id@Origin, Error), [type:error, pid:Id, data:Term, term:Term]) :-
    relay_browser_origin(Origin),
    probe_term_text(Error, Term).

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
        ( acyclic_term(Value) -> qualify_browser_pids(Value, Origin, Display) ; Display = Value ),
        browser_term_text(Display, Text)
    ; term_string(Value, Text)
    ).

browser_term_text(Term, Text) :-
    setup_call_cleanup(
        open(string(""), write, Stream),
        ( write_term(Stream, Term, [quoted(true), compact(true)]),
          get_stream_info(Stream, name, Text) ),
        close(Stream)).

qualify_browser_pids(Term, _, Term) :- var(Term), !.
qualify_browser_pids(Id, Origin, Id@Origin) :- issued_actor_pid(Id), !.
qualify_browser_pids(Id@Node, _, Id@Node) :- integer(Id), atom(Node), !.
qualify_browser_pids(Term, Origin, Display) :-
    compound(Term), !,
    Term =.. [Name|Args],
    ( foreach(Arg, Args), foreach(Value, Values), param(Origin) do
        qualify_browser_pids(Arg, Origin, Value) ),
    Display =.. [Name|Values].
qualify_browser_pids(Term, _, Term).

retire(Id, Text, {[type:error, pid:Id, retired:true, data:Text]}) :-
    exit(Id, http_session_closed).
