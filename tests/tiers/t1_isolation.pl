/*  Tier T1: actors + isolation, with the composition glue.

    Loads layer 0 (actors) and layer 1 (isolation) and installs the
    hook_start_body glue exactly as the umbrella will (Phase 7), then
    verifies:

      - layer honesty: no toplevel/distribution/node modules, no legacy
        src/ modules, no websocket client;
      - per-actor module isolation and the src_text/src_list/
        src_uri/src_predicates options (adapted from the
        demonstrator's actor_tests.pl, pid-shape-agnostic);
      - the actor I/O prelude routing (writeln -> terminal_io_output);
      - canonical source options and spawn-time source preparation;
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
                t1_hooks,
                t1_io_inheritance,
                t1_load_options
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

test(src_list, Msg == ready) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_list([
           (run(Parent) :- send(Parent, ready))
       ])
   ]),
   receive({
       ready -> Msg = ready
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(src_text, Msg == hello_from_text) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_text("run(Parent) :- send(Parent, hello_from_text).")
   ]),
   receive({
       hello_from_text -> Msg = hello_from_text
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(src_text_operator_directive_affects_following_terms,
     Term == likes(alice, bob)) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_text("
:- op(500, xfx, likes).
run(Parent) :-
    Term = (alice likes bob),
    send(Parent, term(Term)).
")
   ]),
   receive({ term(Term) -> true }, [timeout(1), on_timeout(fail)]).

test(src_predicates, Value == a) :-
   self(Self),
   spawn(user:run(Self), _Pid, [
       link(false),
       src_predicates([actor_test_p/1]),
       src_list([
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
       src_uri(URI)
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
       src_list([ (secret(from_a)),
                   (run(Parent) :- secret(V), send(Parent, a(V))) ])
   ]),
   spawn(run(Self), _B, [
       link(false),
       src_list([ (secret(from_b)),
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
       isolation_io(generated),
       src_text("run :- writeln(hello_io_prelude).")
   ]),
   (   thread_get_message(Queue, terminal_io_output(_, Data), [timeout(1)])
   ->  true
   ;   Data = timeout
   ),
   message_queue_destroy(Queue),
   send(Self, sync), receive({ sync -> true }).

test(precompiled_io_routes_writeln, Data == hello_precompiled_io) :-
   self(Self),
   message_queue_create(Queue),
   spawn(run, _Pid, [
       link(false),
       target(Queue),
       src_text("run :- writeln(hello_precompiled_io).")
   ]),
   (   thread_get_message(Queue, terminal_io_output(_, Data), [timeout(1)])
   ->  true
   ;   Data = timeout
   ),
   message_queue_destroy(Queue),
   send(Self, sync), receive({ sync -> true }).

test(precompiled_io_rejects_format_call_specifier,
     true(Error = error(permission_error(use, format_specifier, '~@'), _))) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_text("run(Parent) :- catch(format('~@', [true]), E, send(Parent, error(E))).")
   ]),
   receive({
       error(Error) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(precompiled_io_preserves_meta_call_context, Value == local) :-
   self(Self),
   message_queue_create(Queue),
   spawn(run(Self), _Pid, [
       link(false),
       target(Queue),
       src_text("
run(Parent) :-
    time(local_value(Value)),
    send(Parent, value(Value)).
local_value(local).
")
   ]),
   receive({
       value(Value) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   thread_get_message(Queue, terminal_io_output(_, timing_report(_)),
                      [timeout(1)]),
   message_queue_destroy(Queue).

test(private_source_can_override_precompiled_io, Msg == overridden) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_text("
writeln(Parent) :-
    send(Parent, overridden).
run(Parent) :-
    writeln(Parent).
")
   ]),
   receive({
       overridden -> Msg = overridden
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(consult_load_list_extends_private_db, Msg == extended) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_list([
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

test(actor_exit_bypasses_application_catch_and_runs_cleanup) :-
   self(Self),
   setup_call_cleanup(
       spawn(run(Self), Pid, [
           link(false),
           monitor(true),
           src_text("
run(Parent) :-
    setup_call_cleanup(
        send(Parent, ready),
        catch(sleep(60), _, (send(Parent, application_recovered), repeat)),
        send(Parent, cleaned)).
")
       ]),
       ( receive({ ready -> true }, [timeout(1), on_timeout(fail)]),
         exit(Pid, killed_by_test),
         receive({ cleaned -> true }, [timeout(1), on_timeout(fail)]),
         receive({
             application_recovered -> throw(exit_was_caught);
             down(Pid, _, killed_by_test) -> true
         }, [timeout(1), on_timeout(fail)])
       ),
       catch(exit(Pid, test_cleanup), _, true)).

test(control_guard_preserves_variable_receive_head, Msg == hello) :-
   control_guard:rewrite_goal(test_t1_receive,
                              receive({Msg -> true}), GuardedReceive),
   self(Self),
   send(Self, hello),
   call(GuardedReceive).

test(control_guard_restores_variable_goal_without_recursing) :-
   control_guard:restore_goal(test_t1_restore, Goal, Restored),
   assertion(Goal == Restored).

test(actor_exit_bypasses_catch_inside_receive_body) :-
   self(Self),
   setup_call_cleanup(
       spawn(run(Self), Pid, [
           link(false),
           monitor(true),
           src_text("
run(Parent) :-
    send(Parent, receive_ready),
    setup_call_cleanup(
        true,
        receive({go ->
            catch((send(Parent, receive_body), sleep(60)),
                  _,
                  (send(Parent, receive_recovered), repeat))}),
        send(Parent, receive_cleaned)).
")
       ]),
       ( receive({ receive_ready -> true },
                 [timeout(1), on_timeout(fail)]),
         send(Pid, go),
         receive({ receive_body -> true },
                 [timeout(1), on_timeout(fail)]),
         exit(Pid, receive_kill),
         receive({ receive_cleaned -> true },
                 [timeout(1), on_timeout(fail)]),
         receive({
             receive_recovered -> throw(receive_exit_was_caught);
             down(Pid, _, receive_kill) -> true
         }, [timeout(1), on_timeout(fail)])
       ),
       catch(exit(Pid, test_cleanup), _, true)).

test(actor_exit_bypasses_catch_called_through_loaded_meta_predicate) :-
   self(Self),
   setup_call_cleanup(
       spawn(run(Self), Pid, [
           link(false),
           monitor(true),
           src_text("
run(Parent) :-
    setup_call_cleanup(
        send(Parent, meta_ready),
        maplist(call,
                [catch(sleep(60), _,
                       (send(Parent, meta_recovered), repeat))]),
        send(Parent, meta_cleaned)).
")
       ]),
       ( receive({ meta_ready -> true },
                 [timeout(1), on_timeout(fail)]),
         exit(Pid, meta_kill),
         receive({ meta_cleaned -> true },
                 [timeout(1), on_timeout(fail)]),
         receive({
             meta_recovered -> throw(meta_exit_was_caught);
             down(Pid, _, meta_kill) -> true
         }, [timeout(1), on_timeout(fail)])
       ),
       catch(exit(Pid, test_cleanup), _, true)).

test(src_uri_and_dynamic_assert_cannot_restore_exit_recovery) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, "~s", ["
run(Parent) :-
    assertz((dynamic_wait :-
        catch((send(Parent, dynamic_ready), sleep(60)),
              _,
              (send(Parent, dynamic_recovered), repeat)))),
    setup_call_cleanup(true, dynamic_wait, send(Parent, dynamic_cleaned)).
"]),
         close(Stream),
         atom_concat('file://', File, URI)
       ),
       setup_call_cleanup(
           spawn(run(Self), Pid, [
               link(false),
               monitor(true),
               src_uri(URI)
           ]),
           ( receive({ dynamic_ready -> true },
                     [timeout(1), on_timeout(fail)]),
             exit(Pid, dynamic_kill),
             receive({ dynamic_cleaned -> true },
                     [timeout(1), on_timeout(fail)]),
             receive({
                 dynamic_recovered -> throw(dynamic_exit_was_caught);
                 down(Pid, _, dynamic_kill) -> true
             }, [timeout(1), on_timeout(fail)])
           ),
           catch(exit(Pid, test_cleanup), _, true)),
       catch(delete_file(File), _, true)).

test(ordinary_exception_still_uses_application_recovery) :-
   self(Self),
   spawn(run(Self), Pid, [
       link(false),
       monitor(true),
       src_text("
run(Parent) :-
    catch(throw(application_error), application_error,
          send(Parent, recovered)).
")
   ]),
   receive({ recovered -> true }, [timeout(1), on_timeout(fail)]),
   receive({ down(Pid, _, true) -> true }, [timeout(1), on_timeout(fail)]).

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

t1_prepare_probe_goal(Parent) :-
   send(Parent, actor_started).

%  Probe the preparation-pass contract without modifying the actor module.
%  A source-free actor invokes this hook once; effective source loading
%  invokes it again during the post-load repair pass.
isolation:prepare_module(_Module, _GoalModule, Options) :-
   memberchk(t1_prepare_probe(Parent), Options),
   actors:send(Parent, prepare_called).

test(source_free_module_skips_post_load_repair,
     true(Extra == no_extra_prepare)) :-
   self(Self),
   spawn(t1_prepare_probe_goal(Self), _Pid, [
       link(false),
       t1_prepare_probe(Self)
   ]),
   receive({ prepare_called -> true }, [timeout(1), on_timeout(fail)]),
   receive({ actor_started -> true }, [timeout(1), on_timeout(fail)]),
   receive({
       prepare_called -> Extra = unexpected_extra_prepare
   }, [
       timeout(0),
       on_timeout(Extra = no_extra_prepare)
   ]).

test(explicit_source_retains_post_load_repair, Calls == two) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       t1_prepare_probe(Self),
       src_list([
           (run(Parent) :- send(Parent, actor_started))
       ])
   ]),
   receive({ prepare_called -> true }, [timeout(1), on_timeout(fail)]),
   receive({ prepare_called -> Calls = two }, [timeout(1), on_timeout(fail)]),
   receive({ actor_started -> true }, [timeout(1), on_timeout(fail)]).

test(generated_io_prelude_retains_post_load_repair, Calls == two) :-
   self(Self),
   spawn(t1_prepare_probe_goal(Self), _Pid, [
       link(false),
       isolation_io(generated),
       t1_prepare_probe(Self)
   ]),
   receive({ prepare_called -> true }, [timeout(1), on_timeout(fail)]),
   receive({ prepare_called -> Calls = two }, [timeout(1), on_timeout(fail)]),
   receive({ actor_started -> true }, [timeout(1), on_timeout(fail)]).

test(prepare_module_extends_actor_module, [
        true(Msg == installed),
        setup(assertz(t1_pm_active)),
        cleanup(retractall(t1_pm_active))
     ]) :-
   self(Self),
   spawn(run(Self), _Pid, [
       link(false),
       src_list([
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
       src_list([
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


                /*******************************
                *      I/O-TARGET MATRIX       *
                *******************************/

%  The demonstrator's actor_tests.pl per-builtin I/O-target inheritance
%  cases: a child spawned under with_io_target/2 must route each output
%  builtin through the inherited target as a terminal_output/2 message.
%  Ported verbatim (src_text needs isolation, so they belong here, not
%  in T0).  The shared_db/2 variants depend on node:set_node_shared_db/1
%  and live in T4 with the rest of the node surface.

:- begin_tests(t1_io_inheritance, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(spawned_child_inherits_io_target_for_writeln, Data == 'Alarm ringing!') :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            writeln('Alarm ringing!');
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(spawned_child_inherits_io_target_for_format, Data == "Alarm ringing!") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            format('Alarm ~w!', [ringing]);
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(spawned_child_inherits_io_target_for_writeq, Data == "'Alarm ringing!'") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            writeq('Alarm ringing!');
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(spawned_child_inherits_io_target_for_nl, Data == "\n") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            nl;
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(spawned_child_inherits_io_target_for_print, Data == "1+2") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            print(1+2);
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(spawned_child_inherits_io_target_for_write_canonical, Data == "+(1,2)") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           src_text("
alarm :-
    receive({
        ring ->
            write_canonical(1+2);
        stop ->
            true
    }).
")
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
       down(Pid, _, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

:- end_tests(t1_io_inheritance).


                /*******************************
                *      LOAD-OPTION SURFACE     *
                *******************************/

%  The remaining src_* / src_uri cases from the demonstrator's
%  actor_tests.pl: option aliases, cross-actor private-db isolation,
%  listing_private/1 targeting a selected actor, and the src_uri/1 URI
%  parsing variants (path, file://, shorthand, relative, and the
%  user-bang-operator independence of the loader).  Ported verbatim
%  except: actor:listing_private/1 -> listing_private/1 (isolation
%  reexports it) and the example-path resolver is anchored two levels
%  deeper than the demonstrator's (this file lives in tests/tiers/).

:- dynamic t1_tests_directory/1.
:- prolog_load_context(directory, T1Dir),
   retractall(t1_tests_directory(_)),
   asserta(t1_tests_directory(T1Dir)).

t1_actor_example_path(FileName, Path) :-
   t1_tests_directory(TestDir),
   atomic_list_concat(['../../examples/actors/', FileName], RelativePath),
   absolute_file_name(RelativePath, Path, [
       relative_to(TestDir),
       access(read),
       file_errors(fail)
   ]).

collect_from_messages(Count, Pairs) :-
   collect_from_messages(Count, [], Pairs).

collect_from_messages(0, Acc, Pairs) :-
   !,
   reverse(Acc, Pairs).
collect_from_messages(Count, Acc, Pairs) :-
   Count > 0,
   receive({
       from(Pid, Value) ->
           true
   }),
   Next is Count - 1,
   collect_from_messages(Next, [Pid-Value|Acc], Pairs).

wait_for_downs([]) :- !.
wait_for_downs(Pids) :-
   receive({
       down(Pid, _, true) ->
           true
   }),
   remove_pid(Pid, Pids, Rest),
   wait_for_downs(Rest).

remove_pid(Pid, [Pid|Rest], Rest) :- !.
remove_pid(Pid, [Other|Rest], [Other|Rest1]) :-
   remove_pid(Pid, Rest, Rest1),
   !.

:- begin_tests(t1_load_options, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

test(load_aliases_are_not_source_options) :-
   forall(member(Option, [load_text(x), load_uri(x), load_list([]),
                          load_predicates([])]),
          \+ canonical_source_option(Option, _)).

test(isolation_load_list, Sorted == [a,b]) :-
   self(Self),
   spawn(run(Self), PidA, [
       monitor(true),
       src_list([
           (run(Parent) :-
               self(Pid),
               id(Value),
               Parent ! from(Pid, Value)),
           id(a)
       ])
   ]),
   spawn(run(Self), PidB, [
       monitor(true),
       src_list([
           (run(Parent) :-
               self(Pid),
               id(Value),
               Parent ! from(Pid, Value)),
           id(b)
       ])
   ]),
   collect_from_messages(2, Pairs),
   memberchk(PidA-a, Pairs),
   memberchk(PidB-b, Pairs),
   findall(Value, member(_-Value, Pairs), Values),
   sort(Values, Sorted),
   wait_for_downs([PidA, PidB]).

test(listing_actor_private_by_pid_targets_selected_actor_db) :-
   setup_call_cleanup(
       (
           spawn(receive({stop -> true}), Pid1, [
               monitor(true),
               link(false),
               src_text("hello(a).")
           ]),
           spawn(receive({stop -> true}), Pid2, [
               monitor(true),
               link(false),
               src_text("goodbye(b).")
           ])
       ),
       (
           with_output_to(string(Output), listing_actor_private(Pid2)),
           sub_string(Output, _, _, _, "goodbye(b)."),
           \+ sub_string(Output, _, _, _, "hello(a).")
       ),
       (
           catch(send(Pid1, stop), _, true),
           catch(send(Pid2, stop), _, true),
           receive({down(Pid1, _, _) -> true}, [timeout(1), on_timeout(true)]),
           receive({down(Pid2, _, _) -> true}, [timeout(1), on_timeout(true)])
       )
   ),
   !.

test(load_uri_file_scheme_shorthand, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream),
         sub_atom(File, 1, _, 0, TrimmedFile),
         atomic_list_concat(['file://', TrimmedFile], ShortFileURI)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             src_uri(ShortFileURI)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(Pid, _, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(load_uri_file_scheme_relative, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream),
         working_directory(Cwd, Cwd),
         relative_file_name(File, Cwd, RelFile),
         atomic_list_concat(['file://', RelFile], RelFileURI)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             src_uri(RelFileURI)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(Pid, _, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(load_uri_with_node_localhost, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             node(localhost),
             src_uri(File)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(Pid, _, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(load_uri_without_user_bang_operator, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( current_op(Pri, Type, !),
         t1_actor_example_path('04 count_server.pl', CountActorPath),
         op(0, xfx, !)
       ),
       ( spawn(count_server(0), Pid, [
             monitor(true),
             src_uri(CountActorPath)
         ]),
         send(Pid, count(Self)),
         receive({
             count(1) -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         exit(Pid, kill),
         receive({
             down(Pid, _, kill) -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         Result = true
       ),
       op(Pri, Type, !)
   ).

:- end_tests(t1_load_options).
