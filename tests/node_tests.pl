:- module(test_node, [
    run_tests/0
]).

:- op(800, xfx, !).

:- use_module('../node.pl').
:- use_module('../node_auth.pl', [
    principal_capabilities/2,
    principal_id/2,
    principal_execution_authorized/1,
    require_admin_access/1,
    request_principal/2,
    set_dev_auth_config/2
]).
:- use_module('../node_profile_policy.pl', [
    profile_check_route/1,
    profile_check_goal/2,
    profile_check_source_text/3
]).
:- use_module('../node_call_context.pl', [parse_call_context/9]).
:- use_module('../node_relation_policy.pl', [relation_check_call/3]).
:- use_module('../node_principal_policy.pl', [normalize_principal_policies/2]).
:- use_module('../node_startup_options.pl', [node_options/24]).
:- use_module('../node_response.pl', [answer_to_json/2]).
:- use_module('../node_sandbox.pl', [
    sandbox_check_goal/2,
    sandbox_check_goal_in_module/3,
    sandbox_check_goal_with_source/4,
    sandbox_check_source_text/3,
    sandbox_check_source_options/3,
    normalize_sandbox_mode/2
]).
:- use_module('../dollar_expansion.pl', [
    expand_dollar_vars/3,
    capture_answer_bindings/1,
    session_bindings/2,
    clear_session_bindings/1
]).
:- use_module('../goal_walker.pl', [walk_goal/2]).
:- use_module('../public_goal_guard.pl', [
    rewrite_goal_if_needed/3,
    rewrite_source_text_if_needed/3
]).
:- use_module('../node_session.pl', [cleanup_isotope_session/1]).
:- use_module('../node_runtime_state.pl', [
    register_node_runtime/2,
    with_node_port_context/2,
    current_node_value/2
]).
:- use_module('../node_execution_context.pl', [with_public_execution_profile/2]).
:- use_module('../toplevel_actor.pl', [toplevel_spawn/2, toplevel_call/3, toplevel_next/1]).
:- use_module('../actor.pl', [spawn/3, receive/2, send/2, exit/2, demonitor/1, self/1, self_node_url/1, op(200, xfx, @)]).
:- use_module('../pid_utils.pl', [pid_local/2]).
:- use_module('../statechart_actor.pl', [statechart_spawn/2]).
:- use_module('../examples/services/node_resident_services.pl', [
    service_directory_file/1,
    start_counter_service/1,
    start_pubsub_service/1,
    stop_example_services/0
]).

:- use_module(library(plunit), [run_tests/1]).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/json)).
:- use_module(library(http/websocket)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(modules)).
:- use_module(library(readutil), [read_file_to_string/3]).
:- use_module(library(settings)).
:- use_module(library(socket)).
:- use_module(library(url)).

run_tests :-
    run_tests([node]).

:- meta_predicate with_node_server(-, 0).
:- meta_predicate with_node_server_options(+, -, 0).
:- meta_predicate with_sandbox_mode(+, 0).
:- meta_predicate with_auth_mode(+, 0).
:- meta_predicate with_dev_auth_config(+, +, 0).
:- meta_predicate with_http_public_url(+, +, +, 0).

:- dynamic walked_goal/1.

with_node_server(URI, Goal) :-
    with_node_server_options([], URI, Goal).

with_node_server_options(NodeOptions, URI, Goal) :-
    start_node_server(NodeOptions, Port, URI),
    setup_call_cleanup(
        true,
        Goal,
        stop_node_server(Port)
    ).

with_sandbox_mode(Mode, Goal) :-
    setting(node:sandbox, OldMode),
    setup_call_cleanup(
        set_setting(node:sandbox, Mode),
        Goal,
        set_setting(node:sandbox, OldMode)
    ).

with_auth_mode(Mode, Goal) :-
    setting(node_auth:auth, OldMode),
    setup_call_cleanup(
        set_setting(node_auth:auth, Mode),
        Goal,
        set_setting(node_auth:auth, OldMode)
    ).

with_dev_auth_config(PrincipalId, Capabilities, Goal) :-
    current_dev_auth_config(OldPrincipalId, OldCapabilities),
    setup_call_cleanup(
        set_dev_auth_config(PrincipalId, Capabilities),
        Goal,
        set_dev_auth_config(OldPrincipalId, OldCapabilities)
    ).

with_http_public_url(Host, Port, Scheme, Goal) :-
    setting(http:public_host, OldHost),
    setting(http:public_port, OldPort),
    setting(http:public_scheme, OldScheme),
    setup_call_cleanup(
        (
            set_setting(http:public_host, Host),
            set_setting(http:public_port, Port),
            set_setting(http:public_scheme, Scheme)
        ),
        Goal,
        (
            set_setting(http:public_host, OldHost),
            set_setting(http:public_port, OldPort),
            set_setting(http:public_scheme, OldScheme)
        )
    ).

start_node_server(NodeOptions, Port, URI) :-
    between(1, 20, _),
    pick_free_port(Port0),
    catch(node(Port0, NodeOptions), _, fail),
    !,
    Port = Port0,
    format(atom(URI), 'http://localhost:~w', [Port]).
start_node_server(_, _, _) :-
    throw(error(resource_error(socket),
                context(start_node_server/3, 'unable to start node server'))).

pick_free_port(Port) :-
    tcp_socket(Socket),
    tcp_bind(Socket, Port),
    tcp_close_socket(Socket).

stop_node_server(Port) :-
    catch(http_stop_server(Port, []), _, true),
    cleanup_test_shared_db_side_effects,
    sleep(0.02).

current_dev_auth_config(PrincipalId, Capabilities) :-
    node_auth:dev_auth_config(PrincipalId, Capabilities),
    !.
current_dev_auth_config("dev", [admin]).

record_walked_goal(Goal) :-
    assertz(walked_goal(Goal)).

test_execution_principal(Id, principal{
    id:Id,
    capabilities:[execute],
    unknown:false
}).

cleanup_test_shared_db_side_effects :-
    catch(stop_example_services, _, true).

next_test_ref(Ref) :-
    flag(node_test_ref, Ref0, Ref0 + 1),
    Ref = test_ref(Ref0).

pid_list_value(Value0, Value) :-
    is_list(Value0),
    !,
    Value = Value0.
pid_list_value(Value0, Value) :-
    pid_text_value(Value0, Atom),
    !,
    read_term_from_atom(Atom, Value, [module(test_node)]).

pid_value(Value0, Value) :-
    integer(Value0),
    !,
    Value = Value0.
pid_value(Value0, Value) :-
    pid_text_value(Value0, Atom),
    !,
    read_term_from_atom(Atom, Value, [module(test_node)]).

pid_text_value(Value0, Atom) :-
    (   string(Value0)
    ->  Atom = Value0
    ;   atom(Value0)
    ->  Atom = Value0
    ).

kill_isotope_session(Pid) :-
    catch(actor:exit(Pid, kill), _, true),
    catch(cleanup_isotope_session(Pid), _, true).

await_actor_output(Pid, Data, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_actor_output_until(Pid, Data, Deadline).

await_actor_output_until(Pid, Data, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        output(Pid, Data) -> true;
        terminal_output(Pid, Data) -> true;
        output(_, _) -> test_node:await_actor_output_until(Pid, Data, Deadline);
        terminal_output(_, _) -> test_node:await_actor_output_until(Pid, Data, Deadline)
    }, [
        timeout(Remaining),
        on_timeout(fail)
    ]).

refute_actor_output(Pid, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    refute_actor_output_until(Pid, Deadline).

refute_actor_output_until(Pid, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        output(Pid, _) -> fail;
        terminal_output(Pid, _) -> fail;
        _ -> test_node:refute_actor_output_until(Pid, Deadline)
    }, [
        timeout(Remaining),
        on_timeout(true)
    ]).

counter_service_bump(NodeURL, Parent) :-
    self(Self),
    send(counter@NodeURL, count(Self)),
    receive({
        count(_) ->
            send(Parent, counter_bumped)
    }, [
        timeout(1),
        on_timeout(send(Parent, counter_bumped(timeout)))
    ]).

pubsub_service_subscriber(NodeURL, Parent, Ref) :-
    self(Self),
    send(pubsub_service@NodeURL, subscribe(Self)),
    send(Parent, subscribed(Ref, Self)),
    receive({
        msg(Message) ->
            send(Parent, delivered(Ref, Self, Message))
    }, [
        timeout(1),
        on_timeout(send(Parent, delivered(Ref, Self, timeout)))
    ]).

test(expand_dollar_vars_expands_top_level_code,
     true(Text == "123 ! hello")) :-
    expand_dollar_vars("$Pid ! hello", ['Pid'-123], Text).

test(expand_dollar_vars_leaves_quoted_xml_comment_text_unchanged,
     true(Text == "statechart_spawn(Pid, [load_text(\"<!-- $Pid -->\\n<statechart/>\")])")) :-
    expand_dollar_vars("statechart_spawn(Pid, [load_text(\"<!-- $Pid -->\n<statechart/>\")])",
                       ['Pid'-123],
                       Text).

test(expand_dollar_vars_leaves_prolog_comments_unchanged,
     true(Text == "% $Pid in comment\n123")) :-
    expand_dollar_vars("% $Pid in comment\n$Pid", ['Pid'-123], Text).

test(capture_answer_bindings_does_not_mutate_current_solution,
     [setup(clear_session_bindings(test_session)),
      cleanup(clear_session_bindings(test_session)),
      true(var(Head))]) :-
    capture_answer_bindings(success(test_session, [json{'Y':[a|_]}], true)),
    Answer = success(test_session, [json{'Y':[Head,a|_Tail]}], true),
    capture_answer_bindings(Answer).

test(capture_answer_bindings_updates_shared_prior_bindings,
     [setup(clear_session_bindings(test_session)),
      cleanup(clear_session_bindings(test_session)),
      true(XValue = f(a,b))]) :-
    B = _,
    capture_answer_bindings(success(test_session, [json{'X':f(a,B), 'B':B}], false)),
    capture_answer_bindings(success(test_session, [json{'B':b}], false)),
    session_bindings(test_session, Pairs),
    memberchk('X'-XValue, Pairs).

read_answer(URL, Answer) :-
    setup_call_cleanup(
        http_open(URL, Stream, []),
        read(Stream, Answer),
        close(Stream)
    ).

read_json_answer(URL, JSON) :-
    setup_call_cleanup(
        http_open(URL, Stream, [request_header('Accept'='application/json')]),
        json_read_dict(Stream, JSON),
        close(Stream)
    ).

read_json_answer_headers(URL, Headers, JSON) :-
    request_header_options(Headers, HeaderOptions),
    append(HeaderOptions,
           [request_header('Accept'='application/json')],
           HTTPOptions),
    setup_call_cleanup(
        http_open(URL, Stream, HTTPOptions),
        json_read_dict(Stream, JSON),
        close(Stream)
    ).

read_json_status(URL, Status, JSON) :-
    setup_call_cleanup(
        http_open(URL, Stream, [
            status_code(Status),
            request_header('Accept'='application/json')
        ]),
        json_read_dict(Stream, JSON),
        close(Stream)
    ).

read_json_status_headers(URL, Headers, Status, JSON) :-
    request_header_options(Headers, HeaderOptions),
    append(HeaderOptions,
           [status_code(Status), request_header('Accept'='application/json')],
           HTTPOptions),
    setup_call_cleanup(
        http_open(URL, Stream, HTTPOptions),
        json_read_dict(Stream, JSON),
        close(Stream)
    ).

read_json_post(URL, Body, JSON) :-
    http_post(URL, json(Body), JSON, [json_object(dict)]).

read_json_post_headers(URL, Headers, Body, JSON) :-
    request_header_options(Headers, HeaderOptions),
    http_post(URL, json(Body), JSON, [json_object(dict)|HeaderOptions]).

read_json_post_status_headers(URL, Headers, Body, Status, JSON) :-
    request_header_options(Headers, HeaderOptions),
    http_post(URL, json(Body), JSON,
              [json_object(dict), status_code(Status)|HeaderOptions]).

read_json_post_string_status_headers(URL, Headers, BodyText, Status, JSON) :-
    request_header_options(Headers, HeaderOptions),
    append(HeaderOptions,
           [ method(post),
             post(string('application/json', BodyText)),
             status_code(Status),
             request_header('Accept'='application/json')
           ],
           HTTPOptions),
    setup_call_cleanup(
        http_open(URL, Stream, HTTPOptions),
        json_read_dict(Stream, JSON),
        close(Stream)
    ).

read_text(URL, Text) :-
    setup_call_cleanup(
        http_open(URL, Stream, []),
        read_string(Stream, _, Text),
        close(Stream)
    ).

read_bytes(URL, Count, Bytes) :-
    setup_call_cleanup(
        http_open(URL, Stream, []),
        read_n_bytes(Stream, Count, Bytes),
        close(Stream)
    ).

read_n_bytes(_, Count, []) :-
    Count =< 0,
    !.
read_n_bytes(Stream, Count, Bytes) :-
    get_byte(Stream, Byte),
    (   Byte == -1
    ->  Bytes = []
    ;   Bytes = [Byte|Rest],
        Count1 is Count - 1,
        read_n_bytes(Stream, Count1, Rest)
    ).

repeated_string(Code, Count, Text) :-
    must_be(integer, Code),
    must_be(integer, Count),
    length(Codes, Count),
    maplist(=(Code), Codes),
    string_codes(Text, Codes).

ws_open(BaseURI, WebSocket) :-
    atom_concat(BaseURI, '/ws', WsURI),
    http_open_websocket(WsURI, WebSocket, []).

ws_open_headers(BaseURI, Headers, WebSocket) :-
    atom_concat(BaseURI, '/ws', WsURI),
    request_header_options(Headers, HeaderOptions),
    http_open_websocket(WsURI, WebSocket, HeaderOptions).

ws_send_json(WebSocket, Dict) :-
    atom_json_dict(Text, Dict, []),
    ws_send(WebSocket, text(Text)).

ws_receive_json(WebSocket, Dict) :-
    ws_receive(WebSocket, Frame, []),
    atom_json_dict(Frame.data, Dict, []).

ws_receive_json_until_expected_types(WebSocket, ExpectedTypes, Replies) :-
    ws_receive_json_until_expected_types(WebSocket, ExpectedTypes, [], 30, Replies).

ws_receive_json_until_expected_types(_, [], Replies0, _, Replies) :-
    !,
    reverse(Replies0, Replies).
ws_receive_json_until_expected_types(_, _, _, Attempts, _) :-
    Attempts =< 0,
    !,
    fail.
ws_receive_json_until_expected_types(WebSocket, ExpectedTypes0, Replies0, Attempts, Replies) :-
    ws_receive(WebSocket, Frame, [timeout(1)]),
    atom_json_dict(Frame.data, Dict, []),
    RemainingAttempts is Attempts - 1,
    (   get_dict(type, Dict, Type),
        select(Type, ExpectedTypes0, ExpectedTypes)
    ->  ws_receive_json_until_expected_types(WebSocket, ExpectedTypes,
                                             [Dict|Replies0],
                                             RemainingAttempts, Replies)
    ;   ws_receive_json_until_expected_types(WebSocket, ExpectedTypes0,
                                             Replies0,
                                             RemainingAttempts, Replies)
    ).

ws_flush_until_output(WebSocket, ToplevelPid, OutputData, FinalType) :-
    ws_flush_until_output(WebSocket, ToplevelPid, 50, OutputData, FinalType).

ws_flush_until_output(_, _, Attempts, _, _) :-
    Attempts =< 0,
    !,
    fail.
ws_flush_until_output(WebSocket, ToplevelPid, Attempts, OutputData, FinalType) :-
    ws_send_json(WebSocket, json{
        command:toplevel_call,
        pid:ToplevelPid,
        goal:"flush",
        template:"flush"
    }),
    ws_receive_json(WebSocket, Reply),
    (   get_dict(type, Reply, "output")
    ->  get_dict(data, Reply, OutputData),
        ws_receive_json(WebSocket, FinalReply),
        get_dict(type, FinalReply, FinalType)
    ;   sleep(0.02),
        Remaining is Attempts - 1,
        ws_flush_until_output(WebSocket, ToplevelPid, Remaining, OutputData, FinalType)
    ).

json_call_url(BaseURI, GoalAtom, Offset, Limit, URL) :-
    parse_url(BaseURI, Parts),
    parse_url(URL, [
        path('/call'),
        search([goal=GoalAtom, offset=Offset, limit=Limit])
      | Parts
    ]).

isotope_call_url(BaseURI, Pid, GoalAtom, LoadText, URL) :-
    parse_url(BaseURI, Parts),
    Search0 = [pid=Pid, goal=GoalAtom, format=json],
    (   LoadText == ''
    ->  Search = Search0
    ;   append(Search0, [load_text=LoadText], Search)
    ),
    parse_url(URL, [
        path('/toplevel_call'),
        search(Search)
      | Parts
    ]).

call_url(BaseURI, GoalAtom, TemplateAtom, Offset, Limit, LoadText, Timeout, URL) :-
    call_url(BaseURI, GoalAtom, TemplateAtom, Offset, Limit, LoadText, Timeout,
             false, URL).

call_url(BaseURI, GoalAtom, TemplateAtom, Offset, Limit, LoadText, Timeout, Once, URL) :-
    parse_url(BaseURI, Parts),
    Search0 = [goal=GoalAtom, template=TemplateAtom,
               offset=Offset, limit=Limit, format=prolog],
    (   LoadText == ''
    ->  Search = Search0
    ;   append(Search0, [load_text=LoadText], Search)
    ),
    (   Timeout == none
    ->  Search2 = Search
    ;   append(Search, [timeout=Timeout], Search2)
    ),
    (   Once == false
    ->  Search3 = Search2
    ;   append(Search2, [once=Once], Search3)
    ),
    parse_url(URL, [path('/call'), search(Search3)|Parts]).

json_call_url_with_load_text(BaseURI, GoalAtom, LoadText, URL) :-
    parse_url(BaseURI, Parts),
    parse_url(URL, [
        path('/call'),
        search([goal=GoalAtom, offset=0, limit=1, load_text=LoadText])
      | Parts
    ]).

admin_config_url(BaseURI, URL) :-
    format(atom(URL), '~w/admin/config', [BaseURI]).

builtin_family_profile_value(Families, Id, Profile, Value) :-
    once((
        member(Family, Families),
        Family.get(id) == Id
    )),
    Profiles = Family.get(profiles),
    Value = Profiles.get(Profile).

builtin_family_default_profile_value(Families, Id, Profile, Value) :-
    once((
        member(Family, Families),
        Family.get(id) == Id
    )),
    Profiles = Family.get(default_profiles),
    Value = Profiles.get(Profile).

admin_principals_url(BaseURI, URL) :-
    format(atom(URL), '~w/admin/principals', [BaseURI]).

admin_runtime_url(BaseURI, URL) :-
    format(atom(URL), '~w/admin/runtime', [BaseURI]).

admin_reclaim_url(BaseURI, URL) :-
    format(atom(URL), '~w/admin/reclaim', [BaseURI]).

request_header_options([], []).
request_header_options([Name=Value|Headers], [request_header(Name=Value)|Options]) :-
    request_header_options(Headers, Options).

principal_headers(User, ['X-Web-Prolog-User'=User]).

alice_execute_principal_option(
    principal("alice", [
        execute
    ])
).

% Historical aliases kept to avoid churning test call sites after the
% principal-relative profile model was removed.
alice_full_principal_option(Policy) :-
    alice_execute_principal_option(Policy).

alice_isotope_principal_option(Policy) :-
    alice_execute_principal_option(Policy).

alice_stateless_principal_option(Policy) :-
    alice_execute_principal_option(Policy).

bob_session_user_option(
    principal("bob", [
        execute
    ])
).

with_node_timeout(Timeout, Goal) :-
    setting(node:timeout, OldTimeout),
    setup_call_cleanup(
        set_setting(node:timeout, Timeout),
        Goal,
        set_setting(node:timeout, OldTimeout)
    ).

with_node_cache_size(Size, Goal) :-
    setting(node:cache_size, OldSize),
    setup_call_cleanup(
        set_setting(node:cache_size, Size),
        Goal,
        set_setting(node:cache_size, OldSize)
    ).

clear_node_cache :-
    forall(retract(node:cache(_, _, Pid)),
           clear_cached_pid(Pid)).

clear_cached_pid(Pid) :-
    % Cache cleanup in the suite should be best-effort and local-only. In a
    % long full run the cache can still contain canonical pids from nodes that
    % have already been shut down, and routing actor:exit/2 through the remote
    % transport path here can block on dead nodes. If a cached pid still
    % resolves to a live local thread, stop it directly; otherwise just drop
    % the cache entry.
    (   actor:resolve_thread(Pid, ThreadId)
    ->  catch(thread_signal(ThreadId, exit(kill)), _, true)
    ;   true
    ).

pid_stopped(Pid) :-
    (   Pid = LocalPid@_,
        integer(LocalPid)
    ->  \+ actor:pid_thread(LocalPid, _)
    ;   pid_local(Pid, LocalPid)
    ->  \+ actor:pid_thread(LocalPid, _)
    ;   true
    ).

wait_until_pid_stopped(Pid, Attempts) :-
    (   Attempts =< 0
    ->  pid_stopped(Pid)
    ;   pid_stopped(Pid)
    ->  true
    ;   sleep(0.01),
        Remaining is Attempts - 1,
        wait_until_pid_stopped(Pid, Remaining)
    ).

rp(left).
rp(right).

:- begin_tests(node).

test(node_1_starts_http_endpoint, true(Answer == success([true], false))) :-
    with_node_server(URI,
        (
            format(atom(URL),
                   '~w/call?goal=true&template=true&offset=0&limit=1&format=prolog',
                   [URI]),
            read_answer(URL, Answer)
        )).

test(node_tutorial_and_image_routes_served,
     true((sub_string(TutorialBody, _, _, _, '<title>Web Prolog Tutorial</title>'),
           sub_string(TutorialBody, _, _, _, 'id="tutorial-local-actor-programming"'),
           sub_string(TutorialBody, _, _, _, 'id="tutorial-distributed-actor-programming"'),
           sub_string(TutorialBody, _, _, _, 'Local ACTOR programming'),
           sub_string(TutorialBody, _, _, _, 'Distributed ACTOR programming'),
           Bytes == [137,80,78,71,13,10,26,10]))) :-
    with_node_server(URI,
        (
            format(atom(TutorialURL), '~w/tutorial', [URI]),
            read_text(TutorialURL, TutorialBody),
            format(atom(ImageURL), '~w/img/an-actor.png', [URI]),
            read_bytes(ImageURL, 8, Bytes)
        )).

test(node_portal_and_example_routes_served) :-
    with_node_server(URI,
        (
            format(atom(PortalURL), '~w/portal', [URI]),
            read_text(PortalURL, PortalBody),
            format(atom(EditorFrameURL), '~w/editor_frame?id=editor&mode=prolog', [URI]),
            read_text(EditorFrameURL, EditorFrameBody),
            format(atom(ActorExampleURL), '~w/examples/actors/04%20count_actor.pl', [URI]),
            read_text(ActorExampleURL, ActorExampleBody),
            format(atom(ServiceExampleURL), '~w/examples/services/node_resident_services.pl', [URI]),
            read_text(ServiceExampleURL, ServiceExampleBody),
            format(atom(StatechartURL), '~w/statecharts/game.xml', [URI]),
            read_text(StatechartURL, StatechartBody),
            format(atom(ExamplesIndexURL), '~w/examples_index', [URI]),
            read_json_answer(ExamplesIndexURL, ExamplesIndexJSON),
            ActorEntries = ExamplesIndexJSON.actors,
            StatechartEntries = ExamplesIndexJSON.statecharts,
            assertion(sub_string(PortalBody, _, _, _, 'Your portal to the Prolog Web')),
            assertion(sub_string(PortalBody, _, _, _, 'Don''t show this again.')),
            assertion(sub_string(PortalBody, _, _, _, 'Book manuscript')),
            assertion(sub_string(PortalBody, _, _, _, 'https://trinity.elfenbenstornet.se/book.html')),
            assertion(sub_string(PortalBody, _, _, _, '<div class="settings-title">Font</div>')),
            assertion(sub_string(PortalBody, _, _, _, '<div class="settings-title">Display</div>')),
            assertion(sub_string(PortalBody, _, _, _, '<div class="settings-title">Terminal</div>')),
            assertion(sub_string(PortalBody, _, _, _, 'Show welcome message')),
            assertion(sub_string(PortalBody, _, _, _, 'Hide local node in pid')),
            assertion(sub_string(PortalBody, _, _, _, 'Extra newline after query')),
            assertion(sub_string(PortalBody, _, _, _, 'Code coloring')),
            assertion(sub_string(PortalBody, _, _, _, 'Statechart XML')),
            assertion(sub_string(EditorFrameBody, _, _, _, 'Workbench Editor Frame')),
            assertion(sub_string(ActorExampleBody, _, _, _, 'count_actor')),
            assertion(sub_string(ServiceExampleBody, _, _, _, 'pubsub_actor')),
            assertion(sub_string(StatechartBody, _, _, _, '<statechart')),
            memberchk(_{name:"04 count_actor.pl", url:"/examples/actors/04 count_actor.pl", kind:"prolog"},
                      ActorEntries),
            assertion(\+ memberchk(_{name:"game.xml", url:"/examples/statecharts/game.xml", kind:"statechart"},
                                   StatechartEntries)),
            assertion(sub_string(PortalBody, _, _, _, 'Local ACTOR programming'))
        )).

test(node_admin_page_served,
     true((sub_string(AdminBody, _, _, _, '<title>Web Prolog Admin</title>'),
           sub_string(AdminBody, _, _, _, 'value="whitelist"'),
           sub_string(AdminBody, _, _, _, 'value="blacklist"')))) :-
    with_node_server(URI,
        (
            format(atom(AdminURL), '~w/admin', [URI]),
            read_text(AdminURL, AdminBody)
        )).

test(node_manual_page_served,
     true((sub_string(ManualBody, _, _, _, '<title>Web Prolog Manual</title>'),
           sub_string(ManualBody, _, _, _, 'id="spawn/1-3"'),
           sub_string(ManualBody, _, _, _, 'id="rpc/2-3"')))) :-
    with_node_server(URI,
        (
            format(atom(ManualURL), '~w/manual', [URI]),
            read_text(ManualURL, ManualBody)
        )).

test(node_admin_and_portal_pages_include_manual_predicate_link_support) :-
    module_property(node, file(NodeFile)),
    file_directory_name(NodeFile, Dir),
    directory_file_path(Dir, 'admin.html', AdminFile),
    directory_file_path(Dir, 'workbench.html', WorkbenchFile),
    read_file_to_string(AdminFile, AdminBody, []),
    read_file_to_string(WorkbenchFile, WorkbenchBody, []),
    once((
        sub_string(AdminBody, _, _, _, 'manualEntryHref(predicateName)'),
        sub_string(AdminBody, _, _, _, 'web-prolog-manual'),
        sub_string(AdminBody, _, _, _, 'renderPredicateIndicator(predicateName)'),
        sub_string(WorkbenchBody, _, _, _, 'adminBuiltinManualHref(predicateName)'),
        sub_string(WorkbenchBody, _, _, _, 'web-prolog-manual')
    )).

test(node_admin_and_portal_pages_include_config_help_controls,
     true((sub_string(AdminBody, _, _, _, 'data-help-id="profile"'),
           sub_string(AdminBody, _, _, _, 'data-help-id="max_ws_commands_per_window"'),
           sub_string(PortalBody, _, _, _, 'aria-label="Help for Profile"'),
           sub_string(PortalBody, _, _, _, "adminConfigHelpText('max_ws_commands_per_window')")))) :-
    with_node_server(URI,
        (
            format(atom(AdminURL), '~w/admin', [URI]),
            read_text(AdminURL, AdminBody),
            format(atom(PortalURL), '~w/portal', [URI]),
            read_text(PortalURL, PortalBody)
        )).

test(node_info_route_serves_self_url,
     true((sub_atom(SelfURL, 0, 7, _, 'http://'),
           Profile == "actor",
           SelfPort == URIPort))) :-
    with_node_server(URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            SelfURL = JSON.get(self_url),
            Profile = JSON.get(profile),
            uri_components(URI, URIComponents),
            uri_data(authority, URIComponents, URIAuthority),
            uri_authority_components(URIAuthority, URIAuthComponents),
            uri_authority_data(port, URIAuthComponents, URIPort),
            uri_components(SelfURL, SelfComponents),
            uri_data(authority, SelfComponents, SelfAuthority),
            uri_authority_components(SelfAuthority, SelfAuthComponents),
            uri_authority_data(port, SelfAuthComponents, SelfPort)
        )).

test(node_info_route_announces_configured_profile,
     true(Profile == "isobase")) :-
    with_node_server_options([profile(isobase)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            Profile = JSON.get(profile)
        )).

test(node_info_route_announces_configured_auth_mode,
     true(Auth == "private")) :-
    with_node_server_options([auth(private)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            Auth = JSON.get(auth)
        )).

test(node_info_route_announces_trusted_header_boundary,
     true((AuthBoundary == "trusted_headers",
           memberchk("X-Web-Prolog-User", IdentityHeaders),
           memberchk("X-Web-Prolog-Capabilities", CapabilityHeaders),
           Prefix == "node:"))) :-
    with_node_server_options([auth(private)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            AuthBoundary = JSON.get(auth_boundary),
            IdentityHeaders = JSON.get(trusted_identity_headers),
            CapabilityHeaders = JSON.get(trusted_capability_headers),
            Prefix = JSON.get(internal_transport_principal_prefix)
        )).

test(node_info_route_announces_configured_dev_auth_mode,
     true(Auth == "dev")) :-
    with_node_server_options([auth(dev)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            Auth = JSON.get(auth)
        )).

test(node_info_route_announces_dev_principal_execution_access,
     true((PrincipalId == "dev-isotope",
           PrincipalExecution == true))) :-
    with_node_server_options(
        [auth(dev), dev_principal("dev-isotope"), dev_capabilities([execute])],
        URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            PrincipalId = JSON.get(principal_id),
            PrincipalExecution = JSON.get(principal_execution)
        )).

test(node_info_route_announces_authenticated_principal_execution_access,
     true((PrincipalId == "alice",
           PrincipalExecution == true))) :-
    alice_isotope_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            principal_headers("alice", Headers),
            read_json_answer_headers(NodeInfoURL, Headers, JSON),
            PrincipalId = JSON.get(principal_id),
            PrincipalExecution = JSON.get(principal_execution)
        )).

test(node_info_route_announces_owner_principal_execution_access,
     true((PrincipalId == "owner",
           PrincipalExecution == true))) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            principal_headers("owner", Headers),
            read_json_answer_headers(NodeInfoURL, Headers, JSON),
            PrincipalId = JSON.get(principal_id),
            PrincipalExecution = JSON.get(principal_execution)
        )).

test(node_info_route_marks_anonymous_private_principal_nonexecutable,
     true((PrincipalId == "anonymous",
           PrincipalExecution == false))) :-
    with_node_server_options([auth(private)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, JSON),
            PrincipalId = JSON.get(principal_id),
            PrincipalExecution = JSON.get(principal_execution)
        )).

test(node_info_route_uses_per_node_profile_when_two_nodes_run,
     true((Profile1 == "isobase", Profile2 == "actor"))) :-
    with_node_server_options([profile(isobase)], URI1,
        with_node_server_options([profile(actor)], URI2,
            (
                format(atom(NodeInfoURL1), '~w/node_info', [URI1]),
                format(atom(NodeInfoURL2), '~w/node_info', [URI2]),
                read_json_answer(NodeInfoURL1, JSON1),
                read_json_answer(NodeInfoURL2, JSON2),
                Profile1 = JSON1.get(profile),
                Profile2 = JSON2.get(profile)
            ))).

test(node_root_uses_per_node_shared_db_when_two_nodes_run,
     true((Source1 == "p(a).\n", Source2 == "p(b).\n"))) :-
    with_node_server_options([load_shared_db_text("p(a).\n")], URI1,
        with_node_server_options([load_shared_db_text("p(b).\n")], URI2,
            (
                read_text(URI1, Source1),
                read_text(URI2, Source2)
            ))).

test(auth_mode_is_isolated_per_node,
     true((PrivateType == "error",
           sub_string(PrivateData, _, _, _, "Authentication required"),
           OpenType == "success"))) :-
    with_node_server_options([auth(private)], URI1,
        with_node_server_options([auth(open)], URI2,
            (
                json_call_url(URI1, 'member(X,[a])', 0, 1, PrivateURL),
                read_json_answer(PrivateURL, PrivateJSON),
                PrivateType = PrivateJSON.get(type),
                PrivateData = PrivateJSON.get(data),

                json_call_url(URI2, 'member(X,[a])', 0, 1, OpenURL),
                read_json_answer(OpenURL, OpenJSON),
                OpenType = OpenJSON.get(type)
            ))).

test(principal_policy_is_isolated_per_node,
     true((AllowedType == "success",
           DeniedType == "error",
           sub_string(DeniedData, _, _, _, "unknown principal")))) :-
    alice_stateless_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI1,
        with_node_server_options([auth(private)], URI2,
            (
                principal_headers("alice", Headers),

                json_call_url(URI1, 'member(X,[a])', 0, 1, AllowedURL),
                read_json_answer_headers(AllowedURL, Headers, AllowedJSON),
                AllowedType = AllowedJSON.get(type),

                json_call_url(URI2, 'member(X,[a])', 0, 1, DeniedURL),
                read_json_answer_headers(DeniedURL, Headers, DeniedJSON),
                DeniedType = DeniedJSON.get(type),
                DeniedData = DeniedJSON.get(data)
            ))).

test(admin_config_requires_admin_capability,
     true((Status == 403,
           Type == "error",
           sub_string(Data, _, _, _, "Not authorized")))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI,
        (
            admin_config_url(URI, URL),
            principal_headers("alice", Headers),
            read_json_status_headers(URL, Headers, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(admin_config_open_local_anonymous_updates_actor_builtin_family,
     true((PrincipalId == "anonymous",
           PrincipalExecution == true,
           UpdatedActorDynamic == false,
           DownType == "down",
           DownPid == Pid,
           DownReason == "runtime_config_changed",
           RespawnType == "spawned",
           ReplyType == "error",
           sub_string(ReplyData, _, _, _, "Unknown procedure: assert/1")))) :-
    with_node_server_options([auth(open), profile(actor)], URI,
        (
            format(atom(NodeInfoURL), '~w/node_info', [URI]),
            read_json_answer(NodeInfoURL, NodeInfoJSON),
            PrincipalId = NodeInfoJSON.get(principal_id),
            PrincipalExecution = NodeInfoJSON.get(principal_execution),

            admin_config_url(URI, ConfigURL),
            setup_call_cleanup(
                ws_open(URI, WS),
                (
                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Spawned),
                    get_dict(type, Spawned, "spawned"),
                    get_dict(pid, Spawned, Pid),

                    read_json_post(
                        ConfigURL,
                        json{
                            builtin_families:[
                                json{
                                    id:"dynamic_db",
                                    profiles:json{actor:false}
                                }
                            ]
                        },
                        UpdatedJSON
                    ),
                    UpdatedFamilies = UpdatedJSON.get(builtin_families),
                    builtin_family_profile_value(UpdatedFamilies, "dynamic_db",
                                                 actor, UpdatedActorDynamic),

                    ws_receive_json(WS, Down),
                    DownType = Down.type,
                    DownPid = Down.pid,
                    DownReason = Down.reason,

                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Respawned),
                    RespawnType = Respawned.type,
                    get_dict(pid, Respawned, NewPid),

                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:NewPid,
                        goal:"assert(a)",
                        template:"true"
                    }),
                    ws_receive_json(WS, Reply),
                    ReplyType = Reply.type,
                    ReplyData = Reply.data
                ),
                catch(ws_close(WS, 1000, done), _, true)
            )
        )).

test(admin_config_updates_only_target_node,
     true((UpdatedProfile == "isobase",
           UpdatedSandbox == "whitelist",
           OtherProfile == "actor"))) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI1,
        with_node_server_options([auth(private), owner("owner"), profile(actor)], URI2,
            (
                principal_headers("owner", Headers),
                admin_config_url(URI1, ConfigURL1),
                read_json_post_headers(ConfigURL1, Headers,
                                       json{profile:"isobase", sandbox:"whitelist"},
                                       UpdatedJSON),
                UpdatedProfile = UpdatedJSON.get(profile),
                UpdatedSandbox = UpdatedJSON.get(sandbox),

                format(atom(NodeInfoURL2), '~w/node_info', [URI2]),
                read_json_answer_headers(NodeInfoURL2, Headers, OtherJSON),
                OtherProfile = OtherJSON.get(profile)
            ))).

test(admin_config_reports_blacklist_as_default_sandbox,
     true(Sandbox == "blacklist")) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_answer_headers(ConfigURL, Headers, JSON),
            Sandbox = JSON.get(sandbox)
        )).

test(admin_config_normalizes_legacy_sandbox_alias_to_whitelist,
     true(Sandbox == "whitelist")) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_post_headers(ConfigURL, Headers, json{sandbox:"on"}, UpdatedJSON),
            Sandbox = UpdatedJSON.get(sandbox)
        )).

test(admin_config_updates_builtin_families_only_target_node,
     true((UpdatedActorNaming == false,
           UpdatedRPCIsobase == true,
           OtherActorNaming == true))) :-
    with_node_server_options([auth(private), owner("owner")], URI1,
        with_node_server_options([auth(private), owner("owner")], URI2,
            (
                principal_headers("owner", Headers),
                admin_config_url(URI1, ConfigURL1),
                read_json_post_headers(
                    ConfigURL1,
                    Headers,
                    json{
                        builtin_families:[
                            json{
                                id:"actor_naming",
                                profiles:json{actor:false}
                            }
                        ]
                    },
                    UpdatedJSON
                ),
                UpdatedFamilies = UpdatedJSON.get(builtin_families),
                builtin_family_profile_value(UpdatedFamilies, "actor_naming",
                                             actor, UpdatedActorNaming),
                builtin_family_profile_value(UpdatedFamilies, "rpc",
                                             isobase, UpdatedRPCIsobase),

                admin_config_url(URI2, ConfigURL2),
                read_json_answer_headers(ConfigURL2, Headers, OtherJSON),
                OtherFamilies = OtherJSON.get(builtin_families),
                builtin_family_profile_value(OtherFamilies, "actor_naming",
                                             actor, OtherActorNaming)
            ))).

test(admin_config_includes_private_and_dynamic_db_families,
     true((PrivateDBRelation == false,
           PrivateDBIsobase == true,
           DefaultPrivateDBRelation == false,
           DefaultPrivateDBIsobase == true,
           DefaultDynamicDBRelation == false,
           DynamicDBIsotope == true,
           DynamicDBActor == true,
           DefaultDynamicDBActor == true))) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_answer_headers(ConfigURL, Headers, ConfigJSON),
            Families = ConfigJSON.get(builtin_families),
            builtin_family_profile_value(Families, "private_db",
                                         relation, PrivateDBRelation),
            builtin_family_profile_value(Families, "private_db",
                                         isobase, PrivateDBIsobase),
            builtin_family_default_profile_value(Families, "private_db",
                                                 relation, DefaultPrivateDBRelation),
            builtin_family_default_profile_value(Families, "private_db",
                                                 isobase, DefaultPrivateDBIsobase),
            builtin_family_default_profile_value(Families, "dynamic_db",
                                                 relation, DefaultDynamicDBRelation),
            builtin_family_profile_value(Families, "dynamic_db",
                                         isotope, DynamicDBIsotope),
            builtin_family_profile_value(Families, "dynamic_db",
                                         actor, DynamicDBActor),
            builtin_family_default_profile_value(Families, "dynamic_db",
                                                 actor, DefaultDynamicDBActor)
        )).

test(admin_config_includes_web_api_families,
     true((StatelessRelation == true,
           StatelessActor == true,
           DefaultStatelessActor == true,
           SemiStatefulRelation == false,
           SemiStatefulIsotope == true,
           DefaultSemiStatefulActor == true,
           StatefulIsotope == false,
           StatefulActor == true,
           DefaultStatefulActor == true))) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_answer_headers(ConfigURL, Headers, ConfigJSON),
            Families = ConfigJSON.get(builtin_families),
            builtin_family_profile_value(Families, "stateless_api",
                                         relation, StatelessRelation),
            builtin_family_profile_value(Families, "stateless_api",
                                         actor, StatelessActor),
            builtin_family_default_profile_value(Families, "stateless_api",
                                                 actor, DefaultStatelessActor),
            builtin_family_profile_value(Families, "semistateful_api",
                                         relation, SemiStatefulRelation),
            builtin_family_profile_value(Families, "semistateful_api",
                                         isotope, SemiStatefulIsotope),
            builtin_family_default_profile_value(Families, "semistateful_api",
                                                 actor, DefaultSemiStatefulActor),
            builtin_family_profile_value(Families, "stateful_api",
                                         isotope, StatefulIsotope),
            builtin_family_profile_value(Families, "stateful_api",
                                         actor, StatefulActor),
            builtin_family_default_profile_value(Families, "stateful_api",
                                                 actor, DefaultStatefulActor)
        )).

test(admin_config_compacts_predicate_indicator_series,
     true((memberchk("spawn/1-3", ActorLifecyclePredicates),
           memberchk("demonitor/1-2", ActorMessagingPredicates),
           memberchk("server_yield/2-4", ServerPredicates),
           memberchk("/call", StatelessPredicates)))) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_answer_headers(ConfigURL, Headers, ConfigJSON),
            Families = ConfigJSON.get(builtin_families),
            once((
                member(ActorLifecycleFamily, Families),
                ActorLifecycleFamily.get(id) == "actor_lifecycle"
            )),
            ActorLifecyclePredicates = ActorLifecycleFamily.get(predicates),
            once((
                member(ActorMessagingFamily, Families),
                ActorMessagingFamily.get(id) == "actor_messaging"
            )),
            ActorMessagingPredicates = ActorMessagingFamily.get(predicates),
            once((
                member(ServerFamily, Families),
                ServerFamily.get(id) == "server"
            )),
            ServerPredicates = ServerFamily.get(predicates),
            once((
                member(StatelessFamily, Families),
                StatelessFamily.get(id) == "stateless_api"
            )),
            StatelessPredicates = StatelessFamily.get(predicates)
        )).

test(admin_config_updates_limits_only_target_node,
     true((UpdatedCallLimit == 1,
           UpdatedSessionLimit == 2,
           UpdatedWSLimit == 3,
           UpdatedTermLimit == 111,
           UpdatedLoadLimit == 222,
           UpdatedFrameLimit == 333,
           UpdatedAdminJSONLimit == 444,
           UpdatedRateWindow == 55,
           UpdatedCallRate == 11,
           UpdatedSpawnRate == 12,
           UpdatedWSRate == 13,
           OtherCallLimit == 4,
           OtherTermLimit == 32768))) :-
    with_node_server_options([auth(private), owner("owner")], URI1,
        with_node_server_options([auth(private), owner("owner")], URI2,
            (
                principal_headers("owner", Headers),
                admin_config_url(URI1, ConfigURL1),
                read_json_post_headers(
                    ConfigURL1,
                    Headers,
                    json{
                        max_inflight_calls:1,
                        max_sessions_per_principal:2,
                        max_ws_actors_per_principal:3,
                        max_term_text_bytes:111,
                        max_load_text_bytes:222,
                        max_ws_frame_bytes:333,
                        max_admin_json_bytes:444,
                        rate_window_seconds:55,
                        max_call_requests_per_window:11,
                        max_session_spawns_per_window:12,
                        max_ws_commands_per_window:13
                    },
                    UpdatedJSON
                ),
                UpdatedCallLimit = UpdatedJSON.get(max_inflight_calls),
                UpdatedSessionLimit = UpdatedJSON.get(max_sessions_per_principal),
                UpdatedWSLimit = UpdatedJSON.get(max_ws_actors_per_principal),
                UpdatedTermLimit = UpdatedJSON.get(max_term_text_bytes),
                UpdatedLoadLimit = UpdatedJSON.get(max_load_text_bytes),
                UpdatedFrameLimit = UpdatedJSON.get(max_ws_frame_bytes),
                UpdatedAdminJSONLimit = UpdatedJSON.get(max_admin_json_bytes),
                UpdatedRateWindow = UpdatedJSON.get(rate_window_seconds),
                UpdatedCallRate = UpdatedJSON.get(max_call_requests_per_window),
                UpdatedSpawnRate = UpdatedJSON.get(max_session_spawns_per_window),
                UpdatedWSRate = UpdatedJSON.get(max_ws_commands_per_window),

                admin_config_url(URI2, ConfigURL2),
                read_json_answer_headers(ConfigURL2, Headers, OtherJSON),
                OtherCallLimit = OtherJSON.get(max_inflight_calls),
                OtherTermLimit = OtherJSON.get(max_term_text_bytes)
            ))).

test(admin_config_rejects_oversized_json_body,
     true((Status == 413,
           Type == "error",
           sub_string(Data, _, _, _, "Admin JSON body too large")))) :-
    with_node_server_options([auth(private), owner("owner"), max_admin_json_bytes(32)], URI,
        (
            admin_config_url(URI, URL),
            principal_headers("owner", Headers),
            repeated_string(0'a, 80, Padding),
            format(string(BodyText), "{\"profile\":\"~s\"}", [Padding]),
            read_json_post_string_status_headers(URL, Headers, BodyText, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(admin_principals_update_only_target_node,
     true((AllowedType == "success",
           DeniedType == "error",
           sub_string(DeniedData, _, _, _, "unknown principal")))) :-
    with_node_server_options([auth(private), owner("owner")], URI1,
        with_node_server_options([auth(private), owner("owner")], URI2,
            (
                principal_headers("owner", OwnerHeaders),
                admin_principals_url(URI1, PrincipalsURL1),
                read_json_post_headers(
                    PrincipalsURL1,
                    OwnerHeaders,
                    json{principals:[
                        json{id:"owner", capabilities:["admin"]},
                        json{id:"alice", capabilities:["execute"]}
                    ]},
                    _Updated
                ),

                principal_headers("alice", AliceHeaders),
                json_call_url(URI1, 'member(X,[a])', 0, 1, AllowedURL),
                read_json_answer_headers(AllowedURL, AliceHeaders, AllowedJSON),
                AllowedType = AllowedJSON.get(type),

                json_call_url(URI2, 'member(X,[a])', 0, 1, DeniedURL),
                read_json_answer_headers(DeniedURL, AliceHeaders, DeniedJSON),
                DeniedType = DeniedJSON.get(type),
                DeniedData = DeniedJSON.get(data)
            ))).

test(admin_runtime_reports_live_resources,
     true((SessionCount == 1,
           WSActorCount == 1,
           SessionOwner == "alice",
           SessionProfile == "isotope",
           SessionReady == false,
           WSActorOwner == "alice",
           WSActorKind == "actor",
           SessionLimitCount == 1,
           WSActorLimitCount == 1,
           WSCommandRateCount >= 1))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), owner("owner"), AlicePolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("owner", OwnerHeaders),
                principal_headers("alice", AliceHeaders),
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post_headers(SpawnURL, AliceHeaders, _{options:"[]"}, SpawnJSON),
                SessionPid = SpawnJSON.pid,
                ws_open_headers(URI, AliceHeaders, WS),
                ws_send_json(WS, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WS, WSReply),
                ActorPid = WSReply.pid
            ),
            (
                admin_runtime_url(URI, RuntimeURL),
                read_json_answer_headers(RuntimeURL, OwnerHeaders, RuntimeJSON),
                Sessions = RuntimeJSON.get(sessions),
                WSActors = RuntimeJSON.get(ws_actors),
                length(Sessions, SessionCount),
                length(WSActors, WSActorCount),
                nth0(0, Sessions, SessionInfo),
                SessionOwner = SessionInfo.get(owner),
                SessionProfile = SessionInfo.get(profile),
                SessionReady = SessionInfo.get(ready),
                nth0(0, WSActors, WSActorInfo),
                WSActorOwner = WSActorInfo.get(owner),
                WSActorKind = WSActorInfo.get(kind),
                LimitUsage = RuntimeJSON.get(limit_usage),
                SessionLimits = LimitUsage.get(isotope_sessions),
                SessionLimits = [SessionLimitInfo],
                SessionLimitCount = SessionLimitInfo.get(resources),
                WSActorLimits = LimitUsage.get(ws_actors),
                WSActorLimits = [WSActorLimitInfo],
                WSActorLimitCount = WSActorLimitInfo.get(resources),
                RateUsage = RuntimeJSON.get(rate_limits),
                WSCommandRates = RateUsage.get(ws_commands),
                WSCommandRates = [WSCommandRateInfo|_],
                WSCommandRateCount = WSCommandRateInfo.get(count)
            ),
            (
                catch(ws_close(WS, 1000, "done"), _, true),
                catch(actor:exit(ActorPid, kill), _, true),
                kill_isotope_session(SessionPid)
            )
        )).

test(admin_runtime_reports_client_activity_log,
     true((WSConnectionCount == 1,
           WSConnectionOwner == "alice",
           ActivePrincipals == 1,
           ActiveSessions == 1,
           ActiveWSConnections == 1,
           ActiveWSActors == 1,
           SessionActiveSeconds >= 0,
           WSActorActiveSeconds >= 0,
           PrincipalActiveSessions == 1,
           PrincipalActiveWSConnections == 1,
           PrincipalActiveWSActors == 1,
           PrincipalRecentRequests >= 2,
           HasHTTPSpawnEvent == true,
           HasWSSpawnEvent == true))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), owner("owner"), AlicePolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("owner", OwnerHeaders),
                principal_headers("alice", AliceHeaders),
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post_headers(SpawnURL, AliceHeaders, _{options:"[]"}, SpawnJSON),
                SessionPid = SpawnJSON.pid,
                ws_open_headers(URI, AliceHeaders, WS),
                ws_send_json(WS, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WS, WSReply),
                ActorPid = WSReply.pid
            ),
            (
                admin_runtime_url(URI, RuntimeURL),
                read_json_answer_headers(RuntimeURL, OwnerHeaders, RuntimeJSON),

                Sessions = RuntimeJSON.get(sessions),
                Sessions = [SessionInfo],
                SessionActiveSeconds = SessionInfo.get(active_seconds),

                WSConnections = RuntimeJSON.get(ws_connections),
                length(WSConnections, WSConnectionCount),
                WSConnections = [WSConnectionInfo],
                WSConnectionOwner = WSConnectionInfo.get(principal),

                WSActors = RuntimeJSON.get(ws_actors),
                WSActors = [WSActorInfo],
                WSActorActiveSeconds = WSActorInfo.get(active_seconds),

                ActivitySummary = RuntimeJSON.get(activity_summary),
                ActivePrincipals = ActivitySummary.get(active_principals),
                ActiveSessions = ActivitySummary.get(active_sessions),
                ActiveWSConnections = ActivitySummary.get(active_ws_connections),
                ActiveWSActors = ActivitySummary.get(active_ws_actors),

                PrincipalActivity = RuntimeJSON.get(principal_activity),
                PrincipalActivity = [AliceActivity],
                PrincipalActiveSessions = AliceActivity.get(active_sessions),
                PrincipalActiveWSConnections = AliceActivity.get(active_ws_connections),
                PrincipalActiveWSActors = AliceActivity.get(active_ws_actors),
                PrincipalRecentRequests = AliceActivity.get(recent_requests),

                RecentEvents = RuntimeJSON.get(recent_events),
                (   member(HTTPEvent, RecentEvents),
                    HTTPEvent.get(action) == "toplevel_spawn"
                ->  HasHTTPSpawnEvent = true
                ;   HasHTTPSpawnEvent = false
                ),
                (   member(WSEvent, RecentEvents),
                    WSEvent.get(action) == "spawn"
                ->  HasWSSpawnEvent = true
                ;   HasWSSpawnEvent = false
                )
            ),
            (
                catch(ws_close(WS, 1000, "done"), _, true),
                catch(actor:exit(ActorPid, kill), _, true),
                kill_isotope_session(SessionPid)
            )
        )).

test(admin_reclaim_terminates_session,
     true((RemainingSessions == [],
           Type == "error",
           sub_string(Data, _, _, _, "Not authorized to access session")))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), owner("owner"), AlicePolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("owner", OwnerHeaders),
                principal_headers("alice", AliceHeaders),
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post_headers(SpawnURL, AliceHeaders, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                admin_reclaim_url(URI, ReclaimURL),
                read_json_post_headers(
                    ReclaimURL,
                    OwnerHeaders,
                    json{action:"terminate_session", pid:Pid},
                    ReclaimJSON
                ),
                RemainingSessions = ReclaimJSON.get(sessions),
                isotope_call_url(URI, Pid, 'true', '', CallURL),
                read_json_answer_headers(CallURL, AliceHeaders, CallJSON),
                Type = CallJSON.get(type),
                Data = CallJSON.get(data)
            ),
            kill_isotope_session(Pid)
        )).

test(admin_reclaim_terminates_ws_actor,
     true((RemainingActors == [],
           DownType == "down",
           DownPid == Pid,
           Type == "error",
           sub_string(Data, _, _, _, "Not authorized to access actor")))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), owner("owner"), AlicePolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("owner", OwnerHeaders),
                principal_headers("alice", AliceHeaders),
                ws_open_headers(URI, AliceHeaders, WS),
                ws_send_json(WS, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WS, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                admin_reclaim_url(URI, ReclaimURL),
                read_json_post_headers(
                    ReclaimURL,
                    OwnerHeaders,
                    json{action:"terminate_ws_actor", pid:Pid},
                    ReclaimJSON
                ),
                RemainingActors = ReclaimJSON.get(ws_actors),
                ws_receive_json(WS, DownJSON),
                DownType = DownJSON.get(type),
                DownPid = DownJSON.get(pid),
                ws_send_json(WS, json{command:send, pid:Pid, message:"hello"}),
                ws_receive_json(WS, ReplyJSON),
                Type = ReplyJSON.get(type),
                Data = ReplyJSON.get(data)
            ),
            catch(ws_close(WS, 1000, "done"), _, true)
        )).

test(admin_reclaim_clears_principal_rate_limits,
     true((BeforeCount == 1,
           AfterCallRequests == []))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options(
        [auth(private), owner("owner"), AlicePolicy, rate_window_seconds(60),
         max_call_requests_per_window(10)],
        URI,
        (
            principal_headers("owner", OwnerHeaders),
            principal_headers("alice", AliceHeaders),
            json_call_url(URI, 'true', 0, 1, CallURL),
            read_json_answer_headers(CallURL, AliceHeaders, _),

            admin_runtime_url(URI, RuntimeURL),
            read_json_answer_headers(RuntimeURL, OwnerHeaders, BeforeJSON),
            BeforeRateUsage = BeforeJSON.get(rate_limits),
            BeforeRates = BeforeRateUsage.get(call_requests),
            BeforeRates = [BeforeRateInfo],
            BeforeCount = BeforeRateInfo.get(count),

            admin_reclaim_url(URI, ReclaimURL),
            read_json_post_headers(
                ReclaimURL,
                OwnerHeaders,
                json{action:"clear_principal_rate_limits", principal:"alice"},
                AfterJSON
            ),
            AfterRateUsage = AfterJSON.get(rate_limits),
            AfterCallRequests = AfterRateUsage.get(call_requests)
        )).

test(admin_reclaim_records_audit_event,
     true((HasAuditEvent == true,
           EventStatus == "success"))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), owner("owner"), AlicePolicy], URI,
        (
            principal_headers("owner", OwnerHeaders),
            admin_reclaim_url(URI, ReclaimURL),
            read_json_post_headers(
                ReclaimURL,
                OwnerHeaders,
                json{action:"clear_principal_rate_limits", principal:"alice"},
                AfterJSON
            ),
            RecentEvents = AfterJSON.get(recent_events),
            (   member(Event, RecentEvents),
                Event.get(action) == "clear_principal_rate_limits"
            ->  HasAuditEvent = true,
                EventStatus = Event.get(status)
            ;   HasAuditEvent = false,
                EventStatus = ""
            )
        )).

test(private_call_requires_authenticated_principal,
     true((Type == "error",
           sub_string(Data, _, _, _, "Authentication required")))) :-
    with_node_server_options([auth(private)], URI,
        (
            json_call_url(URI, 'member(X,[a])', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(private_call_rejects_unknown_authenticated_principal,
     true((Type == "error",
           sub_string(Data, _, _, _, "unknown principal")))) :-
    with_node_server_options([auth(private)], URI,
        (
            json_call_url(URI, 'member(X,[a])', 0, 1, URL),
            principal_headers("mallory", Headers),
            read_json_answer_headers(URL, Headers, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(private_call_allows_authenticated_principal,
     true((Type == "success", More == false, Data = [Row], get_dict('X', Row, "a")))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI,
        (
            json_call_url(URI, 'member(X,[a])', 0, 1, URL),
            principal_headers("alice", Headers),
            read_json_answer_headers(URL, Headers, JSON),
            Type = JSON.type,
            Data = JSON.data,
            More = JSON.more
        )).

test(call_limit_rejects_second_inflight_request,
     true((Type == "error",
           sub_string(Data, _, _, _, "Too many concurrent /call requests")))) :-
    with_node_server_options([max_inflight_calls(1)], URI,
        setup_call_cleanup(
            (
                json_call_url(URI, 'sleep(0.2)', 0, 1, LongURL),
                thread_create(read_json_answer(LongURL, _LongJSON), Thread, [])
            ),
            (
                sleep(0.05),
                json_call_url(URI, 'true', 0, 1, URL),
                read_json_answer(URL, JSON),
                Type = JSON.type,
                Data = JSON.data
            ),
            thread_join(Thread, _)
        )).

test(call_rate_limit_rejects_second_request_in_window,
     true((Type == "error",
           sub_string(Data, _, _, _, "Too many /call requests")))) :-
    with_node_server_options([rate_window_seconds(60), max_call_requests_per_window(1)], URI,
        (
            json_call_url(URI, 'true', 0, 1, URL1),
            read_json_answer(URL1, _JSON1),
            json_call_url(URI, 'true', 0, 1, URL2),
            read_json_answer(URL2, JSON2),
            Type = JSON2.type,
            Data = JSON2.data
        )).

test(call_rate_limit_scope_resets_when_port_is_reused,
     true(Type == "success")) :-
    pick_free_port(Port),
    format(atom(URI), 'http://localhost:~w', [Port]),
    setup_call_cleanup(
        node(Port, [rate_window_seconds(60), max_call_requests_per_window(1)]),
        (
            json_call_url(URI, 'true', 0, 1, URL1),
            read_json_answer(URL1, _JSON1)
        ),
        stop_node_server(Port)
    ),
    setup_call_cleanup(
        node(Port, [rate_window_seconds(60), max_call_requests_per_window(1)]),
        (
            json_call_url(URI, 'true', 0, 1, URL2),
            read_json_answer(URL2, JSON2),
            Type = JSON2.type
        ),
        stop_node_server(Port)
    ).

test(call_rate_limit_sweeps_stale_scope_buckets) :-
    start_node_server([rate_window_seconds(60)], Port, _URI),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
            (
                test_execution_principal("charlie", Principal),
                assertz(node_rate_limits:principal_rate_bucket(node_port(Port), call_request, "alice", 0, 1)),
                assertz(node_rate_limits:principal_rate_bucket(node_port(Port), session_spawn_request, "bob", 0, 1)),
                node_rate_limits:enforce_call_request_rate_limit(Principal),
                \+ node_rate_limits:principal_rate_bucket(node_port(Port), _, "alice", 0, _),
                \+ node_rate_limits:principal_rate_bucket(node_port(Port), _, "bob", 0, _)
            )),
        stop_node_server(Port)
    ).

test(call_rate_limit_exempts_admin_and_internal_transport_principals) :-
    start_node_server([rate_window_seconds(60), max_call_requests_per_window(1)], Port, _URI),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
            (
                AdminPrincipal = principal{
                    id:"owner",
                    capabilities:[admin],
                    unknown:false
                },
                InternalPrincipal = principal{
                    id:"node:peer",
                    capabilities:[execute, internal_transport],
                    unknown:false
                },
                node_rate_limits:enforce_call_request_rate_limit(AdminPrincipal),
                node_rate_limits:enforce_call_request_rate_limit(AdminPrincipal),
                node_rate_limits:enforce_call_request_rate_limit(InternalPrincipal),
                node_rate_limits:enforce_call_request_rate_limit(InternalPrincipal)
            )),
        stop_node_server(Port)
    ).

test(resource_limit_sweeps_stale_reservation) :-
    start_node_server([max_ws_actors_per_principal(1)], Port, _URI),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
            (
                test_execution_principal("alice", Principal),
                thread_create(
                    with_node_port_context(Port,
                        node_limits:reserve_ws_actor_capacity(Principal, _Reservation)),
                    Thread,
                    []),
                thread_join(Thread, true),
                node_limits:reserve_ws_actor_capacity(Principal, Reservation),
                node_limits:release_capacity_reservation(Reservation)
            )),
        stop_node_server(Port)
    ).

test(resource_limit_exempts_internal_transport_but_not_admin) :-
    start_node_server([max_ws_actors_per_principal(1)], Port, _URI),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
            (
                AdminPrincipal = principal{
                    id:"owner",
                    capabilities:[admin],
                    unknown:false
                },
                InternalPrincipal = principal{
                    id:"node:peer",
                    capabilities:[execute, internal_transport],
                    unknown:false
                },
                node_limits:reserve_ws_actor_capacity(AdminPrincipal, Reservation0),
                catch(node_limits:reserve_ws_actor_capacity(AdminPrincipal, _),
                      error(resource_limit_exceeded("owner", ws_actors, 1), _),
                      true),
                node_limits:release_capacity_reservation(Reservation0),
                node_limits:reserve_ws_actor_capacity(InternalPrincipal, Reservation1),
                node_limits:reserve_ws_actor_capacity(InternalPrincipal, Reservation2),
                node_limits:release_capacity_reservation(Reservation1),
                node_limits:release_capacity_reservation(Reservation2)
            )),
        stop_node_server(Port)
    ).

test(resource_limit_sweeps_stale_committed_resource) :-
    start_node_server([max_ws_actors_per_principal(1)], Port, _URI),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
            (
                test_execution_principal("alice", Principal),
                node_limits:reserve_ws_actor_capacity(Principal, Reservation0),
                actor:spawn(sleep(10), Pid),
                actor:monitor(Pid, Ref),
                node_limits:commit_ws_actor_capacity(Reservation0, Pid),
                exit(Pid, kill),
                receive({
                    down(Ref, Pid, _) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                node_limits:reserve_ws_actor_capacity(Principal, Reservation1),
                node_limits:release_capacity_reservation(Reservation1)
            )),
        stop_node_server(Port)
    ).

test(call_rejects_oversized_goal_text,
     true((Type == "error",
           sub_string(Data, _, _, _, "Request field too large: goal")))) :-
    with_node_server_options([max_term_text_bytes(16)], URI,
        (
            repeated_string(0'a, 40, GoalAtom),
            json_call_url(URI, GoalAtom, 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(call_rejects_oversized_load_text,
     true((Type == "error",
           sub_string(Data, _, _, _, "Request field too large: load_text")))) :-
    with_node_server_options([max_load_text_bytes(16)], URI,
        (
            repeated_string(0'a, 40, LoadText),
            parse_url(URI, Parts),
            parse_url(URL, [
                path('/call'),
                search([
                    goal='true',
                    template='true',
                    offset=0,
                    limit=1,
                    format=json,
                    load_text=LoadText
                ])
                | Parts
            ]),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(ws_rejects_oversized_frame,
     true((Type == "error",
           sub_string(Data, _, _, _, "WebSocket message too large")))) :-
    with_node_server_options([max_ws_frame_bytes(64)], URI,
        setup_call_cleanup(
            ws_open(URI, WebSocket),
            (
                repeated_string(0'a, 120, GoalText),
                ws_send_json(WebSocket, json{command:"spawn", goal:GoalText}),
                ws_receive_json(WebSocket, Reply),
                Type = Reply.type,
                Data = Reply.data
            ),
            ws_close(WebSocket, 1000, "")
        )).

test(dev_call_allows_local_requests,
     true((Type == "success", More == false, Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server_options([auth(dev)], URI,
        (
            json_call_url(URI, 'member(X,[a])', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data,
            More = JSON.more
        )).

test(open_mode_anonymous_capabilities_include_execute,
     true(memberchk(execute, Capabilities))) :-
    with_auth_mode(open,
        principal_capabilities(anonymous, Capabilities)).

test(open_mode_local_admin_request_is_authorized) :-
    with_auth_mode(open,
        require_admin_access([peer(ip(127,0,0,1))])).

test(open_mode_docker_localhost_admin_request_is_authorized) :-
    with_auth_mode(open,
        require_admin_access([
            peer(ip(172,17,0,1)),
            host('localhost:3054')
        ])).

test(open_mode_loopback_host_admin_request_is_authorized_without_peer_match) :-
    with_auth_mode(open,
        require_admin_access([
            peer(ip(203,0,113,10)),
            host('127.0.0.1:3053')
        ])).

test(open_mode_private_network_admin_request_without_loopback_host_is_denied,
     throws(error(authorization_error(anonymous, capability(admin)), _))) :-
    with_auth_mode(open,
        require_admin_access([
            peer(ip(172,17,0,1)),
            host('admin.elfenbenstornet.se')
        ])).

test(dev_call_requires_execute_capability,
     true((Type == "error",
           sub_string(Data, _, _, _, "Not authorized for node execution")))) :-
    with_node_server_options(
        [auth(dev), dev_principal("dev-readonly"), dev_capabilities([public_read])],
        URI,
        (
            json_call_url(URI, 'member(X,[a])', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(private_call_load_text_allowed_for_execution_principal,
     true((Type == "success",
           Data = [Row],
           get_dict('X', Row, "a")))) :-
    alice_stateless_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI,
        (
            json_call_url_with_load_text(URI, 'q(X)', 'q(a).', URL),
            principal_headers("alice", Headers),
            read_json_answer_headers(URL, Headers, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(private_toplevel_spawn_allows_load_uri_for_execution_principal,
     true(Values == ["a", "b"])) :-
    alice_isotope_principal_option(AlicePolicy),
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server_options([auth(private), AlicePolicy], URI,
                (
                    atom_concat(URI, '/toplevel_spawn', SpawnURL),
                    format(string(OptionsText), "[load_uri(~q)]", [File]),
                    principal_headers("alice", Headers),
                    read_json_post_headers(SpawnURL, Headers,
                                           _{options:OptionsText}, SpawnJSON),
                    get_dict(pid, SpawnJSON, Pid),
                    isotope_call_url(URI, Pid, 'u(X)', '', CallURL),
                    read_json_answer_headers(CallURL, Headers, JSON),
                    get_dict(type, JSON, "success"),
                    get_dict(data, JSON, Rows),
                    findall(Value,
                            ( member(Row, Rows),
                              get_dict('X', Row, Value)
                            ),
                            Values0),
                    sort(Values0, Values)
                ))
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(private_ws_requires_authenticated_principal,
     true((Status == 403,
           Type == "error",
           sub_string(Data, _, _, _, "Authentication required")))) :-
    with_node_server_options([auth(private)], URI,
        (
            format(atom(WsURL), '~w/ws', [URI]),
            read_json_status(WsURL, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(private_ws_allows_authenticated_principal,
     true(Type == "spawned")) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("alice", Headers),
                ws_open_headers(URI, Headers, WebSocket)
            ),
            (
                ws_send_json(WebSocket, json{command:toplevel_spawn}),
                ws_receive_json(WebSocket, Reply),
                Type = Reply.type
            ),
            ws_close(WebSocket, 1000, "done")
        )).

test(private_isotope_session_limit_rejects_second_spawn_and_cleanup_restores_capacity,
     true((Type2 == "error",
           sub_string(Data2, _, _, _, "Too many active ISOTOPE sessions"),
           Type3 == "spawned"))) :-
    alice_isotope_principal_option(AlicePolicy),
    with_node_server_options(
        [auth(private), AlicePolicy, max_sessions_per_principal(1)],
        URI,
        setup_call_cleanup(
            (
                principal_headers("alice", Headers),
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post_headers(SpawnURL, Headers, _{options:"[]"}, Spawn1),
                Pid1 = Spawn1.pid
            ),
            (
                read_json_post_headers(SpawnURL, Headers, _{options:"[]"}, Spawn2),
                Type2 = Spawn2.type,
                Data2 = Spawn2.data,
                kill_isotope_session(Pid1),
                read_json_post_headers(SpawnURL, Headers, _{options:"[]"}, Spawn3),
                Type3 = Spawn3.type,
                Pid2 = Spawn3.pid
            ),
            (
                kill_isotope_session(Pid1),
                (   nonvar(Pid2)
                ->  kill_isotope_session(Pid2)
                ;   true
                )
            )
        )).

test(session_spawn_rate_limit_rejects_second_spawn_in_window,
     true((Type2 == "error",
           sub_string(Data2, _, _, _, "Too many /toplevel_spawn requests")))) :-
    with_node_server_options(
        [rate_window_seconds(60), max_session_spawns_per_window(1)],
        URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, Spawn1),
                Pid1 = Spawn1.pid
            ),
            (
                read_json_post(SpawnURL, _{options:"[]"}, Spawn2),
                Type2 = Spawn2.type,
                Data2 = Spawn2.data
            ),
            kill_isotope_session(Pid1)
        )).

test(private_ws_actor_limit_rejects_second_spawn_and_down_restores_capacity,
     true((Type2 == "error",
           sub_string(Data2, _, _, _, "Too many active WebSocket actors"),
           Type3 == "spawned"))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options(
        [auth(private), AlicePolicy, max_ws_actors_per_principal(1)],
        URI,
        setup_call_cleanup(
            (
                principal_headers("alice", Headers),
                ws_open_headers(URI, Headers, WebSocket)
            ),
            (
                ws_send_json(WebSocket, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WebSocket, Spawn1),
                Pid1 = Spawn1.pid,

                ws_send_json(WebSocket, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WebSocket, Reply2),
                Type2 = Reply2.type,
                Data2 = Reply2.data,

                ws_send_json(WebSocket, json{command:exit, pid:Pid1, reason:"done"}),
                ws_receive_json(WebSocket, Down),
                Down.type == "down",

                ws_send_json(WebSocket, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WebSocket, Spawn3),
                Type3 = Spawn3.type
            ),
            ws_close(WebSocket, 1000, "done")
        )).

test(dev_admin_ws_actor_limit_is_enforced,
     true((Type2 == "error",
           sub_string(Data2, _, _, _, "Too many active WebSocket actors")))) :-
    with_node_server_options(
        [auth(dev), max_ws_actors_per_principal(1)],
        URI,
        setup_call_cleanup(
            ws_open(URI, WebSocket),
            (
                ws_send_json(WebSocket, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WebSocket, Spawn1),
                Pid1 = Spawn1.pid,

                ws_send_json(WebSocket, json{command:spawn, goal:"sleep(5)", options:"[]"}),
                ws_receive_json(WebSocket, Reply2),
                Type2 = Reply2.type,
                Data2 = Reply2.data
            ),
            (
                catch(ws_close(WebSocket, 1000, "done"), _, true),
                (   nonvar(Pid1)
                ->  catch(actor:exit(Pid1, kill), _, true)
                ;   true
                )
            )
        )).

test(private_ws_actor_limit_counts_nested_spawn_from_toplevel_call,
     true((Type == "error",
           sub_string(Data, _, _, _, "Too many active WebSocket actors")))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options(
        [auth(private), AlicePolicy, max_ws_actors_per_principal(2)],
        URI,
        setup_call_cleanup(
            (
                principal_headers("alice", Headers),
                ws_open_headers(URI, Headers, WebSocket)
            ),
            (
                ws_send_json(WebSocket, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WebSocket, Spawned),
                get_dict(pid, Spawned, Pid),

                ws_send_json(WebSocket, json{
                    command:toplevel_call,
                    pid:Pid,
                    goal:"spawn(sleep(5), _P1, [link(false)]), spawn(sleep(5), _P2, [link(false)])",
                    template:"true"
                }),
                ws_receive_json(WebSocket, Reply),
                Type = Reply.type,
                Data = Reply.data
            ),
            ws_close(WebSocket, 1000, "done")
        )).

test(ws_command_rate_limit_rejects_second_command_in_window,
     true((Type2 == "error",
           sub_string(Data2, _, _, _, "Too many WebSocket commands")))) :-
    with_node_server_options(
        [rate_window_seconds(60), max_ws_commands_per_window(1)],
        URI,
        setup_call_cleanup(
            ws_open(URI, WebSocket),
            (
                ws_send_json(WebSocket, json{command:toplevel_spawn}),
                ws_receive_json(WebSocket, Reply1),
                Pid = Reply1.pid,

                ws_send_json(WebSocket, json{command:toplevel_spawn}),
                ws_receive_json(WebSocket, Reply2),
                Type2 = Reply2.type,
                Data2 = Reply2.data
            ),
            (
                catch(ws_close(WebSocket, 1000, "done"), _, true),
                (   nonvar(Pid)
                ->  kill_isotope_session(Pid)
                ;   true
                )
            )
        )).

test(dev_ws_allows_local_requests,
     true(Type == "spawned")) :-
    with_node_server_options([auth(dev)], URI,
        setup_call_cleanup(
            ws_open(URI, WebSocket),
            (
                ws_send_json(WebSocket, json{command:toplevel_spawn}),
                ws_receive_json(WebSocket, Reply),
                Type = Reply.type
            ),
            ws_close(WebSocket, 1000, "done")
        )).

test(ws_rejects_unowned_toplevel_pid_without_sandbox,
     true((Type == "error",
           sub_string(Data, _, _, _, "Not authorized to access session")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (ws_open(URI, WS1), ws_open(URI, WS2)),
            (
                ws_send_json(WS1, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS1, Spawned),
                get_dict(pid, Spawned, ToplevelPid),

                ws_send_json(WS2, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"true",
                    template:"true"
                }),
                ws_receive_json(WS2, Reply),
                Type = Reply.type,
                Data = Reply.data
            ),
            ( catch(ws_close(WS1, 1000, done), _, true),
              catch(ws_close(WS2, 1000, done), _, true)
            )
        )).

test(private_ws_remote_echo_actor_roundtrip_between_nodes,
     true((OutputData == "Shell got echo(hello)",
           FlushType == "success"))) :-
    alice_full_principal_option(AlicePolicy),
    with_node_server_options([auth(private), AlicePolicy], URI1,
        with_node_server_options([auth(private), AlicePolicy], URI2,
            setup_call_cleanup(
                (
                    principal_headers("alice", Headers),
                    ws_open_headers(URI1, Headers, WS)
                ),
                (
                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Spawned),
                    get_dict(pid, Spawned, ToplevelPid),

                    format(string(SpawnGoal),
                           "spawn(echo_actor, Pid, [node('~w'), monitor(true)])",
                           [URI2]),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:ToplevelPid,
                        goal:SpawnGoal,
                        template:"Pid"
                    }),
                    ws_receive_json(WS, SpawnReply),
                    get_dict(data, SpawnReply, [SpawnRow]),
                    get_dict('Pid', SpawnRow, EchoPid),

                    format(string(EchoGoal),
                           "send(~s, echo(~w@'~w', hello))",
                           [EchoPid, ToplevelPid, URI1]),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:ToplevelPid,
                        goal:EchoGoal,
                        template:"true"
                    }),
                    ws_receive_json(WS, _EchoReply),

                    ws_flush_until_output(WS, ToplevelPid, OutputData, FlushType)
                ),
                catch(ws_close(WS, 1000, done), _, true)
            ))).

test(dev_request_principal_uses_local_config,
     true((PrincipalId == "carol",
           Capabilities == [execute],
           Authorized == true))) :-
    with_auth_mode(dev,
        with_dev_auth_config("carol", [execute],
            (
                request_principal([peer(ip(127,0,0,1))], Principal),
                principal_id(Principal, PrincipalId),
                principal_capabilities(Principal, Capabilities),
                (   principal_execution_authorized(Principal)
                ->  Authorized = true
                ;   Authorized = false
                )
            ))).

test(dev_request_principal_rejects_nonlocal_peer,
     true(Principal == anonymous)) :-
    with_auth_mode(dev,
        with_dev_auth_config("carol", [admin],
            request_principal([peer(ip(192,0,2,1))], Principal))).

test(request_principal_accepts_trusted_internal_transport_headers) :-
    request_principal([
        x_web_prolog_user("node:https://n4.example"),
        x_web_prolog_capabilities("execute,internal_transport"),
        x_web_prolog_internal_proxy(true)
    ], Principal),
    principal_id(Principal, PrincipalId),
    principal_capabilities(Principal, Capabilities),
    get_dict(unknown, Principal, Unknown),
    assertion(PrincipalId == "node:https://n4.example"),
    assertion(memberchk(execute, Capabilities)),
    assertion(memberchk(internal_transport, Capabilities)),
    assertion(Unknown == false).

test(request_principal_does_not_trust_internal_transport_headers_without_proxy_marker) :-
    request_principal([
        x_web_prolog_user("node:https://n4.example"),
        x_web_prolog_capabilities("execute,internal_transport")
    ], Principal),
    principal_id(Principal, PrincipalId),
    principal_capabilities(Principal, Capabilities),
    get_dict(unknown, Principal, Unknown),
    assertion(PrincipalId == "node:https://n4.example"),
    assertion(Capabilities == []),
    assertion(Unknown == true).

test(request_principal_accepts_internal_transport_headers_from_private_peer) :-
    request_principal([
        peer(ip(172, 18, 0, 5)),
        x_web_prolog_user("node:https://n4.example"),
        x_web_prolog_capabilities("execute,internal_transport")
    ], Principal),
    principal_id(Principal, PrincipalId),
    principal_capabilities(Principal, Capabilities),
    get_dict(unknown, Principal, Unknown),
    assertion(PrincipalId == "node:https://n4.example"),
    assertion(memberchk(execute, Capabilities)),
    assertion(memberchk(internal_transport, Capabilities)),
    assertion(Unknown == false).

test(with_node_request_context_infers_port_from_pool_client,
     true(URL == "https://n1.example")) :-
    setup_call_cleanup(
        (
            retractall(node_runtime_state:node_runtime(_, _)),
            register_node_runtime(3051, node_runtime{url:"https://n1.example"})
        ),
        once(node_runtime_state:with_node_request_context(
            [pool(client('httpd@3051', node:http_dispatch, dummy_input, dummy_output))],
            current_node_value(url, URL)
        )),
        retractall(node_runtime_state:node_runtime(_, _))
    ).

test(actor_node_url_to_ws_endpoint_honors_runtime_override,
     true(WsURL == 'ws://wp_n4:3055/ws')) :-
    setup_call_cleanup(
        (
            retractall(node_runtime_state:node_runtime(_, _)),
            register_node_runtime(3053, node_runtime{
                url:"https://n3.example",
                ws_endpoint_overrides:[
                    'https://n4.example'-'ws://wp_n4:3055/ws'
                ]
            })
        ),
        once(node_runtime_state:with_node_port_context(
            3053,
            actor:node_url_to_ws_endpoint('https://n4.example', WsURL)
        )),
        retractall(node_runtime_state:node_runtime(_, _))
    ).

test(profile_isobase_rejects_toplevel_spawn_route,
     true((Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([profile(isobase)], URI,
        (
            atom_concat(URI, '/toplevel_spawn', SpawnURL),
            read_json_post(SpawnURL, _{options:"[]"}, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_isobase_rejects_ws_route,
     true((Status == 403,
           Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([profile(isobase)], URI,
        (
            format(atom(WsURL), '~w/ws', [URI]),
            read_json_status(WsURL, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_isotope_rejects_ws_route,
     true((Status == 403,
           Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([profile(isotope)], URI,
        (
            format(atom(WsURL), '~w/ws', [URI]),
            read_json_status(WsURL, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_relation_rejects_toplevel_spawn_route,
     true((Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([profile(relation)], URI,
        (
            atom_concat(URI, '/toplevel_spawn', SpawnURL),
            read_json_post(SpawnURL, _{options:"[]"}, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_relation_rejects_ws_route,
     true((Status == 403,
           Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([profile(relation)], URI,
        (
            format(atom(WsURL), '~w/ws', [URI]),
            read_json_status(WsURL, Status, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(relation_call_allows_shared_db_relation,
     true((Type == "success",
           Data = [Row],
           get_dict('H', Row, "socrates"),
           get_dict('W', Row, "xantippa")))) :-
    with_node_server_options(
        [profile(relation), load_shared_db_text("wife(socrates, xantippa).\n")],
        URI,
        (
            json_call_url(URI, 'wife(H, W)', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(relation_call_rejects_builtin_goal,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: =/2")))) :-
    with_node_server_options(
        [profile(relation), load_shared_db_text("wife(socrates, xantippa).\n")],
        URI,
        (
            json_call_url(URI, 'X=1', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(relation_call_rejects_load_text,
     true((Type == "error",
           sub_string(Data, _, _, _, "Source loading is not available")))) :-
    with_node_server_options(
        [profile(relation), load_shared_db_text("wife(socrates, xantippa).\n")],
        URI,
        (
            json_call_url_with_load_text(URI, 'wife(H, W)', 'wife(plato, xantippa).', URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(relation_call_uses_explicit_relation_whitelist,
     true((AllowedType == "success",
           RejectedType == "error",
           sub_string(RejectedData, _, _, _, "Unknown procedure: husband/2")))) :-
    with_node_server_options(
        [ profile(relation),
          relations([wife/2]),
          load_shared_db_text("wife(socrates, xantippa).\nhusband(socrates, xantippa).\n")
        ],
        URI,
        (
            json_call_url(URI, 'wife(H, W)', 0, 1, AllowedURL),
            read_json_answer(AllowedURL, AllowedJSON),
            AllowedType = AllowedJSON.get(type),

            json_call_url(URI, 'husband(H, W)', 0, 1, RejectedURL),
            read_json_answer(RejectedURL, RejectedJSON),
            RejectedType = RejectedJSON.get(type),
            RejectedData = RejectedJSON.get(data)
        )).

test(relation_call_rejects_all_queries_when_no_relations_are_advertised,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: wife/2")))) :-
    with_node_server_options([profile(relation)], URI,
        (
            json_call_url(URI, 'wife(H, W)', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(relation_call_uses_shared_db_relation_filter,
     true((AllowedType == "success",
           RejectedType == "error",
           sub_string(RejectedData, _, _, _, "Unknown procedure: husband/2")))) :-
    with_node_server_options(
        [ profile(relation),
          load_shared_db_text(
              "wife(socrates, xantippa).\n\
\c               husband(socrates, xantippa).\n\
\c               relation_filter(wife(_, _)).\n")
        ],
        URI,
        (
            json_call_url(URI, 'wife(H, W)', 0, 1, AllowedURL),
            read_json_answer(AllowedURL, AllowedJSON),
            AllowedType = AllowedJSON.get(type),

            json_call_url(URI, 'husband(H, W)', 0, 1, RejectedURL),
            read_json_answer(RejectedURL, RejectedJSON),
            RejectedType = RejectedJSON.get(type),
            RejectedData = RejectedJSON.get(data)
        )).

test(relation_call_callable_patterns_constrain_query_arguments,
     true((Type == "success",
           Data = [Row],
           get_dict('W', Row, "xantippa"),
           \+ get_dict('W', Row, "pythias")))) :-
    with_node_server_options(
        [ profile(relation),
          relations([wife(socrates, _)]),
          load_shared_db_text("wife(socrates, xantippa).\nwife(aristotle, pythias).\n")
        ],
        URI,
        (
            json_call_url(URI, 'wife(H, W)', 0, 10, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data),
            Data = [_]
        )).

test(call_route_uses_isobase_profile_ceiling,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: spawn/2")))) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'spawn(true, Pid)', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_check_route_rejects_stateless_api_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner"), profile(isobase)], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"stateless_api",
                            profiles:json{isobase:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(Port, profile_check_route(call))
        )).

test(profile_check_route_rejects_stateless_api_family_disabled_in_effective_profile,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"stateless_api",
                            profiles:json{isobase:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(Port, profile_check_route(call))
        )).

test(http_call_route_rejects_stateless_api_family_disabled_in_effective_profile,
     true((Type == "error",
           sub_string(Data, _, _, _, "profile_violation")))) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"stateless_api",
                            profiles:json{isobase:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            json_call_url(URI, 'true', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.get(type),
            Data = JSON.get(data)
        )).

test(profile_check_route_rejects_semistateful_api_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner"), profile(isotope)], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"semistateful_api",
                            profiles:json{isotope:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(Port, profile_check_route(toplevel_spawn))
        )).

test(profile_check_route_rejects_stateful_api_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"stateful_api",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(Port, profile_check_route(ws))
        )).

test(profile_check_source_text_rejects_spawn_in_loaded_source,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_source_text(isobase, user, "p :- spawn(true, _Pid).\n").

test(relation_check_call_is_noop_for_non_relation_profiles) :-
    relation_check_call(isobase, member(a, [a]), "q(a).\n").

test(profile_check_goal_rejects_spawn_hidden_in_setof_generator,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(isobase, setof(Pid, spawn(true, Pid), _Pids)).

test(profile_check_goal_rejects_builtin_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"actor_naming",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(Port,
                                   profile_check_goal(actor,
                                                      register(foo, _Pid)))
        )).

test(profile_check_source_options_rejects_private_db_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"private_db",
                            profiles:json{isobase:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                node_profile_policy:profile_check_source_options(
                    isobase,
                    actor,
                    [load_text("p(a).\n")]
                )
            )
        )).

test(profile_check_goal_rejects_private_db_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"private_db",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                profile_check_goal(actor, listing)
            )
        )).

test(profile_check_goal_allows_listing_1_in_actor_profile) :-
    profile_check_goal(actor, listing(123)).

test(profile_check_goal_rejects_non_exported_actor_parent_predicate,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(actor, actor:'$parent'(_Parent)).

test(profile_check_goal_rejects_non_exported_actor_actor_parent_predicate,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(actor, actor:actor_parent(_Parent)).

test(profile_check_goal_rejects_dynamic_db_family_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"dynamic_db",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                profile_check_goal(actor, assert(p(a)))
            )
        )).

test(profile_check_goal_rejects_dynamic_db_reference_form_disabled_in_runtime,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"dynamic_db",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                profile_check_goal(actor, assertz(p(a), _Ref))
            )
        )).

test(profile_check_goal_rejects_disabled_family_inside_parallel_goal_list,
     [throws(error(profile_violation(_, _), _))]) :-
    with_node_server_options([auth(private), owner("owner")], URI,
        (
            admin_config_url(URI, ConfigURL),
            principal_headers("owner", Headers),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"actor_naming",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                profile_check_goal(actor, parallel([register(foo, _Pid)]))
            )
        )).

test(node_startup_options_reject_legacy_principal_profile,
     [throws(error(domain_error(node_principal_profile, "alice"), _))]) :-
    node_options([principal("alice", [execute], isotope)],
                 _SharedDB, _Sandbox, _Profile, _Auth, _DevPrincipal,
                 _DevCapabilities, _PrincipalPolicies, _Timeout,
                 _CacheSize, _MaxInflightCalls, _MaxSessionsPerPrincipal,
                 _MaxWSActorsPerPrincipal, _MaxTermTextBytes,
                 _MaxLoadTextBytes, _MaxWSFrameBytes,
                 _MaxAdminJSONBytes, _RateWindowSeconds,
                 _MaxCallRequestsPerWindow, _MaxSessionSpawnsPerWindow,
                 _MaxWSCommandsPerWindow, _LoadURIAllowedOrigins,
                 _RelationPatterns, _HTTPOptions).

test(node_startup_options_normalize_load_uri_allowed_origins,
     true(LoadURIAllowedOrigins == [
         'https://n1.elfenbenstornet.se:443',
         'https://n2.elfenbenstornet.se:443'
     ])) :-
    pick_free_port(Port),
    node(Port, [
        load_uri_allowed_origins([
            'https://n2.elfenbenstornet.se',
            'https://n1.elfenbenstornet.se:443'
        ])
    ]),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
                               current_node_value(load_uri_allowed_origins,
                                                  LoadURIAllowedOrigins)),
        stop_node_server(Port)
    ).

test(node_principal_policies_reject_profile_key,
     [throws(error(domain_error(node_principal_profile, "alice"), _))]) :-
    normalize_principal_policies([
        _{id:"alice", capabilities:[execute], profile:isotope}
    ], _Policies).

test(profile_check_goal_rejects_spawn_hidden_in_existential_generator,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(isobase, setof(Pid, _Other^spawn(true, Pid), _Pids)).

test(profile_check_goal_rejects_spawn_hidden_in_bagof_generator,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(isobase, bagof(Pid, spawn(true, Pid), _Pids)).

test(profile_check_goal_rejects_spawn_hidden_in_forall,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(isobase, forall(true, spawn(true))).

test(profile_check_goal_rejects_spawn_hidden_in_aggregate_all,
     [throws(error(profile_violation(_, _), _))]) :-
    profile_check_goal(isobase, aggregate_all(count, spawn(true), _Count)).

test(normalize_sandbox_mode_accepts_legacy_aliases,
     true((On == whitelist, Demo == whitelist, Strict == whitelist))) :-
    normalize_sandbox_mode(on, On),
    normalize_sandbox_mode(demo, Demo),
    normalize_sandbox_mode(strict, Strict).

test(normalize_sandbox_mode_accepts_explicit_blacklist,
     true((Whitelist == whitelist, Blacklist == blacklist))) :-
    normalize_sandbox_mode(whitelist, Whitelist),
    normalize_sandbox_mode(blacklist, Blacklist).

test(sandbox_check_goal_rejects_open_hidden_in_setof_generator,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(on,
        (
            catch(sandbox_check_goal(actor, setof(_, open('/tmp/nope', read, _), _)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_rejects_open_hidden_in_forall,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(on,
        (
            catch(sandbox_check_goal(actor, forall(true, open('/tmp/nope', read, _))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_rejects_open_hidden_in_aggregate_all,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(on,
        (
            catch(sandbox_check_goal(actor, aggregate_all(count, open('/tmp/nope', read, _), _Count)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_source_options_allows_load_predicates,
     true(sub_string(SourceText, _, _, _, "rp(left)"))) :-
    with_sandbox_mode(on,
        (
            sandbox_check_source_options(actor, test_node, [load_predicates([rp/1])]),
            source_loader:load_option_text(test_node, load_predicates([rp/1]), SourceText)
        )).

test(sandbox_check_source_text_blacklist_allows_spawn_with_load_predicates_defined_in_same_source) :-
    Source = "pong :- receive({finished -> true}).\nping_pong :- spawn(pong, _, [load_predicates([pong/0])]).\n",
    with_sandbox_mode(blacklist,
        sandbox_check_source_text(actor, test_node, Source)).

test(sandbox_check_goal_allows_nested_spawn_load_uri_option) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~n', []),
            close(Stream),
            with_sandbox_mode(on,
                sandbox_check_goal(actor,
                                   actor:spawn(true, _Pid, [load_uri(File)])))
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(sandbox_check_goal_blacklist_rejects_open,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, open('/tmp/nope', read, _)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_shell,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, shell),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_cd,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, cd('/tmp')),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_halt_one,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, halt(1)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_time_one,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal_in_module(actor, time_blacklist_probe, time(true)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_nl_one,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, nl(user_output)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_writeln_two,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, writeln(user_output, hello)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_print_two,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, print(user_output, 1+2)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_format_three,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor,
                                     format(user_output, '~w', [hello])),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_nb_setval,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, nb_setval(k, open('/tmp/nope', read, _))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_nb_getval,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, nb_getval(k, _Value)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_in_module_blacklist_rejects_imported_shadow_of_blacklisted_predicate,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    next_test_ref(test_ref(Id)),
    format(atom(SourceModule), 'shadow_source_~w', [Id]),
    format(atom(ClientModule), 'shadow_client_~w', [Id]),
    setup_call_cleanup(
        (
            assertz(SourceModule:file_style(_, _) :- true),
            add_import_module(ClientModule, SourceModule, start)
        ),
        with_sandbox_mode(blacklist,
            (
                catch(sandbox_check_goal_in_module(actor, ClientModule,
                                                   file_style(a, b)),
                      Error, true),
                nonvar(Error),
                message_to_string(Error, ErrorString)
            )),
        (
            catch(delete_import_module(ClientModule, SourceModule), _, true),
            catch(abolish(SourceModule:file_style/2), _, true)
        )
    ).

test(sandbox_check_goal_blacklist_allows_dynamic_db_family) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, assertz(q(a)))).

test(sandbox_check_goal_blacklist_allows_safe_dynamic_rule_assertion) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, assertz((q :- true)))).

test(sandbox_check_goal_blacklist_rejects_foreign_module_qualified_assert,
     true(sub_string(ErrorString, _, _, _, "module-qualified goal"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, m:assert(p(a))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_assert_of_qualified_clause_head,
     true(sub_string(ErrorString, _, _, _, "module-qualified clause heads"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, assert(m:p(a))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_unsafe_dynamic_rule_assertion,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor,
                                     assertz((q :- open('/tmp/nope', read, _)))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_rejects_open_hidden_in_catch_recovery,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor,
                                     catch(true, _Error,
                                           open('/tmp/nope', read, _))),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_allows_local_clause_introspection) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal_with_source(actor, actor,
                                       clause(p(_), _Body),
                                       "p(a).\n")).

test(sandbox_check_goal_blacklist_allows_clause_with_variable_head) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, clause(_Head, _Body))).

test(sandbox_check_goal_blacklist_allows_clause_with_callable_head) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, clause(member(_, _), _Body))).

test(sandbox_check_goal_blacklist_rejects_module_qualified_clause_head,
     true(sub_string(ErrorString, _, _, _, "module-qualified"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, clause(m:p(_), _Body)),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_goal_blacklist_allows_format_atom_sink) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, format(atom(_Q), '~q?', [hello]))).

test(sandbox_check_goal_blacklist_allows_format_string_sink) :-
    with_sandbox_mode(blacklist,
        sandbox_check_goal(actor, format(string(_Q), '~w', [42]))).

test(sandbox_check_goal_blacklist_rejects_format_stream,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_goal(actor, format(user_output, '~w', [hello])),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(sandbox_check_source_text_blacklist_rejects_op_directive,
     true(sub_string(ErrorString, _, _, _, "sandboxed"))) :-
    with_sandbox_mode(blacklist,
        (
            catch(sandbox_check_source_text(actor, test_node,
                                            ":- op(400, xfx, foo).\n"),
                  Error, true),
            nonvar(Error),
            message_to_string(Error, ErrorString)
        )).

test(goal_walker_walks_call_eight) :-
    setup_call_cleanup(
        retractall(test_node:walked_goal(_)),
        (
            walk_goal(test_node:record_walked_goal,
                      call(target, a, b, c, d, e, f, g)),
            test_node:walked_goal(target)
        ),
        retractall(test_node:walked_goal(_))
    ).

test(node_public_host_controls_self_url,
     true(URL == 'https://demo.example.org')) :-
    with_http_public_url('demo.example.org', 443, https,
        with_node_server(_URI,
            self_node_url(URL))).

test(node_public_host_nondefault_port_controls_self_url,
     true(URL == 'https://demo.example.org:8443')) :-
    with_http_public_url('demo.example.org', 8443, https,
        with_node_server(_URI,
            self_node_url(URL))).

test(answer_to_json_serializes_statechart_trace_terminal_output) :-
    once(answer_to_json(terminal_output(42, statechart_trace(configuration(['Idle']))), JSON)),
    JSON = json{type:statechart_trace, pid:42, data:"configuration(['Idle'])"}.

test(answer_to_json_preserves_statechart_trace_variable_identity,
     true(Data == "execution((self(A),ponger!ping(A)))")) :-
    Trace = execution((self(Self), ponger ! ping(Self))),
    once(answer_to_json(terminal_output(42, statechart_trace(Trace)), JSON)),
    Data = JSON.data.

test(answer_to_json_uses_anonymous_placeholders_for_unnamed_vars,
     true((YText == "[_,a|_]", XText == "f(A,_)"))) :-
    Row = json{'Y':[_Head, a|_Tail], 'X':f(A, _B), 'A':A},
    once(answer_to_json(success(test_session, [Row], true), JSON)),
    [JSONRow] = JSON.data,
    YText = JSONRow.'Y',
    XText = JSONRow.'X'.

test(answer_to_json_serializes_timing_terminal_output) :-
    once(answer_to_json(terminal_output(42, timing_report("% 7 inferences in 0.003 seconds")), JSON)),
    JSON = json{type:output, pid:42, data:"% 7 inferences in 0.003 seconds", kind:"timing"}.

test(answer_to_json_strips_trailing_tilde_n_from_terminal_output_atom) :-
    once(answer_to_json(terminal_output(42, 'Ping received pong.~n'), JSON)),
    JSON = json{type:output, pid:42, data:"Ping received pong."}.

test(answer_to_json_strips_trailing_newline_from_terminal_output_string) :-
    once(answer_to_json(terminal_output(42, "Ping received pong.\n"), JSON)),
    JSON = json{type:output, pid:42, data:"Ping received pong."}.

test(answer_to_json_marks_io_terminal_output_source) :-
    once(answer_to_json(terminal_io_output(42, "Ping received pong.\n"), JSON)),
    JSON = json{type:output, pid:42, data:"Ping received pong.", source:"io"}.

test(answer_to_json_sanitizes_prolog_stack_context,
     true(sub_string(Data, _, _, _, "sandboxed"))) :-
    Error = error(permission_error(call, sandboxed, open('/tmp/nope', read, _)),
                  context(prolog_stack([]), iso_stream_io)),
    answer_to_json(error(Error), JSON),
    Data = JSON.data.

test(answer_to_json_simplifies_shell_command_sandbox_error,
     true(Data == "Unknown procedure: ls/0")) :-
    Error = error(permission_error(call, sandboxed, ls),
                  context(node_sandbox:reject_forbidden_goal/3, shell_commands)),
    answer_to_json(error(Error), JSON),
    Data = JSON.data.

test(answer_to_json_formats_name_is_in_use_error) :-
    answer_to_json(error(name_is_in_use(echo_actor)), JSON),
    JSON = json{type:error, data:"Name is in use."}.

test(answer_to_json_formats_process_already_has_name_error) :-
    answer_to_json(error(process_already_has_a_name(42)), JSON),
    JSON = json{type:error, data:"Name is in use."}.

test(rewrite_source_text_if_needed_noops_when_blacklist_disabled,
     true(Source == "q :- saved(G), G.")) :-
    setup_call_cleanup(
        (
            setting(node:sandbox, SavedSandbox),
            set_setting(node:sandbox, off)
        ),
        with_public_execution_profile(
            isobase,
            rewrite_source_text_if_needed(test_module, "q :- saved(G), G.", Source)
        ),
        set_setting(node:sandbox, SavedSandbox)
    ).

test(rewrite_goal_if_needed_wraps_time_meta_goal,
     true(Rewritten = time(public_goal_guard:'$sandbox_call'(test_module, Goal)))) :-
    with_sandbox_mode(blacklist,
        with_public_execution_profile(
            actor,
            rewrite_goal_if_needed(test_module, time(Goal), Rewritten)
        )).

test(parse_call_context_json_hides_helper_bindings_behind_anon_assignment,
     true(Template = json{'E':_})) :-
    GoalAtom = '_Tmp=(X=a,throw(oops)),catch(call(_Tmp),E,true)',
    parse_call_context(GoalAtom, _TemplateAtom0, json, false, none,
                       _Goal, Template, _Once, _RequestedTimeout).

test(parse_call_context_json_keeps_non_helper_bindings,
     true(Template = json{'X':_,'Y':_})) :-
    GoalAtom = 'X=a,Y=b',
    parse_call_context(GoalAtom, _TemplateAtom0, json, false, none,
                       _Goal, Template, _Once, _RequestedTimeout).

test(parse_call_context_json_exposes_bindings_from_anon_assignment_used_as_data,
     true(Template = json{'X':_,'Y':_,'Z':_})) :-
    GoalAtom = '_Goals=[(X=a,true),(Y=b,true),(Z=c,true)],parallel(_Goals)',
    parse_call_context(GoalAtom, _TemplateAtom0, json, false, none,
                       _Goal, Template, _Once, _RequestedTimeout).

test(statechart_spawn_load_uri_node_relative) :-
    with_node_server(_URI,
        (
            statechart_spawn(Pid, [
                monitor(true),
                load_uri('statecharts/game.xml')
            ]),
            await_actor_output(Pid, 'IDLE', 1.0),
            send(Pid, play),
            await_actor_output(Pid, 'PLAYING', 1.0),
            exit(Pid, stop)
        )).

test(ws_toplevel_spawn_honors_initial_trace_flag,
     true(TraceData \== "")) :-
    with_node_server_options([auth(dev)], URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{
                    command:toplevel_spawn,
                    options:"[]",
                    trace:"true"
                }),
                ws_receive_json(WS, Spawned),
                get_dict(type, Spawned, "spawned"),
                get_dict(pid, Spawned, ToplevelPid),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"statechart_spawn(Pid, [load_uri('statecharts/game.xml'), monitor(true)])",
                    template:"Pid"
                }),
                ws_receive_json_until_expected_types(
                    WS,
                    ["success", "statechart_trace"],
                    Replies
                ),
                once((member(Success, Replies),
                      get_dict(type, Success, "success"))),
                once((member(TraceReply, Replies),
                      get_dict(type, TraceReply, "statechart_trace"))),
                get_dict(data, TraceReply, TraceData)
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )).

test(ws_toplevel_next_preserves_member_solutions,
     true((Y1 == "[a|_]",
           Y2 == "[_,a|_]",
           Y3 == "[_,_,a|_]"))) :-
    with_node_server_options([auth(dev)], URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, ToplevelPid),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"member(a, Y)",
                    template:"Y",
                    offset:0,
                    limit:1,
                    once:false,
                    format:"json",
                    load_text:""
                }),
                ws_receive_json(WS, Reply1),
                [Row1] = Reply1.data,
                Y1 = Row1.'Y',
                ws_send_json(WS, json{command:toplevel_next, pid:ToplevelPid, limit:1}),
                ws_receive_json(WS, Reply2),
                [Row2] = Reply2.data,
                Y2 = Row2.'Y',
                ws_send_json(WS, json{command:toplevel_next, pid:ToplevelPid, limit:1}),
                ws_receive_json(WS, Reply3),
                [Row3] = Reply3.data,
                Y3 = Row3.'Y'
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )).

test(ws_actor_toplevel_session_exposes_actor_primitives) :-
    with_node_server_options([profile(actor), auth(dev)], URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, ToplevelPid),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"self(Self)",
                    format:"json"
                }),
                ws_receive_json(WS, SelfReply),
                assertion(SelfReply.type == "success"),
                SelfReply.data = [SelfRow],
                assertion(SelfRow.'Self' \== ""),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"(spawn(2 > 1, Child, [monitor(true)]), receive({down(_, Child, Reason) -> true}, [timeout(1), on_timeout(Reason=timeout)]))",
                    format:"json"
                }),
                ws_receive_json(WS, MonitorReply),
                assertion(MonitorReply.type == "success"),
                MonitorReply.data = [MonitorRow],
                assertion(MonitorRow.'Reason' == "true")
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )).

test(ws_actor_toplevel_monitor_notification_visible_to_flush) :-
    with_node_server_options([profile(actor), auth(dev)], URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, ToplevelPid),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"spawn(2 > 1, Child, [monitor(true)])",
                    format:"json"
                }),
                ws_receive_json(WS, SpawnReply),
                assertion(SpawnReply.type == "success"),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"flush",
                    template:"true",
                    format:"json"
                }),
                ws_receive_json_until_expected_types(
                    WS,
                    ["output", "success"],
                    Replies
                ),
                once((member(OutputReply, Replies),
                      get_dict(type, OutputReply, "output"),
                      get_dict(data, OutputReply, OutputData))),
                once((member(SuccessReply, Replies),
                      get_dict(type, SuccessReply, "success"))),
                assertion(sub_string(OutputData, _, _, _, "Shell got down(")),
                assertion(sub_string(OutputData, _, _, _, "true"))
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )).

test(node_json_default_success_bindings,
     true((Type == "success", More == true, Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'member(X,[a,b])', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data,
            More = JSON.more
        )).

test(node_json_reports_bindings_from_anon_assignment_used_as_data,
     true((Type == "success",
           More == false,
           Data = [Row],
           get_dict('X', Row, "a"),
           get_dict('Y', Row, "b")))) :-
    with_node_server(URI,
        (
            Goal = '_Goals=[(X=a,Y=b)],member(G,_Goals),call(G)',
            uri_encoded(query_value, EncGoal, Goal),
            format(atom(URL),
                   '~w/call?goal=~w&offset=0&limit=1&format=json',
                   [URI, EncGoal]),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data,
            More = JSON.more
        )).

test(node_json_goal_with_conjunction,
     true((Type == "success", More == false, Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'true,member(X,[a])', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data,
            More = JSON.more
        )).

test(node_json_default_failure, true(Type == "failure")) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'fail', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type
        )).

test(node_json_default_error,
     true((Type == "error", string(Data), sub_string(Data, _, _, _, "Unknown procedure")))) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'unknown_predicate', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(node_json_default_error_simplified,
     true(Data == "Unknown procedure: unknown_predicate/0")) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'unknown_predicate', 0, 1, URL),
            read_json_answer(URL, JSON),
            Data = JSON.data
        )).

test(node_json_syntax_error_simplified,
     true((Type == "error", sub_string(Data, 0, _, _, "Syntax error: line ")))) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'a(b,)', 0, 1, URL),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(node_json_arithmetic_error_simplified,
     true(Data == "Arithmetic: evaluation error: zero_divisor")) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'S is 1/0', 0, 1, URL),
            read_json_answer(URL, JSON),
            Data = JSON.data
        )).

test(node_json_type_error_simplified,
     true(Data == "Type error: integer expected, found a (an atom)")) :-
    with_node_server(URI,
        (
            json_call_url(URI, 'must_be(integer,a)', 0, 1, URL),
            read_json_answer(URL, JSON),
            Data = JSON.data
        )).

test(node_call_blacklist_rejects_saved_goal_term_via_call,
     true((Type == "error", sub_string(Data, _, _, _, "sandboxed")))) :-
    with_node_server_options([sandbox(blacklist)], URI,
        (
            json_call_url_with_load_text(
                URI,
                'saved(G), call(G)',
                "saved(open('/tmp/nope', read, _)).",
                URL
            ),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(node_call_blacklist_rejects_saved_goal_term_via_direct_variable,
     true((Type == "error", sub_string(Data, _, _, _, "sandboxed")))) :-
    with_node_server_options([sandbox(blacklist)], URI,
        (
            json_call_url_with_load_text(
                URI,
                q,
                "saved(open('/tmp/nope', read, _)). q :- saved(G), G.",
                URL
            ),
            read_json_answer(URL, JSON),
            Type = JSON.type,
            Data = JSON.data
        )).

test(node_json_ignores_template_parameter,
     true((Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server(URI,
        (
            format(atom(URL),
                   '~w/call?goal=member(X,[a])&template=true&offset=0&limit=1&format=json',
                   [URI]),
            read_json_answer(URL, JSON),
            Data = JSON.data
        )).

test(isotope_spawn_returns_pid,
     true((Type == "spawned", integer(Pid)))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(URL), '~w/toplevel_spawn', [URI]),
                read_json_post(URL, _{options:"[]"}, JSON),
                Type = JSON.type,
                Pid = JSON.pid
            ),
            true,
            kill_isotope_session(Pid)
        )).

test(private_isotope_session_rejects_other_principal,
     true((Type == "error",
           PID == Pid,
           sub_string(Data, _, _, _, "Not authorized to access session")))) :-
    alice_isotope_principal_option(AlicePolicy),
    bob_session_user_option(BobPolicy),
    with_node_server_options([auth(private), AlicePolicy, BobPolicy], URI,
        setup_call_cleanup(
            (
                principal_headers("alice", SpawnHeaders),
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post_headers(SpawnURL, SpawnHeaders, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(URI, Pid, 'true', '', CallURL),
                principal_headers("bob", CallHeaders),
                read_json_answer_headers(CallURL, CallHeaders, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_uses_session_load_text,
     true((Type == "success", PID == Pid, More == false,
           Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL,
                               _{options:"[load_text('q(X):-p(X). p(a).')]"},
                               SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=q(X)&limit=1&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data,
                More = JSON.more
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_load_text_parameter,
     true((Type == "success", PID == Pid, Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(URI, Pid, 'q(X)', 'q(X):-p(X). p(a).', URL),
                read_json_answer(URL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_uses_node_shared_db,
     true((Type == "success", PID == Pid, Data = [Row], get_dict('X', Row, "a")))) :-
    with_node_server_options(
        [load_shared_db_text("p(a).\np(b).\n")],
        URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=p(X)&limit=1&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_load_text_persists_across_calls,
     true((Type1 == "success", Type2 == "success",
           Data1 = [Row1], Data2 = [Row2],
           get_dict('X', Row1, "c"), get_dict('X', Row2, "c")))) :-
    with_node_server_options(
        [load_shared_db_text("p(a).\np(b).\n")],
        URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(URI, Pid, 'p(X)', 'p(c).', URL1),
                read_json_answer(URL1, JSON1),
                Type1 = JSON1.type,
                Data1 = JSON1.data,
                format(atom(CallURL2),
                       '~w/toplevel_call?pid=~w&goal=p(X)&limit=1&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL2, JSON2),
                Type2 = JSON2.type,
                Data2 = JSON2.data
            ),
            kill_isotope_session(Pid)
        )).


test(isotope_call_unchanged_load_text_twice,
     true((Type1 == "success", Type2 == "success",
           Data1 = [Row1], Data2 = [Row2],
           get_dict('X', Row1, "a"), get_dict('X', Row2, "a")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL,
                               _{options:"[]", load_text:"q(X):-p(X). p(a)."},
                               SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(URI, Pid, 'q(X)', 'q(X):-p(X). p(a).', URL1),
                read_json_answer(URL1, JSON1),
                Type1 = JSON1.type,
                Data1 = JSON1.data,
                isotope_call_url(URI, Pid, 'q(X)', 'q(X):-p(X). p(a).', URL2),
                read_json_answer(URL2, JSON2),
                Type2 = JSON2.type,
                Data2 = JSON2.data
            ),
            kill_isotope_session(Pid)
        )).


test(isotope_load_text_independent_across_sessions,
     true((Type1 == "success", Type2 == "success",
           Data1 = [Row1], Data2 = [Row2],
           get_dict('X', Row1, "a"), get_dict('Y', Row2, "b")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, Spawn1),
                Pid1 = Spawn1.pid,
                read_json_post(SpawnURL, _{options:"[]"}, Spawn2),
                Pid2 = Spawn2.pid
            ),
            (
                isotope_call_url(URI, Pid1, 'q(X)', 'q(X):-p(X). p(a).', URL1),
                read_json_answer(URL1, JSON1),
                Type1 = JSON1.type,
                Data1 = JSON1.data,
                isotope_call_url(URI, Pid2, 'r(Y)', 'r(Y):-s(Y). s(b).', URL2),
                read_json_answer(URL2, JSON2),
                Type2 = JSON2.type,
                Data2 = JSON2.data
            ),
            (
                kill_isotope_session(Pid1),
                kill_isotope_session(Pid2)
            )
        )).

test(isotope_next_returns_following_solution,
     true((Type1 == "success", More1 == true, Data1 = [Row1], get_dict('X', Row1, "a"),
           Type2 == "success", More2 == false, Data2 = [Row2], get_dict('X', Row2, "b")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=member(X,[a,b])&template=X&limit=1&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, First),
                Type1 = First.type,
                Data1 = First.data,
                More1 = First.more,
                format(atom(NextURL),
                       '~w/toplevel_next?pid=~w&limit=1&format=json',
                       [URI, Pid]),
                read_json_answer(NextURL, Second),
                Type2 = Second.type,
                Data2 = Second.data,
                More2 = Second.more
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_writeln_emits_output_event,
     true((Type == "output", PID == Pid, Data == "hello"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(writeln(hello),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_blacklist_rewrites_asserted_clause_body_guard,
     true((Type == "error", sub_string(Data, _, _, _, "sandboxed")))) :-
    with_node_server_options([sandbox(blacklist)], URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(
                    URI,
                    Pid,
                    '(assertz((q :- saved(G), call(G))), q)',
                    "saved(open('/tmp/nope', read, _)).",
                    CallURL
                ),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_write_emits_output_event,
     true((Type == "output", PID == Pid, Data == "hello"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(write(hello),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_write_strips_trailing_tilde_n_from_output_event,
     true((Type == "output", PID == Pid, Data == "hello"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(write(%27hello~~n%27),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_format_emits_output_event,
     true((Type == "output", PID == Pid, Data == "hello world"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(format(%27hello%20~~w%27,[world]),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_format_strips_trailing_newline_from_output_event,
     true((Type == "output", PID == Pid, Data == "hello world"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(format(%27hello%20~~w~~n%27,[world]),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_writeq_emits_output_event,
     true((Type == "output", PID == Pid, Data == "'hello world'"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(writeq(%27hello%20world%27),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_writeln_strips_trailing_tilde_n_from_output_event,
     true((Type == "output", PID == Pid, Data == "hello"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(writeln(%27hello~~n%27),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_write_term_emits_output_event,
     true((Type == "output", PID == Pid, Data == "'hello world'"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(write_term(%27hello%20world%27,[quoted(true)]),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_nl_emits_output_event,
     true((Type == "output", PID == Pid, Data == "\n"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(nl,true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_time_emits_timing_output_event,
     true((Type == "output",
           PID == Pid,
           Kind == "timing",
           sub_string(Data, 0, 2, _, "% "),
           sub_string(Data, _, _, _, "inferences in"),
           sub_string(Data, _, _, _, "seconds")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(time(true),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Kind = JSON.kind,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_helper_bindings_hidden_behind_anon_assignment_are_not_reported,
     true((Type == "success",
           PID == Pid,
           Rows = [Row],
           get_dict('E', Row, "oops"),
           \+ get_dict('X', Row, _)))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                Goal = '_Tmp=(X=a,throw(oops)),catch(call(_Tmp),E,true)',
                uri_encoded(query_value, EncGoal, Goal),
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=~w&format=json',
                       [URI, Pid, EncGoal]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Rows = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_listing_lists_private_db_only,
     true((Type == "output",
           PID == Pid,
           sub_string(Data, _, _, _, "hello(a)."),
           \+ sub_string(Data, _, _, _, "human(")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(assertz(hello(a)),listing,true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_listing_1_lists_private_db_for_explicit_pid,
     true((Type == "output",
           PID == Pid,
           sub_string(Data, _, _, _, "hello(a)."),
           \+ sub_string(Data, _, _, _, "human(")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(assertz(hello(a)),listing(~w),true)&format=json',
                       [URI, Pid, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_parent_is_not_available_to_clients,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: parent/1")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=parent(A)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_dollar_parent_is_not_available_to_clients,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure"),
           sub_string(Data, _, _, _, "$parent/1")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid,
                uri_encoded(query_value, EncGoal, "'$parent'(A)")
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=~w&format=json',
                       [URI, Pid, EncGoal]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_actor_parent_is_not_available_to_clients,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: actor_parent/1")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=actor_parent(A)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_listing_separates_predicates_with_blank_line,
     true((Type == "output",
           PID == Pid,
           sub_string(Data, _, _, _, "goodbye(b).\n\nhello(a).")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(assertz(hello(a)),assertz(goodbye(b)),listing,true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_listing_starts_with_blank_line,
     true((Type == "output",
           PID == Pid,
           sub_string(Data, 0, _, _, "\nhello(a).")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(assertz(hello(a)),listing,true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_listing_has_no_trailing_blank_line,
     true((Type == "output",
           PID == Pid,
           \+ sub_string(Data, _, _, 0, "\n\n")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(assertz(hello(a)),listing,true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_print_emits_output_event,
     true((Type == "output", PID == Pid, Data == "1+2"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(print(1%2B2),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_display_emits_output_event,
     true((Type == "output", PID == Pid, Data == "+(1,2)"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(display(1%2B2),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_call_write_canonical_emits_output_event,
     true((Type == "output", PID == Pid, Data == "+(1,2)"))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(write_canonical(1%2B2),true)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, JSON),
                Type = JSON.type,
                PID = JSON.pid,
                Data = JSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_prompt_respond_then_pull_success,
     true((PromptType == "prompt", PromptPID == Pid, PromptData == "hello",
           RespondType == "responded",
           PollType == "success", PollPID == Pid, PollMore == false,
           PollData = [Row], get_dict('X', Row, "ok")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(actor:input(hello,X),X=ok)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, PromptJSON),
                PromptType = PromptJSON.type,
                PromptPID = PromptJSON.pid,
                PromptData = PromptJSON.data,
                format(atom(RespondURL),
                       '~w/toplevel_respond?pid=~w&input=ok&format=json',
                       [URI, Pid]),
                read_json_answer(RespondURL, RespondJSON),
                RespondType = RespondJSON.type,
                format(atom(PollURL),
                       '~w/toplevel_poll?pid=~w&format=json',
                       [URI, Pid]),
                read_json_answer(PollURL, PollJSON),
                PollType = PollJSON.type,
                PollPID = PollJSON.pid,
                PollData = PollJSON.data,
                PollMore = PollJSON.more
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_read_respond_then_pull_success,
     true((PromptType == "prompt", PromptPID == Pid, PromptData == "|:",
           RespondType == "responded",
           PollType == "success", PollPID == Pid, PollMore == false,
           PollData = [Row], get_dict('X', Row, "ok")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=(read(X),X=ok)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, PromptJSON),
                PromptType = PromptJSON.type,
                PromptPID = PromptJSON.pid,
                PromptData = PromptJSON.data,
                format(atom(RespondURL),
                       '~w/toplevel_respond?pid=~w&input=ok.&format=json',
                       [URI, Pid]),
                read_json_answer(RespondURL, RespondJSON),
                RespondType = RespondJSON.type,
                format(atom(PullURL),
                       '~w/toplevel_poll?pid=~w&format=json',
                       [URI, Pid]),
                read_json_answer(PullURL, PullJSON),
                PollType = PullJSON.type,
                PollPID = PullJSON.pid,
                PollData = PullJSON.data,
                PollMore = PullJSON.more
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_read_response_requires_period,
     true((PromptType == "prompt", PromptData == "|:",
           RespondType == "error",
           sub_string(RespondData, _, _, _, "Syntax error")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(CallURL),
                       '~w/toplevel_call?pid=~w&goal=read(X)&format=json',
                       [URI, Pid]),
                read_json_answer(CallURL, PromptJSON),
                PromptType = PromptJSON.type,
                PromptData = PromptJSON.data,
                format(atom(RespondURL),
                       '~w/toplevel_respond?pid=~w&input=ok&format=json',
                       [URI, Pid]),
                read_json_answer(RespondURL, RespondJSON),
                RespondType = RespondJSON.type,
                RespondData = RespondJSON.data
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_abort_returns_abort_event,
     true((Type == "abort", PID == Pid))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                format(atom(AbortURL),
                       '~w/toplevel_abort?pid=~w&format=json',
                       [URI, Pid]),
                read_json_answer(AbortURL, JSON),
                Type = JSON.type,
                PID = JSON.pid
            ),
            kill_isotope_session(Pid)
        )).

test(isotope_pull_maps_abort_goal_message_to_abort_event,
     true((Type == "abort", PID == Pid))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                node:isotope_session_queue(Pid, Queue),
                thread_send_message(Queue, '$abort_goal'),
                format(atom(PullURL),
                       '~w/toplevel_poll?pid=~w&format=json',
                       [URI, Pid]),
                read_json_answer(PullURL, JSON),
                Type = JSON.type,
                PID = JSON.pid
            ),
            kill_isotope_session(Pid)
        )).


test(isotope_loaded_program_read_prompt_then_success,
     true((Type1 == "output", PID1 == Pid, Data1 == "prompting",
           Type2 == "prompt", PID2 == Pid, Data2 == "|:",
           Type3 == "responded",
           Type4 == "success", PID4 == Pid, More4 == false,
           Data4 = [Row4], get_dict('X', Row4, "ok")))) :-
    with_node_server(URI,
        setup_call_cleanup(
            (
                format(atom(SpawnURL), '~w/toplevel_spawn', [URI]),
                read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                Pid = SpawnJSON.pid
            ),
            (
                isotope_call_url(URI, Pid, 'loop_2(X)',
                                 "loop_2(X) :- writeln(prompting), read(X).",
                                 CallURL),
                read_json_answer(CallURL, JSON1),
                Type1 = JSON1.type,
                PID1 = JSON1.pid,
                Data1 = JSON1.data,
                format(atom(PullURL), '~w/toplevel_poll?pid=~w&format=json', [URI, Pid]),
                read_json_answer(PullURL, JSON2),
                Type2 = JSON2.type,
                PID2 = JSON2.pid,
                Data2 = JSON2.data,
                format(atom(RespondURL),
                       '~w/toplevel_respond?pid=~w&input=ok.&format=json',
                       [URI, Pid]),
                read_json_answer(RespondURL, JSON3),
                Type3 = JSON3.type,
                read_json_answer(PullURL, JSON4),
                Type4 = JSON4.type,
                PID4 = JSON4.pid,
                Data4 = JSON4.data,
                More4 = JSON4.more
            ),
            kill_isotope_session(Pid)
        )).

test(rpc_2_returns_all_solutions, set(X == [a, b, c])) :-
    with_node_server(URI, rpc(URI, member(X, [a, b, c]))).

test(rpc_3_honors_limit, set(X == [a, b, c])) :-
    with_node_server(URI, rpc(URI, member(X, [a, b, c]), [limit(1)])).

test(rpc_3_once_true_returns_first_slice_only, set(X == [a])) :-
    with_node_server(URI,
                     rpc(URI, member(X, [a, b, c]), [limit(1), once(true)])).

test(rpc_3_failure, [fail]) :-
    with_node_server(URI, rpc(URI, fail, [limit(1)])).

test(rpc_3_error, [throws(test_error)]) :-
    with_node_server(URI, rpc(URI, throw(test_error), [limit(1)])).

test(rpc_3_load_text, set(X == [a, b])) :-
    with_node_server(URI,
        rpc(URI, p(X), [load_text('p(a). p(b).')])).

test(rpc_3_load_list, set(X == [a, b])) :-
    with_node_server(URI,
        rpc(URI, p(X), [load_list([p(a), p(b)])])).

test(rpc_3_load_predicates, set(X == [left, right])) :-
    with_node_server(URI,
        rpc(URI, test_node:rp(X), [load_predicates([rp/1])])).

test(rpc_3_load_uri, set(X == [a, b])) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server(URI,
                rpc(URI, u(X), [load_uri(File)]))
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(rpc_3_localhost_with_load_uri, set(X == [a, b])) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'v(a).~nv(b).~n', []),
            close(Stream),
            with_node_server(_URI,
                rpc(localhost, v(X), [load_uri(File)]))
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(node_root_serves_shared_db, true(Source == "w(a).\nw(b).\n")) :-
    with_node_server_options(
        [load_shared_db_text("w(a).\nw(b).\n")],
        URI,
        read_text(URI, Source)
    ).

test(node_root_serves_default_shared_db) :-
    with_node_server_options(
        [],
        URI,
        (
            read_text(URI, Source),
            once(sub_string(Source, _, _, _, "echo_server :-")),
            once(sub_string(Source, _, _, _, "echo_actor :-"))
        )
    ).

test(default_shared_db_visible_in_user_module) :-
    with_node_server_options(
        [],
        _URI,
        (
            once(current_predicate(user:echo_server/0)),
            once(current_predicate(user:echo_actor/0))
        )
    ).

test(shared_db_text_visible_in_user_module, true(P == [a, b])) :-
    node:shared_db(Prev),
    setup_call_cleanup(
        node:set_node_shared_db("p(a).\np(b).\n"),
        setof(X, user:p(X), P),
        node:set_node_shared_db(Prev)
    ).

test(rpc_3_uses_shared_db_without_load_options, set(X == [a, b])) :-
    with_node_server_options(
        [load_shared_db_text("shared_q(a).\nshared_q(b).\n")],
        URI,
        rpc(URI, shared_q(X))
    ).

test(rpc_3_uses_per_node_shared_db_when_two_nodes_run,
     true((Answer1 == success([a], false),
           Answer2 == success([b], false)))) :-
    with_node_server_options([load_shared_db_text("p(a).\n")], URI1,
        with_node_server_options([load_shared_db_text("p(b).\n")], URI2,
            (
                call_url(URI1, 'p(X)', 'X', 0, 1, '', none, URL1),
                read_answer(URL1, Answer1),
                call_url(URI2, 'p(X)', 'X', 0, 1, '', none, URL2),
                read_answer(URL2, Answer2)
            ))).

test(rpc_3_load_uri_from_node_root_shared_db, set(X == [a, b])) :-
    with_node_server_options(
        [load_shared_db_text("root_u(a).\nroot_u(b).\n")],
        URI,
        rpc(URI, root_u(X), [load_uri(URI)])
    ).

test(rpc_3_load_uri_from_node_root_shared_db_when_origin_allowlisted,
     set(X == [a, b])) :-
    pick_free_port(Port),
    format(atom(URI), 'http://localhost:~w', [Port]),
    node(Port, [
        load_shared_db_text("root_allowed(a).\nroot_allowed(b).\n"),
        load_uri_allowed_origins([URI])
    ]),
    setup_call_cleanup(
        true,
        with_node_port_context(Port,
                               rpc(URI, root_allowed(X), [load_uri(URI)])),
        stop_node_server(Port)
    ).

test(rpc_3_load_uri_rejects_local_file_when_origin_allowlist_active,
     [throws(error(permission_error(load, source_uri, _), _))]) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server_options(
                [load_uri_allowed_origins(['https://n1.elfenbenstornet.se'])],
                URI,
                (
                    parse_url(URI, Parts),
                    memberchk(port(Port), Parts),
                    with_node_port_context(Port,
                                           rpc(URI, u(_X), [load_uri(File)]))
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(rpc_3_load_uri_rejects_external_origin_when_origin_allowlist_active,
     [throws(error(permission_error(load, source_uri, 'https://example.com/demo.pl'), _))]) :-
    with_node_server_options(
        [load_uri_allowed_origins(['http://localhost:65535'])],
        URI,
        (
            parse_url(URI, Parts),
            memberchk(port(Port), Parts),
            with_node_port_context(
                Port,
                rpc(URI, demo(_X), [load_uri('https://example.com/demo.pl')])
            )
        )
    ).

test(sandbox_spawn_option_allows_allowlisted_public_node_url) :-
    start_node_server(
        [ sandbox(blacklist),
          load_uri_allowed_origins(['https://n4.elfenbenstornet.se'])
        ],
        Port,
        _URI
    ),
    setup_call_cleanup(
        true,
        with_node_port_context(
            Port,
            node_sandbox:sandbox_check_spawn_options(actor, [node('https://n4.elfenbenstornet.se')])
        ),
        stop_node_server(Port)
    ).

test(sandbox_spawn_option_rejects_non_allowlisted_public_node_url,
     [throws(error(permission_error(option, sandboxed, node('https://n4.elfenbenstornet.se')), _))]) :-
    start_node_server(
        [ sandbox(blacklist),
          load_uri_allowed_origins(['https://n3.elfenbenstornet.se'])
        ],
        Port,
        _URI
    ),
    setup_call_cleanup(
        true,
        with_node_port_context(
            Port,
            node_sandbox:sandbox_check_spawn_options(actor, [node('https://n4.elfenbenstornet.se')])
        ),
        stop_node_server(Port)
    ).

test(rpc_3_uses_shared_db_loaded_from_file, set(X == [a, b])) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'file_q(a).~nfile_q(b).~n', []),
            close(Stream),
            with_node_server_options(
                [load_shared_db_file(File)],
                URI,
                rpc(URI, file_q(X))
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(rpc_3_uses_shared_db_loaded_from_uri, set(X == [a, b])) :-
    with_node_server_options(
        [load_shared_db_text("uri_q(a).\nuri_q(b).\n")],
        SourceNodeURI,
        with_node_server_options(
            [load_shared_db_uri(SourceNodeURI)],
            URI,
            rpc(URI, uri_q(X))
        )
    ).

test(node_resident_services_are_discoverable_via_rpc,
     true(ServicesSorted == [
         counter-meta(actor, protocol(count_v1)),
         pubsub_service-meta(actor, protocol(pubsub_v1))
     ])) :-
    service_directory_file(File),
    with_node_server_options(
        [load_shared_db_file(File)],
        URI,
        (
            findall(Name-Meta, rpc(URI, service(Name, Meta)), Services),
            sort(Services, ServicesSorted)
        )
    ).

test(node_resident_counter_service_exposes_shared_state,
     true((First == 1, Third == 3))) :-
    service_directory_file(File),
    with_node_server_options(
        [load_shared_db_file(File)],
        URI,
        setup_call_cleanup(
            start_counter_service(_CounterPid),
            (
                self(Self),
                send(counter@URI, count(Self)),
                receive({
                    count(First) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                spawn(counter_service_bump(URI, Self), _BumpPid, [link(false)]),
                receive({
                    counter_bumped -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                send(counter@URI, count(Self)),
                receive({
                    count(Third) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ])
            ),
            stop_example_services
        )
    ).

test(node_resident_pubsub_service_coordinates_clients,
     true(MessagesSorted == [hello, hello])) :-
    service_directory_file(File),
    with_node_server_options(
        [load_shared_db_file(File)],
        URI,
        setup_call_cleanup(
            start_pubsub_service(_PubSubPid),
            (
                self(Self),
                next_test_ref(Ref),
                spawn(pubsub_service_subscriber(URI, Self, Ref), SubPid1, [link(false)]),
                spawn(pubsub_service_subscriber(URI, Self, Ref), SubPid2, [link(false)]),
                receive({
                    subscribed(Ref, Subscriber1) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                receive({
                    subscribed(Ref, Subscriber2) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                sort([Subscriber1, Subscriber2], SubscriberPids),
                sort([SubPid1, SubPid2], SubscriberPids),
                send(pubsub_service@URI, publish(hello)),
                receive({
                    delivered(Ref, Delivered1, Message1) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                receive({
                    delivered(Ref, Delivered2, Message2) -> true
                }, [
                    timeout(1),
                    on_timeout(fail)
                ]),
                sort([Delivered1, Delivered2], DeliveredPids),
                sort([SubPid1, SubPid2], DeliveredPids),
                msort([Message1, Message2], MessagesSorted)
            ),
            stop_example_services
        )
    ).

test(public_actor_client_sees_service_as_sendable_but_not_client_registered,
     true((Visible == "undefined", Count == "1"))) :-
    service_directory_file(File),
    with_node_server_options(
        [profile(actor), sandbox(off), load_shared_db_file(File)],
        URI,
        setup_call_cleanup(
            start_counter_service(_CounterPid),
            setup_call_cleanup(
                ws_open(URI, WS),
                (
                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Spawned),
                    get_dict(pid, Spawned, ToplevelPid),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:ToplevelPid,
                        goal:"whereis(counter, P), unregister(counter), self(S), counter ! count(S), receive({count(N) -> true}, [timeout(1), on_timeout(fail)])",
                        template:"P-N"
                    }),
                    ws_receive_json(WS, Reply),
                    get_dict(type, Reply, "success"),
                    get_dict(data, Reply, [Row]),
                    get_dict('P', Row, Visible),
                    get_dict('N', Row, Count)
                ),
                catch(ws_close(WS, 1000, done), _, true)
            ),
            stop_example_services
        )
    ).

test(public_actor_client_cannot_access_service_registry_predicates) :-
    with_node_server_options(
        [profile(actor), sandbox(off)],
        URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, ToplevelPid),

                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"whereis_service(counter, P)",
                    template:"P"
                }),
                ws_receive_json(WS, WhereisReply),
                get_dict(type, WhereisReply, "error"),
                get_dict(data, WhereisReply, WhereisError),

                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"unregister_service(counter)",
                    template:"true"
                }),
                ws_receive_json(WS, UnregisterReply),
                get_dict(type, UnregisterReply, "error"),
                get_dict(data, UnregisterReply, UnregisterError),

                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"self(S), register_service(counter, S)",
                    template:"S"
                }),
                ws_receive_json(WS, RegisterReply),
                get_dict(type, RegisterReply, "error"),
                get_dict(data, RegisterReply, RegisterError)
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )
    ),
    once(sub_string(WhereisError, _, _, _, "service registration is reserved")),
    once(sub_string(UnregisterError, _, _, _, "service registration is reserved")),
    once(sub_string(RegisterError, _, _, _, "service registration is reserved")).

test(public_ws_clients_have_isolated_registered_name_namespaces,
     true((Self1 == Pid1,
           Self2 == Pid2,
           Self1 \== Self2,
           After1 == "undefined",
           After2 == Pid2))) :-
    with_node_server_options(
        [profile(actor), sandbox(off)],
        URI,
        setup_call_cleanup(
            (ws_open(URI, WS1), ws_open(URI, WS2)),
            (
                ws_send_json(WS1, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS1, Spawned1),
                get_dict(pid, Spawned1, ToplevelPid1),
                ws_send_json(WS2, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS2, Spawned2),
                get_dict(pid, Spawned2, ToplevelPid2),

                ws_send_json(WS1, json{
                    command:toplevel_call,
                    pid:ToplevelPid1,
                    goal:"self(S), register(foo, S), whereis(foo, P)",
                    template:"S-P"
                }),
                ws_receive_json(WS1, Reply1),
                get_dict(type, Reply1, "success"),
                get_dict(data, Reply1, [Row1]),
                get_dict('S', Row1, Self1),
                get_dict('P', Row1, Pid1),

                ws_send_json(WS2, json{
                    command:toplevel_call,
                    pid:ToplevelPid2,
                    goal:"self(S), register(foo, S), whereis(foo, P)",
                    template:"S-P"
                }),
                ws_receive_json(WS2, Reply2),
                get_dict(type, Reply2, "success"),
                get_dict(data, Reply2, [Row2]),
                get_dict('S', Row2, Self2),
                get_dict('P', Row2, Pid2),

                ws_send_json(WS1, json{
                    command:toplevel_call,
                    pid:ToplevelPid1,
                    goal:"unregister(foo), whereis(foo, P)",
                    template:"P"
                }),
                ws_receive_json(WS1, AfterReply1),
                get_dict(type, AfterReply1, "success"),
                get_dict(data, AfterReply1, [AfterRow1]),
                get_dict('P', AfterRow1, After1),

                ws_send_json(WS2, json{
                    command:toplevel_call,
                    pid:ToplevelPid2,
                    goal:"whereis(foo, P)",
                    template:"P"
                }),
                ws_receive_json(WS2, AfterReply2),
                get_dict(type, AfterReply2, "success"),
                get_dict(data, AfterReply2, [AfterRow2]),
                get_dict('P', AfterRow2, After2)
            ),
            ( catch(ws_close(WS1, 1000, done), _, true),
              catch(ws_close(WS2, 1000, done), _, true)
            )
        )
    ).

test(public_actor_client_actors_list_is_namespace_scoped,
     true((SortedVisible == SortedExpected,
           \+ member(ToplevelPid2, VisiblePids),
           \+ member(OwnerPid, VisiblePids)))) :-
    with_node_server_options(
        [profile(actor), sandbox(off)],
        URI,
        setup_call_cleanup(
            spawn(sleep(5), OwnerPid, [link(false)]),
            setup_call_cleanup(
                (ws_open(URI, WS1), ws_open(URI, WS2)),
                (
                    ws_send_json(WS1, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS1, Spawned1),
                    get_dict(pid, Spawned1, ToplevelPid1),

                    ws_send_json(WS2, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS2, Spawned2),
                    get_dict(pid, Spawned2, ToplevelPid2),

                    ws_send_json(WS1, json{
                        command:toplevel_call,
                        pid:ToplevelPid1,
                        goal:"self(Self), spawn(sleep(5), Child, [link(false)]), actors(Pids)",
                        template:"Self-Child-Pids"
                    }),
                    ws_receive_json(WS1, Reply),
                    get_dict(type, Reply, "success"),
                    get_dict(data, Reply, [Row]),
                    get_dict('Self', Row, SelfPid0),
                    pid_value(SelfPid0, SelfPid),
                    get_dict('Child', Row, ChildPid0),
                    pid_value(ChildPid0, ChildPid),
                    get_dict('Pids', Row, VisiblePids0),
                    pid_list_value(VisiblePids0, VisiblePids),
                    sort(VisiblePids, SortedVisible),
                    sort([SelfPid, ChildPid], SortedExpected)
                ),
                (
                    catch(ws_close(WS1, 1000, done), _, true),
                    catch(ws_close(WS2, 1000, done), _, true),
                    (   nonvar(ChildPid)
                    ->  catch(exit(ChildPid, kill), _, true)
                    ;   true
                    )
                )
            ),
            catch(exit(OwnerPid, kill), _, true)
        )
    ).

test(public_actor_client_listing_by_pid_is_namespace_scoped,
     true((sub_string(OwnOutput, _, _, _, "hello(a)."),
           OwnFinalType == "success",
           OtherType == "error",
           sub_string(OtherError, _, _, _, "current public namespace")))) :-
    with_node_server_options(
        [profile(actor), sandbox(off)],
        URI,
        setup_call_cleanup(
            (ws_open(URI, WS1), ws_open(URI, WS2)),
            (
                ws_send_json(WS1, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS1, Spawned1),
                get_dict(pid, Spawned1, ToplevelPid1),

                ws_send_json(WS2, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS2, Spawned2),
                get_dict(pid, Spawned2, ToplevelPid2),

                ws_send_json(WS1, json{
                    command:toplevel_call,
                    pid:ToplevelPid1,
                    goal:"spawn(receive({stop -> true}), Child, [load_text(\"hello(a).\"), link(false)]), Child=Child",
                    template:"Child"
                }),
                ws_receive_json(WS1, SpawnChildReply),
                get_dict(type, SpawnChildReply, "success"),
                get_dict(data, SpawnChildReply, [SpawnChildRow]),
                get_dict('Child', SpawnChildRow, ChildPid0),
                pid_value(ChildPid0, ChildPid),

                format(string(OwnListingGoal), "listing(~q)", [ChildPid]),
                ws_send_json(WS1, json{
                    command:toplevel_call,
                    pid:ToplevelPid1,
                    goal:OwnListingGoal,
                    template:"true"
                }),
                ws_receive_json_until_expected_types(WS1, ["output", "success"], [], 20, OwnReplies),
                once((
                    member(OwnOutputReply, OwnReplies),
                    get_dict(type, OwnOutputReply, "output"),
                    get_dict(data, OwnOutputReply, OwnOutput)
                )),
                once((
                    member(OwnFinalReply, OwnReplies),
                    get_dict(type, OwnFinalReply, OwnFinalType),
                    OwnFinalType \== "output"
                )),

                format(string(OtherListingGoal), "listing(~q)", [ChildPid]),
                ws_send_json(WS2, json{
                    command:toplevel_call,
                    pid:ToplevelPid2,
                    goal:OtherListingGoal,
                    template:"true"
                }),
                ws_receive_json(WS2, OtherReply),
                get_dict(type, OtherReply, OtherType),
                get_dict(data, OtherReply, OtherError)
            ),
            (
                catch(ws_close(WS1, 1000, done), _, true),
                catch(ws_close(WS2, 1000, done), _, true),
                (   nonvar(ChildPid)
                ->  catch(exit(ChildPid, kill), _, true)
                ;   true
                )
            )
        )
    ).

test(rpc_3_shared_db_and_load_text_boundary, true((P == [a, b], W == [aristotle-pythias, socrates-xantippa]))) :-
    with_node_server_options(
        [load_shared_db_text("p(a). p(b).")],
        URI,
        (
            findall(X,
                    rpc(URI, p(X), [load_text("wife(socrates, xantippa). wife(aristotle, pythias).")]),
                    P),
            findall(A-B,
                    rpc(URI, wife(A, B), [load_text("wife(socrates, xantippa). wife(aristotle, pythias).")]),
                    W0),
            sort(W0, W)
        )
    ).

test(call_cache_key_includes_load_text,
     true((A1 == success([a], true),
           A2 == success([d], false)))) :-
    with_node_server(URI,
        (
            call_url(URI, 'q(X)', 'X', 0, 1, 'q(a). q(b).', none, URL1),
            read_answer(URL1, A1),
            call_url(URI, 'q(X)', 'X', 1, 1, 'q(c). q(d).', none, URL2),
            read_answer(URL2, A2)
        )).

test(call_cache_eviction_stops_evicted_actor,
     true((A1 == success([a], true),
           A2 == success([c], true)))) :-
    with_node_cache_size(1,
        with_node_server(URI,
            setup_call_cleanup(
                clear_node_cache,
                (
                    call_url(URI, 'q(X)', 'X', 0, 1, 'q(a). q(b).', none, URL1),
                    read_answer(URL1, A1),
                    once(node:cache(_, _, EvictedPid)),
                    call_url(URI, 'q(X)', 'X', 0, 1, 'q(c). q(d).', none, URL2),
                    read_answer(URL2, A2),
                    wait_until_pid_stopped(EvictedPid, 200)
                ),
                clear_node_cache
            ))).

test(call_cache_is_isolated_per_node,
     true((A1 == success([a], true),
           A2 == success([c], true),
           Pid1Stopped == false))) :-
    with_node_server_options([cache_size(1)], URI1,
        with_node_server_options([cache_size(1)], URI2,
            setup_call_cleanup(
                clear_node_cache,
                (
                    call_url(URI1, 'q(X)', 'X', 0, 1, 'q(a). q(b).', none, URL1),
                    read_answer(URL1, A1),
                    once(node:cache(_, _, Pid1)),
                    call_url(URI2, 'q(X)', 'X', 0, 1, 'q(c). q(d).', none, URL2),
                    read_answer(URL2, A2),
                    (   pid_stopped(Pid1)
                    ->  Pid1Stopped = true
                    ;   Pid1Stopped = false
                    )
                ),
                clear_node_cache
            ))).

test(call_timeout_parameter_honored, true(Answer == error(timeout))) :-
    with_node_timeout(1,
        with_node_server(URI,
            (
                call_url(URI, 'sleep(0.05)', 'true', 0, 1, '', 0.01, URL),
                read_answer(URL, Answer)
            ))).

test(call_timeout_owner_cap_wins, true(Answer == error(timeout))) :-
    with_node_timeout(0.01,
        with_node_server(URI,
            (
                call_url(URI, 'sleep(0.05)', 'true', 0, 1, '', 1, URL),
                read_answer(URL, Answer)
            ))).

test(call_timeout_is_isolated_per_node,
     true((Answer1 == error(timeout),
           Answer2 == success([true], false)))) :-
    with_node_server_options([timeout(0.01)], URI1,
        with_node_server_options([timeout(1)], URI2,
            (
                call_url(URI1, 'sleep(0.05)', 'true', 0, 1, '', 1, URL1),
                read_answer(URL1, Answer1),
                call_url(URI2, 'sleep(0.05)', 'true', 0, 1, '', 1, URL2),
                read_answer(URL2, Answer2)
            ))).

test(node_json_timeout_message,
     true((sub_string(Body, _, _, _, "\"type\":\"error\""),
           sub_string(Body, _, _, _, "Timeout exceeded")))) :-
    with_node_timeout(1,
        with_node_server(URI,
            (
                parse_url(URI, Parts),
                parse_url(URL, [
                    path('/call'),
                    search([goal='sleep(0.05)', offset=0, limit=1, timeout='0.01'])
                  | Parts
                ]),
                read_text(URL, Body)
            ))).

test(call_once_parameter_honored, true(Answer == success([a], false))) :-
    with_node_server(URI,
        (
            call_url(URI, 'member(X,[a,b,c])', 'X', 0, 1, '',
                     none, true, URL),
            read_answer(URL, Answer)
        )).

test(rpc_3_timeout_requests_remote_timeout, [throws(timeout)]) :-
    with_node_timeout(1,
        with_node_server(URI,
            rpc(URI, sleep(0.05), [timeout(0.01)]))).

test(rpc_3_timeout_owner_cap_wins, [throws(timeout)]) :-
    with_node_timeout(0.01,
        with_node_server(URI,
            rpc(URI, sleep(0.05), [timeout(1)]))).

test(rpc_3_http_timeout_option_is_transport, true) :-
    with_node_server(URI,
        once(rpc(URI, true, [http_timeout(1)]))).

test(promise_3_and_yield_2,
     true((integer(Ref),
           Ref >= 1000000000,
           Ref =< 9999999999,
           Answer == success([true], false)))) :-
    with_node_server(URI,
        (
            promise(URI, true, Ref),
            yield(Ref, Answer)
        )).

test(promise_4_options, true(Answer == success([2], true))) :-
    with_node_server(URI,
        (
            promise(URI, member(X, [1, 2, 3]), Ref,
                    [template(X), offset(1), limit(1)]),
            yield(Ref, Answer)
        )).

test(yield_3_timeout_default_succeeds_with_unbound, true(var(Message))) :-
    yield(4242424242, Message, [timeout(0.01)]).

test(yield_3_timeout_on_timeout_goal, true(Result == timed_out)) :-
    yield(4242424242, _Message,
          [timeout(0.01), on_timeout(Result = timed_out)]).

%  ---- WebSocket remote spawn tests ----

%% Test: local session actor can find shared DB predicate q/1
test(local_session_spawn_shared_db_query,
     true(Data == [a])) :-
    with_node_server_options(
        [load_shared_db_text("q(a).\nq(b).\nq(c).\n")],
        _URI,
        (
            toplevel_spawn(Pid, [session(true), monitor(true)]),
            toplevel_call(Pid, q(X), [template(X), limit(1)]),
            receive({
                success(_, Data0, _) -> Data = Data0
                ;
                failure(_) -> Data = '$FAILURE'
                ;
                error(_, Err) -> Data = '$ERROR'(Err)
            }, [timeout(5), on_timeout(Data = '$TIMEOUT')]),
            catch(demonitor(Pid), _, true),
            exit(Pid, kill)
        )).

%% Test: WS remote spawn with a built-in (no shared DB needed)
test(ws_remote_spawn_builtin_query,
     true(Data == [1])) :-
    with_node_server(
        URI,
        (
            toplevel_spawn(Pid, [session(true), monitor(true), node(URI)]),
            toplevel_call(Pid, member(X, [1,2,3]), [template(X), limit(1)]),
            receive({
                success(_, Data0, _) -> Data = Data0
                ;   failure(_) -> Data = '$FAILURE'
                ;   error(_, Err) -> Data = '$ERROR'(Err)
            }, [timeout(5), on_timeout(Data = '$TIMEOUT')]),
            catch(demonitor(Pid), _, true),
            catch(exit(Pid, kill), _, true)
        )).

%% Test: WS remote spawn with shared DB predicate q/1
test(ws_remote_spawn_shared_db_query,
     true(Data == [a])) :-
    with_node_server_options(
        [load_shared_db_text("q(a).\nq(b).\nq(c).\n")],
        URI,
        (
            toplevel_spawn(Pid, [session(true), monitor(true), node(URI)]),
            toplevel_call(Pid, q(X), [template(X), limit(1)]),
            receive({
                success(_, Data0, _) -> Data = Data0
                ;   failure(_) -> Data = '$FAILURE'
                ;   error(_, Err) -> Data = '$ERROR'(Err)
            }, [timeout(5), on_timeout(Data = '$TIMEOUT')]),
            catch(demonitor(Pid), _, true),
            catch(exit(Pid, kill), _, true)
        )).

test(ws_remote_spawn_call_does_not_bind_caller_variables,
     true((StillVar == true,
           Data == [q(a)],
           More == true))) :-
    with_node_server_options(
        [load_shared_db_text("q(a).\nq(b).\nq(c).\n")],
        URI,
        (
            toplevel_spawn(Pid, [session(true), monitor(true), node(URI)]),
            toplevel_call(Pid, q(X), [limit(1)]),
            (   var(X)
            ->  StillVar = true
            ;   StillVar = false
            ),
            receive({
                success(_, Data0, More0) ->
                    Data = Data0,
                    More = More0
                ;   failure(_) ->
                    Data = '$FAILURE',
                    More = false
                ;   error(_, Err) ->
                    Data = '$ERROR'(Err),
                    More = false
            }, [timeout(5), on_timeout((Data = '$TIMEOUT', More = false))]),
            catch(demonitor(Pid), _, true),
            catch(exit(Pid, kill), _, true)
        )).

%% Test: distributed actor send/2 is no longer available through the /call
%% ISOBASE route, even when targeting a live remote session.
test(call_route_rejects_remote_session_send,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: send/2")))) :-
    with_node_server(URI1,
        with_node_server(URI2,
            (
                atom_concat(URI1, '/toplevel_spawn', SpawnURL),
                read_json_post(SpawnURL, json{options:"[session(true)]"}, Spawned),
                get_dict(pid, Spawned, SessionPid),

                format(atom(RemoteSendGoal),
                       "send(~w@'~w', hello)",
                       [SessionPid, URI1]),
                json_call_url(URI2, RemoteSendGoal, 0, 1, RemoteSendURL),
                read_json_answer(RemoteSendURL, RemoteSendJSON),
                Type = RemoteSendJSON.type,
                Data = RemoteSendJSON.data
            ))).

%% Test: HTTP ISOTOPE sessions reject actor spawning once profile ceilings are
%% enforced.
test(isotope_call_rejects_actor_spawn_on_http_isotope_session,
     true((CallType == "error",
           sub_string(CallData, _, _, _, "Unknown procedure: spawn/3")))) :-
    with_node_server(URI,
        (
            atom_concat(URI, '/toplevel_spawn', SpawnURL),
            read_json_post(SpawnURL, json{options:"[session(true)]"}, Spawned),
            get_dict(pid, Spawned, SessionPid),

            isotope_call_url(URI, SessionPid,
                             'spawn(output(hi), ChildPid, [link(false)])',
                             '', CallURL),
            read_json_answer(CallURL, CallJSON),
            CallType = CallJSON.type,
            CallData = CallJSON.data
        )).

test(isotope_call_rejects_statechart_spawn_on_http_isotope_session,
     true((CallType == "error",
           sub_string(CallData, _, _, _, "Unknown procedure: statechart_spawn/2")))) :-
    with_node_server(URI,
        (
            atom_concat(URI, '/toplevel_spawn', SpawnURL),
            read_json_post(SpawnURL, json{options:"[session(true)]"}, Spawned),
            get_dict(pid, Spawned, SessionPid),

            atomics_to_string([
                "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
                "  <state id=\"Idle\">\n",
                "    <onentry>output('IDLE')</onentry>\n",
                "  </state>\n",
                "</statechart>\n"
            ], StatechartText),
            format(atom(GoalAtom),
                   "statechart_spawn(StatechartPid, [load_text(~q), monitor(true)])",
                   [StatechartText]),
            isotope_call_url(URI, SessionPid, GoalAtom, '', CallURL),
            read_json_answer(CallURL, CallJSON),
            CallType = CallJSON.type,
            CallData = CallJSON.data
        )).

%% Test: an existing inbound browser websocket does not widen the /call route
%% beyond the ISOBASE profile ceiling.
test(call_route_rejects_remote_session_send_with_existing_inbound_ws,
     true((Type == "error",
           sub_string(Data, _, _, _, "Unknown procedure: send/2")))) :-
    with_node_server(URI1,
        with_node_server(URI2,
            setup_call_cleanup(
                ws_open(URI1, BrowserWS),
                (
                    atom_concat(URI1, '/toplevel_spawn', SpawnURL),
                    read_json_post(SpawnURL, json{options:"[session(true)]"}, Spawned),
                    get_dict(pid, Spawned, SessionPid),

                    format(atom(RemoteSendGoal),
                           "send(~w@'~w', hello)",
                           [SessionPid, URI1]),
                    json_call_url(URI2, RemoteSendGoal, 0, 1, RemoteSendURL),
                    read_json_answer(RemoteSendURL, RemoteSendJSON),
                    Type = RemoteSendJSON.type,
                    Data = RemoteSendJSON.data
                ),
                catch(ws_close(BrowserWS, 1000, "done"), _, true)
            ))).

%% Test: exact shell flow over /ws with a remote actor replying back to the
%% live session node over a second inbound websocket connection.
test(ws_remote_echo_actor_roundtrip_between_nodes,
     true((OutputData == "Shell got echo(hello)",
           FlushType == "success"))) :-
    with_node_server(URI1,
        with_node_server(URI2,
            setup_call_cleanup(
                ws_open(URI1, WS),
                (
                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Spawned),
                    get_dict(pid, Spawned, ToplevelPid),

                    format(string(SpawnGoal),
                           "spawn(echo_actor, Pid, [node('~w'), monitor(true)])",
                           [URI2]),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:ToplevelPid,
                        goal:SpawnGoal,
                        template:"Pid"
                    }),
                    ws_receive_json(WS, SpawnReply),
                    get_dict(data, SpawnReply, [SpawnRow]),
                    get_dict('Pid', SpawnRow, EchoPid),

                    format(string(EchoGoal),
                           "send(~s, echo(~w@'~w', hello))",
                           [EchoPid, ToplevelPid, URI1]),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:ToplevelPid,
                        goal:EchoGoal,
                        template:"true"
                    }),
                    ws_receive_json(WS, _EchoReply),

                    ws_flush_until_output(WS, ToplevelPid, OutputData, FlushType)
                ),
                catch(ws_close(WS, 1000, done), _, true)
            ))).

%% Test: WS remote toplevel_spawn forwards load_text option to remote actor
test(ws_remote_spawn_load_text_option,
     true(Data == [a])) :-
    with_node_server(
        URI,
        (
            toplevel_spawn(Pid, [
                session(true),
                monitor(true),
                node(URI),
                load_text("hello(a). hello(b).")
            ]),
            toplevel_call(Pid, hello(X), [template(X), limit(1)]),
            receive({
                success(_, Data0, _) -> Data = Data0
                ;   failure(_) -> Data = '$FAILURE'
                ;   error(_, Err) -> Data = '$ERROR'(Err)
            }, [timeout(5), on_timeout(Data = '$TIMEOUT')]),
            catch(demonitor(Pid), _, true),
            catch(exit(Pid, kill), _, true)
        )).

test(ws_remote_actor_io_output_suppressed) :-
    with_node_server(
        URI,
        (
            spawn(run, Pid, [
                node(URI),
                load_text("run :- writeln(hello).")
            ]),
            refute_actor_output(Pid, 0.5)
        )).

test(ws_remote_toplevel_io_output_suppressed) :-
    with_node_server(
        URI,
        (
            toplevel_spawn(Pid, [node(URI)]),
            toplevel_call(Pid, writeln(hello), [template(true)]),
            receive({
                success(Pid, _, false) -> true
                ; failure(Pid) -> fail
                ; error(Pid, Err) -> throw(Err)
            }, [timeout(5), on_timeout(fail)]),
            refute_actor_output(Pid, 0.5)
        )).

%% Test: WS remote toplevel_next/1 inherits prior call limit
test(ws_remote_next_inherits_call_limit,
     true((First == [1,2,3,4,5],
           More1 == true,
           Second == [6,7,8,9,10],
           More2 == true))) :-
    with_node_server(
        URI,
        (
            toplevel_spawn(Pid, [session(true), monitor(true), node(URI)]),
            toplevel_call(Pid, between(1,12,X), [template(X), limit(5)]),
            receive({
                success(_, Data1, MoreA) -> First = Data1, More1 = MoreA
                ;   failure(_) -> First = '$FAILURE', More1 = none
                ;   error(_, Err1) -> First = '$ERROR'(Err1), More1 = none
            }, [timeout(5), on_timeout((First = '$TIMEOUT', More1 = none))]),
            toplevel_next(Pid),
            receive({
                success(_, Data2, MoreB) -> Second = Data2, More2 = MoreB
                ;   failure(_) -> Second = '$FAILURE', More2 = none
                ;   error(_, Err2) -> Second = '$ERROR'(Err2), More2 = none
            }, [timeout(5), on_timeout((Second = '$TIMEOUT', More2 = none))]),
            catch(demonitor(Pid), _, true),
            catch(exit(Pid, kill), _, true)
        )).

test(ws_direct_echo_actor_roundtrip,
     true((OutputData == "Shell got echo(hi)",
           FlushType == "success"))) :-
    with_node_server(
        URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, ToplevelPid),

                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:"spawn(echo_actor, Pid)",
                    template:"Pid"
                }),
                ws_receive_json(WS, SpawnReply),
                get_dict(data, SpawnReply, [SpawnRow]),
                get_dict('Pid', SpawnRow, EchoPid),

                format(string(EchoGoal), "self(S), ~s ! echo(S, hi)", [EchoPid]),
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:ToplevelPid,
                    goal:EchoGoal,
                    template:"S"
                }),
                ws_receive_json(WS, _EchoReply),

                ws_flush_until_output(WS, ToplevelPid, OutputData, FlushType)
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )).

test(sandbox_public_paths) :-
    once(with_node_server_options(
        [sandbox(on)],
        URI,
        (
                    call_url(URI, 'p(X)', 'X', 0, 1, 'p(a).', none, StatelessURL),
                    read_answer(StatelessURL, StatelessAnswer),
                    StatelessAnswer == success([a], false),

                    call_url(URI, 'phrase(foo, [a])', 'true', 0, 1,
                             'foo --> [a].', none, DcgURL),
                    read_answer(DcgURL, DcgAnswer),
                    DcgAnswer == success([true], false),

                    parse_url(URI, Parts),
                    parse_url(RejectedURL,
                              [ path('/call'),
                                search([goal='q(X)', template='X',
                                       offset=0, limit=1,
                                       format=json,
                                       load_text=':- use_module(library(lists)). q(X) :- X = a.'])
                              | Parts]),
                    read_json_answer(RejectedURL, RejectedJSON),
                    get_dict(type, RejectedJSON, "error"),
                    get_dict(data, RejectedJSON, RejectedErrorData),
                    sub_string(RejectedErrorData, _, _, _, "sandboxed"),

                    atom_concat(URI, '/toplevel_spawn', SpawnURL),
                    read_json_post(SpawnURL, _{options:"[]"}, SpawnJSON),
                    get_dict(pid, SpawnJSON, Pid),
                    isotope_call_url(URI, Pid, 'q(X)', 'q(X) :- p(X). p(a).', CallURL),
                    read_json_answer(CallURL, JSON),
                    get_dict(type, JSON, "success"),
                    get_dict(data, JSON, [Row]),
                    get_dict('X', Row, "a"),

                    isotope_call_url(URI, Pid, 'phrase(foo, [a])',
                                     'foo --> [a].', DcgCallURL),
                    read_json_answer(DcgCallURL, DcgJSON),
                    get_dict(type, DcgJSON, "success"),
                    get_dict(more, DcgJSON, false),
                    get_dict(data, DcgJSON, [_]),

                    isotope_call_url(URI, Pid, 'assertz(q(a))',
                                     ':- dynamic q/1.\n', AssertCallURL),
                    read_json_answer(AssertCallURL, AssertJSON),
                    get_dict(type, AssertJSON, "success"),

                    isotope_call_url(URI, Pid, 'retract(q(X))', '', RetractCallURL),
                    read_json_answer(RetractCallURL, RetractJSON),
                    get_dict(type, RetractJSON, "success"),
                    get_dict(data, RetractJSON, [RetractRow]),
                    get_dict('X', RetractRow, "a"),

                    setup_call_cleanup(
                        (ws_open(URI, WS1), ws_open(URI, WS2)),
                        (
                            ws_send_json(WS1, json{
                                command:spawn,
                                goal:"true",
                                options:"[node('http://example.com')]"
                            }),
                            ws_receive_json(WS1, RejectReply),
                            get_dict(type, RejectReply, "error"),
                            get_dict(data, RejectReply, RejectData),
                            sub_string(RejectData, _, _, _, "sandboxed"),

                            ws_send_json(WS1, json{command:toplevel_spawn, options:"[]"}),
                            ws_receive_json(WS1, Spawned),
                            get_dict(pid, Spawned, ToplevelPid),

                            ws_send_json(WS1, json{
                                command:toplevel_call,
                                pid:ToplevelPid,
                                goal:"append([a],[b,c],Xs)",
                                template:"Xs"
                            }),
                            ws_receive_json(WS1, AllowedReply),
                            get_dict(type, AllowedReply, "success"),
                            get_dict(data, AllowedReply, [_]),

                            ws_send_json(WS1, json{
                                command:toplevel_call,
                                pid:ToplevelPid,
                                goal:"toplevel_spawn(Pid, [session(true), monitor(true)])",
                                template:"Pid"
                            }),
                            ws_receive_json(WS1, SpawnToplevelReply),
                            get_dict(type, SpawnToplevelReply, "success"),
                            get_dict(data, SpawnToplevelReply, [SpawnToplevelRow]),
                            get_dict('Pid', SpawnToplevelRow, _),

                            ws_send_json(WS2, json{
                                command:toplevel_call,
                                pid:ToplevelPid,
                                goal:"true",
                                template:"true"
                            }),
                            ws_receive_json(WS2, Reply),
                            get_dict(type, Reply, "error"),
                            get_dict(data, Reply, ErrorData),
                            sub_string(ErrorData, _, _, _, "Not authorized to access session")
                        ),
                        ( catch(ws_close(WS1, 1000, done), _, true),
                          catch(ws_close(WS2, 1000, done), _, true)
                        )
                    )
                )
        )).

test(sandbox_on_http_toplevel_spawn_accepts_load_uri,
     true(Values == ["a", "b"])) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server_options(
                [sandbox(on), auth(dev)],
                URI,
                (
                    atom_concat(URI, '/toplevel_spawn', SpawnURL),
                    format(string(OptionsText), "[load_uri(~q)]", [File]),
                    read_json_post(SpawnURL, _{options:OptionsText}, SpawnJSON),
                    get_dict(pid, SpawnJSON, Pid),
                    isotope_call_url(URI, Pid, 'u(X)', '', CallURL),
                    read_json_answer(CallURL, JSON),
                    get_dict(type, JSON, "success"),
                    get_dict(data, JSON, Rows),
                    findall(Value,
                            ( member(Row, Rows),
                              get_dict('X', Row, Value)
                            ),
                            Values0),
                    sort(Values0, Values)
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(sandbox_on_http_toplevel_spawn_rejects_load_uri_outside_allowlist,
     true((Type == "error",
           sub_string(Data, _, _, _, "allowlist")))) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server_options(
                [
                    sandbox(on),
                    auth(dev),
                    load_uri_allowed_origins(['https://n1.elfenbenstornet.se'])
                ],
                URI,
                (
                    atom_concat(URI, '/toplevel_spawn', SpawnURL),
                    format(string(OptionsText), "[load_uri(~q)]", [File]),
                    read_json_post(SpawnURL, _{options:OptionsText}, JSON),
                    Type = JSON.type,
                    Data = JSON.data
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(sandbox_on_ws_toplevel_spawn_accepts_load_uri,
     true(Values == ["a", "b"])) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'u(a).~nu(b).~n', []),
            close(Stream),
            with_node_server_options(
                [sandbox(on), auth(dev)],
                URI,
                setup_call_cleanup(
                    ws_open(URI, WS),
                    (
                        format(string(OptionsText), "[load_uri(~q)]", [File]),
                        ws_send_json(WS, json{
                            command:toplevel_spawn,
                            options:OptionsText
                        }),
                        ws_receive_json(WS, Spawned),
                        get_dict(pid, Spawned, Pid),
                        sleep(0.2),
                        ws_send_json(WS, json{
                            command:toplevel_call,
                            pid:Pid,
                            goal:"u(X)",
                            template:"X"
                        }),
                        ws_receive_json(WS, Reply),
                        get_dict(type, Reply, "success"),
                        get_dict(data, Reply, Rows),
                        findall(Value,
                                ( member(Row, Rows),
                                  get_dict('X', Row, Value)
                                ),
                                Values0),
                        sort(Values0, Values)
                    ),
                    catch(ws_close(WS, 1000, done), _, true)
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(sandbox_on_ws_toplevel_call_allows_nested_spawn_load_uri,
     true(Type == "success")) :-
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, 'child(Parent) :- send(Parent, loaded).~n', []),
            close(Stream),
            with_node_server_options(
                [sandbox(on), auth(dev)],
                URI,
                setup_call_cleanup(
                    ws_open(URI, WS),
                    (
                        ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                        ws_receive_json(WS, Spawned),
                        get_dict(pid, Spawned, Pid),
                        format(string(GoalText),
                               "self(Self), spawn(child(Self), _Pid, [load_uri(~q), link(false)]), receive({loaded -> true})",
                               [File]),
                        ws_send_json(WS, json{
                            command:toplevel_call,
                            pid:Pid,
                            goal:GoalText,
                            template:"true"
                        }),
                        ws_receive_json(WS, Reply),
                        get_dict(type, Reply, Type)
                    ),
                    catch(ws_close(WS, 1000, done), _, true)
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

test(sandbox_on_ws_toplevel_call_allows_computed_nested_spawn_load_list,
     true(Type == "success")) :-
    with_node_server_options(
        [sandbox(on), auth(dev), dev_capabilities([execute])],
        URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, Pid),
                GoalText = "findall(s(N), between(1,3,N), Ns), spawn(true, _Pid, [load_list(Ns), link(false)])",
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:Pid,
                    goal:GoalText,
                    template:"true"
                }),
                ws_receive_json(WS, Reply),
                get_dict(type, Reply, Type)
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )
    ).

test(sandbox_on_ws_toplevel_call_reports_size_error_for_computed_nested_spawn_load_list,
     true((Type == "error",
           sub_string(Data, _, _, _, "load_list"),
           sub_string(Data, _, _, _, "limit 1024 bytes")))) :-
    with_node_server_options(
        [sandbox(on), auth(dev), dev_capabilities([execute]), max_load_text_bytes(1024)],
        URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, Pid),
                GoalText = "findall(s(N), between(1,2000,N), Ns), spawn(receive({}), _Pid, [load_list(Ns), link(false)])",
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:Pid,
                    goal:GoalText,
                    template:"true"
                }),
                ws_receive_json(WS, Reply),
                Type = Reply.type,
                Data = Reply.data
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )
    ).

test(sandbox_on_ws_toplevel_call_repeats_size_error_for_computed_nested_spawn_load_list,
     true((Type1 == "error",
           sub_string(Data1, _, _, _, "load_list"),
           sub_string(Data1, _, _, _, "limit 100 bytes"),
           Type2 == "error",
           sub_string(Data2, _, _, _, "load_list"),
           sub_string(Data2, _, _, _, "limit 100 bytes")))) :-
    with_node_server_options(
        [sandbox(on), auth(dev), max_load_text_bytes(100)],
        URI,
        setup_call_cleanup(
            ws_open(URI, WS),
            (
                ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                ws_receive_json(WS, Spawned),
                get_dict(pid, Spawned, Pid),
                GoalText = "findall(s(N), between(1,250,N), Ns), spawn(receive({}), _Pid, [load_list(Ns), link(false)])",
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:Pid,
                    goal:GoalText,
                    template:"true"
                }),
                ws_receive_json(WS, Reply1),
                Type1 = Reply1.type,
                Data1 = Reply1.data,
                ws_send_json(WS, json{
                    command:toplevel_call,
                    pid:Pid,
                    goal:GoalText,
                    template:"true"
                }),
                ws_receive_json(WS, Reply2),
                Type2 = Reply2.type,
                Data2 = Reply2.data
            ),
            catch(ws_close(WS, 1000, done), _, true)
        )
    ).

test(ws_toplevel_spawn_allows_commented_dynamic_db_examples_when_dynamic_db_disabled,
     true((SpawnType == "spawned",
           ReplyType == "error",
           sub_string(ReplyData, _, _, _, "Unknown procedure: a/0")))) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            read_json_post_headers(
                ConfigURL,
                Headers,
                json{
                    builtin_families:[
                        json{
                            id:"dynamic_db",
                            profiles:json{actor:false}
                        }
                    ]
                },
                _UpdatedJSON
            ),
            atomics_to_string([
                "% Optional dynamic example\n",
                "sample_wife(socrates, xantippa).\n",
                "% :- dynamic sample_p/1.\n",
                "% sample_assert_and_retract :- assert(sample_p(1)).\n"
            ], LoadText),
            setup_call_cleanup(
                ws_open_headers(URI, Headers, WS),
                (
                    ws_send_json(WS, json{
                        command:toplevel_spawn,
                        load_text:LoadText
                    }),
                    ws_receive_json(WS, Spawned),
                    SpawnType = Spawned.type,
                    get_dict(pid, Spawned, Pid),
                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:Pid,
                        goal:"a",
                        template:"true"
                    }),
                    ws_receive_json(WS, Reply),
                    ReplyType = Reply.type,
                    ReplyData = Reply.data
                ),
                catch(ws_close(WS, 1000, done), _, true)
            )
        )).

test(admin_config_builtin_family_update_recycles_ws_toplevel_session,
     true((DownType == "down",
           DownPid == Pid,
           DownReason == "runtime_config_changed",
           RespawnType == "spawned",
           ReplyType == "error",
           sub_string(ReplyData, _, _, _, "Unknown procedure: assert/1")))) :-
    with_node_server_options([auth(private), owner("owner"), profile(actor)], URI,
        (
            principal_headers("owner", Headers),
            admin_config_url(URI, ConfigURL),
            setup_call_cleanup(
                ws_open_headers(URI, Headers, WS),
                (
                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Spawned),
                    get_dict(type, Spawned, "spawned"),
                    get_dict(pid, Spawned, Pid),

                    read_json_post_headers(
                        ConfigURL,
                        Headers,
                        json{
                            builtin_families:[
                                json{
                                    id:"dynamic_db",
                                    profiles:json{actor:false}
                                }
                            ]
                        },
                        _UpdatedJSON
                    ),

                    ws_receive_json(WS, Down),
                    DownType = Down.type,
                    DownPid = Down.pid,
                    DownReason = Down.reason,

                    ws_send_json(WS, json{command:toplevel_spawn, options:"[]"}),
                    ws_receive_json(WS, Respawned),
                    RespawnType = Respawned.type,
                    get_dict(pid, Respawned, NewPid),

                    ws_send_json(WS, json{
                        command:toplevel_call,
                        pid:NewPid,
                        goal:"assert(a)",
                        template:"true"
                    }),
                    ws_receive_json(WS, Reply),
                    ReplyType = Reply.type,
                    ReplyData = Reply.data
                ),
                catch(ws_close(WS, 1000, done), _, true)
            )
        )).

test(sandbox_on_http_toplevel_spawn_rejects_oversized_load_uri_source,
     true((Type == "error",
           sub_string(Data, _, _, _, "load_uri"),
           sub_string(Data, _, _, _, "limit 8 bytes")))) :-
    repeated_string(0'a, 32, SourceText),
    setup_call_cleanup(
        tmp_file_stream(text, File, Stream),
        (
            format(Stream, '~s', [SourceText]),
            close(Stream),
            with_node_server_options(
                [sandbox(on), auth(dev), max_load_text_bytes(8)],
                URI,
                (
                    atom_concat(URI, '/toplevel_spawn', SpawnURL),
                    format(string(OptionsText), "[load_uri(~q)]", [File]),
                    read_json_post(SpawnURL, _{options:OptionsText}, JSON),
                    Type = JSON.type,
                    Data = JSON.data
                )
            )
        ),
        (
            catch(close(Stream), _, true),
            catch(delete_file(File), _, true)
        )
    ).

:- end_tests(node).
