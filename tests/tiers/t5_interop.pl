/*  Tier T5: wire-level interop against the unmodified demonstrator.

    The strongest "semantics exactly preserved" check in the plan:
    the remote side is the unmodified demonstrator node, running in a
    separate OS process — module tables genuinely node-local, unlike
    the in-process harness; the local side is the new layered stack
    acting as a client: actors + isolation + toplevel_actors +
    distribution + rpc.

    The demonstrator source was removed from the working tree once the
    tiers subsumed the LEGACY suite; its last in-tree state is preserved
    under the `demonstrator-peer` git tag, which this tier extracts into
    a throwaway temp directory to launch the peer (see
    materialize_demonstrator/1).

    Covered here (client->server direction):
      - rpc/2-3 solutions and transparent paging over /call,
      - promise/3-4 + yield/2,
      - remote spawn over /ws: completion down, exit/2 with a custom
        reason, one-way send/2 driving a remote receive,
      - remote toplevel: spawn, '$call' answers, halt round-trip.

    Since Phase 6 the local side runs a new-stack node of its own, so
    the server->client direction is covered too: a remote actor on the
    demonstrator node sends pong back to a local pid over OUR /ws.
*/

:- use_module('../../prolog/web_prolog/node.pl').
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/isolation.pl').
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../prolog/web_prolog/distribution.pl').
:- use_module('../../prolog/web_prolog/rpc.pl').
:- use_module('../../prolog/web_prolog/pid_utils.pl', [register_node_self/1]).
:- use_module(library(plunit)).
:- use_module(library(socket)).
:- use_module(library(process)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(library(pcre)).
:- use_module(library(filesex), [delete_directory_and_contents/1]).

%  No tier-local hook_start_body glue: node.pl loads node_glue, which
%  is the composition.

run_tier :-
    layer_honesty,
    setup_call_cleanup(
        ( start_demonstrator_node,
          start_local_node
        ),
        run_tests([t5_interop, t5_bidirectional, t5_golden]),
        stop_demonstrator_node
    ),
    ensure_mailbox_empty.

layer_honesty :-
    %  The new node layer is loaded here by design; the violation
    %  would be the LEGACY src/ modules sneaking in locally.
    forall(member(M-FileSub, [ actor-'src/actor',
                               toplevel_actor-'src/toplevel_actor',
                               node_client-'src/node_client'
                             ]),
           (   current_module(M),
               module_property(M, file(F)),
               sub_atom(F, _, _, _, FileSub)
           ->  throw(layer_violation(legacy_module_loaded(M)))
           ;   true
           )).

%  The local new-stack node: needed for the server->client direction
%  (remote actors send back to local pids over our /ws).
:- dynamic t5_local_url/1.

start_local_node :-
    retractall(t5_local_url(_)),
    pick_free_port(Port),
    node(Port, [profile(actor), auth(open)]),
    format(atom(URL), 'http://localhost:~w', [Port]),
    register_node_self(URL),
    assertz(t5_local_url(URL)).

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


                /*******************************
                *   DEMONSTRATOR SUBPROCESS    *
                *******************************/

:- dynamic t5_node/2.                   % Process, URL
:- dynamic t5_peer_dir/1.               % extracted demonstrator tree

%  The git tag whose tree still carries the in-tree demonstrator (src/).
demonstrator_peer_tag('demonstrator-peer').

swipl_executable(Exe) :-
    (   getenv('SWIPL', Exe0)
    ->  Exe = Exe0
    ;   Exe = path(swipl)
    ).

pick_free_port(Port) :-
    tcp_socket(Socket),
    tcp_bind(Socket, Port),
    tcp_close_socket(Socket).

%!  materialize_demonstrator(-PeerDir) is det.
%
%   Extract the demonstrator tree at the `demonstrator-peer` tag into a
%   fresh temp directory. The peer process is then launched from there
%   with `use_module('src/node.pl')`, exactly as it ran when src/ lived
%   in the working tree — but without keeping that copy in the repo.
materialize_demonstrator(PeerDir) :-
    t5_dir(TiersDir),
    file_directory_name(TiersDir, TestsDir),
    file_directory_name(TestsDir, RepoDir),
    demonstrator_peer_tag(Tag),
    (   git_in(RepoDir, ['rev-parse', '--verify', '--quiet', Tag], _)
    ->  true
    ;   throw(error(t5_demonstrator_tag_missing(Tag), _))
    ),
    tmp_file(t5_demonstrator, Base),
    make_directory(Base),
    PeerDir = Base,
    format(atom(Cmd),
           "git -C '~w' archive '~w' | tar -x -C '~w'",
           [RepoDir, Tag, PeerDir]),
    process_create(path(sh), ['-c', Cmd],
                   [ process(P), stdout(null), stderr(null) ]),
    process_wait(P, Status),
    (   Status == exit(0)
    ->  true
    ;   catch(delete_directory_and_contents(PeerDir), _, true),
        throw(error(t5_demonstrator_checkout_failed(Tag, Status), _))
    ).

%!  git_in(+Dir, +Args, -Status) is det.
git_in(Dir, Args, Status) :-
    process_create(path(git), ['-C', Dir | Args],
                   [ process(P), stdout(null), stderr(null) ]),
    process_wait(P, Status),
    Status == exit(0).

start_demonstrator_node :-
    retractall(t5_node(_, _)),
    materialize_demonstrator(PeerDir),
    assertz(t5_peer_dir(PeerDir)),
    pick_free_port(Port),
    format(atom(URL), 'http://localhost:~w', [Port]),
    format(atom(Goal),
           "use_module('src/node.pl'), node(~w, [profile(actor), auth(open)])",
           [Port]),
    swipl_executable(Exe),
    %  The -t goal must be ground (it is stored in a prolog flag);
    %  waiting for a message that never arrives blocks forever.
    process_create(Exe,
                   [ '-q', '-g', Goal, '-t', 'thread_get_message(quit)' ],
                   [ cwd(PeerDir),
                     process(Process),
                     stdout(null),
                     stderr(null)
                   ]),
    assertz(t5_node(Process, URL)),
    (   wait_node_ready(URL, 20)
    ->  true
    ;   stop_demonstrator_node,
        throw(error(t5_node_not_ready(URL), _))
    ).

%  prolog_load_context/2 is only meaningful at load time; capture the
%  directory now.
:- dynamic t5_dir/1.
:- prolog_load_context(directory, D),
   asserta(t5_dir(D)).

wait_node_ready(URL, Tries) :-
    Tries > 0,
    atom_concat(URL, '/call?goal=true&format=prolog', ProbeURL),
    (   catch(
            setup_call_cleanup(
                http_open(ProbeURL, Stream, [timeout(2)]),
                read(Stream, Reply),
                close(Stream)),
            _, fail),
        Reply = success(_, _)
    ->  true
    ;   sleep(0.5),
        Tries1 is Tries - 1,
        wait_node_ready(URL, Tries1)
    ).

stop_demonstrator_node :-
    forall(retract(t5_node(Process, _)),
           ( catch(process_kill(Process), _, true),
             catch(process_wait(Process, _), _, true)
           )),
    forall(retract(t5_peer_dir(Dir)),
           catch(delete_directory_and_contents(Dir), _, true)).

node_url(URL) :-
    t5_node(_, URL).


                /*******************************
                *            TESTS             *
                *******************************/

:- begin_tests(t5_interop, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(rpc_solutions, Xs == [a, b, c]) :-
   node_url(URL),
   findall(X, rpc(URL, member(X, [a, b, c])), Xs).

test(rpc_paging_across_requests, Ns == [1, 2, 3, 4, 5]) :-
   node_url(URL),
   findall(N, rpc(URL, between(1, 5, N), [limit(2)]), Ns).

test(rpc_once, X == 1) :-
   node_url(URL),
   rpc(URL, between(1, 5, X), [once(true)]),
   !.

test(promise_yield, Rows == [1, 2, 3]) :-
   node_url(URL),
   promise(URL, member(X, [1, 2, 3]), Ref, [template(X)]),
   yield(Ref, Msg),
   Msg = success(Rows, _).

test(remote_spawn_completion_down, Reason == true) :-
   node_url(URL),
   flush_shell_mailbox,
   spawn(true, Pid, [node(URL), monitor(true)]),
   receive({
       down(_, Pid, Reason) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

test(remote_spawn_exit_custom_reason, Reason == test_reason) :-
   node_url(URL),
   spawn(receive({never -> true}), Pid, [node(URL), monitor(true)]),
   exit(Pid, test_reason),
   receive({
       down(_, Pid, Reason) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

%  One-way send: drive a remote receive loop from the local side.
%  (The pong direction needs the local side to be a node — Phase 6.)
test(remote_send_drives_remote_receive, Reason == told_to_stop) :-
   node_url(URL),
   spawn(receive({ go -> exit(told_to_stop) }), Pid,
         [node(URL), monitor(true)]),
   send(Pid, go),
   receive({
       down(_, Pid, Reason) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

test(remote_toplevel_call_answers, Rows == [a, b]) :-
   node_url(URL),
   toplevel_spawn(Pid, [node(URL), session(true), monitor(true)]),
   toplevel_call(Pid, member(X, [a, b]), [template(X)]),
   receive({
       success(Pid, Rows, false) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]),
   toplevel_halt(Pid, _Reply),
   receive({
       down(_, Pid, _) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

test(remote_toplevel_halt_reply, Reply == true) :-
   node_url(URL),
   toplevel_spawn(Pid, [node(URL), session(true), monitor(true)]),
   toplevel_halt(Pid, Reply),
   receive({
       down(_, Pid, _) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

:- end_tests(t5_interop).


                /*******************************
                *   DIFFERENTIAL GOLDEN TESTS  *
                *******************************/

%  The plan's "golden response tests" (§3.4, Phase 6 gate), in their
%  strongest form: the same HTTP request goes to the UNMODIFIED
%  demonstrator and to the new-stack node, and the raw response
%  bodies must be identical byte for byte (after masking pids, the
%  only legitimately nondeterministic content).

fetch_raw(BaseURL, PathAndQuery, Status, Body) :-
    atom_concat(BaseURL, PathAndQuery, URL),
    setup_call_cleanup(
        http_open(URL, Stream, [status_code(Status), timeout(10)]),
        read_string(Stream, _, Body),
        close(Stream)).

mask_pids(S0, S) :-
    re_replace("[0-9]{9,}"/g, "PID", S0, S).

both_nodes_agree(PathAndQuery, Status, Masked) :-
    node_url(LegacyURL),
    t5_local_url(NewURL),
    fetch_raw(LegacyURL, PathAndQuery, LegacyStatus, LegacyBody),
    fetch_raw(NewURL, PathAndQuery, NewStatus, NewBody),
    mask_pids(LegacyBody, LegacyMasked),
    mask_pids(NewBody, NewMasked),
    (   LegacyStatus == NewStatus,
        LegacyMasked == NewMasked
    ->  Status = LegacyStatus,
        Masked = LegacyMasked
    ;   throw(golden_mismatch(PathAndQuery,
                              legacy(LegacyStatus, LegacyMasked),
                              new(NewStatus, NewMasked)))
    ).

:- begin_tests(t5_golden).

test(call_prolog_success) :-
    both_nodes_agree('/call?goal=member(X,[a,b,c])&template=X&format=prolog', _, _).

test(call_prolog_paged_more) :-
    both_nodes_agree('/call?goal=between(1,9,N)&template=N&limit=3&format=prolog', _, _).

test(call_prolog_failure) :-
    both_nodes_agree('/call?goal=fail&format=prolog', _, _).

test(call_prolog_existence_error) :-
    %  format=prolog passes the raw error term through, including the
    %  prolog_stack context — which embeds internal module names,
    %  stack depths (the hook indirections add frames), and
    %  GC-timing artifacts ('<garbage_collected>') that are not
    %  byte-stable even between runs of one implementation.  The
    %  frozen surface is the error formal; compare up to context(.
    %  See DEVIATIONS.md.
    node_url(LegacyURL),
    t5_local_url(NewURL),
    fetch_raw(LegacyURL, '/call?goal=unknown_pred_xyz_77&format=prolog', S1, B1),
    fetch_raw(NewURL, '/call?goal=unknown_pred_xyz_77&format=prolog', S2, B2),
    S1 == S2,
    mask_pids(B1, M1),
    mask_pids(B2, M2),
    sub_string(M1, Before1, _, _, "context("),
    sub_string(M2, Before2, _, _, "context("),
    sub_string(M1, 0, Before1, _, Formal1),
    sub_string(M2, 0, Before2, _, Formal2),
    (   Formal1 == Formal2
    ->  true
    ;   throw(golden_mismatch(existence_error_formal,
                              legacy(Formal1), new(Formal2)))
    ).

test(call_prolog_once) :-
    both_nodes_agree('/call?goal=between(1,5,N)&template=N&once=true&format=prolog', _, _).

test(call_json_success) :-
    both_nodes_agree('/call?goal=member(X,[a,b])&template=X', _, _).

test(call_json_failure) :-
    both_nodes_agree('/call?goal=fail', _, _).

test(call_json_existence_error) :-
    both_nodes_agree('/call?goal=unknown_pred_xyz_77', _, _).

test(call_parse_error) :-
    both_nodes_agree('/call?goal=foo(&format=prolog', _, _).

test(call_json_load_text) :-
    both_nodes_agree('/call?goal=p(X)&template=X&load_text=p(1).%0Ap(2).', _, _).

test(node_info_agrees) :-
    %  The layered node extends /node_info with additive metadata the
    %  frozen demonstrator does not emit (provides, services,
    %  self_contained, tutorial_sections, ws_allowed_origins — see
    %  DEVIATIONS.md).  The interop invariant is therefore preservation,
    %  not byte-equality: every field the demonstrator emits must still be
    %  present and identical (ports masked); the layered node may only add
    %  fields, never alter or drop one.
    %
    %  node_info embeds the node URL (different ports) — mask the port
    %  digits before comparing.
    node_url(LegacyURL),
    t5_local_url(NewURL),
    fetch_raw(LegacyURL, '/node_info', S1, B1),
    fetch_raw(NewURL, '/node_info', S2, B2),
    S1 == S2,
    re_replace(":[0-9]+"/g, ":PORT", B1, M1),
    re_replace(":[0-9]+"/g, ":PORT", B2, M2),
    atom_json_dict(M1, Legacy, []),
    atom_json_dict(M2, New, []),
    forall(get_dict(Key, Legacy, LegacyVal),
           (   get_dict(Key, New, NewVal)
           ->  (   NewVal == LegacyVal
               ->  true
               ;   throw(golden_mismatch('/node_info'-Key,
                                         legacy(LegacyVal), new(NewVal)))
               )
           ;   throw(golden_mismatch('/node_info'-missing(Key),
                                     legacy(LegacyVal), new(absent)))
           )).

:- end_tests(t5_golden).


:- begin_tests(t5_bidirectional, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

%  Full round trip across implementations: an actor on the
%  DEMONSTRATOR node receives ping(From) where From is a pid on OUR
%  new-stack node, and its reply crosses back over our /ws.
test(ping_pong_across_implementations, Got == pong) :-
   node_url(RemoteURL),
   self(Self),
   spawn(receive({ ping(From) -> From ! pong }), Pid,
         [node(RemoteURL), monitor(true)]),
   send(Pid, ping(Self)),
   receive({
       pong -> Got = pong
   }, [
       timeout(5),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, _) -> true
   }, [
       timeout(5),
       on_timeout(fail)
   ]).

:- end_tests(t5_bidirectional).
