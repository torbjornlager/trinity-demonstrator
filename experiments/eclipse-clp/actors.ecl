:- module(actors).

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
:- tool(post_actor_event/2, post_actor_event_/3).
:- tool(discard_deferred/1, discard_deferred_/2).

:- local store(actor_registry).
:- local record(actor_monitors).
:- local record(actor_names).
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

spawn_(Goal, Pid, Module) :-
    spawn_(Goal, Pid, [], Module).

spawn_(Goal, Pid, Options, Module) :-
    self(Parent),
    spawn_options(Options, Parent, Link, Monitor, Source, Destination),
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
              erase_module(Private),
              throw(Error)
            )
        )
    ).

spawn_options(Options, Parent, Link, Monitor, Source, Destination) :-
    ( is_list(Options) -> true
    ; throw(error(type_error(list, Options), spawn/3))
    ),
    spawn_options_(Options, options(unset, unset, none, local),
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
    ; nonvar(Option), Option = src_text(Text), Source == none ->
        source_string(Text, String),
        Next = options(Link, Monitor, text(String), Destination)
    ; nonvar(Option), Option = node(Node), Destination == local, atom(Node) ->
        Next = options(Link, Monitor, Source, remote(Node))
    ;
        throw(error(domain_error(local_spawn_option, Option), spawn/3))
    ),
    spawn_options_(Options, Next, Parsed).

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
    ( string(Text) -> String = Text
    ; atom(Text) -> atom_string(Text, String)
    ; throw(error(type_error(text, Text), spawn/3))
    ).

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
    compile_term([(:- import(actors)), (:- import(exit/1 from actors))])@Private,
    ( current_module(isotope_rpc), nonvar(Goal), Goal = Module:Entry,
      Module == toplevel_actors, nonvar(Entry), functor(Entry, ptcp, 3) ->
        compile_term([(:- import(rpc/2 from isotope_rpc)),
                      (:- import(rpc/3 from isotope_rpc)),
                      (:- import(promise/3 from isotope_rpc)),
                      (:- import(promise/4 from isotope_rpc)),
                      (:- import(yield/2 from isotope_rpc))])@Private
    ; true
    ),
    ( nonvar(Goal), Goal = toplevel_actors:ptcp(_, _, browser) ->
        compile_term([(:- import(toplevel_spawn/1 from toplevel_actors)),
                      (:- import(toplevel_spawn/2 from toplevel_actors)),
                      (:- import(toplevel_call/2 from toplevel_actors)),
                      (:- import(toplevel_call/3 from toplevel_actors))])@Private
    ; true
    ),
    open(string(Text), read, Stream),
    catch(
        ( read_source(Stream, Private, Clauses) -> true
        ; throw(error(syntax_error(src_text), spawn/3))
        ),
        Error,
        ( close(Stream), throw(Error) )
    ),
    close(Stream),
    compile_term(Clauses)@Private,
    yield(ready, run),
    once(call(Goal)@Private).

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
    ( memberchk(Name, [':', '@', ':-', '?-', '-->', end_of_file]) ->
        throw(error(domain_error(actor_source_head, Head), spawn/3))
    ;
        true
    ).

run_actor(Pid, Parent, Inbox, Goal, Module) :-
    set_actor_context(Pid, Parent, Inbox),
    once(call(Goal)@Module).

set_actor_context(Pid, Parent, Inbox) :-
    set_self(Pid),
    mailbox_store(Store),
    store_set(Store, web_prolog_parent, Parent),
    attach_mailbox(Inbox).

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
        erase_module(Module)
    ;
        true
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
