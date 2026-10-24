## Summary

`http_stop_server/2` can block indefinitely if its stop signal arrives while the acceptor is inside `http:schedule_workers/1`. The scheduling hook's broad catch prints and consumes `http_stop(Stopper)`; the acceptor returns to `tcp_accept/3` and shutdown waits forever in `thread_join/2`. The fallback wake-up connection cannot restore the swallowed exception.

Tested on macOS arm64 with SWI core `09b6299f696574c9230f23e53b1ab041a942b6f3` (reports 10.1.18), HTTP package `9d1e28e676831618c9894f728ef50872b2eb87d7`. Before filing, I searched all-state issues and pull requests for `http_stop_server`, `schedule_workers` and HTTP shutdown; no matching report was found. Current HTTP master is still that HTTP commit and has the broad catch.

The candidate patch below reuses the existing `accept_rethrow_error/1` classification in `http_enough_workers/3`. Ordinary scheduling errors retain their current reporting/recovery. This is separate from the recent protected message-wait fix in the core.

## Standalone reproduction

No Web Prolog code is needed. Save this as `http-stop-gated.pl` and run `swipl -f none -q -s http-stop-gated.pl -g http_stop_gated:run -t halt` under an external watchdog. The hook gate deliberately forces the interleaving that was also traced naturally during a callback-sandbox test, after the expected error JSON had already reached its client.

~~~prolog
:- module(http_stop_gated,[run/0]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(socket)).
:- dynamic main/1,armed/0.
:- multifile http:schedule_workers/1.
http:schedule_workers(Dict) :- http_stop_gated:gate(Dict).
:- http_handler(root(block),block,[]).
:- http_handler(root(second),second,[]).
log(Term) :- get_time(T),format(user_error,'~Ncontrol(~q,~q).~n',[T,Term]),flush_output(user_error).
block(_) :- main(Main),thread_self(Self),thread_send_message(Main,handler_ready(Self)),thread_get_message(release),second(_).
second(_) :- format('Content-type: text/plain~n~nhello~n').
gate(Dict) :-
 retract(armed),main(Main),thread_self(Acceptor),
 log(scheduler_gate(Dict,Acceptor)),thread_send_message(Main,scheduling(Acceptor)),
 thread_get_message(release_scheduler),log(unexpected_scheduler_release).
client(URL) :- catch(setup_call_cleanup(http_open(URL,S,[]),read_string(S,_,_),close(S)),E,log(client_error(E))).
run :-
 thread_self(Main),assertz(main(Main)),assertz(armed),
 tcp_socket(Socket),tcp_bind(Socket,Port),tcp_close_socket(Socket),
 http_server(http_dispatch,[port(Port),workers(1)]),
 format(atom(First),'http://localhost:~w/block',[Port]),format(atom(Second),'http://localhost:~w/second',[Port]),
 thread_create(client(First),_,[detached(true)]),thread_get_message(handler_ready(Worker)),
 thread_create(client(Second),_,[detached(true)]),thread_get_message(scheduling(Acceptor)),
 log(releasing_worker(Worker)),thread_send_message(Worker,release),
 log(stop_begin(Port,Acceptor)),http_stop_server(Port,[]),log(stop_completed(Port)).
~~~

Unpatched: prints `Unknown message: http_stop(main)` and never reaches `stop_completed`; a 30-second watchdog terminated it. Native samples show the caller in thread_join and the acceptor in accept.

## Verification

With the candidate library in a separate complete private runtime prefix:

- New three-case regression suite: 20/20 fresh processes pass (60 case executions).
- Original callback-sandbox test: 30/30 fresh processes pass, unchanged assertions/timeouts.
- Native paging and HTTP cache eviction/TTL/isolation cleanup: 5/5 batches pass.
- Complete native T4 suite: all 983 scheduled cases pass.
- Existing HTTP, CGI-stream, multipart, proxy, WebSocket, GraphQL and SSE test entry points pass. The initial proxy attempt lacked sibling SSL certificate fixtures; after restoring the matching fixtures, all 13 proxy cases passed. The initial setup failure is retained in our records.

No C changes or engine rebuild were needed: the separate candidate copies the complete staged installation and patches only this Prolog library. Installed runtimes and existing application nodes were unchanged.

## Complete candidate patch

Apply at the HTTP package root with `patch -p1 < http-shutdown.patch`. Run `swipl -f none -q -s test_thread_httpd.pl -g test_thread_httpd -t halt`. Use an external watchdog on unpatched libraries, since the regression exposes a cleanup hang. Message waits are bounded at five seconds; our regression-process watchdog was 30 seconds. The ordinary scheduling error printed by the second test is intentional.

~~~diff
--- a/thread_httpd.pl
+++ b/thread_httpd.pl
@@ -587,7 +587,10 @@
         debug(http(scheduler), 'Asking to reschedule: ~p', [Data]),
         catch(http:schedule_workers(Data),
               Error,
-              print_message(error, Error))
+              (   accept_rethrow_error(Error)
+              ->  throw(Error)
+              ;   print_message(error, Error)
+              ))
     ->  true
     ;   true
     ).
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -148,7 +148,7 @@
 swipl_examples(${PWP_FILES}
 	       SUBDIR pwp)
 
-test_libs(cgi_stream http multipart proxy websocket graphql sse
+test_libs(cgi_stream http thread_httpd multipart proxy websocket graphql sse
 	  PACKAGES clib sgml plunit ssl zlib
 	  PARENT_LIB)
 endif(SWIPL_WITH_HTTP_SERVER)
--- /dev/null
+++ b/test_thread_httpd.pl
@@ -0,0 +1,90 @@
+:- module(test_thread_httpd, [test_thread_httpd/0]).
+
+:- use_module(library(http/thread_httpd)).
+:- use_module(library(http/http_open)).
+:- use_module(library(socket)).
+:- use_module(library(plunit)).
+:- dynamic gate/2, parent/2.
+:- multifile http:schedule_workers/1.
+
+http:schedule_workers(Data) :-
+    test_thread_httpd:schedule(Data).
+
+schedule(Data) :-
+    retract(gate(Data.port, Main)),
+    thread_self(Acceptor),
+    thread_send_message(Main, scheduling(Acceptor)),
+    thread_get_message(resume(Action)),
+    call(Action).
+
+handler(Request) :-
+    memberchk(path(Path), Request),
+    (   Path == '/block'
+    ->  thread_self(Self), parent(SelfMain, _),
+        thread_send_message(SelfMain, handler_ready(Self)),
+        thread_get_message(release)
+    ;   true
+    ),
+    format('Content-type: text/plain~n~nhello~n').
+
+client(URL, Main, Tag) :-
+    catch(setup_call_cleanup(http_open(URL, Stream, [timeout(5)]),
+                             read_string(Stream, _, Body), close(Stream)),
+          Error, Body = error(Error)),
+    thread_send_message(Main, done(Tag, Body)).
+
+start(Port) :-
+    thread_self(Main),
+    http_server(test_thread_httpd:handler, [port(Port), workers(1)]),
+    assertz(parent(Main, Port)).
+
+stop(Port) :-
+    retractall(gate(Port, _)),
+    retractall(parent(_, Port)),
+    ( http_current_server(_, Port) -> http_stop_server(Port, []) ; true ).
+
+prepare(Port, Worker, Acceptor) :-
+    thread_self(Main),
+    format(atom(First), 'http://localhost:~w/block', [Port]),
+    format(atom(Second), 'http://localhost:~w/second', [Port]),
+    thread_create(client(First, Main, first), _, [detached(true)]),
+    wait_message(handler_ready(Worker)),
+    assertz(gate(Port, Main)),
+    thread_create(client(Second, Main, second), _, [detached(true)]),
+    wait_message(scheduling(Acceptor)).
+
+wait_message(Message) :-
+    thread_self(Self), thread_get_message(Self, Message, [timeout(5)]).
+
+await_clients :-
+    wait_message(done(first, A)),
+    wait_message(done(second, B)),
+    assertion(A == "hello\n"), assertion(B == "hello\n").
+
+test_thread_httpd :- run_tests(http_shutdown).
+
+:- begin_tests(http_shutdown).
+
+test(stop_during_scheduler, [setup(start(Port)), cleanup(stop(Port))]) :-
+    prepare(Port, Worker, _),
+    thread_send_message(Worker, release),
+    http_stop_server(Port, []),
+    assertion(\+ http_current_server(_, Port)),
+    % Closing pending accepts may prevent the second request completing.
+    wait_message(done(first, _)),
+    wait_message(done(second, _)).
+
+test(ordinary_scheduler_error_still_recovers,
+     [setup(start(Port)), cleanup(stop(Port))]) :-
+    prepare(Port, Worker, Acceptor),
+    thread_send_message(Worker, release),
+    thread_send_message(Acceptor, resume(throw(error(test_scheduler_error, _)))),
+    await_clients,
+    http_stop_server(Port, []),
+    assertion(\+ http_current_server(_, Port)).
+
+test(normal_shutdown, [setup(start(Port)), cleanup(stop(Port))]) :-
+    http_stop_server(Port, []),
+    assertion(\+ http_current_server(_, Port)).
+
+:- end_tests(http_shutdown).
~~~

