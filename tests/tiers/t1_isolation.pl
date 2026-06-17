/*  Tier T1: actors + isolation, with the composition glue.

    Loads layer 0 (actors) and layer 1 (isolation) and installs the
    hook_start_body glue exactly as the umbrella will (Phase 7), then
    verifies:

      - layer honesty: no toplevel/distribution/node modules, no legacy
        src/ modules, no websocket client;
      - per-actor module isolation and the load_text/load_list/
        load_uri/load_predicates options (adapted from the
        demonstrator's actor_tests.pl, pid-shape-agnostic);
      - the actor I/O prelude routing (writeln -> terminal_io_output);
      - the spawn handshake on preparation errors (src_* rejection
        surfaces as a thrown error from spawn/3);
      - isolation hook contracts: prepare_module/3 extension and
        prepare_goal/3 rewriting.
*/

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/isolation.pl').
:- use_module(library(plunit)).

%  The composition glue: every local spawn prepares a private module.
%  This is the single transformation chain rule from the plan (§2.3):
%  one clause, defined by the composition layer, never interleaved.
actors:hook_start_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
    isolation:spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner).

run_tier :-
    layer_honesty,
    run_tests([ t1_isolation,
                t1_hooks
              ]),
    ensure_mailbox_empty.

layer_honesty :-
    forall(member(M, [ toplevel_actors,
                       distribution,
                       node,
                       actor,                 % legacy src/actor.pl
                       actor_source,          % legacy src/actor_source.pl
                       source_loader,         % legacy src/source_loader.pl
                       node_controller,
                       remote_protocol,
                       pid_utils,
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

actor_test_p(a). actor_test_p(b). actor_test_p(c).


:- begin_tests(t1_isolation, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(load_list, Msg == ready) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       load_list([
           (run(Parent) :- send(Parent, ready))
       ])
   ]),
   receive({
       ready -> Msg = ready
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(load_text, Msg == hello_from_text) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       load_text("run(Parent) :- send(Parent, hello_from_text).")
   ]),
   receive({
       hello_from_text -> Msg = hello_from_text
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(load_predicates, Value == a) :-
   self(Self),
   spawn(user:run(Self), _Pid, [
       link(false),
       load_predicates([actor_test_p/1]),
       load_list([
           (run(Parent) :-
               actor_test_p(V),
               send(Parent, value(V)),
               !)
       ])
   ]),
   receive({
       value(Value) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(load_uri_file_scheme, Msg == hello_from_file) :-
   self(Self),
   tmp_file_stream(text, File, Stream),
   format(Stream, "run(Parent) :- send(Parent, hello_from_file).~n", []),
   close(Stream),
   atom_concat('file://', File, URI),
   spawn(run(Self), _Pid, [
       link(false),
       load_uri(URI)
   ]),
   receive({
       hello_from_file -> Msg = hello_from_file
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   catch(delete_file(File), _, true).

%  Two actors load conflicting definitions of the same predicate; each
%  must see only its own, and nothing leaks into the caller's module.
test(private_databases_do_not_crosstalk, Values == [from_a, from_b]) :-
   self(Self),
   spawn(run(Self), _A, [
       link(false),
       load_list([ (secret(from_a)),
                   (run(Parent) :- secret(V), send(Parent, a(V))) ])
   ]),
   spawn(run(Self), _B, [
       link(false),
       load_list([ (secret(from_b)),
                   (run(Parent) :- secret(V), send(Parent, b(V))) ])
   ]),
   receive({ a(VA) -> true }, [timeout(1), on_timeout(fail)]),
   receive({ b(VB) -> true }, [timeout(1), on_timeout(fail)]),
   Values = [VA, VB],
   \+ current_predicate(user:secret/1).

test(io_prelude_routes_writeln, Data == hello_io_prelude) :-
   self(Self),
   message_queue_create(Queue),
   spawn(run, _Pid, [
       link(false),
       target(Queue),
       load_text("run :- writeln(hello_io_prelude).")
   ]),
   (   thread_get_message(Queue, terminal_io_output(_, Data), [timeout(1)])
   ->  true
   ;   Data = timeout
   ),
   message_queue_destroy(Queue),
   send(Self, sync), receive({ sync -> true }).

test(src_options_are_rejected,
     true(Error = error(domain_error(load_source_option, src_text(_)), _))) :-
   catch(spawn(true, _Pid, [src_text("foo."), link(false)]),
         Error,
         true),
   nonvar(Error).

test(consult_load_list_extends_private_db, Msg == extended) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       load_list([
           (run(Parent) :-
               isolation:consult_load_list([ (extra(extended)) ]),
               extra(V),
               send(Parent, V))
       ])
   ]),
   receive({
       extended -> Msg = extended
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

:- end_tests(t1_isolation).


:- begin_tests(t1_hooks, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

:- dynamic t1_pm_active/0.
:- dynamic t1_pg_active/0.

%  Static hook clauses gated by dynamic flags (the pattern real layers
%  use, minus the flags).
isolation:prepare_module(Module, _GoalModule, _Options) :-
   t1_pm_active,
   Module:assertz(t1_marker(installed)).

isolation:prepare_goal(_Module, t1_goal_probe(Parent), actors:send(Parent, was_rewritten)) :-
   t1_pg_active.

test(prepare_module_extends_actor_module, [
        true(Msg == installed),
        setup(assertz(t1_pm_active)),
        cleanup(retractall(t1_pm_active))
     ]) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       load_list([
           (run(Parent) :- t1_marker(V), send(Parent, V))
       ])
   ]),
   receive({
       installed -> Msg = installed
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(prepare_goal_rewrites_start_goal, [
        true(Msg == was_rewritten),
        setup(assertz(t1_pg_active)),
        cleanup(retractall(t1_pg_active))
     ]) :-
   self(Self),
   spawn(user:t1_goal_probe(Self), _Pid, [link(false)]),
   receive({
       was_rewritten -> Msg = was_rewritten
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

%  Default check: without the flags, the hooks are inert.
test(hooks_inert_without_clauses, Msg == plain) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       load_list([
           (run(Parent) :-
               (   current_predicate(t1_marker/1)
               ->  send(Parent, polluted)
               ;   send(Parent, plain)
               ))
       ])
   ]),
   receive({
       Msg -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

:- end_tests(t1_hooks).
