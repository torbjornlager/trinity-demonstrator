:- module(toplevel_actors).
:- use_module(actors).
:- use_module(solution_buffer).
:- lib(prolog_extras).
:- lib(format).

:- export toplevel_spawn/1, toplevel_spawn/2.
:- export toplevel_call/2, toplevel_call/3.
:- export toplevel_next/1, toplevel_next/2.
:- export toplevel_call_synch/3, toplevel_call_synch/4.
:- export toplevel_next_synch/2, toplevel_next_synch/3.
:- export toplevel_stop/1, toplevel_stop/2, toplevel_abort/1.
:- export toplevel_halt/1, toplevel_halt/2.
:- lib(timeout).
:- export ptcp/4.  % Runtime entry point, called from the private actor module.
:- export toplevel_spawn_browser/2.
:- export browser_format/2.

browser_format(Control, Args) :-
    setup_call_cleanup(
        open(string(""), write, Stream),
        ( format(Stream, Control, Args), get_stream_info(Stream, name, Text) ),
        close(Stream)
    ),
    self(Pid),
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    store_get(Store, web_prolog_ptcp, Session),
    shelf_get(Session, 3, Target),
    send(Target, browser_output(Pid, Text)),
    receive_ptcp({ '$browser_ack' -> true }).

:- tool(toplevel_spawn/1, toplevel_spawn_/2).
:- tool(toplevel_spawn/2, toplevel_spawn_/3).
:- tool(toplevel_call_synch/3, toplevel_call_synch_/4).
:- tool(toplevel_call_synch/4, toplevel_call_synch_/5).
:- tool(toplevel_next_synch/2, toplevel_next_synch_/3).
:- tool(toplevel_next_synch/3, toplevel_next_synch_/4).

toplevel_spawn_(Pid, Module) :-
    toplevel_spawn_(Pid, [], Module).

toplevel_spawn_(Pid, Options, Module) :-
    spawn_toplevel(Pid, Options, local, Module).

toplevel_spawn_browser(Pid, Options) :-
    spawn_toplevel(Pid, Options, browser, toplevel_actors).

spawn_toplevel(Pid, Options, Kind, Module) :-
    require_creation_list(Options, toplevel_spawn/2),
    self(Self),
    split_spawn_options(Options, unset, unset, SessionOption, TargetOption, Remaining),
    ( SessionOption == unset -> Session = false ; Session = SessionOption ),
    ( TargetOption == unset -> Target = Self ; TargetOption = target(Target) ),
    spawn_limit(time_limit, Remaining, Time, AfterTime),
    spawn_limit(idle_limit, AfterTime, Idle, SpawnOptions),
    ( memberchk(node(Uri), SpawnOptions),
      node_destination(Uri, toplevel_spawn/2, remote(_)) ->
        ( Target == Self -> true
        ; throw(error(domain_error(remote_toplevel_target, Target), toplevel_spawn/2)) ),
        remote_limit_options(Time, Idle, Limits),
        spawn('$peer_toplevel'([session(Session)|Limits]), Pid, SpawnOptions)@Module
    ; spawn(toplevel_actors:ptcp(Target, Session, Kind, limits(Time, Idle)),
            Pid, [src_text("")|SpawnOptions])@Module ).

remote_limit_options(Time, Idle, Options) :-
    ( Time == infinite -> Options = Rest ; Options = [time_limit(Time)|Rest] ),
    ( Idle == infinite -> Rest = [] ; Rest = [idle_limit(Idle)] ).

spawn_limit(Name, Options, Limit, Rest) :-
    collect_spawn_limit(Options, Name, unset, Selected, Rest),
    ( Selected == unset -> Limit = infinite ; Limit = Selected ).

collect_spawn_limit([], _, Selected, Selected, []).
collect_spawn_limit([Option|Options], Name, Previous, Selected, Rest) :-
    ( functor(Option, Name, 1) ->
        arg(1, Option, Value),
        ( Value == infinite ; number(Value), Value > 0, Value < 1.0Inf ),
        !,
        first_creation_option(Previous, Value, Next),
        collect_spawn_limit(Options, Name, Next, Selected, Rest)
    ; functor(Option, Name, 1) ->
        throw(error(domain_error(toplevel_limit, Name), toplevel_spawn/2))
    ; Rest = [Option|More],
      collect_spawn_limit(Options, Name, Previous, Selected, More) ).

split_spawn_options([], Session, Target, Session, Target, []).
split_spawn_options([Option|Options], Session0, Target0, Session, Target, Rest) :-
    require_creation_value(Option, toplevel_spawn/2),
    ( Option = session(Value) ->
        validate_creation_boolean(Value, toplevel_spawn/2),
        first_creation_option(Session0, Value, Selected),
        split_spawn_options(Options, Selected, Target0, Session, Target, Rest)
    ; Option = target(Value) ->
        require_creation_value(Value, toplevel_spawn/2),
        first_creation_option(Target0, target(Value), Selected),
        split_spawn_options(Options, Session0, Selected, Session, Target, Rest)
    ; Rest = [Option|More],
      split_spawn_options(Options, Session0, Target0, Session, Target, More) ).

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal, Options) :-
    call_options(Options, Goal, _, _, _, _, _),
    check_remote_options(Pid, Options, toplevel_call/3),
    send(Pid, '$call'(Goal, Options)).

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    next_options(Options, all, main, _, _),
    check_remote_options(Pid, Options, toplevel_next/2),
    send(Pid, '$next'(Options)).

check_remote_options(Target, Options, Caller) :-
    actor_address(Target, Caller, Pid),
    ( nonvar(Pid), Pid = '@'(_, _), (memberchk(target(_), Options) ; memberchk(io_target(_), Options)) ->
        throw(error(domain_error(remote_toplevel_options, Options), Caller))
    ; true ).

toplevel_call_synch_(Pid, Goal, Answer, Module) :-
    toplevel_call_synch_(Pid, Goal, Answer, [], Module).

toplevel_call_synch_(Pid, Goal, Answer, Options, Module) :-
    synchronous_options(call, Options, Request, Query, Wait, Callback),
    synchronous_request(Pid, '$call'(Goal, Query),
                        Request, Answer, Wait, Callback, Module).

toplevel_next_synch_(Pid, Answer, Module) :-
    toplevel_next_synch_(Pid, Answer, [], Module).

toplevel_next_synch_(Pid, Answer, Options, Module) :-
    synchronous_options(next, Options, Request, Query, Wait, Callback),
    synchronous_request(Pid, '$next'(Query),
                        Request, Answer, Wait, Callback, Module).

synchronous_options(Kind, Options, Request, ['$request_ref'(Request),target(Self)|Query], Wait, Callback) :-
    self(Self),
    sync_option_context(Kind, Caller, _),
    ( var(Options) -> throw(error(instantiation_error, Caller))
    ; is_list(Options) -> split_sync_options(Options, Kind, Self, Query, Wait)
    ; throw(error(type_error(list, Options), Caller))
    ),
    option_value(on_timeout, Wait, true, Callback),
    fresh_reference(Request).

sync_option_context(call, toplevel_call_synch/4, toplevel_call_synch_option).
sync_option_context(next, toplevel_next_synch/3, toplevel_next_synch_option).

split_sync_options([], _, _, [], []).
split_sync_options([Option|Options], Kind, Self, Query, Wait) :-
    sync_option_context(Kind, Caller, Domain),
    ( var(Option) -> throw(error(instantiation_error, Caller))
    ; Option = target(Target) ->
        ( var(Target) -> throw(error(instantiation_error, Caller))
        ; Target == Self -> true
        ; throw(error(domain_error(synchronous_toplevel_target, Target), Caller))
        ),
        Query = Qs, Wait = Ws
    ; Option = timeout(Seconds) ->
        ( var(Seconds) -> throw(error(instantiation_error, Caller))
        ; number(Seconds) -> true
        ; throw(error(type_error(number, Seconds), Caller))
        ),
        Query = Qs, Wait = [Option|Ws]
    ; Option = on_timeout(Callback) ->
        ( var(Callback) -> throw(error(instantiation_error, Caller))
        ; callable(Callback) -> true
        ; throw(error(type_error(callable, Callback), Caller))
        ),
        Query = Qs, Wait = [Option|Ws]
    ; valid_option(Option, Kind) ->
        Query = [Option|Qs], Wait = Ws
    ;
        throw(error(domain_error(Domain, Option), Caller))
    ),
    split_sync_options(Options, Kind, Self, Qs, Ws).

synchronous_request(Target, Command, Request, Answer, Options, Callback, Module) :-
    actor_address(Target, monitor/2, Pid),
    setup_call_cleanup(
        monitor(Pid, Monitor),
        ( send(Pid, Command),
          sync_deadline(Options, Deadline),
          once(synchronous_receive(Pid, Monitor, Request, Answer, Deadline, Callback, Module))
        ),
        demonitor(Monitor, [flush])
    ).

sync_deadline(Options, Deadline) :-
    ( memberchk(timeout(Seconds), Options) ->
        ( Seconds > 0 -> elapsed(Now), End is Now + Seconds, Deadline = until(End)
        ; Deadline = poll )
    ; Deadline = infinite ).

% Only discard obsolete private replies from this toplevel. Keep ordinary
% answers and other messages in the caller's mailbox.
synchronous_receive(Pid, Monitor, Request, Answer, Deadline, Callback, Module) :-
    Clauses = {
        '$toplevel_reply'(Ref, Reply) if answer_pid(Reply, Pid) ->
            ( Ref == Request -> synchronous_result(Reply, Answer)
            ; synchronous_receive(Pid, Monitor, Request, Answer, Deadline, Callback, Module) )
    ;
        down(_, Monitor, Reason) -> throw(toplevel_down(Reason))
    },
    ( Deadline == infinite -> receive_ptcp(Clauses)
    ; Deadline == poll ->
        receive(Clauses, [timeout(0), on_timeout(sync_timeout(Callback, Module))])
    ; Deadline = until(End),
      elapsed(Now), Remaining is End - Now,
      ( Remaining > 0 ->
          receive(Clauses, [timeout(Remaining), on_timeout(sync_timeout(Callback, Module))])
      ; sync_timeout(Callback, Module) )
    ).

sync_timeout(Callback, Module) :-
    prepare_actor_goal(Callback, Prepared),
    call(Prepared)@Module.

answer_pid(success(Pid, _, _), Expected) :- Pid == Expected.
answer_pid(failure(Pid), Expected) :- Pid == Expected.
answer_pid(error(Pid, _), Expected) :- Pid == Expected.
answer_pid('$sync_unsupported'(Pid), Expected) :- Pid == Expected.

synchronous_result('$sync_unsupported'(_@Node), _) :- !,
    throw(error(permission_error(use, toplevel_correlation, Node), toplevel_actors)).
synchronous_result(Reply, Reply).

toplevel_stop(Pid) :-
    send(Pid, '$stop').

% The HTTP bridge waits for this acknowledgement before allowing a new call.
toplevel_stop(Pid, Target) :-
    send(Pid, '$stop'(Target)).

toplevel_abort(Target) :-
    actor_address(Target, toplevel_abort/1, Pid),
    ( nonvar(Pid), Pid = '@'(_, _) -> send(Pid, '$abort')
    ; post_actor_event(Pid, interrupt_ptcp) ).

toplevel_halt(Pid) :-
    exit(Pid, true).

% Wait on a private monitor so any spawn-time down remains for the caller.
toplevel_halt(Pid, true) :-
    setup_call_cleanup(
        monitor(Pid, Ref),
        ( toplevel_halt(Pid),
          receive_ptcp({ down(_, Ref, _) -> true })
        ),
        demonitor(Ref, [flush])
    ).

ptcp(DefaultTarget, Session, Kind, Limits) :-
    self(Pid),
    actor_module(Pid, Module),
    ( Kind == browser -> set_browser_prompt_correlation ; true ),
    shelf_create(control(recovering, 0, DefaultTarget, Limits), Control),
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    store_set(Store, web_prolog_ptcp, Control),
    catch(ptcp_running(Pid, Module, DefaultTarget, Session, Control), '$ptcp_idle_limit', true).

% As in SWI, reinstall the catch before acknowledging an abort and
% restarting. Events received during recovery add another acknowledgement.
ptcp_running(Pid, Module, DefaultTarget, Session, Control) :-
    catch(
        ( clear_io_target,
          drain_abort_acks(Pid, Control, Count),
          ( Count > 0, Session == false -> true
          ; state_1(Pid, Module, DefaultTarget, Session, Control)
          )
        ),
        '$abort_goal',
        ptcp_running(Pid, Module, DefaultTarget, Session, Control)
    ).

interrupt_ptcp :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    ( store_get(Store, web_prolog_ptcp, Control) ->
        shelf_inc(Control, 2),
        ( shelf_test_and_set(Control, 1, ready, recovering) ->
            throw('$abort_goal')
        ;
            true
        )
    ;
        true
    ).

drain_abort_acks(Pid, Control, Count) :-
    ( events_defer ->
        drain_abort_acks_(Pid, Control, Count),
        events_nodefer
    ;
        drain_abort_acks_(Pid, Control, Count)
    ).

drain_abort_acks_(Pid, Control, Count) :-
    shelf_get(Control, 2, Count),
    shelf_set(Control, 2, 0),
    shelf_get(Control, 3, Target),
    send_abort_acks(Count, Target, Pid),
    shelf_set(Control, 1, ready).

send_abort_acks(0, _, _) :- !.
send_abort_acks(Count, Target, Pid) :-
    send(Target, abort(Pid)),
    Left is Count - 1,
    send_abort_acks(Left, Target, Pid).

state_1(Pid, Module, DefaultTarget, Session, Control) :-
    receive_idle_ptcp({
        '$call'(Goal, Options) ->
            discard_deferred(stale_command),
            run_call(Pid, Module, DefaultTarget, Goal, Options, Control)
    }, Control),
    ( Session == true -> state_1(Pid, Module, DefaultTarget, Session, Control)
    ; true
    ).

% A posted throw may wait for a native queue read to return. Bound PTCP
% mailbox waits so a suspended or idle toplevel regularly services events.
receive_ptcp(Clauses) :-
    receive(Clauses, [timeout(0.05), on_timeout(receive_ptcp(Clauses))]).

receive_idle_ptcp(Clauses, Control) :-
    shelf_get(Control, 4, limits(_, Idle)),
    ( Idle == infinite -> receive_ptcp(Clauses)
    ; elapsed(Now), Deadline is Now + Idle,
      receive_until(Clauses, Deadline)
    ).

receive_until(Clauses, Deadline) :-
    elapsed(Now),
    ( Now >= Deadline -> throw('$ptcp_idle_limit')
    ; Wait is min(0.05, Deadline - Now),
      receive(Clauses, [timeout(Wait), on_timeout(receive_until(Clauses, Deadline))])
    ).

stale_command('$next'(_)).
stale_command('$stop').
stale_command('$stop'(_)).
stale_command('$input'(_, _)).
stale_command('$input'(_, _, _)).
stale_command('$browser_ack').

run_call(Pid, Module, DefaultTarget, Goal0, RequestOptions, Control) :-
    request_options(RequestOptions, Request, Options),
    plain_goal(Goal0, Goal),
    call_options(Options, Goal, Template0, Offset, Limit, Once, TargetOption),
    plain_goal(Template0, Template),
    ( TargetOption = target(Target) -> true ; Target = DefaultTarget ),
    shelf_set(Control, 3, Target),
    ( configured_io_target(DefaultIo) -> true ; DefaultIo = Target ),
    option_value(io_target, Options, DefaultIo, IoTarget),
    set_io_target(IoTarget),
    new_solution_buffer(Buffer),
    shelf_create(page(Target, Limit, Offset, Buffer, Request), Page),
    setup_call_cleanup(
        set_timed_mailbox(Mailbox),
        catch(run_answers(Pid, Module, Goal, Template, Once, Page, Control),
              Error, query_error(Pid, Page, Once, Error, Control)),
        ( clear_timed_mailbox(Mailbox),
          ( current_module(isotope_rpc) -> call(clear_promises)@isotope_rpc ; true ) )
    ),
    clear_io_target.

% Abort posts an engine event even when the query has no time limit.
% A bounded native mailbox wait lets the engine service that event.
set_timed_mailbox(Mailbox) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Mailbox),
    store_set(Mailbox, timed_mailbox, true).

clear_timed_mailbox(Store) :-
    store_delete(Store, timed_mailbox).

% Like SWI's state 2/3, wait for next on the same Prolog stack. ECLiPSe's
% own cleanup implementation uses get_cut/1 to detect residual alternatives.
% The buffer retains the partial page, and a shelf retains next options.
run_answers(Pid, Module, Goal, Template, Once, Page, Control) :-
    ( configured_io_target(_) -> prepare_actor_goal(Goal, Prepared)
    ; portable_goal(Goal, Prepared) ),
    shelf_get(Control, 4, limits(Time, _)),
    ( call_with_budget(Prepared, Module, Time, Deterministic),
      add_solution(Page, Template, Full),
      ( Deterministic == true ->
          send_final_page(Pid, Page)
      ; Full == true ->
          ( Once == true ->
              send_final_page(Pid, Page)
          ;
              send_page(Pid, Page, true),
              await_next(Page, Control, Action),
              Action == stop
          )
      ;
          fail
      )
    ;
        send_final_page(Pid, Page)
    ),
    !.

call_with_budget(Goal, Module, infinite, Deterministic) :- !,
    call_with_choicepoint(Goal, Module, Deterministic).
call_with_budget(Goal, Module, Time, Deterministic) :-
    timeout(call_with_choicepoint(Goal, Module, Deterministic), Time,
            throw(error(resource_error(time), toplevel_call/3))).

call_with_choicepoint(Goal, Module, Deterministic) :-
    sepia_kernel:get_cut(Before),
    call(Goal)@Module,
    sepia_kernel:get_cut(After),
    ( Before == After -> Deterministic = true ; Deterministic = false ).

add_solution(Page, Template, Full) :-
    shelf_get(Page, 3, Offset),
    ( Offset > 0 ->
        Left is Offset - 1,
        shelf_set(Page, 3, Left),
        Full = false
    ;
        shelf_get(Page, 4, Buffer),
        shelf_get(Page, 2, Limit),
        buffer_solution(Buffer, Template, Limit, Full)
    ).

send_final_page(Pid, Page) :-
    shelf_get(Page, 4, Buffer),
    solution_count(Buffer, Count),
    ( Count == 0 ->
        send_answer(Page, failure(Pid))
    ;
        send_page(Pid, Page, false)
    ).

send_page(Pid, Page, More) :-
    shelf_get(Page, 4, Buffer),
    buffered_solutions(Buffer, Answers),
    send_answer(Page, success(Pid, Answers, More)).

send_answer(Page, Answer) :-
    shelf_get(Page, 1, Target),
    shelf_get(Page, 5, Request),
    ( Request == none -> Message = Answer
    ; Message = '$toplevel_reply'(Request, Answer) ),
    send(Target, Message).

await_next(Page, Control, Action) :-
    receive_idle_ptcp({
        '$next'(Options) -> prepare_next(Options, Page, Control), Action = next
    ;
        '$stop' -> Action = stop
    ;
        '$stop'(Target) ->
            self(Pid),
            send(Target, stop(Pid)),
            Action = stop
    }, Control).

prepare_next(RequestOptions, Page, Control) :-
    request_options(RequestOptions, Request, Options),
    shelf_get(Page, 1, OldTarget),
    shelf_get(Page, 2, OldLimit),
    next_options(Options, OldLimit, OldTarget, Limit, Target),
    shelf_set(Control, 3, Target),
    shelf_set(Page, 1, Target),
    shelf_set(Page, 2, Limit),
    shelf_set(Page, 5, Request),
    shelf_get(Page, 4, Buffer),
    clear_solution_buffer(Buffer).

query_error(_, _, _, '$abort_goal', _) :- !, throw('$abort_goal').
query_error(_, _, _, '$ptcp_idle_limit', _) :- !, throw('$ptcp_idle_limit').
query_error(Pid, Page, Once, Error, Control) :-
    shelf_get(Page, 4, Buffer),
    solution_count(Buffer, Count),
    ( Count == 0 ->
        send_error(Pid, Page, Error)
    ; Once == true ->
        send_page(Pid, Page, false)
    ;
        send_page(Pid, Page, true),
        await_next(Page, Control, Action),
        ( Action == next -> send_error(Pid, Page, Error) ; true )
    ).

send_error(Pid, Page, Error) :-
    send_answer(Page, error(Pid, Error)).

request_options([Option|Options], Request, Options) :-
    nonvar(Option), Option = '$request_ref'(Request), integer(Request), !.
request_options(Options, none, Options).

plain_goal(Goal0, Goal) :-
    ( nonvar(Goal0), Goal0 = Module:Plain, atom(Module) -> Goal = Plain
    ; Goal = Goal0
    ).

call_options(Options, Goal, Template, Offset, Limit, Once, Target) :-
    validate_options(Options, call),
    option_value(template, Options, Goal, Template),
    option_value(offset, Options, 0, Offset),
    option_value(limit, Options, all, Limit),
    option_value(once, Options, false, Once),
    ( memberchk(target(Pid), Options) -> Target = target(Pid) ; Target = default ).

next_options(Options, OldLimit, OldTarget, Limit, Target) :-
    validate_options(Options, next),
    option_value(limit, Options, OldLimit, Limit),
    option_value(target, Options, OldTarget, Target).

option_value(Name, Options, Default, Value) :-
    Option =.. [Name, Selected],
    ( memberchk(Option, Options) -> Value = Selected ; Value = Default ).

validate_options(Options, Command) :-
    ( is_list(Options) -> validate_option_list(Options, Command)
    ; throw(error(type_error(list, Options), Command))
    ).

validate_option_list([], _).
validate_option_list([Option|Options], Command) :-
    ( nonvar(Option), valid_option(Option, Command) -> true
    ; throw(error(domain_error(toplevel_option, Option), Command))
    ),
    validate_option_list(Options, Command).

valid_option(limit(N), _) :- integer(N), N > 0.
valid_option(target(Pid), _) :- ground(Pid).
valid_option(offset(N), call) :- integer(N), N >= 0.
valid_option(template(_), call).
valid_option(io_target(Pid), call) :- ground(Pid).
valid_option(once(Value), call) :- boolean_option(Value).

boolean_option(Value) :-
    ( ( Value == true ; Value == false ) -> true
    ; throw(error(domain_error(boolean, Value), toplevel_actors))
    ).
