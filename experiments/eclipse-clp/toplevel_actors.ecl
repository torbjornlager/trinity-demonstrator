:- module(toplevel_actors).
:- use_module(actors).
:- use_module(solution_buffer).
:- lib(prolog_extras).
:- lib(format).

:- export toplevel_spawn/1, toplevel_spawn/2.
:- export toplevel_call/2, toplevel_call/3.
:- export toplevel_next/1, toplevel_next/2.
:- export toplevel_stop/1, toplevel_stop/2, toplevel_abort/1.
:- export ptcp/3.  % Runtime entry point, called from the private actor module.
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

toplevel_spawn(Pid) :-
    toplevel_spawn(Pid, []).

toplevel_spawn(Pid, Options) :-
    spawn_toplevel(Pid, Options, local).

toplevel_spawn_browser(Pid, Options) :-
    spawn_toplevel(Pid, Options, browser).

spawn_toplevel(Pid, Options, Kind) :-
    ( is_list(Options) -> true
    ; throw(error(type_error(list, Options), toplevel_spawn/2))
    ),
    self(Self),
    split_spawn_options(Options, false, Self, Session, Target, SpawnOptions),
    ( memberchk(src_text(_), SpawnOptions) -> PrivateOptions = SpawnOptions
    ; PrivateOptions = [src_text("")|SpawnOptions]
    ),
    spawn(toplevel_actors:ptcp(Target, Session, Kind), Pid, PrivateOptions).

split_spawn_options([], Session, Target, Session, Target, []).
split_spawn_options([Option|Options], Session0, Target0, Session, Target, Rest) :-
    ( nonvar(Option), Option = session(Value) ->
        boolean_option(Value),
        split_spawn_options(Options, Value, Target0, Session, Target, Rest)
    ; nonvar(Option), Option = target(Value) ->
        split_spawn_options(Options, Session0, Value, Session, Target, Rest)
    ;
        Rest = [Option|More],
        split_spawn_options(Options, Session0, Target0, Session, Target, More)
    ).

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal, Options) :-
    call_options(Options, Goal, _, _, _, _, _),
    send(Pid, '$call'(Goal, Options)).

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    next_options(Options, all, main, _, _),
    send(Pid, '$next'(Options)).

toplevel_stop(Pid) :-
    send(Pid, '$stop').

% The HTTP bridge waits for this acknowledgement before allowing a new call.
toplevel_stop(Pid, Target) :-
    send(Pid, '$stop'(Target)).

toplevel_abort(Pid) :-
    post_actor_event(Pid, interrupt_ptcp).

ptcp(DefaultTarget, Session, _Kind) :-
    self(Pid),
    actor_module(Pid, Module),
    shelf_create(control(recovering, 0, DefaultTarget), Control),
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    store_set(Store, web_prolog_ptcp, Control),
    ptcp_running(Pid, Module, DefaultTarget, Session, Control).

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
    receive_ptcp({
        '$call'(Goal, Options) ->
            discard_deferred(stale_command),
            run_call(Pid, Module, DefaultTarget, Goal, Options, Control)
    }),
    ( Session == true -> state_1(Pid, Module, DefaultTarget, Session, Control)
    ; true
    ).

% A posted throw may wait for a native queue read to return. Bound PTCP
% mailbox waits so a suspended or idle toplevel regularly services events.
receive_ptcp(Clauses) :-
    receive(Clauses, [timeout(0.05), on_timeout(receive_ptcp(Clauses))]).

stale_command('$next'(_)).
stale_command('$stop').
stale_command('$stop'(_)).
stale_command('$input'(_, _)).
stale_command('$input'(_, _, _)).
stale_command('$browser_ack').

run_call(Pid, Module, DefaultTarget, Goal0, Options, Control) :-
    plain_goal(Goal0, Goal),
    call_options(Options, Goal, Template0, Offset, Limit, Once, TargetOption),
    plain_goal(Template0, Template),
    ( TargetOption = target(Target) -> true ; Target = DefaultTarget ),
    shelf_set(Control, 3, Target),
    option_value(io_target, Options, Target, IoTarget),
    set_io_target(IoTarget),
    new_solution_buffer(Buffer),
    shelf_create(page(Target, Limit, Offset, Buffer), Page),
    setup_call_cleanup(
        true,
        catch(run_answers(Pid, Module, Goal, Template, Once, Page, Control),
              Error, query_error(Pid, Page, Once, Error, Control)),
        ( current_module(isotope_rpc) -> call(clear_promises)@isotope_rpc ; true )
    ),
    clear_io_target.

% Like SWI's state 2/3, wait for next on the same Prolog stack. ECLiPSe's
% own cleanup implementation uses get_cut/1 to detect residual alternatives.
% The buffer retains the partial page, and a shelf retains next options.
run_answers(Pid, Module, Goal, Template, Once, Page, Control) :-
    ( sepia_kernel:get_cut(Before),
      call(Goal)@Module,
      sepia_kernel:get_cut(After),
      add_solution(Page, Template, Full),
      ( Before == After ->
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
        shelf_get(Page, 1, Target),
        send(Target, failure(Pid))
    ;
        send_page(Pid, Page, false)
    ).

send_page(Pid, Page, More) :-
    shelf_get(Page, 1, Target),
    shelf_get(Page, 4, Buffer),
    buffered_solutions(Buffer, Answers),
    send(Target, success(Pid, Answers, More)).

await_next(Page, Control, Action) :-
    receive_ptcp({
        '$next'(Options) -> prepare_next(Options, Page, Control), Action = next
    ;
        '$stop' -> Action = stop
    ;
        '$stop'(Target) ->
            self(Pid),
            send(Target, stop(Pid)),
            Action = stop
    }).

prepare_next(Options, Page, Control) :-
    shelf_get(Page, 1, OldTarget),
    shelf_get(Page, 2, OldLimit),
    next_options(Options, OldLimit, OldTarget, Limit, Target),
    shelf_set(Control, 3, Target),
    shelf_set(Page, 1, Target),
    shelf_set(Page, 2, Limit),
    shelf_get(Page, 4, Buffer),
    clear_solution_buffer(Buffer).

query_error(_, _, _, '$abort_goal', _) :- !, throw('$abort_goal').
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
    shelf_get(Page, 1, Target),
    send(Target, error(Pid, Error)).

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
