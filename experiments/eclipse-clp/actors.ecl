:- module(actors).
:- lib(format).
:- lib(lists).
:- lib(prolog_extras).
:- ensure_loaded(library(swi)).

:- export spawn/1, actors/1.
:- export browser_goal/2, browser_format/2, browser_chart_trace/1, source_body/2.
:- export flush/0, browser_time/1, browser_sleep/1, browser_random_between/3.
:- export browser_call_cleanup/2, browser_random_member/2.
:- export send/3, cancel/1.
:- export spawn/2, spawn/3, self/1, send/2, (!)/2.
:- export op(800, xfx, !).
:- export receive/1, receive/2.
:- export monitor/2, demonitor/1, demonitor/2.
:- export register/2, unregister/1, whereis/2.
:- export exit/1, exit/2.
:- export output/1, output/2, input/2, input/3, respond/2, respond/3.
:- export retarget_prompt/3.
:- export set_io_target/1, clear_io_target/0.
:- export set_browser_prompt_correlation/0.
:- export set_linked_spawn_transport/2.
:- export set_peer_send_transport/2.
:- export set_prompt_relay/1.
:- export acknowledge_remote_spawn/2, remote_actor_down/3.
:- export op(1000, xfy, if).
:- export start_actor_runtime/0, attach_mailbox/1.
:- export actor_module/2, discard_deferred/1, post_actor_event/2.
:- export source_option/1, source_options_text/3, load_actor_source/2, fresh_reference/1, elapsed/1.
:- export unicode_literal/2, text_string/2.
:- tool(post_actor_event/2, post_actor_event_/3).
:- tool(discard_deferred/1, discard_deferred_/2).

:- local store(actor_registry).
:- local record(actor_monitors).
:- local record(actor_names).
:- local record(delayed_sends).
:- tool(spawn/1, spawn_/2).
:- tool(source_body/2, source_body_/3).
:- tool(browser_time/1, browser_time_/2).
:- tool(browser_call_cleanup/2, browser_call_cleanup_/3).
:- tool(spawn/2, spawn_/3).
:- tool(spawn/3, spawn_/4).

:- tool(receive/1, receive_/2).
:- tool(receive/2, receive_/3).

% Start once from the root engine, before spawning actors.
start_actor_runtime :-
    record_create(Reports),
    shelf_create(counter(0), Counter),
    bag_create(Lock),
    engine_self(Main),
    record_create(Inbox),
    attach_mailbox(Inbox),
    set_self(main),
    store_set(actor_registry, main, actor(Main, Inbox, detached)),
    store_set(actor_registry, runtime, runtime(Reports, Counter, Lock)),
    engine_create(Reaper, [thread, detached(true)]),
    engine_resume_thread(Reaper, reap_actors(Reports, Lock)).

spawn_(Goal, Module) :- spawn_(Goal, _, Module).

spawn_(Goal, Pid, Module) :-
    spawn_(Goal, Pid, [], Module).

spawn_(Goal, Pid, Options, Module) :-
    self(Parent),
    spawn_options(Options, Parent, Link, Monitor, SourceOption, Destination),
    spawn_source(SourceOption, Module, Source),
    ( Destination == local ->
        spawn_local(Goal, Pid, Parent, Link, Monitor, Source, Module)
    ; Destination = remote(Node),
      spawn_remote(Goal, Pid, Parent, Link, Monitor, Source, Node)
    ).

spawn_local(Goal, Pid, Parent, Link, Monitor, Source, Module) :-
    store_get(actor_registry, runtime, runtime(Reports, Counter, Lock)),
    shelf_inc_and_get(Counter, 1, Id),
    Pid = actor(Id),
    record_create(Inbox),
    engine_create(Engine, [thread, report_to(Reports)]),
    ( Source == none ->
        with_mutex(Lock, start_actor(Pid, Engine, Inbox, Link, Monitor, none,
                                    run_actor(Pid, Parent, Inbox, Goal, Module)))
    ;
        Source = text(Text),
        concat_atom(['$web_prolog_actor_', Id], Private),
        create_module(Private),
        catch(
            prepare_and_start(Pid, Parent, Engine, Inbox, Link, Monitor, Private, Goal, Text, Lock),
            Error,
            ( engine_post(Engine, exit(0))@eclipse_language,
              discard_source(Private),
              erase_module(Private),
              throw(Error)
            )
        )
    ).

spawn_options(Options, Parent, Link, Monitor, Source, Destination) :-
    ( is_list(Options) -> true
    ; throw(error(type_error(list, Options), spawn/3))
    ),
    spawn_options_(Options, options(unset, unset, [], local),
                   options(LinkOption, MonitorOption, Source, Destination)),
    ( LinkOption == false -> Link = detached ; Link = linked(Parent) ),
    ( MonitorOption == true -> Monitor = watch(Parent) ; Monitor = none ).

spawn_options_([], Options, Options).
spawn_options_([Option|Options], options(Link, Monitor, Source, Destination), Parsed) :-
    ( nonvar(Option), Option = link(Value), Link == unset,
      ( Value == true ; Value == false ) ->
        Next = options(Value, Monitor, Source, Destination)
    ; nonvar(Option), Option = monitor(Value), Monitor == unset,
      ( Value == true ; Value == false ) ->
        Next = options(Link, Value, Source, Destination)
    ; source_option(Option) ->
        Next = options(Link, Monitor, [Option|Source], Destination)
    ; nonvar(Option), Option = node(Node), Destination == local, atom(Node) ->
        Next = options(Link, Monitor, Source, remote(Node))
    ;
        throw(error(domain_error(local_spawn_option, Option), spawn/3))
    ),
    spawn_options_(Options, Next, Parsed).

% Copy only the selected predicates into the child, as SWI does. Keep
% the original terms for static predicates and read live dynamic clauses.
spawn_source([], _, none) :- !.
spawn_source(Reversed, Module, text(Text)) :-
    reverse(Reversed, Options),
    source_options_text(Options, Module, Text).

source_option(Option) :-
    nonvar(Option),
    ( Option = src_text(Text), text_string(Text, _)
    ; Option = src_list(Clauses), is_list(Clauses)
    ; Option = src_predicates(Indicators), is_list(Indicators)
    ).

source_options_text(Options, Module, Text) :-
    findall(Part, (member(Option, Options), source_part(Option, Module, Part)), Parts),
    join_string(Parts, "\n", Text).

source_part(src_text(Text), _, String) :- source_string(Text, String).
source_part(src_list(Clauses), _, Text) :- serialize_source(Clauses, Text).
source_part(src_predicates(Indicators), Module, Text) :-
    findall(Clause,
        ( member(Indicator, Indicators), selected_clause(Indicator, Module, Clause) ),
        Clauses),
    serialize_source(Clauses, Text).

serialize_source(Clauses, Text) :-
    open(string(""), write, Stream),
    setup_call_cleanup(true,
        ( write_source(Clauses, Stream), get_stream_info(Stream, name, Text) ),
        close(Stream)).

selected_clause(Indicator, Module, Clause) :-
    ( nonvar(Indicator), Indicator = Name/Arity, local_indicators(Indicator) -> true
    ; throw(error(type_error(predicate_indicator, Indicator), spawn/3))
    ),
    ( get_flag(Indicator, stability, dynamic)@Module,
      Clause = (:- dynamic(Indicator))
    ; functor(Head, Name, Arity),
      source_body_(Head, Body, Module),
      Clause = (Head :- Body)
    ).

source_body_(Head, Body, Module) :-
    functor(Head, Name, Arity),
    ( get_flag(Name/Arity, stability, dynamic)@Module ->
        clause(Head, Body)@Module
    ; store_get(actor_registry, source(Module), Clauses),
      member(Clause, Clauses),
      ( Clause = (ClauseHead :- Body) -> Head = ClauseHead
      ; functor(Clause, Name, Arity), Clause = Head, Body = true )
    ).

write_source([], _).
write_source([Clause|Rest], Stream) :-
    write_term(Stream, Clause, [quoted(true), portable(true), max_depth(0)]),
    write(Stream, ".\n"),
    write_source(Rest, Stream).

actors(Pids) :-
    ( browser_session(_) -> Browser = true ; Browser = false ),
    stored_keys_and_values(actor_registry, Entries),
    findall(Pid,
        ( member(Pid-actor(Engine, _, _), Entries), Pid = actor(_),
          get_engine_property(Engine, status, Status), \+ finished_status(Status),
          ( Browser == false
          ; get_engine_property(Engine, store, Store), store_get(Store, browser_session, _) ) ),
        Pids).

% The embedding transport owns the wire connection.
set_linked_spawn_transport(Node, Transport) :-
    mailbox_store(Store),
    store_set(Store, spawn_transport(Node), Transport).

% Keep the local proxy linked during startup so an interrupted caller
% cannot strand it. Detach it after acknowledgement and before returning.
spawn_remote(Goal, Pid, Parent, Link, Monitor, Source, Node) :-
    Pid = '@'(Id, Node),
    mailbox_store(Store),
    ( store_get(Store, spawn_transport(Node), Transport) -> true
    ; throw(error(existence_error(spawn_transport, Node), spawn/3))
    ),
    ( Monitor = watch(Parent) -> ProxyMonitor = remote_watch(Parent) ; ProxyMonitor = none ),
    spawn_local(remote_spawn_proxy(Transport, Parent, Node, Goal, Source, Link),
                Proxy, Parent, linked(Parent), ProxyMonitor, none, actors),
    catch(
        ( receive({ remote_spawn_reply(Proxy, Reply) -> true },
                  [timeout(8), on_timeout(throw(error(remote_spawn_timeout(Node), spawn/3)))]),
          ( Reply = spawned(Id) -> true
          ; Reply = error(Reason) -> throw(error(remote_spawn_failed(Reason), spawn/3))
          ; exit(Proxy, kill), fail
          )
        ),
        Error,
        ( exit(Proxy, kill), throw(Error) )
    ).

remote_spawn_proxy(Transport, Parent, Node, Goal, Source, Link) :-
    self(Proxy),
    send(Transport, remote_spawn(Parent, Proxy, Node, Goal, Source)),
    receive({ remote_spawn_reply(Reply) -> true }),
    ( Reply = spawned(_) ->
        activate_remote_link(Proxy, Link),
        send(Parent, remote_spawn_reply(Proxy, Reply)),
        receive({ remote_down(Reason) -> exit(Reason) })
    ; send(Parent, remote_spawn_reply(Proxy, Reply))
    ).

activate_remote_link(_, linked(_)).
activate_remote_link(Proxy, detached) :-
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock,
        ( store_get(actor_registry, Proxy, actor(Engine, Inbox, _)),
          \+ store_get(actor_registry, exit_reason(Proxy), _),
          store_set(actor_registry, Proxy, actor(Engine, Inbox, detached))
        )).

% The wire PID stays live until the transport reports down, even when the
% local proxy has already retired to trigger a linked exit. The actor that
% acknowledges the spawn owns the route for outgoing messages.
acknowledge_remote_spawn(Proxy, Pid) :-
    Pid = '@'(Id, _),
    ground(Pid),
    self(Transport),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock,
        ( store_get(actor_registry, Proxy, actor(_, _, _)),
          \+ store_get(actor_registry, exit_reason(Proxy), _),
          \+ store_get(actor_registry, remote(Pid), _),
          store_set(actor_registry, remote(Pid), remote(Proxy, Transport)),
          ( store_get(actor_registry, pending_spawn_monitor(Proxy), Watcher) ->
              store_delete(actor_registry, pending_spawn_monitor(Proxy)),
              install_monitor(Watcher, Pid, Pid)
          ; true ),
          send(Proxy, remote_spawn_reply(spawned(Id)))
        )).

remote_actor_down(Proxy, Pid, Reason) :-
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock,
        ( store_get(actor_registry, remote(Pid), remote(Proxy, _)) ->
            store_delete(actor_registry, remote(Pid)),
            notify_monitors(Pid, Reason),
            send(Proxy, remote_down(Reason))
        ; true
        )).

source_string(Text, String) :-
    ( text_string(Text, String) -> true
    ; throw(error(type_error(text, Text), spawn/3))
    ).

text_string(Text, String) :-
    ( string(Text) -> String = Text
    ; atom(Text) -> atom_string(Text, String)
    ; is_list(Text), phrase(character_bytes(Text), Bytes), string_list(String, Bytes)
    ).

character_bytes([]) --> [].
character_bytes([Char|Chars]) -->
    { atom(Char), atom_string(Char, Text), string_list(Text, Bytes),
      utf8_character(Bytes, Bytes, []) },
    byte_sequence(Bytes),
    character_bytes(Chars).

byte_sequence([]) --> [].
byte_sequence([Byte|Bytes]) --> [Byte], byte_sequence(Bytes).

% The native reader handles quote syntax and escapes. Its strings contain
% bytes, so group each UTF-8 scalar before interning a character atom.
unicode_literal(String, Chars) :-
    string_list(String, Bytes),
    ( utf8_chars(Bytes, Chars) -> true
    ; throw(error(representation_error(utf8), read/2))
    ).

utf8_chars([], []).
utf8_chars(Bytes, [Char|Chars]) :-
    utf8_character(Bytes, Character, Rest),
    string_list(Text, Character),
    atom_string(Char, Text),
    utf8_chars(Rest, Chars).

utf8_character([Lead|Bytes], [Lead|Tail], Rest) :-
    ( Lead < 128 -> Tail = [], Rest = Bytes
    ; Lead >= 194, Lead =< 223 ->
        utf8_continuation(Bytes, Tail, Rest, 1)
    ; Lead >= 224, Lead =< 239 ->
        ( Lead =:= 224 -> Low = 160 ; Low = 128 ),
        ( Lead =:= 237 -> High = 159 ; High = 191 ),
        Bytes = [Second|More], Second >= Low, Second =< High,
        Tail = [Second|Last], utf8_continuation(More, Last, Rest, 1)
    ; Lead >= 240, Lead =< 244,
      ( Lead =:= 240 -> Low = 144 ; Low = 128 ),
      ( Lead =:= 244 -> High = 143 ; High = 191 ),
      Bytes = [Second|More], Second >= Low, Second =< High,
      Tail = [Second|Last], utf8_continuation(More, Last, Rest, 2)
    ).

utf8_continuation(Bytes, [], Bytes, 0) :- !.
utf8_continuation([Byte|Bytes], [Byte|Tail], Rest, Count) :-
    Byte >= 128, Byte =< 191,
    Next is Count - 1,
    utf8_continuation(Bytes, Tail, Rest, Next).

% Like SWI's child-side preparation handshake, readiness precedes
% publication and application execution. The preparatory resume is
% synchronous, so the reaper sees only the subsequent asynchronous run.
prepare_and_start(Pid, Parent, Engine, Inbox, Link, Monitor, Private, Goal, Text, Lock) :-
    engine_resume(Engine, prepare_actor(Pid, Parent, Inbox, Goal, Private, Text), Status),
    ( Status == yielded(ready) ->
        with_mutex(Lock, start_actor(Pid, Engine, Inbox, Link, Monitor, Private, run))
    ; Status = exception(Error) ->
        throw(Error)
    ;
        throw(error(source_preparation_failed(Status), spawn/3))
    ).

start_actor(Pid, Engine, Inbox, Link, Monitor, Private, Start) :-
    store_set(actor_registry, Pid, actor(Engine, Inbox, Link)),
    ( Private == none -> true
    ; store_set(actor_registry, actor_module(Pid), Private)
    ),
    install_start_monitor(Monitor, Pid),
    catch(
        engine_resume_thread(Engine, Start),
        Error,
        ( store_delete(actor_registry, Pid),
          remove_start_monitor(Monitor, Pid),
          ( Private == none -> true ; store_delete(actor_registry, actor_module(Pid)) ),
          throw(Error)
        )
    ).

install_start_monitor(none, _).
install_start_monitor(watch(Watcher), Pid) :- install_monitor(Watcher, Pid, Pid).
install_start_monitor(remote_watch(Watcher), Proxy) :-
    store_set(actor_registry, pending_spawn_monitor(Proxy), Watcher).

remove_start_monitor(none, _).
remove_start_monitor(watch(Watcher), Pid) :- remove_monitor(Watcher, Pid).
remove_start_monitor(remote_watch(_), Proxy) :- clear_pending_spawn_monitor(Proxy).

clear_pending_spawn_monitor(Pid) :-
    ( store_get(actor_registry, pending_spawn_monitor(Pid), _) ->
        store_delete(actor_registry, pending_spawn_monitor(Pid))
    ; true
    ).

prepare_actor(Pid, Parent, Inbox, Goal, Private, Text) :-
    set_actor_context(Pid, Parent, Inbox),
    ( nonvar(Goal), Goal = toplevel_actors:ptcp(_, _, browser) ->
        mailbox_store(Store), store_set(Store, browser_session, Pid)
    ; true
    ),
    compile_term([(:- local op(200, xfx, '@')),
                  (:- import(actors)), (:- import(exit/1 from actors)),
                  (:- local macro(type(string), unicode_literal/2, [])),
                  (:- import(select/3 from lists)),
                  (:- import(subtract/3 from lists)),
                  (:- import(forall/2 from swi))])@Private,
    ( current_module(isotope_rpc), nonvar(Goal), Goal = Module:Entry,
      Module == toplevel_actors, nonvar(Entry), functor(Entry, ptcp, 3) ->
        compile_term([(:- import(rpc/2 from isotope_rpc)),
                      (:- import(rpc/3 from isotope_rpc)),
                      (:- import(promise/3 from isotope_rpc)),
                      (:- import(promise/4 from isotope_rpc)),
                      (:- import(yield/2 from isotope_rpc)),
                      (:- import(yield/3 from isotope_rpc))])@Private
    ; true
    ),
    ( current_module(n5_shared_db) ->
        compile_term([(:- import(n5_shared_db))])@Private
    ; true ),
    ( nonvar(Goal), Goal = toplevel_actors:ptcp(_, _, browser) ->
        compile_term([(:- import(supervisor_spawn/3 from server_behaviours)),
                      (:- import(supervisor_halt/1 from server_behaviours)),
                      (:- import(server_request/3 from server_behaviours)),
                      (:- import(server_promise/3 from server_behaviours)),
                      (:- import(server_yield/2 from server_behaviours)),
                      (:- import(server_upgrade/3 from server_behaviours)),
                      (:- import(toplevel_spawn/1 from toplevel_actors)),
                      (:- import(toplevel_spawn/2 from toplevel_actors)),
                      (:- import(toplevel_call/2 from toplevel_actors)),
                      (:- import(toplevel_call/3 from toplevel_actors))])@Private
    ; true
    ),
    ( browser_session(_) ->
        compile_term([(:- import(demo_services))])@Private
    ; current_module(n5_shared_db) ->
        compile_term([(:- import(linda_out/1 from demo_services)),
                      (:- import(linda_in/1 from demo_services)),
                      (:- import(linda_rd/1 from demo_services)),
                      (:- import(linda_inp/1 from demo_services)),
                      (:- import(linda_rdp/1 from demo_services))])@Private
    ; true ),
    load_actor_source(Text, Private),
    yield(ready, run),
    run_actor_goal(Goal, Private).

load_actor_source(Text, Module) :-
    setup_call_cleanup(open(string(Text), read, Stream),
        ( read_source(Stream, Module, Clauses) -> true
        ; throw(error(syntax_error(src_text), spawn/3)) ),
        close(Stream)),
    ( browser_session(_) ->
        maplist(browser_source_clause, Clauses, Compiled)
    ; Compiled = Clauses
    ),
    declare_shared_shadows(Clauses, Module),
    compile_term(Compiled)@Module,
    ( store_get(actor_registry, source(Module), Previous) -> true ; Previous = [] ),
    append(Previous, Clauses, Source),
    store_set(actor_registry, source(Module), Source).

% ECLiPSe requires an explicit local declaration before compiling a
% definition that shadows an imported predicate.
declare_shared_shadows(Clauses, Module) :-
    ( current_module(n5_shared_db) ->
        findall((:- local(Indicator)),
            ( member(Clause, Clauses),
              source_indicator(Clause, Indicator),
              current_module_predicate(exported, Indicator)@n5_shared_db ),
            Declarations),
        sort(Declarations, Unique),
        ( Unique == [] -> true ; compile_term(Unique)@Module )
    ; true ).

source_indicator((:- dynamic(Spec)), Indicator) :- !,
    source_dynamic_indicator(Spec, Indicator).
source_indicator((Head --> _), Name/Arity) :- !,
    functor(Head, Name, Extra), Arity is Extra + 2.
source_indicator((Head :- _), Name/Arity) :- !, functor(Head, Name, Arity).
source_indicator(Head, Name/Arity) :- functor(Head, Name, Arity).

source_dynamic_indicator((A, B), Indicator) :- !,
    ( source_dynamic_indicator(A, Indicator) ; source_dynamic_indicator(B, Indicator) ).
source_dynamic_indicator(Indicator, Indicator).

% Restrict the first loader to local clauses and dynamic declarations.
% In particular, never pass module-changing directives to the compiler.
read_source(Stream, Module, Clauses) :-
    read(Stream, Term)@Module,
    ( Term == end_of_file, at_eof(Stream) ->
        Clauses = []
    ;
        source_clause(Term),
        Clauses = [Term|Rest],
        read_source(Stream, Module, Rest)
    ).

source_clause(Term) :-
    ( nonvar(Term), Term = (:- dynamic(Spec)), local_indicators(Spec) -> true
    ; nonvar(Term), Term = (Head :- _) -> local_clause_head(Head)
    ; nonvar(Term), Term = (Head --> _) -> local_clause_head(Head)
    ; local_clause_head(Term) -> true
    ; throw(error(domain_error(actor_source_clause, Term), spawn/3))
    ).

local_indicators(Spec) :-
    nonvar(Spec),
    ( Spec = (A, B) -> local_indicators(A), local_indicators(B)
    ; Spec = Name/Arity, atom(Name), integer(Arity), Arity >= 0
    ).

local_clause_head(Head) :-
    nonvar(Head),
    ( atom(Head) ; compound(Head) ),
    functor(Head, Name, _),
    ( memberchk(Name, [':', '@', ':-', '?-', ',', '-->', end_of_file]) ->
        throw(error(domain_error(actor_source_head, Head), spawn/3))
    ;
        true
    ).

run_actor(Pid, Parent, Inbox, Goal, Module) :-
    set_actor_context(Pid, Parent, Inbox),
    run_actor_goal(Goal, Module).

run_actor_goal(Goal, Module) :-
    ( browser_session(_) -> browser_goal(Goal, Call) ; Call = Goal ),
    once(call(Call)@Module).

set_actor_context(Pid, Parent, Inbox) :-
    set_self(Pid),
    mailbox_store(Store),
    store_set(Store, web_prolog_parent, Parent),
    ( store_get(actor_registry, Parent, actor(Engine, _, _)),
      get_engine_property(Engine, store, ParentStore),
      store_get(ParentStore, browser_session, Session) ->
        store_set(Store, browser_session, Session)
    ; true
    ),
    attach_mailbox(Inbox).

browser_session(Session) :-
    mailbox_store(Store),
    store_get(Store, browser_session, Session).

browser_source_clause((Head :- Body), (Head :- Translated)) :- !,
    browser_goal(Body, Translated).
browser_source_clause(Clause, Clause).

% Only rewrite executable positions. In a receive, guards and actions
% are goals, while the pattern is data.
browser_goal(Goal, Goal) :- var(Goal), !.
browser_goal(format(Control), actors:browser_format(Control, [])) :- !.
browser_goal(format(Control, Args), actors:browser_format(Control, Args)) :- !.
browser_goal(time(Goal), actors:browser_time(Translated)) :- !,
    browser_goal(Goal, Translated).
browser_goal(call_cleanup(Goal, Cleanup), actors:browser_call_cleanup(Call, Done)) :- !,
    browser_goal(Goal, Call), browser_goal(Cleanup, Done).
browser_goal(sleep(Time), actors:browser_sleep(Time)) :- !.
browser_goal(random_between(Low, High, Random), actors:browser_random_between(Low, High, Random)) :- !.
browser_goal(random_member(Item, List), actors:browser_random_member(Item, List)) :- !.
browser_goal(write(Term), actors:browser_format("~w", [Term])) :- !.
browser_goal(nl, actors:browser_format("~n", [])) :- !.
browser_goal(writeln(Term), actors:browser_format("~w~n", [Term])) :- !.
browser_goal(read(Value), input('|:', Value, [correlate(true)])) :- !.
browser_goal(clause(Head, Body), actors:source_body(Head, Body)) :- !.
browser_goal(call(Goal), call(Translated)) :- !, browser_goal(Goal, Translated).
browser_goal((A,B), (X,Y)) :- !, browser_goal(A, X), browser_goal(B, Y).
browser_goal((A;B), (X;Y)) :- !, browser_goal(A, X), browser_goal(B, Y).
browser_goal((A->B), (X->Y)) :- !, browser_goal(A, X), browser_goal(B, Y).
browser_goal(receive({Clauses}), receive({Translated})) :- !,
    browser_receive_clauses(Clauses, Translated).
browser_goal(receive({Clauses}, Options), receive({Translated}, Options)) :- !,
    browser_receive_clauses(Clauses, Translated).
browser_goal(Goal, Goal).

browser_receive_clauses(Clauses, Clauses) :- var(Clauses), !.
browser_receive_clauses({}, {}) :- !.
browser_receive_clauses((A;B), (X;Y)) :- !,
    browser_receive_clauses(A, X), browser_receive_clauses(B, Y).
browser_receive_clauses((Head -> Body), ((Pattern if Test) -> Action)) :-
    nonvar(Head), Head = (Pattern if Guard), !,
    browser_goal(Guard, Test), browser_goal(Body, Action).
browser_receive_clauses((Pattern -> Body), (Pattern -> Action)) :- !,
    browser_goal(Body, Action).
browser_receive_clauses(Clauses, Clauses).

browser_format(Control, Args) :-
    ( text_string(Control, Format) -> true ; Format = Control ),
    self(Pid),
    ( browser_session(Session), Pid \== Session ->
        open(string(""), write, Stream),
        setup_call_cleanup(true,
            ( format(Stream, Format, Args), get_stream_info(Stream, name, Text) ),
            close(Stream)),
        send(main, browser_child_output(Session, Text))
    ; toplevel_actors:browser_format(Format, Args)
    ).

browser_chart_trace(Event) :-
    ( browser_session(Session), self(Actor) ->
        term_string(Event, Text),
        send(main, browser_child_trace(Session, Actor, Text))
    ; true ).

flush :-
    receive({ Message -> flush_message(Message), flush }, [timeout(0)]).

flush_message(Message) :-
    ( browser_session(_) -> browser_format("Shell got ~w~n", [Message])
    ; output(Message)
    ).

browser_time_(Goal, Module) :-
    setup_call_cleanup(elapsed(Start), call(Goal)@Module, report_elapsed(Start)).

report_elapsed(Start) :-
    elapsed(End),
    Seconds is End - Start,
    browser_session(Session),
    sprintf(Text, "%% %.3f seconds elapsed%n", [Seconds]),
    send(main, browser_child_output(Session, Text)).

browser_sleep(Time) :-
    ( number(Time) -> sleep(Time)
    ; var(Time) -> throw(error(instantiation_error, sleep/1))
    ; throw(error(type_error(number, Time), sleep/1))
    ).

browser_random_between(Low, High, Random) :-
    integer(Low), integer(High), Low =< High,
    frandom(Fraction),
    Random is Low + fix(floor(Fraction * (High - Low + 1))).

browser_random_member(Item, List) :-
    length(List, Length),
    browser_random_between(1, Length, Index),
    list_item(Index, List, Item).

list_item(1, [Item|_], Item) :- !.
list_item(Index, [_|Rest], Item) :-
    Next is Index - 1,
    list_item(Next, Rest, Item).

% ECLiPSe copies the native cleanup goal when it registers it. Run a
% deterministic cleanup directly so its bindings reach the caller.
browser_call_cleanup_(Goal, Cleanup, Module) :-
    shelf_create(cleaned(false), State),
    setup_call_cleanup(
        true,
        ( sepia_kernel:get_cut(Before),
          call(Goal)@Module,
          sepia_kernel:get_cut(After),
          ( Before == After ->
              shelf_set(State, 1, true),
              once(call(Cleanup)@Module)
          ; true )
        ),
        finish_browser_cleanup(State, Cleanup, Module)
    ).

finish_browser_cleanup(State, Cleanup, Module) :-
    ( shelf_get(State, 1, false) -> call(Cleanup)@Module ; true ).

set_self(Pid) :-
    mailbox_store(Store),
    store_set(Store, web_prolog_pid, Pid).

self(Pid) :-
    mailbox_store(Store),
    store_get(Store, web_prolog_pid, Pid).

Pid ! Message :-
    send(Pid, Message).

% Share the lifecycle lock with the reaper so registration cannot race
% with retirement. This registry is shared by the node's owner sessions.
register(Name, Pid) :-
    require_actor_name(Name, register/2),
    ( ground(Pid) -> true ; throw(error(instantiation_error, register/2)) ),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock, register_actor(Name, Pid)).

register_actor(Name, Pid) :-
    ( recorded(actor_names, registered(_, Pid), _) ->
        throw(process_already_has_a_name(Pid))
    ; ( Name == main ; recorded(actor_names, registered(Name, _), _) ) ->
        throw(name_is_in_use(Name))
    ; store_get(actor_registry, Pid, actor(Engine, _, _)),
      \+ store_get(actor_registry, exit_reason(Pid), _),
      get_engine_property(Engine, status, Status),
      \+ finished_status(Status) ->
        recordz(actor_names, registered(Name, Pid))
    ;
        throw(error(existence_error(process, Pid),
                    context(actors:register/2, 'local actor no longer exists')))
    ).

unregister(Name) :-
    require_actor_name(Name, unregister/1),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock, remove_actor_name(Name, _)).

whereis(Name, Pid) :-
    require_actor_name(Name, whereis/2),
    ( registered_actor(Name, Found) -> Pid = Found ; Pid = undefined ).

require_actor_name(Name, Caller) :-
    ( atom(Name) -> true
    ; var(Name) -> throw(error(instantiation_error, Caller))
    ; throw(error(type_error(atom, Name), Caller))
    ).

registered_actor(Name, Pid) :-
    atom(Name),
    recorded(actor_names, registered(Name, Pid), _).

remove_actor_name(Name, Pid) :-
    ( recorded(actor_names, registered(Name, Pid), Entry) -> erase(Entry)
    ; true ).

send(Name, Message) :-
    registered_actor(Name, Pid), !,
    send(Pid, Message).
send(Pid, Message) :-
    ( ground(Pid), store_get(actor_registry, Pid, actor(_, Inbox, _)) ->
        record_wait_append(Inbox, Message, block, 9999999)
    ; ground(Pid), store_get(actor_registry, remote(Pid), remote(_, Transport)) ->
        send(Transport, remote_send(Pid, Message))
    ; ground(Pid), Pid = '@'(_, Node),
      mailbox_store(Store), store_get(Store, send_transport(Node), Transport) ->
        self(Sender),
        send(Transport, remote_send_from(Sender, Pid, Message))
    ; atom(Pid), Pid \== main ->
        throw(error(existence_error(actor_name, Pid),
                    context(actor:send/2, 'no actor registered under name')))
    ;
        true
    ).

% A timer is linked to its scheduling actor. Publish its cancellation
% record before letting the timer start, including when the delay is zero.
send(Pid, Message, Options) :-
    ( is_list(Options) -> true ; throw(error(type_error(list, Options), send/3)) ),
    ( memberchk(delay(Delay), Options) -> true ; Delay = 0 ),
    ( number(Delay), Delay >= 0 -> true
    ; throw(error(domain_error(nonnegative_delay, Delay), send/3))
    ),
    self(Owner),
    spawn_(delayed_delivery(Pid, Message, Delay), Timer, actors),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock,
        ( ( memberchk(id(Id), Options) ->
              recordz(delayed_sends, timer(Owner, Id, Timer))
          ; true ),
          send(Timer, '$start_timer')
        )).

delayed_delivery(Pid, Message, Delay) :-
    receive({ '$start_timer' -> true }),
    receive({ '$cancel_timer' -> true },
            [timeout(Delay), on_timeout(send(Pid, Message))]).

cancel(Id) :-
    self(Owner),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock, cancel_timers(Owner, Id)).

cancel_timers(Owner, Id) :-
    copy_term(Id, Pattern),
    ( recorded(delayed_sends, timer(Owner, Pattern, Timer), Entry) ->
        erase(Entry),
        send(Timer, '$cancel_timer'),
        cancel_timers(Owner, Id)
    ; true
    ).

set_peer_send_transport(Node, Transport) :-
    mailbox_store(Store),
    store_set(Store, send_transport(Node), Transport).

set_prompt_relay(Target) :-
    mailbox_store(Store),
    store_set(Store, prompt_relay, Target).

output(Term) :-
    output(Term, []).

output(Term, Options) :-
    self(Pid),
    ( memberchk(target(Target), Options) -> send(Target, output(Pid, Term))
    ; actor_parent(Parent) -> send(Parent, output(Pid, Term))
    ; writeln(Term)
    ).

input(Prompt, Value) :-
    input(Prompt, Value, []).

input(Prompt, Value, Options) :-
    self(Pid),
    ( memberchk(target(Target), Options) -> true
    ; current_io_target(Target) -> true
    ; actor_parent(Target)
    ),
    ( ( memberchk(correlate(true), Options) ; browser_prompt_target(Target) ) ->
        correlated_input(Pid, Target, Prompt, Value)
    ;
        send_input_prompt(Target, Pid, plain, Prompt),
        wait_input(legacy, Value)
    ).

% Browser toplevels must correlate input from loaded predicates as well as
% input written directly in a query. Nested actors keep their own I/O rules.
set_browser_prompt_correlation :-
    mailbox_store(Store),
    store_set(Store, browser_prompt_correlation, true).

browser_prompt_target(Target) :-
    mailbox_store(Store),
    store_get(Store, browser_prompt_correlation, true),
    current_io_target(Bridge),
    Target == Bridge.

correlated_input(Pid, Target, Prompt, Value) :-
    fresh_reference(Ref),
    send_input_prompt(Target, Pid, correlated(Ref), Prompt),
    wait_correlated_input(Pid, Ref, Prompt, Value).

send_input_prompt(Target, Pid, Mode, Prompt) :-
    mailbox_store(Store),
    ( store_get(Store, prompt_relay, Relay), Target == Relay ->
        Event = '$input_prompt'(Pid, Mode, Prompt)
    ; Mode = correlated(Ref) -> Event = prompt(Pid, prompt_ref(Ref, Prompt))
    ; Event = prompt(Pid, Prompt)
    ),
    send(Target, Event).

wait_correlated_input(Pid, Ref, Prompt, Value) :-
    receive({ '$input'(_, Ref, Value) -> true
            ; '$input_retarget'(Ref, Replacement) if ground(Replacement) ->
                correlated_input(Pid, Replacement, Prompt, Value)
            }, [timeout(0.05), on_timeout(wait_correlated_input(Pid, Ref, Prompt, Value))]).

wait_input(legacy, Value) :-
    receive({ '$input'(_, Value) -> true },
            [timeout(0.05), on_timeout(wait_input(legacy, Value))]).

respond(Pid, Value) :-
    self(From),
    send(Pid, '$input'(From, Value)).

respond(Pid, Ref, Value) :-
    ( ground(Ref) -> true ; throw(error(instantiation_error, respond/3)) ),
    self(From),
    send(Pid, '$input'(From, Ref, Value)).

retarget_prompt(Pid, Ref, Target) :-
    ( ground(Ref-Target) -> true ; throw(error(instantiation_error, retarget_prompt/3)) ),
    send(Pid, '$input_retarget'(Ref, Target)).

actor_parent(Parent) :-
    mailbox_store(Store),
    store_get(Store, web_prolog_parent, Parent).

current_io_target(Target) :-
    mailbox_store(Store),
    store_get(Store, web_prolog_io_target, Target).

set_io_target(Target) :-
    mailbox_store(Store),
    store_set(Store, web_prolog_io_target, Target).

clear_io_target :-
    mailbox_store(Store),
    ( store_get(Store, web_prolog_io_target, _) ->
        store_delete(Store, web_prolog_io_target)
    ;
        true
    ).

fresh_reference(ref(Id)) :-
    store_get(actor_registry, runtime, runtime(_, Counter, _)),
    shelf_inc_and_get(Counter, 1, Id).

% The first request to commit under the lifecycle lock owns the reason.
% A reaper request is queued before releasing the lock, so delivery does
% not depend on the requesting actor remaining alive.
exit(Reason) :-
    ( var(Reason) -> throw(error(instantiation_error, exit/1)) ; true ),
    self(Pid),
    ( Pid == main ->
        throw(error(permission_error(exit, actor, main), exit/1))
    ;
        request_actor_exit(Pid, Reason),
        eclipse_language:exit(0)
    ).

exit(Pid, Reason) :-
    ( ground(Pid) -> true ; throw(error(instantiation_error, exit/2)) ),
    ( var(Reason) -> throw(error(instantiation_error, exit/2)) ; true ),
    ( Pid \== main, self(Pid) -> exit(Reason)
    ; request_actor_exit(Pid, Reason)
    ).

request_actor_exit(Pid, Reason) :-
    store_get(actor_registry, runtime, runtime(Reports, _, Lock)),
    with_mutex(Lock,
        ( store_get(actor_registry, remote(Pid), remote(_, Transport)) ->
            send(Transport, remote_exit(Pid, Reason))
        ; commit_exit(Pid, Reason, Reports)
        )).

commit_exit(Pid, Reason, Reports) :-
    ( Pid \== main,
      store_get(actor_registry, Pid, actor(Engine, _, _)),
      \+ store_get(actor_registry, exit_reason(Pid), _) ->
        store_set(actor_registry, exit_reason(Pid), Reason),
        record_wait_append(Reports, exit_request(Engine), block, 9999999)
    ;
        true
    ).

% Native completion reports cover ordinary returns. Explicit exit requests
% also schedule a status check because forced exit can omit that report.
reap_actors(Reports, Lock) :-
    record_wait_remove(Reports, Report, block),
    reap_report(Report, Reports, Lock),
    reap_actors(Reports, Lock).

reap_report(exit_request(Engine), Reports, Lock) :- !,
    get_engine_property(Engine, status, Status),
    ( finished_status(Status) ->
        finish_reap(Engine, Status, Reports, Lock)
    ;
        engine_post(Engine, exit(0))@eclipse_language,
        record_wait_append(Reports, forced_exit(Engine), block, 9999999)
    ).
reap_report(forced_exit(Engine), Reports, Lock) :- !,
    ( engine_join(Engine, 0.05, Status), Status \== running ->
        finish_reap(Engine, Status, Reports, Lock)
    ;
        record_wait_append(Reports, forced_exit(Engine), block, 9999999)
    ).
reap_report(Engine, Reports, Lock) :-
    engine_join(Engine, block, Status),
    finish_reap(Engine, Status, Reports, Lock).

finished_status(true).
finished_status(false).
finished_status(exception(_)).
finished_status(exited(_)).

finish_reap(Engine, Status, Reports, Lock) :-
    with_mutex(Lock, retire_actor(Engine, Status, Reports)).

retire_actor(Engine, Status, Reports) :-
    stored_keys_and_values(actor_registry, Entries),
    ( memberchk(Pid-actor(Engine, _, _), Entries) ->
        store_delete(actor_registry, Pid),
        remove_actor_name(_, Pid),
        ( recorded(delayed_sends, timer(_, _, Pid), TimerEntry) -> erase(TimerEntry) ; true ),
        % Joining a completed threaded engine leaves it available for reuse.
        % Explicitly close it so retired actors release their native threads.
        ( Status = exited(_) -> true ; engine_post(Engine, exit(3))@eclipse_language ),
        clear_pending_spawn_monitor(Pid),
        retire_actor_module(Pid),
        discard_watcher_monitors(Pid),
        ( store_get(actor_registry, exit_reason(Pid), Committed) ->
            store_delete(actor_registry, exit_reason(Pid)),
            monitor_reason(Committed, Reason)
        ;
            monitor_reason(Status, Reason)
        ),
        findall(Child, member(Child-actor(_, _, linked(Pid)), Entries), Children),
        stop_linked_children(Children, Reports),
        notify_monitors(Pid, Reason)
    ;
        true
    ).

retire_actor_module(Pid) :-
    ( store_get(actor_registry, actor_module(Pid), Module) ->
        store_delete(actor_registry, actor_module(Pid)),
        discard_source(Module),
        erase_module(Module)
    ;
        true
    ).

discard_source(Module) :-
    ( store_get(actor_registry, source(Module), _) ->
        store_delete(actor_registry, source(Module))
    ; true
    ).

stop_linked_children([], _).
stop_linked_children([Child|Children], Reports) :-
    ( store_get(actor_registry, Child, actor(Engine, _, _)),
      get_engine_property(Engine, status, Status),
      \+ finished_status(Status) ->
        commit_exit(Child, kill, Reports)
    ;
        true
    ),
    stop_linked_children(Children, Reports).

% Installation, delivery and removal share the pid lifecycle mutex. Once
% demonitor releases it, any down for this ref has already been enqueued.
monitor(Target, Ref) :-
    ( nonvar(Target) -> true ; throw(error(instantiation_error, monitor/2)) ),
    self(Watcher),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    fresh_reference(Ref),
    with_mutex(Lock,
        ( ( registered_actor(Target, Found) -> Pid = Found ; Pid = Target ),
          install_monitor(Watcher, Pid, Ref)
        )).

install_monitor(Watcher, Pid, Ref) :-
    ( ground(Pid),
      ( store_get(actor_registry, Pid, actor(_, _, _))
      ; store_get(actor_registry, remote(Pid), _)
      ) ->
        recordz(actor_monitors, monitor(Watcher, Pid, Ref))
    ;
        send(Watcher, down(Pid, Ref, no_process))
    ).

demonitor(Ref) :-
    demonitor(Ref, []).

demonitor(Ref, Options) :-
    ( ground(Ref) -> true ; throw(error(instantiation_error, demonitor/2)) ),
    ( is_list(Options) -> true ; throw(error(type_error(list, Options), demonitor/2)) ),
    validate_demonitor_options(Options),
    self(Watcher),
    store_get(actor_registry, runtime, runtime(_, _, Lock)),
    with_mutex(Lock, remove_monitor(Watcher, Ref)),
    ( memberchk(flush, Options) -> flush_monitor_down(Ref) ; true ).

validate_demonitor_options([]).
validate_demonitor_options([Option|Options]) :-
    ( Option == flush -> true
    ; var(Option) -> throw(error(instantiation_error, demonitor/2))
    ; throw(error(domain_error(demonitor_option, Option), demonitor/2))
    ),
    validate_demonitor_options(Options).

remove_monitor(Watcher, Ref) :-
    ( recorded(actor_monitors, monitor(Watcher, _, Ref), Entry) -> erase(Entry)
    ; true
    ).

flush_monitor_down(Ref) :-
    receive({ down(_, Ref, _) -> flush_monitor_down(Ref) }, [timeout(0)]).

discard_watcher_monitors(Watcher) :-
    ( recorded(actor_monitors, monitor(Watcher, _, _), Entry) ->
        erase(Entry),
        discard_watcher_monitors(Watcher)
    ;
        true
    ).

notify_monitors(Pid, Reason) :-
    ( recorded(actor_monitors, monitor(Watcher, Pid, Ref), Entry) ->
        erase(Entry),
        send(Watcher, down(Pid, Ref, Reason)),
        notify_monitors(Pid, Reason)
    ;
        true
    ).

monitor_reason(exception(error(Formal, _)), exception(error(Formal, _))) :- !.
monitor_reason(Status, Status).

% Called by the actor launcher, in the receiving engine, before running its
% goal. The inbox is shared with senders; only this engine reads either queue.
attach_mailbox(Inbox) :-
    record_create(Deferred),
    mailbox_store(Store),
    store_set(Store, web_prolog_mailbox, mailbox(Inbox, Deferred)).

mailbox_store(Store) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store).

% Internal control path for the toplevel layer.
post_actor_event_(Pid, Goal, Module) :-
    ( ground(Pid), Pid \== main,
      store_get(actor_registry, Pid, actor(Engine, _, _)),
      \+ store_get(actor_registry, exit_reason(Pid), _) ->
        engine_post(Engine, Goal)@Module
    ;
        true
    ).

actor_module(Pid, Module) :-
    store_get(actor_registry, actor_module(Pid), Module).

% The toplevel uses this after accepting a new call to remove commands
% that arrived before it. Later messages in the inbox stay untouched.
discard_deferred_(Test, Module) :-
    mailbox_store(Store),
    store_get(Store, web_prolog_mailbox, mailbox(_, Deferred)),
    ( recorded(Deferred, Message, Ref),
      call(Test, Message)@Module ->
        erase(Ref),
        discard_deferred_(Test, Module)
    ;
        true
    ).

receive_(Clauses, Module) :-
    receive_(Clauses, [], Module).

receive_({}, Options, Module) :- !,
    receive_({(_ if fail) -> true}, Options, Module).
receive_({Clauses}, Options, Module) :-
    mailbox_store(Store),
    store_get(Store, web_prolog_mailbox, mailbox(Inbox, Deferred)),
    wait_spec(Options, Wait, OnTimeout),
    ( recorded(Deferred, Message, Ref),
      select_body(Clauses, Message, Module, Body) ->
        erase(Ref),
        call(Body)@Module
    ;
        receive_scan(Inbox, Deferred, Clauses, Module, Wait, OnTimeout)
    ).

% Like SWI, record the incoming message before evaluating guards. Once
% selected, erase it before calling the body, even if the body later fails.
receive_scan(Inbox, Deferred, Clauses, Module, Wait, OnTimeout) :-
    ( wait_message(Inbox, Wait, Message) ->
        recordz(Deferred, Message, Ref),
        ( select_body(Clauses, Message, Module, Body) ->
            erase(Ref),
            call(Body)@Module
        ;
            receive_scan(Inbox, Deferred, Clauses, Module, Wait, OnTimeout)
        )
    ;
        call(OnTimeout)@Module
    ).

select_body((Clause ; Clauses), Message, Module, Body) :-
    ( select_body(Clause, Message, Module, Body)
    ; select_body(Clauses, Message, Module, Body)
    ).
select_body((Head -> Body), Message, Module, Body) :-
    ( nonvar(Head), Head = if(Pattern, Guard) ->
        match_message(Pattern, Message),
        catch(once(call(Guard)@Module), Error, guard_exception(Error))
    ;
        match_message(Head, Message)
    ).

match_message(Pattern, Message) :-
    instance(Message, Pattern),
    Pattern = Message.

guard_exception(abort) :- !, throw(abort).
guard_exception('$abort_goal') :- !, throw('$abort_goal').
guard_exception('$ptcp_time_limit') :- !, throw('$ptcp_time_limit').
guard_exception(unwind(Reason)) :- !, throw(unwind(Reason)).
guard_exception(_) :- fail.

wait_spec(Options, Wait, OnTimeout) :-
    ( memberchk(on_timeout(Goal), Options) -> OnTimeout = Goal ; OnTimeout = true ),
    ( memberchk(timeout(Seconds), Options) ->
        ( Seconds =:= 0 ->
            Wait = poll
        ;
            elapsed(Now),
            Deadline is Now + Seconds,
            Wait = until(Deadline)
        )
    ;
        Wait = block
    ).

wait_message(Inbox, block, Message) :-
    record_wait_remove(Inbox, Message, block).
wait_message(Inbox, poll, Message) :-
    record_wait_remove(Inbox, Message, 0).
wait_message(Inbox, until(Deadline), Message) :-
    elapsed(Now),
    Remaining is Deadline - Now,
    Remaining > 0,
    record_wait_remove(Inbox, Message, Remaining).

elapsed(Seconds) :-
    statistics(times, [_, _, Seconds]).
