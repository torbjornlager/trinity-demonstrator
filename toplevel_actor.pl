:- module(toplevel_actor,
   [ toplevel_spawn/1,
     toplevel_spawn/2,
     toplevel_call/2,
     toplevel_call/3,
     toplevel_next/1,
     toplevel_next/2,
     toplevel_halt/2,
     toplevel_stop/1,
     toplevel_abort/1
   ]).

/** <module> Toplevel Actor

A toplevel actor is the execution engine behind both:

  - stateless `/call` queries (ephemeral toplevel), and
  - semi-stateful ISOTOPE sessions (long-lived toplevel).

The actor speaks a small command protocol over mailbox messages:

  - `'$call'(Goal, Options)` to start a query,
  - `'$next'(Options)` to fetch additional solutions,
  - `'$stop'` to stop paging,
  - `'$halt'(From)` to halt an idle toplevel session.

Replies are sent as `success/failure/error` terms enriched with `Pid`.
*/

:- use_module(actor, [
    spawn/3,
    self/1,
    send/2,
    receive/1,
    exit/2,
    register/2,
    actor_module/2,
    with_io_target/2,
    localhost_node/1,
    remote_request_spawn/3,
    remote_send_command/2,
    register_remote_proxy/2,
    op(200, xfx, @)
]).

:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(public_goal_guard, [rewrite_goal_if_needed/3]).
:- use_module(source_loader, [rewrite_source_options/3]).
:- use_module(remote_protocol, [
    term_to_wire_atom/2,
    goal_template_to_wire_atoms/4,
    ws_json_down_reason/2,
    ws_json_is_io_output/1,
    ws_json_to_actor_event/3
]).

:- meta_predicate
    toplevel_spawn(-, :),
    toplevel_call(+, :),
    toplevel_call(+, :, +).


%!  toplevel_spawn(-Pid) is det.
%!  toplevel_spawn(-Pid, +Options) is det.
%
%   Spawn a new toplevel.  Options:
%
%     - session(+Bool)
%       Determines if the toplevel is a session that can accept
%       new goals after the first goal has run to completion.
%       Defaults to false.
%     - target(+Target)
%       Send messages to Target. Default is the process that
%       called toplevel_spawn/1-2.

toplevel_spawn(Pid) :-
    toplevel_spawn(Pid, []).

%  Remote node case: open the WebSocket here (blocking), get the remote Pid,
%  spawn a local proxy actor, and return RemotePid@NodeURL as the caller's Pid.
%  This intercepts before spawn/3 can throw not_implemented(node(_)).
toplevel_spawn(RemotePid@NodeURL, Options0) :-
    strip_module(Options0, SourceModule, Options),
    option(node(NodeURL), Options),
    \+ localhost_node(NodeURL),
    !,
    self(Self),
    option(target(Target), Options, Self),
    remote_toplevel_spawn_options(Options, SourceModule, RemoteOptions),
    term_to_wire_atom(RemoteOptions, RemoteOptionsAtom),
    remote_request_spawn(NodeURL, json{
        command: toplevel_spawn,
        options: RemoteOptionsAtom
    }, RemotePid),
    CompoundPid = RemotePid@NodeURL,
    spawn(remote_toplevel_proxy(NodeURL, RemotePid, Target),
          LocalPid, [link(false)]),
    register_remote_proxy(CompoundPid, LocalPid),
    maybe_register_toplevel_name(Options, CompoundPid),
    (   option(monitor(true), Options)
    ->  assertz(actor:monitor(Self, CompoundPid, CompoundPid))
    ;   true
    ).

toplevel_spawn(Pid, Options0) :-
    strip_module(Options0, SourceModule, Options),
    self(Self),
    option(session(Session), Options, false),
    option(target(Target), Options, Self),
    exclude(is_toplevel_spawn_opt, Options, SpawnOptions),
    spawn(ptcp(Pid, Target, Session), Pid,
          [source_module(SourceModule)|SpawnOptions]),
    maybe_register_toplevel_name(Options, Pid).

remote_toplevel_spawn_options(Options0, SourceModule, RemoteOptions) :-
    rewrite_source_options(Options0, SourceModule, Options),
    exclude(remote_toplevel_local_option, Options, RemoteOptions).

is_toplevel_spawn_opt(name(_)).

maybe_register_toplevel_name(Options, Pid) :-
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).

remote_toplevel_local_option(node(_)).
remote_toplevel_local_option(link(_)).
remote_toplevel_local_option(monitor(_)).
remote_toplevel_local_option(target(_)).
remote_toplevel_local_option(source_module(_)).
remote_toplevel_local_option(name(_)).

%!  ptcp(+Pid, +Target, +Session) is det.
%
%   Main process loop entry point for one toplevel actor.
%
%   The loop catches `'$abort_goal'` so external abort requests do not kill the
%   actor process itself; only the currently running goal is interrupted.

ptcp(Pid, Target, Session) :-
    catch(state_1(Pid, Target, Session),
          '$abort_goal',
          ptcp(Pid, Target, Session)).

%!  state_1(+Pid, +DefaultTarget, +SessionMode) is det.
%
%   Idle/dispatch state:
%
%     - wait for `'$call'`,
%     - run query and emit first answer,
%     - if more answers exist, move to state_3/2 (paging state),
%     - if `session(true)`, return to idle for further calls.
%
%   Monitor notifications from child actors remain in the toplevel mailbox.
%   This lets shell tools such as `receive/1` and `flush/0` inspect them.

state_1(Pid, Target0, Session) :-
    Control = control(continue),
    receive({
        '$call'(Goal, Options) ->
            option(template(Template0), Options, Goal),
            strip_module(Template0, _, Template),
            option(offset(Offset), Options, 0),
            option(limit(Limit0), Options, 10 000 000 000),
            option(once(Once), Options, false),
            option(target(Target1), Options, Target0),
            Limit = count(Limit0),
            Target = target(Target1),
            state_2(Goal, Template, Offset, Limit, Once, Target, Pid, Answer),
            arg(1, Target, Out),
            send(Out, Answer),
            (   arg(3, Answer, true)
            ->  state_3(Limit, Target)
            ;   true
            );
        '$halt'(From) ->
            send(From, reply(true)),
            nb_setarg(1, Control, halt)
        }),
    (   arg(1, Control, halt)
    ->  true
    ;   Session == false
    ->  true
    ;   state_1(Pid, Target0, Session)
    ).

%!  state_2(+Goal, +Template, +Offset, +Limit, +Once, +TargetBox, +Pid, -Answer) is det.
%
%   Execute one query slice in the actor module and package answer with pid.

state_2(Goal0, Template, Offset, Limit, Once, TargetBox, Pid, Answer) :-
    strip_module(Goal0, _, PlainGoal),
    actor_module(Pid, Module),
    rewrite_goal_if_needed(Module, PlainGoal, RewrittenGoal),
    arg(1, TargetBox, Target),
    with_io_target(Target,
        (   Once == true
        ->  once(answer(Module:RewrittenGoal, Template, Offset, Limit, Answer0))
        ;   answer(Module:RewrittenGoal, Template, Offset, Limit, Answer0)
        )),
    apply_once_answer(Once, Answer0, Answer1),
    add_pid(Answer1, Pid, Answer).

%!  state_3(+LimitBox, +TargetBox) is det.
%
%   Paging state after a `success(..., true)` answer.
%
%   `LimitBox` and `TargetBox` are mutable one-argument compounds used as
%   in-place cells (`nb_setarg/3`) so subsequent `'$next'` commands may update
%   limit/target without rebuilding all call state.

state_3(Limit, Target) :-
    receive({
        '$next'(Options2) ->
            (   option(limit(NewLimit), Options2)
            ->  nb_setarg(1, Limit, NewLimit)
            ;   true
            ),
            (   option(target(NewTarget), Options2)
            ->  nb_setarg(1, Target, NewTarget)
            ;   true
            ),
            fail ;
        '$stop' -> true
    }).

%!  answer(+Goal, +Template, +Offset, +Limit, -Answer) is det.
%
%   Run a goal with `findnsols/4`-based slicing and map execution outcome to
%   `success/failure/error`.
%
%   - nondeterministic remainder -> `success(Slice, true)`
%   - deterministic completion   -> `success(Slice, false)`
%   - empty slice                -> `failure`
%   - exception                  -> `error(Exception)`

answer(Goal, Template, Offset, Limit, Answer) :-
    catch(
       call_cleanup(slice(Goal, Template, Offset, Limit, Slice),
                    Det = true),
           Error, true),
    (   nonvar(Error),
        Error == '$abort_goal'
    ->  throw('$abort_goal')
    ;   Slice == []
    ->  Answer = failure
    ;   nonvar(Error)
    ->  Answer = error(Error)
    ;   var(Det)
    ->  Answer = success(Slice, true)
    ;   Det == true
    ->  Answer = success(Slice, false)
    ).

apply_once_answer(true, success(Slice, _), success(Slice, false)) :-
    !.
apply_once_answer(_, Answer, Answer).

%!  slice(+Goal, +Template, +Offset, +Limit, -Slice) is det.
%
%   Compute one page of solutions from Goal.

slice(Goal, Template, Offset, Limit, Slice) :-
    findnsols(Limit, Template, offset(Offset, Goal), Slice).

%!  add_pid(+Answer0, +Pid, -Answer) is det.
%
%   Add actor pid to outward-facing answer terms.

add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).
add_pid(failure, Pid, failure(Pid)).
add_pid(error(Term), Pid, error(Pid, Term)).


%!  toplevel_call(+Pid, :Goal) is det.
%!  toplevel_call(+Pid, :Goal, +Options) is det.

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal, Options) :-
    copy_term(Goal-Options, GoalCopy-OptionsCopy),
    send(Pid, '$call'(GoalCopy, OptionsCopy)).


%!  toplevel_next(+Pid) is det.
%!  toplevel_next(+Pid, +Options) is det.

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    copy_term(Options, OptionsCopy),
    send(Pid, '$next'(OptionsCopy)).


%!  toplevel_halt(+Pid, -Reply) is det.

toplevel_halt(Pid, Reply) :-
    self(Self),
    send(Pid, '$halt'(Self)),
    receive({
        reply(Reply) -> true
    }).

%!  toplevel_stop(+Pid) is det.

toplevel_stop(Pid) :-
    send(Pid, '$stop').


%!  toplevel_abort(+Pid) is det.
%
%   Abort the currently running goal in toplevel actor Pid using thread_signal/2.

toplevel_abort(Pid) :-
    (   actor:resolve_thread(Pid, ThreadId)
    ->  catch(thread_signal(ThreadId, throw('$abort_goal')),
              error(existence_error(_,_), _),
              true)
    ;   true
    ).


                /*******************************
                *      REMOTE TOPLEVEL         *
                *******************************/

%!  remote_toplevel_proxy(+NodeURL, +RemotePid, +Target) is det.
%
%   Goal for a local proxy actor that represents a remote toplevel.
%
%   The remote toplevel already exists (RemotePid is assigned by the remote
%   node). Incoming WS events are routed to this proxy by actor.pl's shared
%   connection manager as '$ws_remote_event'(Dict) messages.
%
%   The proxy receives local '$call'/'$next'/'$stop' requests, translates
%   them to WS commands on the shared connection, and forwards remote events
%   to Target.

remote_toplevel_proxy(NodeURL, RemotePid, Target) :-
    CompoundPid = RemotePid@NodeURL,
    ExitReason = reason(done),
    LimitBox = limit(10 000 000 000),
    catch(
        remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox),
        _,
        true
    ),
    arg(1, ExitReason, DownReason),
    retractall(actor:remote_pid_proxy(CompoundPid, _)),
    forall(
        retract(actor:monitor(Other, CompoundPid, Ref)),
        send(Other, down(Ref, CompoundPid, DownReason))
    ).

%!  remote_proxy_loop(+NodeURL, +RemotePid, +CompoundPid, +Target,
%!                    +ExitReason, +LimitBox) is det.
%
%   Receive local toplevel requests and routed remote WS events.
remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox) :-
    receive({
        '$call'(Goal, Options) ->
            option(template(Template0), Options, Goal),
            goal_template_to_wire_atoms(Goal, Template0, GoalAtom, TemplateAtom),
            option(limit(Limit), Options, 10 000 000 000),
            nb_setarg(1, LimitBox, Limit),
            option(offset(Offset), Options, 0),
            option(once(Once), Options, false),
            (   catch(remote_send_command(NodeURL, json{
                command:  toplevel_call,
                pid:      RemotePid,
                goal:     GoalAtom,
                template: TemplateAtom,
                format:   prolog,
                limit:    Limit,
                offset:   Offset,
                once:     Once
            }), _, fail)
            ->  remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            ;   nb_setarg(1, ExitReason, connection_closed)
            )
        ;
        '$next'(Options2) ->
            arg(1, LimitBox, CurrentLimit),
            option(limit(Limit2), Options2, CurrentLimit),
            nb_setarg(1, LimitBox, Limit2),
            (   catch(remote_send_command(NodeURL, json{
                command: toplevel_next,
                pid:     RemotePid,
                limit:   Limit2
            }), _, fail)
            ->  remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            ;   nb_setarg(1, ExitReason, connection_closed)
            )
        ;
        '$stop' ->
            (   catch(remote_send_command(NodeURL, json{
                command: toplevel_stop,
                pid:     RemotePid
            }), _, fail)
            ->  remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            ;   nb_setarg(1, ExitReason, connection_closed)
            )
        ;
        '$ws_remote_event'(Dict) ->
            (   ws_json_down_reason(Dict, Reason)
            ->  nb_setarg(1, ExitReason, Reason)
            ;   ws_json_is_io_output(Dict)
            ->  remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            ;   ws_json_to_actor_event(Dict, CompoundPid, Event)
            ->  send(Target, Event),
                remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            ;   remote_proxy_loop(NodeURL, RemotePid, CompoundPid, Target, ExitReason, LimitBox)
            )
        ;
        '$ws_remote_close' ->
            nb_setarg(1, ExitReason, connection_closed)
        ;
        '$kill'(Reason) ->
            term_to_wire_atom(Reason, ReasonAtom),
            catch(remote_send_command(NodeURL, json{
                command: exit,
                pid: RemotePid,
                reason: ReasonAtom
            }), _, true),
            nb_setarg(1, ExitReason, Reason)
    }).
