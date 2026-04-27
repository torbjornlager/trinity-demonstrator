
                /*******************************
                *             TESTS            *
                *******************************/   

:- use_module('../actor.pl').
:- use_module('../toplevel_actor.pl').
:- use_module('../node.pl').

:- use_module(library(plunit)).
:- use_module(library(debug)).
:- use_module(library(uri)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(socket)).

:- dynamic actor_tests_directory/1.
:- prolog_load_context(directory, ActorTestsDirectory),
   asserta(actor_tests_directory(ActorTestsDirectory)).


test :-
   run_tests([ receive,
               actors,
               compute_answer,
               programs,
               parallel
             ]),
   ensure_mailbox_empty.

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

with_node_server(URI, Goal) :-
   between(1, 20, _),
   pick_free_port(Port),
   catch(node(Port), _, fail),
   !,
   format(atom(URI), 'http://localhost:~w', [Port]),
   setup_call_cleanup(
       true,
       Goal,
       catch(http_stop_server(Port, []), _, true)
   ).

pick_free_port(Port) :-
   tcp_socket(Socket),
   tcp_bind(Socket, Port),
   tcp_close_socket(Socket).


actor_example_path(FileName, Path) :-
   actor_tests_directory(TestDir),
   atomic_list_concat(['../examples/actors/', FileName], RelativePath),
   absolute_file_name(RelativePath, Path, [
       relative_to(TestDir),
       access(read),
       file_errors(fail)
   ]).


:- begin_tests(receive, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).
   
test(receive1, X == bar) :-
   self(Self),
   Self ! foo(bar),    
   receive({
       foo(X) -> true
   }).

test(receive2, X == baz) :-
   self(Self),
   Self ! not_matching,    
   Self ! foo(bar),    
   % The catch-all clause consumes the first mailbox entry, so the later
   % foo(bar) message is handled by the second receive/2 below.
   receive({
       foo(X) -> true;
       _ -> X = baz
   }),
   receive({
       foo(_) -> true
   }).    

test(receive3, X == baz) :-
   receive({
       foo(X) -> true
   },[
       timeout(1),
       on_timeout(X = baz)
   ]).

test(receive4, X == baz) :-
   receive({
       foo(X) -> true
   },[
       timeout(0),
       on_timeout(X = baz)
   ]).
   
test(receive5, Result == [hello, goodbye]) :-
   self(S),
   S ! hello,
   S ! goodbye,
   receive({A -> true}),
   receive({B -> true}),
   Result = [A,B].
   
test(receive6, X == baz) :-
   self(S),
   S ! foo(baz),    
   receive({
       foo(X) if true, true -> 
           true
   }).

test(receive7, X == a) :-
   self(S),
   S ! foo,    
   receive({
       foo if actor_test_p(X) -> 
           true
   }). 
   
test(receive8, X == b) :-
   self(S),
   S ! foo(b),    
   receive({
       foo(X) if actor_test_p(Y), X=Y -> 
           true
   }).        
       
test(receive9, Result = done) :-
   receive({}, [timeout(1)]),
   Result = done.

test(receive10, Result == done) :-
   self(Self),
   Self ! done,
   receive({
       Result -> true ;
       unreachable ->
           Result = wrong
   }).

test(receive11, Result == done) :-
   self(Self),
   (   true
   ;   Self ! foo(stop),
       receive({
          foo(X) -> 
             Self ! X
       })
   ),
   receive({
      stop -> true
   }, [
       timeout(0),
       on_timeout(fail)
   ]),
   Result = done.
   
:- end_tests(receive).


:- begin_tests(actors, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).


test(actors2_exit_1, Reason == reason) :-
   spawn(exit(reason), Pid, [
       monitor(true)
   ]),
   receive({
       down(_, Pid, Reason) -> true
   }).
test(actors2_exit_2, Reason == reason) :-
   spawn((repeat, fail), Pid, [
       monitor(true)
   ]),
   exit(Pid, reason),
   receive({
       down(_, Pid, Reason) -> true
   }).
test(nested_spawn_exit_does_not_abort_parent, Result == true) :-
   self(Self),
   spawn(( spawn(exit(kill)),
           send(Self, ready),
           receive({})
         ),
         Pid,
         [monitor(true)]),
   receive({
       ready -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   exit(Pid, kill),
   receive({
       down(_, Pid, kill) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   Result = true.
test(actors3_register_1, Msg == hello) :-
   self(Pid),
   register(test, Pid),
   test ! hello,
   unregister(test),
   receive({
       Msg -> true
   }).
test(actors3_register_2, Reason == reason) :-
   spawn((repeat, fail), Pid, [
      monitor(true)
   ]),
   register(test2, Pid),
   whereis(test2, Pid2),
   exit(Pid2, reason),
   whereis(test2, undefined),
   unregister(test2),
   receive({
       down(_, Pid2, Reason) -> true
   }).
test(actors3_register_3,
     true(Error = error(existence_error(actor_name, noname), _))) :-
   catch(send(noname, msg), Error, true),
   nonvar(Error).
test(actors3_service_registry_is_separate,
     [ cleanup(catch(unregister_service(test_service), _, true)),
       true((Visible == undefined, ServicePid == Self, Missing == undefined,
             Error = error(existence_error(actor_name, test_service), _)))
     ]) :-
   self(Self),
   register_service(test_service, Self),
   whereis(test_service, Visible),
   unregister(test_service),
   send(test_service, hello),
   receive({
       hello -> true
   }),
   whereis_service(test_service, ServicePid),
   unregister_service(test_service),
   whereis_service(test_service, Missing),
   catch(send(test_service, again), Error, true),
   nonvar(Error).

test(actors_load_list, Msg == ready) :-
   self(Self),
   spawn(run(Self), Pid, [
       monitor(true),
       load_list([
           run(Parent) :-
               Parent ! ready
       ])
   ]),
   receive({
       Msg -> true
   }),
   receive({
       down(_, Pid, true) -> true
   }).

test(actors_load_text, Result == true) :-
   self(Self),
   spawn(run(Self), Pid, [
       monitor(true),
       load_text("
run(Parent) :-
    Parent ! ready.
")
   ]),
   receive({
       ready -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, true) -> true
   }),
   Result = true.

test(actors_load_list_alias, Result == true) :-
   self(Self),
   spawn(run(Self), Pid, [
       monitor(true),
       load_list([
           run(Parent) :-
               Parent ! ready
       ])
   ]),
   receive({
       ready -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, true) -> true
   }),
   Result = true.

test(actors_load_text_alias, Result == true) :-
   self(Self),
   spawn(run(Self), Pid, [
       monitor(true),
       load_text("run(Parent) :- Parent ! ready.")
   ]),
   receive({
       ready -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, true) -> true
   }),
   Result = true.

test(actors_load_uri_path, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             load_uri(File)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(actors_load_uri_file_scheme, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream),
         uri_file_name(FileURI, File)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             load_uri(FileURI)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(actors_load_uri_file_scheme_shorthand, Result == true) :-
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
             load_uri(ShortFileURI)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(actors_load_uri_file_scheme_relative, Result == true) :-
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
             load_uri(RelFileURI)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
	   ).

test(actors_load_uri_with_node_localhost, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( tmp_file_stream(text, File, Stream),
         format(Stream, 'run(Parent) :- Parent ! ready.~n', []),
         close(Stream)
       ),
       ( spawn(run(Self), Pid, [
             monitor(true),
             node(localhost),
             load_uri(File)
         ]),
         receive({
             ready -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         receive({
             down(_, Pid, true) -> true
         }),
         Result = true
       ),
       catch(delete_file(File), _, true)
   ).

test(actors_load_uri_without_user_bang_operator, Result == true) :-
   self(Self),
   setup_call_cleanup(
       ( current_op(Pri, Type, !),
         actor_example_path('04 count_actor.pl', CountActorPath),
         op(0, xfx, !)
       ),
       ( spawn(count_actor(0), Pid, [
             monitor(true),
             load_uri(CountActorPath)
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
             down(_, Pid, kill) -> true
         }, [
             timeout(1),
             on_timeout(fail)
         ]),
         Result = true
       ),
       op(Pri, Type, !)
   ).

test(actors_load_predicates, Result == true) :-
   self(Self),
   spawn(user:run(Self), Pid, [
       monitor(true),
       load_predicates([actor_test_p/1]),
       load_list([
           (run(Parent) :-
               actor_test_p(Value),
               send(Parent, Value),
               !)
       ])
   ]),
   receive({
       a -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, true) -> true
   }),
   Result = true.

test(actors_load_predicates_alias, Result == true) :-
   self(Self),
   spawn(user:run(Self), Pid, [
       monitor(true),
       load_predicates([actor_test_p/1]),
       load_list([
           (run(Parent) :-
               actor_test_p(Value),
               send(Parent, Value),
               !)
       ])
   ]),
   receive({
       a -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   receive({
       down(_, Pid, true) -> true
   }),
   Result = true.

test(actors_reject_src_options, Result == true) :-
   catch(
       spawn(true, _Pid, [
           monitor(true),
           src_list([p(a)])
       ]),
       Reason,
       true
   ),
   receive({
       down(_, _, _) -> true
   }, [
       timeout(0),
       on_timeout(true)
   ]),
   subsumes_term(
       error(domain_error(load_source_option, src_list(_)), _),
       Reason),
   Result = true.

test(actors_spawn_node_localhost_option, Result == true) :-
   spawn(true, Pid, [
       monitor(true),
       node(localhost)
   ]),
   receive({
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   Result = true.

test(actors_spawn_remote_node_option, Result == true) :-
   with_node_server(URI,
      (
         spawn(true, Pid, [
             monitor(true),
             node(URI)
         ]),
         receive({
             down(_, Pid, true) -> true
         }, [
             timeout(2),
             on_timeout(fail)
         ]),
         Result = true
      )).

test(actors_spawn_remote_can_message_global_self, Msg == hello) :-
   with_node_server(URI,
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

test(actors_spawn_remote_can_message_global_self_with_bang, Msg == hello) :-
   with_node_server(URI,
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

test(actors_remote_node_reuses_shared_ws_connection, Connections == 1) :-
   with_node_server(URI,
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
         findall(Conn, actor:ws_connection(URI, Conn, _, _), Conns),
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

test(actors_isolation_load_list, Sorted == [a,b]) :-
   self(Self),
   spawn(run(Self), PidA, [
       monitor(true),
       load_list([
           (run(Parent) :-
               self(Pid),
               id(Value),
               Parent ! from(Pid, Value)),
           id(a)
       ])
   ]),
   spawn(run(Self), PidB, [
       monitor(true),
       load_list([
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

test(actors_injected_program_calls_toplevel_spawn, Result == true) :-
   self(Self),
   spawn(run_toplevel(Self), Pid, [
       monitor(true),
       load_list([
           (run_toplevel(Parent) :-
               toplevel_spawn(ToplevelPid, [target(Parent), link(false)]),
               toplevel_call(ToplevelPid, true, [template(true), limit(1)]))
       ])
   ]),
   wait_for_injected_toplevel_success_and_down(Pid),
   Result = true.

test(actors_send_with_delay_option, Value == ok) :-
   self(Self),
   send(Self, delayed(ok), [
       delay(0.05)
   ]),
   receive({
       delayed(Value) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_spawned_child_inherits_io_target_for_writeln, Data == 'Alarm ringing!') :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_shared_db_child_inherits_io_target_for_writeln, Data == 'Alarm ringing!') :-
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

test(actors_flush_preserves_child_output_and_terminal_output_wrappers) :-
   spawn((output(hi), writeln(line)), _Pid, [link(false)]),
   sleep(0.1),
   with_output_to(string(Output), flush),
   sub_string(Output, _, _, _, "Shell got output("),
   sub_string(Output, _, _, _, ",hi)"),
   sub_string(Output, _, _, _, "Shell got terminal_output("),
   sub_string(Output, _, _, _, ",line)"),
   !.

test(actors_listing_private_by_pid_targets_selected_actor_db) :-
   setup_call_cleanup(
       (
           spawn(receive({stop -> true}), Pid1, [
               monitor(true),
               link(false),
               load_text("hello(a).")
           ]),
           spawn(receive({stop -> true}), Pid2, [
               monitor(true),
               link(false),
               load_text("goodbye(b).")
           ])
       ),
       (
           with_output_to(string(Output), actor:listing_private(Pid2)),
           sub_string(Output, _, _, _, "goodbye(b)."),
           \+ sub_string(Output, _, _, _, "hello(a).")
       ),
       (
           catch(send(Pid1, stop), _, true),
           catch(send(Pid2, stop), _, true),
           receive({down(_, Pid1, _) -> true}, [timeout(1), on_timeout(true)]),
           receive({down(_, Pid2, _) -> true}, [timeout(1), on_timeout(true)])
       )
   ),
   !.

test(actors_spawned_child_inherits_io_target_for_format, Data == "Alarm ringing!") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_shared_db_child_inherits_io_target_for_format, Data == "Alarm ringing!") :-
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

test(actors_spawned_child_inherits_io_target_for_writeq, Data == "'Alarm ringing!'") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_shared_db_child_inherits_io_target_for_write_term, Data == "'Alarm ringing!'") :-
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

test(actors_spawned_child_inherits_io_target_for_nl, Data == "\n") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_spawned_child_inherits_io_target_for_print, Data == "1+2") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_shared_db_child_inherits_io_target_for_display, Data == "+(1,2)") :-
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

test(actors_spawned_child_inherits_io_target_for_write_canonical, Data == "+(1,2)") :-
   self(Self),
   with_io_target(Self,
       spawn(alarm, Pid, [
           monitor(true),
           load_text("
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
       down(_, Pid, true) -> true
   }, [
       timeout(1),
       on_timeout(fail)
   ]).

test(actors_cancel_delayed_send, Result == timeout) :-
   self(Self),
   make_id(ID),
   send(Self, delayed(ID), [
       delay(0.4),
       id(ID)
   ]),
   cancel(ID),
   receive({
       delayed(ID) -> Result = delivered
   }, [
       timeout(0.6),
       on_timeout(Result = timeout)
   ]).

test(actors_cancel_all_delayed_sends_with_same_id, Result == timeout) :-
   self(Self),
   make_id(ID),
   send(Self, delayed(one, ID), [
       delay(0.4),
       id(ID)
   ]),
   send(Self, delayed(two, ID), [
       delay(0.4),
       id(ID)
   ]),
   cancel(ID),
   receive({
       delayed(_, ID) -> Result = delivered
   }, [
       timeout(0.6),
       on_timeout(Result = timeout)
   ]).
    
:- end_tests(actors).


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
       down(_, Pid, true) ->
           true
   }),
   remove_pid(Pid, Pids, Rest),
   wait_for_downs(Rest).

remove_pid(Pid, [Pid|Rest], Rest) :- !.
remove_pid(Pid, [Other|Rest], [Other|Rest1]) :-
   remove_pid(Pid, Rest, Rest1),
   !.

wait_for_injected_toplevel_success_and_down(Pid) :-
   wait_for_injected_toplevel_success_and_down(Pid, false, false).

wait_for_injected_toplevel_success_and_down(_Pid, true, true) :-
   !.
wait_for_injected_toplevel_success_and_down(Pid, GotSuccess0, GotDown0) :-
   receive({
       success(_ToplevelPid, [true], false) ->
           GotSuccess = true,
           GotDown = GotDown0 ;
       down(_, Pid, true) ->
           GotSuccess = GotSuccess0,
           GotDown = true
   }, [
       timeout(1),
       on_timeout(fail)
   ]),
   wait_for_injected_toplevel_success_and_down(Pid, GotSuccess, GotDown).




:- begin_tests(compute_answer, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).

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

:- end_tests(compute_answer).


:- begin_tests(programs, [
   setup(flush_shell_mailbox),
   cleanup(ensure_mailbox_empty)
]).


test(program1, Msg == hello) :-
   spawn(program_echo_server, Pid, [
      monitor(true)
   ]),
   self(Self),
   Pid ! echo(Self, hello),
   receive({Msg -> true}),
   Pid ! echo(Self, hello),
   receive({Msg -> true}),
   exit(Pid, kill),
   receive({
       down(_, Pid, kill) -> true
   }).
  
test(program2, Count == 3) :-
   spawn(program_count_server(0), Pid, [
      monitor(true)
   ]),
   self(Self),
   Pid ! count(Self),
   receive({Count1 -> true}),
   Pid ! count(Self),
   receive({Count2 -> true}),
   Count is Count1 + Count2,
   Pid ! stop,
   receive({
       down(_, Pid, true) -> true
   }).

test(program3, Messages == [high,high,low,low]) :-
    self(S),
    S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high,
    important(Messages),
    S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high,
    important(Messages).
    
test(program4, Response == ok(cheese)) :-
   spawn(fridge([]), Pid, [
       monitor(true)
   ]),
   store(Pid, cheese, ok),
   take(Pid, cheese, Response),
   Pid ! terminate,
   receive({
       down(_, Pid, true) -> true
   }).
    
test(program5, Response == ok(meat)) :-
   spawn(server(fridge, []), Pid, [
       monitor(true)
   ]),
   rpc_synch(Pid, store(meat), ok),
   rpc_synch(Pid, take(meat), Response),
   Pid ! upgrade(fridge),
   rpc_synch(Pid, store(meat), ok),
   rpc_synch(Pid, take(meat), Response),
   Pid ! terminate,
   receive({
       down(_, Pid, true) -> true
   }).

test(program6, Done == true) :-
   ring(12, hello),
   sleep(0.1),
   Done = true.
    
test(program7, Done == true) :-
    ping_pong,
    sleep(0.05),
    flush_shell_mailbox,
    Done = true.

test(program8_myfindall_1, Results == [1,2,3]) :-
    myfindall(N, between(1,3,N), Results).
    
test(program8_myfindall_2, Results == []) :-
    myfindall(_N, fail, Results).
    
test(program8_myfindall_3, Error = error(_,_)) :-
    catch(myfindall(N, N is 1/0, _Results), Error, true).
        
:- end_tests(programs).


    
    
                /*******************************
                *        TEST UTILITIES        *
                *******************************/


actor_test_p(a). actor_test_p(b). actor_test_p(c).

mortal(Who) :- human(Who).

human(socrates). 
human(plato).
human(aristotle).


                /*******************************
                *           PROGRAMS           *
                *******************************/

program_echo_server  :-          
   receive({            
      echo(Pid, Msg) ->
         Pid ! Msg,   
         program_echo_server  
   }).
    
program_count_server(Count0) :-                            
   receive({                         
      count(From) ->
         Count is Count0 + 1,              
         From ! Count,              
         program_count_server(Count);
      stop ->
         true       
   }).            

important(Messages) :-
   receive({
      Priority-Message if Priority > 10 ->
         Messages = [Message|MoreMessages],
         important(MoreMessages)
   },[ timeout(0),
       on_timeout(normal(Messages))
   ]).

normal(Messages) :-
   receive({
      _-Message ->
         Messages = [Message|MoreMessages],
         normal(MoreMessages)
   },[ timeout(0),
       on_timeout(Messages=[])
   ]).


fridge(FoodList0) :-
    receive({
        store(From, Food) ->
            self(Self),
            From ! Self-ok,
            fridge([Food|FoodList0]);
        take(From, Food) ->
            self(Self),
            (   select(Food, FoodList0, FoodList)
            ->  From ! Self-ok(Food),
                fridge(FoodList)
            ;   From ! Self-not_found,
                fridge(FoodList0)
            );
        terminate ->
            true
    }).
   
store(Pid, Food, Response) :-
    self(Self),
    Pid ! store(Self, Food),
    receive({
        Pid-Response -> true
    }).
 
take(Pid, Food, Response) :-
    self(Self),
    Pid ! take(Self, Food),
    receive({
        Pid-Response -> true
    }).


server(Pred, State0) :-
    receive({
        rpc(From, Ref, Request) ->
            call(Pred, Request, State0, Response, State),
            From ! Ref-Response,
            server(Pred, State);
        upgrade(Pred1) ->
            server(Pred1, State0);
        terminate ->
            true
    }).

fridge(store(Food), FoodList, ok, [Food|FoodList]).
fridge(take(Food), FoodList, ok(Food), FoodListRest) :-
    select(Food, FoodList, FoodListRest), !.
fridge(take(_Food), FoodList, not_found, FoodList).

rpc_synch(To, Request, Response) :-
    self(Self),
    make_id(Ref),
    To ! rpc(Self, Ref, Request),
    receive({
        Ref-Response -> true
    }).
   

% ring(12, hello).

ring(NumberProcesses, Message) :-
   spawn(create(NumberProcesses, Message)).
   
create(NumberProcesses, Message) :-
   self(Self),
   create(NumberProcesses, Self, Message).

create(1, NextProcess, Message) :- !,
   self(Self),
   format("Process ~p connected with ~p~n", [Self, NextProcess]),
   format("Process ~p injects message ~p~n", [Self, Message]),
   NextProcess ! Message.
create(NumberProcesses, NextProcess, Message) :-
   spawn(loop(NextProcess), Prev, [
       link(true)
   ]),
   format("Process ~p created and connected with ~p~n", [Prev, NextProcess]),
   NumberProcesses1 is NumberProcesses - 1,
   create(NumberProcesses1, Prev, Message).

loop(NextProcess) :-
   receive({
      Msg ->
         format("Got message ~p, passing it to ~p~n", [Msg, NextProcess]),
         NextProcess ! Msg
    }).


ping(0, Pong_Pid) :-
    Pong_Pid ! finished,
    format('Ping finished~n',[]).
ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong -> 
            format('Ping received pong~n',[])
    }),
    N1 is N - 1,
    ping(N1, Pong_Pid).
    
pong :-
    receive({
        finished ->
            format('Pong finished~n',[]);
        ping(Ping_Pid) ->
            format('Pong received ping~n',[]),
            Ping_Pid ! pong,
            pong
    }).
    
ping_pong :-
    spawn(pong, Pong_Pid, [
        monitor(true)
    ]),
    spawn(ping(3, Pong_Pid), Ping_Pid, [
        monitor(true)
    ]),
    receive({
       down(_, Ping_Pid, true) ->
          true
    }),
    receive({
       down(_, Pong_Pid, true) ->
          true
    }).

% ping-pong for benchmarking send and receive  
    
bm_ping(0, Pong_Pid) :-
    Pong_Pid ! finished.
bm_ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong -> true
    }),
    N1 is N - 1,
    bm_ping(N1, Pong_Pid).
    
bm_pong :-
    receive({
        finished -> true;
        ping(Ping_Pid) ->
            Ping_Pid ! pong,
            bm_pong
    }).
    
bm_ping_pong(N) :-
    spawn(bm_pong, Pong_Pid),
    spawn(bm_ping(N, Pong_Pid), Ping_Pid, [
        monitor(true)
    ]),
    receive({
       down(_, Ping_Pid, true) ->
          true
    }).



restarter(Init, Name, Count) :-
   spawn(restarter_loop(Init, Name, Count), _, [
      monitor(true)
   ]).

restarter_loop(Init, Name, Count0) :-
   spawn(Init, Pid, [
      monitor(true)
   ]),
   register(Name, Pid),
   receive({
      down(_, Pid, true) ->
         writeln('normal shutdown received') ; 
      down(_, Pid, _Anything) ->
         (   Count0 == 0
         ->  true
         ;   Count is Count0 - 1,
             restarter_loop(Init, Name, Count)
         )
    }).


search(Template, Goal, Pid) :-
    search(Template, Goal, Pid, []).
    
search(Template, Goal, Pid, Options) :-
    self(Self),
    spawn(goal(Template, Goal, Pid, Self), Pid,  [
          monitor(true)
        | Options
    ]).
    
goal(Template, Goal, Pid, Parent) :-
    call_cleanup(Goal, Det=true),
    (   var(Det)
    ->  Parent ! success(Pid, Template, true),
        receive({
            next -> fail ;
            stop ->
                Parent ! stopped(Pid)
        })
    ;   Parent ! success(Pid, Template, false)
    ).
   

% myfindall

myfindall(Template, Goal, Solutions) :-
    toplevel_spawn(Pid, [
        session(false)
    ]),
    toplevel_call(Pid, Goal, [
        template(Template)
    ]),
    receive({
        success(Pid, Solutions, false) ->
            true ;
        failure(Pid) ->
            Solutions = [] ;
        error(Pid, Error) ->
            throw(Error)
    }).
    
    
% Benchmarking -- see p. 106 in Erlang Programming

start(Num) :-
    self(Self),
    start_proc(Num, Self).
        
start_proc(0, Pid) :- !,
    Pid ! ok.
start_proc(Num, Pid) :-
    Num1 is Num-1,
    spawn(start_proc(Num1, Pid), NPid),
    NPid ! ok,
    receive({ok -> true}).
    


    


   
