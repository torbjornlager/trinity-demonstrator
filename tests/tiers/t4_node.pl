/*  Tier T4: the full node layer (all layers composed).

    The demonstrator's complete node test surface, from adapted copies
    in tests/tiers/node/ (import paths to the new layered modules via
    the actor_api facade; actor:/toplevel_actor: qualifications
    renamed; everything else verbatim):

      - node_tests.pl          ISOBASE /call, ISOTOPE sessions, /ws,
                               auth/profile/relation/sandbox policies,
                               responses, startup options
      - goal_walker_tests.pl
      - actor_remote_exit_failure.plt
      - down_wire_format_tests.plt
      - statechart_trace_options_tests.plt
      - cross_node_lifecycle_tests.plt   (in-process multi-node harness)
      - node_controller_tests.plt

    No tier-local glue here: node_glue.pl (loaded by node.pl) is the
    composition — exactly what a production node runs.
*/

:- use_module('../../prolog/web_prolog/node.pl').
:- use_module(library(plunit)).
:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).

%  Fetch a URL and capture its HTTP status (in `user`, so the
%  with_node_server bodies can call it as user:http_status/2).
http_status(URL, Status) :-
    catch(
        setup_call_cleanup(
            http_open(URL, S, [status_code(Status), timeout(10)]),
            read_string(S, _, _),
            close(S)),
        _, Status = error).

:- user:load_files('node/goal_walker_tests.pl', []).
:- use_module('node/node_tests.pl', []).
:- user:load_files('node/actor_remote_exit_failure.plt', []).
:- user:load_files('node/down_wire_format_tests.plt', []).
:- user:load_files('node/statechart_trace_options_tests.plt', []).
:- user:load_files('node/cross_node_lifecycle_tests.plt', []).
:- user:load_files('node/node_controller_tests.plt', []).

run_tier :-
    layer_honesty,
    run_tests([ node,
                goal_walker,
                actor_remote_exit_failure,
                down_wire_format,
                statechart_trace_options,
                cross_node_lifecycle,
                node_controller,
                t4_profile_matrix,
                t4_operational,
                t4_ceilings,
                t4_logging,
                t4_maintenance,
                t4_tokens,
                t4_tiers,
                t4_ip,
                t4_anon_ip,
                t4_autoban,
                t4_counters,
                t4_audit,
                t4_doctor,
                t4_posture,
                t4_ws_spawn_cleanup,
                t4_deviations,
                t4_compute_answer,
                t4_shared_db_io,
                t4_remote_self
              ]).

%  The node_engine answer-batching surface (compute_answer/5): the
%  windowed slicing that ISOBASE /call and ISOTOPE sessions sit on.
%  Ported from the demonstrator's actor_tests.pl `compute_answer` group
%  (node:compute_answer/5 verbatim) so its offset/limit windowing, the
%  final-slice `false` flag, failure, and error shapes stay pinned at
%  the node tier — they had no coverage anywhere in T0–T5 before.
:- begin_tests(t4_compute_answer).

test(compute_answer_1a, Response == success([1,2,3,4,5],true)) :-
    once(node:compute_answer(between(1, 12, N), N, 0, 5, Response)).

test(compute_answer_1b, Response == success([6,7,8,9,10],true)) :-
    once(node:compute_answer(between(1, 12, N), N, 5, 5, Response)).

test(compute_answer_1c, Response == success([11,12],false)) :-
    node:compute_answer(between(1, 12, N), N, 10, 5, Response).

test(compute_answer_2, Response == failure) :-
    node:compute_answer(between(1, 12, N), N, 15, 5, Response).

test(compute_answer_3,
        Response = error(error(existence_error(procedure, _:unknown/0),_))) :-
    node:compute_answer(unknown, unknown, 0, 1, Response).

:- end_tests(t4_compute_answer).

%  The shared_db half of the demonstrator's I/O-target inheritance
%  matrix: a child spawned against the node-wide shared database (rather
%  than load_text) still inherits the parent's I/O target.  Ported
%  verbatim from actor_tests.pl — they depend on node:shared_db/1 and
%  node:set_node_shared_db/1, so they belong at the node tier (the
%  spawned/load_text variants live in T1).
:- begin_tests(t4_shared_db_io).

test(shared_db_child_inherits_io_target_for_writeln, Data == 'Alarm ringing!') :-
   node:shared_db(Prev),
   setup_call_cleanup(
       node:set_node_shared_db("
alarm :-
    receive({
        ring ->
            writeln('Alarm ringing!');
        stop ->
            true
    }).
"),
       (
           self(Self),
           with_io_target(Self,
               spawn(alarm, Pid, [
                   monitor(true)
               ])),
           send(Pid, ring, [
               delay(0.05)
           ]),
           receive({
               terminal_output(Pid, Data) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ]),
           receive({
               down(_, Pid, true) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ])
       ),
       node:set_node_shared_db(Prev)
   ).

test(shared_db_child_inherits_io_target_for_format, Data == "Alarm ringing!") :-
   node:shared_db(Prev),
   setup_call_cleanup(
       node:set_node_shared_db("
alarm :-
    receive({
        ring ->
            format('Alarm ~w!', [ringing]);
        stop ->
            true
    }).
"),
       (
           self(Self),
           with_io_target(Self,
               spawn(alarm, Pid, [
                   monitor(true)
               ])),
           send(Pid, ring, [
               delay(0.05)
           ]),
           receive({
               terminal_output(Pid, Data) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ]),
           receive({
               down(_, Pid, true) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ])
       ),
       node:set_node_shared_db(Prev)
   ).

test(shared_db_child_inherits_io_target_for_write_term, Data == "'Alarm ringing!'") :-
   node:shared_db(Prev),
   setup_call_cleanup(
       node:set_node_shared_db("
alarm :-
    receive({
        ring ->
            write_term('Alarm ringing!', [quoted(true)]);
        stop ->
            true
    }).
"),
       (
           self(Self),
           with_io_target(Self,
               spawn(alarm, Pid, [
                   monitor(true)
               ])),
           send(Pid, ring, [
               delay(0.05)
           ]),
           receive({
               terminal_output(Pid, Data) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ]),
           receive({
               down(_, Pid, true) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ])
       ),
       node:set_node_shared_db(Prev)
   ).

test(shared_db_child_inherits_io_target_for_display, Data == "+(1,2)") :-
   node:shared_db(Prev),
   setup_call_cleanup(
       node:set_node_shared_db("
alarm :-
    receive({
        ring ->
            display(1+2);
        stop ->
            true
    }).
"),
       (
           self(Self),
           with_io_target(Self,
               spawn(alarm, Pid, [
                   monitor(true)
               ])),
           send(Pid, ring, [
               delay(0.05)
           ]),
           receive({
               terminal_output(Pid, Data) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ]),
           receive({
               down(_, Pid, true) -> true
           }, [
               timeout(1),
               on_timeout(fail)
           ])
       ),
       node:set_node_shared_db(Prev)
   ).

:- end_tests(t4_shared_db_io).

%  The remote-self cases from the demonstrator's actor_tests.pl: an actor
%  spawned on a (loopback) remote node can address the originating shell
%  through global self, and the per-node WebSocket connection is shared
%  across remote spawns rather than reopened.  Ported verbatim except the
%  internal qualifier actor:ws_connection/4 -> distribution:ws_connection/4
%  (the client-side connection pool moved from src/actor.pl into the
%  distribution layer).  with_node_server/2 is the node tier's harness.
:- begin_tests(t4_remote_self).

test(spawn_remote_can_message_global_self, Msg == hello) :-
   test_node:with_node_server(URI,
      (
         self(Self),
         spawn(send(Self, hello), Pid, [
             monitor(true),
             node(URI)
         ]),
         receive({
             hello -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         Msg = hello
      )).

test(spawn_remote_can_message_global_self_with_bang, Msg == hello) :-
   test_node:with_node_server(URI,
      (
         self(Self),
         spawn(Self ! hello, Pid, [
             monitor(true),
             node(URI)
         ]),
         receive({
             hello -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         Msg = hello
      )).

test(remote_node_reuses_shared_ws_connection, Connections == 1) :-
   test_node:with_node_server(URI,
      (
         toplevel_spawn(ToplevelPid, [
             session(true),
             monitor(true),
             node(URI)
         ]),
         spawn(true, Pid, [
             monitor(true),
             node(URI)
         ]),
         findall(Conn, distribution:ws_connection(URI, Conn, _, _), Conns),
         length(Conns, Connections),
         exit(ToplevelPid, kill),
         receive({
             down(_, ToplevelPid, kill) -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ])
      )).

:- end_tests(t4_remote_self).

%  Resource ceilings (Phase 8): a public node must survive a single
%  client's runaway goal. Wall-clock timeouts don't stop a memory bomb
%  (it OOMs in milliseconds) or bound CPU tightly. These pin that the
%  per-call inference ceiling and per-actor memory ceiling turn such
%  goals into ordinary error answers, leaving the node serving.
:- begin_tests(t4_ceilings).

%  An infinite, solution-free goal must hit the inference ceiling and
%  come back as an error — not hang until the wall-clock timeout.
test(inference_ceiling_stops_infinite_goal, true(Type == "error")) :-
    test_node:with_node_server_options([max_call_inferences(2000000)], URI,
        ( atom_concat(URI, '/call?goal=(between(1,1000000000,_),fail)', URL),
          test_node:read_json_answer(URL, J),
          get_dict(type, J, Type) )).

%  A memory bomb must hit the per-actor stack ceiling and come back as
%  an error, with the node still answering afterwards.
test(memory_ceiling_stops_allocation_bomb, true((Type == "error", After == "success"))) :-
    test_node:with_node_server_options([max_actor_stack_bytes(67108864)], URI,
        ( atom_concat(URI, '/call?goal=length(_,100000000)&template=true', URL),
          test_node:read_json_answer(URL, J),
          get_dict(type, J, Type),
          atom_concat(URI, '/call?goal=true&template=true', URL2),
          test_node:read_json_answer(URL2, J2),
          get_dict(type, J2, After) )).

%  A configured-but-not-exceeded inference ceiling leaves normal
%  queries working (the ceiling is generous, not a straitjacket).
test(inference_ceiling_allows_normal_query, true(Type == "success")) :-
    test_node:with_node_server_options([max_call_inferences(100000000)], URI,
        ( atom_concat(URI, '/call?goal=member(X,[a,b,c])&template=X', URL),
          test_node:read_json_answer(URL, J),
          get_dict(type, J, Type) )).

:- end_tests(t4_ceilings).

%  Operational endpoints for turn-key deployment (Phase 8): liveness,
%  readiness, build identity. Unauthenticated and side-effect-free.
:- begin_tests(t4_operational).

test(healthz_ok, true(Status == "ok")) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/healthz', URL),
          test_node:read_json_answer(URL, J),
          get_dict(status, J, Status) )).

test(readyz_ready, true(Status == "ready")) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/readyz', URL),
          test_node:read_json_answer(URL, J),
          get_dict(status, J, Status) )).

test(version_reports_components,
     true((nonvar(WP), nonvar(SWI), nonvar(Git), integer(Protocol)))) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/version', URL),
          test_node:read_json_answer(URL, J),
          get_dict(web_prolog, J, WP),
          get_dict(swipl, J, SWI),
          get_dict(protocol, J, Protocol),
          get_dict(git, J, Git) )).

%  /metrics renders Prometheus text with the build-info line, the live
%  activity gauges, and the configured limit gauges (which carry the
%  resource ceilings through to a dashboard).
test(metrics_prometheus_exposition) :-
    test_node:with_node_server_options([max_actors(4242)], URI,
        ( atom_concat(URI, '/metrics', URL),
          test_node:read_text(URL, Text),
          assertion(sub_string(Text, _, _, _, "web_prolog_build_info{")),
          assertion(sub_string(Text, _, _, _, "# TYPE web_prolog_uptime_seconds gauge")),
          assertion(sub_string(Text, _, _, _, "web_prolog_active_sessions ")),
          assertion(sub_string(Text, _, _, _, "web_prolog_limit_max_actors 4242")) )).

:- end_tests(t4_operational).

%  Interaction-log rotation (Phase 8): the durable JSONL log (browser
%  telemetry — portal loads etc.) must not grow unbounded on a public
%  node. A configured size cap rotates it, keeping a bounded number of
%  backups.
:- begin_tests(t4_logging).

:- dynamic t4_saved_log_path/1.
:- dynamic t4_rotation_logfile/1.

t4_rotation_setup(LogFile) :-
    tmp_file(wp_rotlog, Base),
    atom_concat(Base, '.jsonl', LogFile),
    retractall(t4_rotation_logfile(_)),
    assertz(t4_rotation_logfile(LogFile)),
    ( setting(node_interaction_log:interaction_log_file, Old) -> true ; Old = 'logs/interactions.jsonl' ),
    retractall(t4_saved_log_path(_)),
    assertz(t4_saved_log_path(Old)),
    set_setting(node_interaction_log:interaction_log_file, LogFile).

t4_rotation_cleanup :-
    ( t4_saved_log_path(Old) -> set_setting(node_interaction_log:interaction_log_file, Old) ; true ),
    ( t4_rotation_logfile(LogFile)
    -> forall(member(Suffix, ['', '.1', '.2', '.3', '.4', '.5']),
              ( atom_concat(LogFile, Suffix, F),
                ( exists_file(F) -> catch(delete_file(F), _, true) ; true ) ))
    ; true ),
    retractall(t4_saved_log_path(_)),
    retractall(t4_rotation_logfile(_)).

test(interaction_log_rotates_and_caps_backups, [
        setup(t4_rotation_setup(LogFile)),
        cleanup(t4_rotation_cleanup)
     ]) :-
    test_node:with_node_server_options(
        [max_interaction_log_bytes(500), max_interaction_log_backups(3)], URI,
        ( forall(between(1, 60, _),
                 ( atom_concat(URI, '/portal', U),
                   catch(test_node:read_text(U, _), _, true) )),
          %  rotation produced at least the first backup ...
          atom_concat(LogFile, '.1', Backup1),
          assertion(exists_file(Backup1)),
          %  ... and never more than `backups` of them (no .4).
          atom_concat(LogFile, '.4', Backup4),
          assertion(\+ exists_file(Backup4)) )).

:- end_tests(t4_logging).

%  Maintenance / drain mode (Phase 8): toggled via the headless admin
%  API, surfaced through /readyz (so a load balancer drains the node)
%  and the execution entry points (no new work), while /healthz stays
%  up and in-flight is unaffected. The SIGTERM graceful drain that
%  pairs with this lives in Deployment/start_node.pl (process-level).
:- begin_tests(t4_maintenance).

test(maintenance_toggle_drains_and_recovers) :-
    test_node:with_node_server_options([profile(actor), auth(open)], URI,
        ( atom_concat(URI, '/admin/maintenance', MURL),
          atom_concat(URI, '/readyz', RZ),
          atom_concat(URI, '/healthz', HZ),
          atom_concat(URI, '/call?goal=true&format=prolog', CALL),

          %  Normal: ready, /call serves.
          user:http_status(RZ, 200),
          user:http_status(CALL, 200),

          %  Enable maintenance via the admin API.
          test_node:read_json_post(MURL, json{enabled:true}, On),
          assertion(get_dict(maintenance, On, true)),

          %  Draining: /readyz 503, new work refused 503, liveness 200.
          user:http_status(RZ, 503),
          user:http_status(CALL, 503),
          user:http_status(HZ, 200),

          %  GET reports the state.
          test_node:read_json_answer(MURL, State),
          assertion(get_dict(maintenance, State, true)),

          %  Disable: back to normal.
          test_node:read_json_post(MURL, json{enabled:false}, Off),
          assertion(get_dict(maintenance, Off, false)),
          user:http_status(RZ, 200),
          user:http_status(CALL, 200) )).

:- end_tests(t4_maintenance).

%  Bearer API tokens (node_tokens): a proven authenticated identity source
%  layered before the proxy-trusted X-Web-Prolog-User header. Off by
%  default (no tokens => unchanged behavior); these exercise the
%  issue/verify/revoke mechanism and its node_auth integration.
:- begin_tests(t4_tokens, [
       setup(node_tokens:clear_all_tokens),
       cleanup(node_tokens:clear_all_tokens)
   ]).

bearer_request(FullToken, Request) :-
    format(atom(Header), "Bearer ~w", [FullToken]),
    Request = [authorization(Header), method(get), path('/call')].

test(issue_then_verify_roundtrip, true(Id-Caps == "api-client"-[execute])) :-
    node_tokens:issue_token("api-client", [execute], [], Full),
    node_tokens:verify_bearer_token(Full, Principal),
    assertion(get_dict(unknown, Principal, false)),
    get_dict(id, Principal, Id),
    get_dict(capabilities, Principal, Caps).

test(wrong_secret_rejected, fail) :-
    node_tokens:issue_token("c", [execute], [], Full),
    string_concat(Full, "0", Tampered),
    node_tokens:verify_bearer_token(Tampered, _).

test(unknown_id_rejected, fail) :-
    node_tokens:verify_bearer_token("wp_deadbeefdeadbeef_cafef00dcafef00d", _).

test(malformed_token_rejected, fail) :-
    node_tokens:verify_bearer_token("not-a-wp-token", _).

test(revoked_token_rejected, [setup(node_tokens:clear_all_tokens)]) :-
    node_tokens:issue_token("c", [execute], [], Full),
    node_tokens:current_tokens([Info]),
    get_dict(id, Info, Id),
    assertion(node_tokens:revoke_token(Id)),
    assertion(\+ node_tokens:verify_bearer_token(Full, _)).

test(expired_token_rejected, fail) :-
    node_tokens:issue_token("c", [execute], [expires_in(-100)], Full),
    node_tokens:verify_bearer_token(Full, _).

test(unexpired_token_valid) :-
    node_tokens:issue_token("c", [execute], [expires_in(3600)], Full),
    node_tokens:verify_bearer_token(Full, Principal),
    assertion(get_dict(id, Principal, "c")).

test(current_tokens_hides_secret_and_hash, [setup(node_tokens:clear_all_tokens)]) :-
    node_tokens:issue_token("c", [execute], [label("ci")], _Full),
    node_tokens:current_tokens([Info]),
    assertion(\+ get_dict(hash, Info, _)),
    assertion(get_dict(label, Info, "ci")),
    assertion(get_dict(revoked, Info, false)).

test(node_auth_resolves_bearer_principal, true(Id == "agent")) :-
    node_tokens:issue_token("agent", [execute], [], Full),
    bearer_request(Full, Request),
    node_auth:request_authenticated_principal(Request, Principal),
    get_dict(id, Principal, Id).

test(bearer_takes_precedence_over_user_header, true(Id == "tokuser")) :-
    node_tokens:issue_token("tokuser", [execute], [], Full),
    format(atom(Header), "Bearer ~w", [Full]),
    Request = [ authorization(Header),
                x_web_prolog_user("headeruser"),
                method(get), path('/call') ],
    node_auth:request_principal(Request, Principal),
    get_dict(id, Principal, Id).

test(bad_token_falls_back_to_anonymous, true(Principal == anonymous)) :-
    Request = [authorization('Bearer wp_bad_bad'), method(get), path('/call')],
    node_auth:request_principal(Request, Principal).

test(bearer_grants_execution) :-
    node_tokens:issue_token("agent", [execute], [], Full),
    bearer_request(Full, Request),
    node_auth:request_principal(Request, Principal),
    node_auth:require_execution_access(Principal).

test(bearer_without_execute_denied,
     throws(error(authorization_error(_, execution), _))) :-
    node_tokens:issue_token("ro", [public_read], [], Full),
    bearer_request(Full, Request),
    node_auth:request_principal(Request, Principal),
    node_auth:require_execution_access(Principal).

%  --- admin HTTP surface (issue / list / revoke over /admin/tokens) ---

test(admin_tokens_endpoint_issue_list_revoke, [
        setup(( node_tokens:clear_all_tokens,
                retractall(node_tokens:tokens_file_path(_)) )),
        cleanup(node_tokens:clear_all_tokens)
     ]) :-
    test_node:with_node_server(URI,
        (   atom_concat(URI, '/admin/tokens', TokensURL),
            %  issue (local request on an open-mode node ⇒ admin authorized)
            http_post(TokensURL,
                      json(_{principal:"api-client",
                             capabilities:["execute"], label:"ci"}),
                      Issued, [json_object(dict)]),
            get_dict(token, Issued, Full),
            get_dict(id, Issued, Id),
            assertion(sub_string(Full, 0, 3, _, "wp_")),
            %  the freshly issued token authorizes a /call
            format(atom(Header), "Bearer ~w", [Full]),
            format(atom(CallURL),
                   "~w/call?goal=true&template=true&offset=0&limit=1&format=prolog",
                   [URI]),
            setup_call_cleanup(
                http_open(CallURL, CS, [request_header('Authorization'=Header)]),
                read_string(CS, _, CallBody),
                close(CS)),
            assertion(sub_string(CallBody, _, _, _, "success")),
            %  GET lists it, without secret or hash
            http_get(TokensURL, Listed, [json_object(dict)]),
            get_dict(tokens, Listed, TokenList),
            once(( member(Info, TokenList), get_dict(id, Info, Id) )),
            assertion(\+ get_dict(hash, Info, _)),
            assertion(get_dict(principal_id, Info, "api-client")),
            %  DELETE ?id= revokes
            format(atom(DelURL), "~w/admin/tokens?id=~w", [URI, Id]),
            setup_call_cleanup(
                http_open(DelURL, DS,
                          [method(delete),
                           request_header('Accept'='application/json')]),
                json_read_dict(DS, Deleted),
                close(DS)),
            assertion(get_dict(revoked, Deleted, true))
        )).

%  --- persistence ---

token_test_file('/tmp/wp_t4_tokens_test.pl').

token_persist_setup :-
    node_tokens:clear_all_tokens,
    token_test_file(File),
    catch(delete_file(File), _, true),
    node_tokens:set_tokens_file(File).

token_persist_cleanup :-
    retractall(node_tokens:tokens_file_path(_)),
    node_tokens:clear_all_tokens,
    token_test_file(File),
    catch(delete_file(File), _, true).

test(persists_and_reloads_from_disk, [
        setup(token_persist_setup), cleanup(token_persist_cleanup)
     ]) :-
    node_tokens:issue_token("persisted", [execute], [label("p")], Full),
    %  simulate a restart: drop the in-memory store, reload from disk
    retractall(node_tokens:token_record(_, _)),
    node_tokens:load_tokens,
    node_tokens:verify_bearer_token(Full, Principal),
    assertion(get_dict(id, Principal, "persisted")).

test(revocation_persists_across_reload, [
        setup(token_persist_setup), cleanup(token_persist_cleanup)
     ]) :-
    node_tokens:issue_token("r", [execute], [], Full),
    node_tokens:current_tokens([Info]),
    get_dict(id, Info, Id),
    node_tokens:revoke_token(Id),
    retractall(node_tokens:token_record(_, _)),
    node_tokens:load_tokens,
    assertion(\+ node_tokens:verify_bearer_token(Full, _)),
    node_tokens:current_tokens([Reloaded]),
    assertion(get_dict(revoked, Reloaded, true)).

test(disk_store_never_contains_the_secret, [
        setup(token_persist_setup), cleanup(token_persist_cleanup)
     ]) :-
    node_tokens:issue_token("s", [execute], [], Full),
    %  the secret is everything after the second underscore
    split_string(Full, "_", "", ["wp", _Id, Secret]),
    token_test_file(File),
    read_file_to_string(File, Disk, []),
    assertion(\+ sub_string(Disk, _, _, _, Secret)).

test(in_memory_mode_save_load_are_noops, [
        setup(( node_tokens:clear_all_tokens,
                retractall(node_tokens:tokens_file_path(_)) )),
        cleanup(node_tokens:clear_all_tokens)
     ]) :-
    node_tokens:save_tokens,
    node_tokens:load_tokens,
    node_tokens:issue_token("mem", [execute], [], Full),
    node_tokens:verify_bearer_token(Full, _).

:- end_tests(t4_tokens).

%  The "registered" capability tier (node_auth): a default capability set
%  for an authenticated principal that has no explicit policy entry — what
%  makes the SSO recipe usable without hand-adding every user. Off by
%  default (empty), so behavior is unchanged unless an operator opts in.
:- begin_tests(t4_tiers).

reset_tier :-
    set_setting(node_auth:authenticated_default_capabilities, []).

test(no_tier_by_default_leaves_authenticated_principal_unknown, [
        setup(reset_tier), cleanup(reset_tier)
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("sso@example.com"), peer(ip(127,0,0,1)),
         method(get), path('/call')],
        Principal),
    assertion(\+ node_auth:principal_has_capability(Principal, execute)).

test(registered_tier_grants_caps_to_authenticated_principal, [
        setup(set_setting(node_auth:authenticated_default_capabilities, [execute])),
        cleanup(reset_tier)
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("sso@example.com"), peer(ip(127,0,0,1)),
         method(get), path('/call')],
        Principal),
    %  keeps its own id (for audit / per-principal limits) + gets the tier
    assertion(node_auth:principal_id(Principal, "sso@example.com")),
    assertion(node_auth:principal_has_capability(Principal, execute)).

test(explicit_policy_overrides_the_tier, [
        setup(( set_setting(node_auth:authenticated_default_capabilities, [execute]),
                node_principal_policy:set_principal_policies([principal("vip", [execute, admin])]) )),
        cleanup(( reset_tier,
                  node_principal_policy:set_principal_policies([]) ))
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("vip"), peer(ip(127,0,0,1)), method(get), path('/call')],
        Principal),
    assertion(node_auth:principal_has_capability(Principal, admin)).

test(tier_does_not_apply_to_an_untrusted_peer, [
        setup(set_setting(node_auth:authenticated_default_capabilities, [execute])),
        cleanup(reset_tier)
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("sso@example.com"), peer(ip(8,8,8,8)),
         method(get), path('/call')],
        Principal),
    assertion(\+ node_auth:principal_has_capability(Principal, execute)).

test(tier_never_grants_admin_or_internal_transport, [
        setup(set_setting(node_auth:authenticated_default_capabilities,
                          [execute, admin, internal_transport])),
        cleanup(reset_tier)
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("sso@example.com"), peer(ip(127,0,0,1)),
         method(get), path('/call')],
        Principal),
    assertion(node_auth:principal_has_capability(Principal, execute)),
    assertion(\+ node_auth:principal_has_capability(Principal, admin)),
    assertion(\+ node_auth:principal_has_capability(Principal, internal_transport)).

:- end_tests(t4_tiers).

%  IP/CIDR access control (node_ip_policy): spoof-resistant client-IP
%  resolution + allow/block lists at the execution edge. Off by default.
:- begin_tests(t4_ip).

reset_ip_lists :-
    node_ip_policy:set_ip_blocklist([]),
    node_ip_policy:set_ip_allowlist([]).

test(ipv4_cidr_in_range) :-
    assertion(node_ip_policy:ip_matches("1.2.3.4", '1.2.3.0/24')).
test(ipv4_cidr_out_of_range) :-
    assertion(\+ node_ip_policy:ip_matches("1.2.4.4", '1.2.3.0/24')).
test(ipv4_slash32_is_exact) :-
    assertion(node_ip_policy:ip_matches("9.9.9.9", '9.9.9.9/32')),
    assertion(\+ node_ip_policy:ip_matches("9.9.9.10", '9.9.9.9/32')).
test(ipv4_slash0_matches_all) :-
    assertion(node_ip_policy:ip_matches("203.0.113.7", '0.0.0.0/0')).
test(exact_ipv4_match) :-
    assertion(node_ip_policy:ip_matches("8.8.8.8", '8.8.8.8')),
    assertion(\+ node_ip_policy:ip_matches("8.8.8.9", '8.8.8.8')).
test(exact_ipv6_match) :-
    assertion(node_ip_policy:ip_matches("::1", '::1')).
test(ipv4_cidr_never_matches_ipv6) :-
    assertion(\+ node_ip_policy:ip_matches("::1", '10.0.0.0/8')).

test(client_ip_uses_peer_when_direct, IP == "203.0.113.5") :-
    node_auth:client_ip([peer(ip(203,0,113,5)), method(get)], IP).
test(client_ip_ignores_xff_from_untrusted_peer, IP == "203.0.113.5") :-
    node_auth:client_ip([peer(ip(203,0,113,5)),
                              x_forwarded_for("1.1.1.1")], IP).
test(client_ip_uses_rightmost_xff_from_trusted_proxy, IP == "203.0.113.9") :-
    node_auth:client_ip([peer(ip(172,17,0,2)),
                              x_forwarded_for("1.1.1.1, 203.0.113.9")], IP).

test(off_by_default_denies_nothing, [setup(reset_ip_lists), cleanup(reset_ip_lists)]) :-
    assertion(\+ node_ip_policy:ip_access_denied([peer(ip(203,0,113,5))])).

test(blocklist_bars_a_range, [
        setup(node_ip_policy:set_ip_blocklist(['203.0.113.0/24'])),
        cleanup(reset_ip_lists)
     ]) :-
    assertion(node_ip_policy:ip_access_denied([peer(ip(203,0,113,5))])),
    assertion(\+ node_ip_policy:ip_access_denied([peer(ip(198,51,100,5))])).

test(allowlist_bars_everything_else, [
        setup(node_ip_policy:set_ip_allowlist(['10.0.0.0/8'])),
        cleanup(reset_ip_lists)
     ]) :-
    assertion(\+ node_ip_policy:ip_access_denied([peer(ip(10,1,2,3))])),
    assertion(node_ip_policy:ip_access_denied([peer(ip(203,0,113,5))])).

test(blocklist_wins_within_allowlist, [
        setup(( node_ip_policy:set_ip_allowlist(['10.0.0.0/8']),
                node_ip_policy:set_ip_blocklist(['10.6.6.0/24']) )),
        cleanup(reset_ip_lists)
     ]) :-
    assertion(node_ip_policy:ip_access_denied([peer(ip(10,6,6,6))])),
    assertion(\+ node_ip_policy:ip_access_denied([peer(ip(10,1,1,1))])).

:- end_tests(t4_ip).

%  Per-IP anonymous identity (node_auth, anon_per_ip): individualise the
%  shared anonymous principal per client IP so it is not one rate / limit
%  / audit bucket for the whole internet. Off by default.
:- begin_tests(t4_anon_ip).

reset_anon_ip :-
    set_setting(node_auth:anon_per_ip, false).

clear_global_rate :-
    node_rate_limits:clear_rate_limit_scope(global).

test(off_by_default_anonymous_is_the_shared_atom, P == anonymous) :-
    set_setting(node_auth:anon_per_ip, false),
    node_auth:request_principal([peer(ip(203,0,113,5)), method(get), path('/call')], P).

test(per_ip_individualises_anonymous, [
        setup(set_setting(node_auth:anon_per_ip, true)),
        cleanup(reset_anon_ip)
     ]) :-
    node_auth:request_principal([peer(ip(203,0,113,5)), method(get), path('/call')], P1),
    node_auth:request_principal([peer(ip(198,51,100,9)), method(get), path('/call')], P2),
    node_auth:principal_id(P1, Id1),
    node_auth:principal_id(P2, Id2),
    assertion(Id1 == "anon:203.0.113.5"),
    assertion(Id2 == "anon:198.51.100.9"),
    assertion(Id1 \== Id2).

test(per_ip_uses_forwarded_for_behind_trusted_proxy, Id == "anon:203.0.113.9") :-
    setup_call_cleanup(
        set_setting(node_auth:anon_per_ip, true),
        ( node_auth:request_principal(
              [peer(ip(172,17,0,2)),
               x_forwarded_for("1.1.1.1, 203.0.113.9"),
               method(get), path('/call')],
              P),
          node_auth:principal_id(P, Id) ),
        reset_anon_ip).

test(per_ip_rate_buckets_are_independent, [
        setup(( clear_global_rate,
                set_setting(node_auth:anon_per_ip, true),
                set_setting(node_rate_limits:max_call_requests_per_window, 2) )),
        cleanup(( reset_anon_ip,
                  set_setting(node_rate_limits:max_call_requests_per_window, 500),
                  clear_global_rate ))
     ]) :-
    node_auth:request_principal([peer(ip(10,0,0,1)), path('/call')], A),
    node_auth:request_principal([peer(ip(10,0,0,2)), path('/call')], B),
    %  IP A: two allowed, the third exceeds its own bucket
    node_rate_limits:enforce_call_request_rate_limit(A),
    node_rate_limits:enforce_call_request_rate_limit(A),
    catch(node_rate_limits:enforce_call_request_rate_limit(A), Error, true),
    assertion(nonvar(Error)),
    %  IP B is unaffected — its bucket is separate
    node_rate_limits:enforce_call_request_rate_limit(B).

:- end_tests(t4_anon_ip).

%  Temporary auto-bans (node_ip_policy): an IP that keeps tripping the
%  rate limit is auto-blocklisted for a TTL, then denied via the same
%  ip_access_denied path. Off by default (threshold 0).
:- begin_tests(t4_autoban).

reset_autoban :-
    node_ip_policy:clear_ip_bans,
    set_setting(node_ip_policy:auto_ban_threshold, 0),
    set_setting(node_ip_policy:auto_ban_seconds, 900),
    set_setting(node_ip_policy:ip_allowlist, []).

%  A request whose (trusted-proxy) client IP is the given address.
ab_request(IP, [peer(ip(127,0,0,1)), x_forwarded_for(IP), method(get), path('/call')]).

test(off_by_default_never_bans, [setup(reset_autoban), cleanup(reset_autoban)]) :-
    ab_request("9.9.9.9", R),
    forall(between(1, 10, _), node_ip_policy:record_ip_offense(R)),
    assertion(\+ node_ip_policy:ip_temp_banned("9.9.9.9")),
    assertion(\+ node_ip_policy:ip_access_denied(R)).

test(bans_after_threshold_offenses, [
        setup(( reset_autoban,
                set_setting(node_ip_policy:auto_ban_threshold, 3) )),
        cleanup(reset_autoban)
     ]) :-
    ab_request("9.9.9.9", R),
    node_ip_policy:record_ip_offense(R),
    node_ip_policy:record_ip_offense(R),
    assertion(\+ node_ip_policy:ip_temp_banned("9.9.9.9")),   % 2 < 3, not yet
    node_ip_policy:record_ip_offense(R),                       % 3rd trips it
    assertion(node_ip_policy:ip_temp_banned("9.9.9.9")),
    assertion(node_ip_policy:ip_access_denied(R)).

test(expired_ban_is_not_denied, [
        setup(( reset_autoban,
                set_setting(node_ip_policy:auto_ban_threshold, 1),
                set_setting(node_ip_policy:auto_ban_seconds, -1) )),   % already in the past
        cleanup(reset_autoban)
     ]) :-
    ab_request("9.9.9.9", R),
    node_ip_policy:record_ip_offense(R),
    assertion(\+ node_ip_policy:ip_temp_banned("9.9.9.9")).

test(allowlisted_ip_is_never_auto_banned, [
        setup(( reset_autoban,
                set_setting(node_ip_policy:auto_ban_threshold, 1),
                set_setting(node_ip_policy:ip_allowlist, ['9.9.9.0/24']) )),
        cleanup(reset_autoban)
     ]) :-
    ab_request("9.9.9.9", R),
    forall(between(1, 5, _), node_ip_policy:record_ip_offense(R)),
    assertion(\+ node_ip_policy:ip_temp_banned("9.9.9.9")).

:- end_tests(t4_autoban).

%  Cumulative metrics counters (node_metrics_counters): request / error
%  totals + rejections-by-reason, incremented at the choke points and
%  rendered as Prometheus counters by /metrics.
:- begin_tests(t4_counters).

clear_counters :-
    node_metrics_counters:clear_metric_counters_scope(global).

test(counts_requests_errors_and_reason, [setup(clear_counters), cleanup(clear_counters)]) :-
    node_metrics_counters:note_request_admitted,
    node_metrics_counters:note_request_admitted,
    node_metrics_counters:note_request_error(error(authorization_error(x, execution), ctx)),
    assertion(node_metrics_counters:metric_counter_value(requests_total, 2)),
    assertion(node_metrics_counters:metric_counter_value(errors_total, 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(auth), 1)).

test(categorises_every_rejection_reason, [setup(clear_counters), cleanup(clear_counters)]) :-
    node_metrics_counters:note_request_error(error(authorization_error(_, _), _)),
    node_metrics_counters:note_request_error(error(profile_violation(_, _), _)),
    node_metrics_counters:note_request_error(error(rate_limit_exceeded(_, _, _, _), _)),
    node_metrics_counters:note_request_error(error(permission_error(call, sandboxed, _), _)),
    node_metrics_counters:note_ip_rejection,
    assertion(node_metrics_counters:metric_counter_value(rejection(auth), 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(profile), 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(rate_limit), 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(sandbox), 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(ip), 1)).

test(uncategorised_error_still_counts_as_an_error, [setup(clear_counters), cleanup(clear_counters)]) :-
    node_metrics_counters:note_request_error(error(some_other_error, ctx)),
    assertion(node_metrics_counters:metric_counter_value(errors_total, 1)),
    assertion(node_metrics_counters:metric_counter_value(rejection(auth), 0)).

%  /metrics renders the counters (right TYPE + reason labels) after a call.
test(metrics_renders_counters) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/call?goal=true&template=true&offset=0&limit=1&format=prolog', CallURL),
          test_node:read_text(CallURL, _),
          atom_concat(URI, '/metrics', MetricsURL),
          test_node:read_text(MetricsURL, Text),
          assertion(sub_string(Text, _, _, _, "# TYPE web_prolog_requests_total counter")),
          assertion(sub_string(Text, _, _, _, "# TYPE web_prolog_errors_total counter")),
          assertion(sub_string(Text, _, _, _, "# TYPE web_prolog_rejections_total counter")),
          assertion(sub_string(Text, _, _, _, "web_prolog_rejections_total{reason=\"sandbox\"}")) )).

:- end_tests(t4_counters).

%  Config-change audit trail: admin mutations (config / principals /
%  tokens / maintenance / reclaim) are durably recorded — who/what/when —
%  in the append-only interaction log, with event names prefixed "admin:".
:- begin_tests(t4_audit).

:- dynamic t4_audit_saved/1.
:- dynamic t4_audit_logfile/1.

t4_audit_setup(LogFile) :-
    tmp_file(wp_audit, Base),
    atom_concat(Base, '.jsonl', LogFile),
    retractall(t4_audit_logfile(_)),
    assertz(t4_audit_logfile(LogFile)),
    ( setting(node_interaction_log:interaction_log_file, Old) -> true ; Old = 'logs/interactions.jsonl' ),
    retractall(t4_audit_saved(_)),
    assertz(t4_audit_saved(Old)),
    set_setting(node_interaction_log:interaction_log_file, LogFile).

t4_audit_cleanup :-
    ( t4_audit_saved(Old) -> set_setting(node_interaction_log:interaction_log_file, Old) ; true ),
    ( t4_audit_logfile(F), exists_file(F) -> catch(delete_file(F), _, true) ; true ),
    retractall(t4_audit_saved(_)),
    retractall(t4_audit_logfile(_)).

test(maintenance_toggle_is_durably_audited, [
        setup(t4_audit_setup(LogFile)), cleanup(t4_audit_cleanup)
     ]) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/admin/maintenance', URL),
          http_post(URL, json(_{enabled:true}), _Reply, [json_object(dict)]) )),
    read_file_to_string(LogFile, Text, []),
    assertion(sub_string(Text, _, _, _, "\"event\":\"admin:admin_maintenance\"")),
    %  the log pipeline stringifies field values, so enabled is "true"
    assertion(sub_string(Text, _, _, _, "\"enabled\":\"true\"")),
    assertion(sub_string(Text, _, _, _, "\"action\":\"admin_maintenance\"")).

test(token_issue_is_audited_without_the_secret, [
        setup(t4_audit_setup(LogFile)), cleanup(t4_audit_cleanup)
     ]) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/admin/tokens', URL),
          http_post(URL, json(_{principal:"audit-bot", capabilities:["execute"]}),
                    Reply, [json_object(dict)]),
          get_dict(token, Reply, FullToken) )),
    read_file_to_string(LogFile, Text, []),
    assertion(sub_string(Text, _, _, _, "\"event\":\"admin:admin_token_issue\"")),
    assertion(sub_string(Text, _, _, _, "audit-bot")),
    %  the one-time secret must never be written to the audit trail
    assertion(\+ sub_string(Text, _, _, _, FullToken)).

:- end_tests(t4_audit).

%  /admin/doctor self-diagnostics (node_doctor): a green/amber/red review
%  of the node's security and operational posture.
:- begin_tests(t4_doctor).

test(doctor_reports_checks_and_overall_status) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/admin/doctor', URL),
          test_node:read_json_answer(URL, J),
          get_dict(status, J, Status),
          get_dict(checks, J, Checks),
          assertion(memberchk(Status, ["ok", "warn", "fail"])),
          assertion(Checks \== []),
          assertion(( member(C1, Checks), get_dict(id, C1, "sandbox") )),
          assertion(( member(C2, Checks), get_dict(id, C2, "auth") )) )).

test(doctor_warns_on_open_auth, true(AuthStatus == "warn")) :-
    test_node:with_node_server_options([auth(open)], URI,
        ( atom_concat(URI, '/admin/doctor', URL),
          test_node:read_json_answer(URL, J),
          get_dict(checks, J, Checks),
          once(( member(C, Checks), get_dict(id, C, "auth") )),
          get_dict(status, C, AuthStatus) )).

test(doctor_fails_when_sandbox_is_off, true(Overall == "fail")) :-
    test_node:with_node_server_options([sandbox(off)], URI,
        ( atom_concat(URI, '/admin/doctor', URL),
          test_node:read_json_answer(URL, J),
          get_dict(status, J, Overall) )).

:- end_tests(t4_doctor).

%  /admin/posture (node_admin): a read-only view of security/ops settings
%  configured outside the editable Config form (registered tier, anon
%  per-IP, load_uri origins, RELATION patterns, IP allow/block/auto-ban,
%  in-memory log capacity/retention). GET, admin-gated.
:- begin_tests(t4_posture).

test(posture_reports_safe_defaults) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/admin/posture', URL),
          test_node:read_json_answer(URL, J),
          assertion(get_dict(ip_allowlist, J, [])),
          assertion(get_dict(ip_blocklist, J, [])),
          assertion(get_dict(authenticated_default_capabilities, J, [])),
          assertion(get_dict(auto_ban_threshold, J, 0)),
          assertion(( get_dict(log_capacity, J, Cap), integer(Cap), Cap > 0 )),
          assertion(get_dict(anon_per_ip, J, _)) )).

test(posture_reflects_ip_blocklist,
     [ setup(node_ip_policy:set_ip_blocklist(['203.0.113.0/24'])),
       cleanup(node_ip_policy:set_ip_blocklist([])),
       true(Block == ["203.0.113.0/24"]) ]) :-
    test_node:with_node_server(URI,
        ( atom_concat(URI, '/admin/posture', URL),
          test_node:read_json_answer(URL, J),
          get_dict(ip_blocklist, J, Block) )).

:- end_tests(t4_posture).

%  The Phase-6 gate's "profile matrix verified": the Route Matrix from
%  docs/PROFILE_MATRIX.md, transcribed as data and checked exhaustively
%  against node_profile_policy:profile_allows_route/2.
:- begin_tests(t4_profile_matrix).

matrix_route(call).
matrix_route(toplevel_spawn).
matrix_route(toplevel_call).
matrix_route(toplevel_next).
matrix_route(toplevel_poll).
matrix_route(toplevel_stop).
matrix_route(toplevel_abort).
matrix_route(toplevel_respond).
matrix_route(ws).

%  PROFILE_MATRIX.md "Route Matrix" verbatim.
matrix_allows(relation, [call]).
matrix_allows(isobase,  [call]).
matrix_allows(isotope,  [call, toplevel_spawn, toplevel_call, toplevel_next,
                         toplevel_poll, toplevel_stop, toplevel_abort,
                         toplevel_respond]).
matrix_allows(actor,    [call, toplevel_spawn, toplevel_call, toplevel_next,
                         toplevel_poll, toplevel_stop, toplevel_abort,
                         toplevel_respond, ws]).

test(route_matrix_exhaustive, Mismatches == []) :-
    findall(Profile-Route-expected(Expected)-got(Got),
            ( matrix_allows(Profile, Allowed),
              matrix_route(Route),
              (   memberchk(Route, Allowed)
              ->  Expected = allowed
              ;   Expected = denied
              ),
              (   node_profile_policy:profile_allows_route(Profile, Route)
              ->  Got = allowed
              ;   Got = denied
              ),
              Expected \== Got
            ),
            Mismatches).

:- end_tests(t4_profile_matrix).

:- use_module(library(http/websocket)).

%  WS spawn cleanup (node_ws): a toplevel_spawn whose *initial* load_text
%  fails must tear the session down completely. The old path called
%  toplevel_abort/1, which only interrupts the current goal — it left the
%  idle actor alive plus its ws_actor/2 row, committed capacity, and
%  isotope state. (use_module/1 is a forbidden directive in every sandbox
%  mode, so it is a reliable initial-load failure.)
:- begin_tests(t4_ws_spawn_cleanup).

test(failed_initial_load_leaks_no_actor_or_capacity, Type == "error") :-
    test_node:with_node_server(URI,
        (
            atom_concat(URI, '/ws', HttpWsURI),
            sub_atom(HttpWsURI, 4, _, 0, Tail),
            atom_concat(ws, Tail, WsURI),
            setup_call_cleanup(
                http_open_websocket(WsURI, WS,
                                    [request_header('Origin'=URI)]),
                (
                    %  Snapshot the actor/capacity rows before this failed
                    %  session, so we measure what *it* leaks rather than
                    %  the global set — rows left by earlier tests (whose
                    %  async teardown may not have settled before their
                    %  server stopped) would otherwise fail this assertion
                    %  under slower CI scheduling.
                    findall(P, node_ws:ws_actor(_, P), ActorsBefore),
                    findall(R, node_limits:principal_limit_resource(
                                   _, ws_actor, _, R), CapacityBefore),
                    test_node:ws_send_json(WS,
                        json{command:toplevel_spawn,
                             options:"[session(true)]",
                             load_text:":- use_module(library(lists))."}),
                    test_node:ws_receive_json(WS, Reply),
                    get_dict(type, Reply, Type),
                    %  Nothing about the failed session may survive. The
                    %  teardown completes just after the error reply is
                    %  sent, so wait (bounded) for it to add no new rows
                    %  before asserting, rather than racing it.
                    test_node:wait_until(
                        ( forall(node_ws:ws_actor(_, P1),
                                 memberchk(P1, ActorsBefore)),
                          forall(node_limits:principal_limit_resource(
                                     _, ws_actor, _, R1),
                                 memberchk(R1, CapacityBefore)) ),
                        100),
                    assertion(forall(node_ws:ws_actor(_, P2),
                                     memberchk(P2, ActorsBefore))),
                    assertion(forall(node_limits:principal_limit_resource(
                                         _, ws_actor, _, R2),
                                     memberchk(R2, CapacityBefore)))
                ),
                catch(ws_close(WS, 1000, done), _, true)
            )
        )).

:- end_tests(t4_ws_spawn_cleanup).

%  Pins for intentional deviations recorded in DEVIATIONS.md — these
%  are OUR behavior, deliberately different from the demonstrator, so
%  they live here rather than in the adapted demonstrator suites.
:- begin_tests(t4_deviations).

%  2026-06-11: a browser's same-origin Origin header must be accepted
%  on non-default ports (the portal's ACTOR mode on a locally run
%  node).  The demonstrator drops the port when reconstructing the
%  host origin and rejects the handshake.
test(ws_same_origin_with_explicit_port_accepted, Reply == "spawned") :-
    test_node:with_node_server(URI,
        (
            %  http://localhost:P  ->  ws://localhost:P/ws
            atom_concat(URI, '/ws', HttpWsURI),
            sub_atom(HttpWsURI, 4, _, 0, Tail),
            atom_concat(ws, Tail, WsURI),
            setup_call_cleanup(
                http_open_websocket(WsURI, WS,
                                    [request_header('Origin'=URI)]),
                (
                    test_node:ws_send_json(WS,
                        json{command:toplevel_spawn, options:"[session(true)]"}),
                    test_node:ws_receive_json(WS, Spawned),
                    get_dict(type, Spawned, Reply)
                ),
                catch(ws_close(WS, 1000, done), _, true)
            )
        )).

%  2026-06-13: node_request_port must key node identity on the bind
%  port (the `httpd@<port>` pool client id), not on the request's
%  port(_) field, which SWI derives from the client-controlled Host
%  header.  Behind a port-remapping front end (Docker `-p 8080:3060`,
%  a multi-node reverse proxy) the Host port differs from the bind
%  port; preferring it resolved a non-existent runtime, so /readyz
%  reported 503 and per-node work broke.  Verified live in a container
%  published on a remapped port.
test(request_port_prefers_bind_port_over_host_header, Port == 3060) :-
    Request = [ pool(client('httpd@3060', user:http_dispatch, in, out)),
                port(8080),                 % Host-header-derived, remapped
                host(localhost), method(get), path('/readyz') ],
    node_runtime_state:node_request_port(Request, Port).

test(request_port_falls_back_to_host_port_without_pool, Port == 7000) :-
    Request = [ port(7000), host(localhost), method(get), path('/readyz') ],
    node_runtime_state:node_request_port(Request, Port).

%  2026-06-13: the forwarded identity header (X-Web-Prolog-User) is a
%  *claimed* identity with no secret, so a configured principal's
%  capabilities are granted only when the header arrives from a trusted
%  front end (loopback / private-network peer). The demonstrator honours
%  it from any peer; on a directly reachable node that lets any client
%  assume any principal by setting the header.
test(forwarded_identity_trusted_only_for_local_or_private_peer) :-
    assertion(node_auth:request_forwarded_identity_trusted([peer(ip(127,0,0,1))])),
    assertion(node_auth:request_forwarded_identity_trusted([peer(ip(172,17,0,5))])),
    assertion(\+ node_auth:request_forwarded_identity_trusted([peer(ip(8,8,8,8))])),
    assertion(\+ node_auth:request_forwarded_identity_trusted([])).

test(forwarded_user_header_grants_policy_caps_from_trusted_peer, [
        setup(node_principal_policy:set_principal_policies([principal("wp-alice", [execute])])),
        cleanup(node_principal_policy:set_principal_policies([]))
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("wp-alice"), peer(ip(127,0,0,1)), method(get), path('/call')],
        Principal),
    assertion(node_auth:principal_id(Principal, "wp-alice")),
    assertion(node_auth:principal_has_capability(Principal, execute)).

test(forwarded_user_header_denied_from_public_peer, [
        setup(node_principal_policy:set_principal_policies([principal("wp-alice", [execute])])),
        cleanup(node_principal_policy:set_principal_policies([]))
     ]) :-
    node_auth:request_principal(
        [x_web_prolog_user("wp-alice"), peer(ip(8,8,8,8)), method(get), path('/call')],
        Principal),
    %  a public client that merely sets the header is NOT granted the
    %  configured principal's execute capability
    assertion(\+ node_auth:principal_has_capability(Principal, execute)).

:- end_tests(t4_deviations).

layer_honesty :-
    %  At T4 everything new is loaded; the only violation would be the
    %  legacy src/ modules sneaking in (same module names for the node
    %  files, so check the two whose names differ).
    forall(member(M-FileSub, [ actor-'src/actor',
                               toplevel_actor-'src/toplevel_actor'
                             ]),
           (   current_module(M),
               module_property(M, file(F)),
               sub_atom(F, _, _, _, FileSub)
           ->  throw(layer_violation(legacy_module_loaded(M)))
           ;   true
           )).
