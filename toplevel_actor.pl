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

:- use_module(node_controller, []).
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
    register_remote_pid/2,
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
    %  Step 6: no per-pid proxy actor.  Install monitor + link first,
    %  then register the target (the readiness marker for inbound
    %  dispatch), then flush.  See spawn_remote/4 in actor.pl for
    %  the rationale.
    maybe_register_toplevel_name(Options, CompoundPid),
    (   option(monitor(true), Options)
    ->  assertz(actor:monitor(Self, CompoundPid, CompoundPid)),
        node_controller:add_remote_monitor(Self, CompoundPid, CompoundPid)
    ;   true
    ),
    %  Mirror the link-default behavior of actor.pl's remote spawn
    %  path.  Without this, a cross-node toplevel_spawn never
    %  installs the parent->child link, so when the parent dies,
    %  stop/2 has no link record to walk and the remote toplevel is
    %  orphaned on the target node.  Documented contract:
    %  manual.html:204 / manual.html:406 say link defaults to true
    %  and toplevel_spawn/2 accepts all spawn/3 options.
    option(link(Link), Options, true),
    (   Link == true
    ->  assertz(actor:link(Self, CompoundPid)),
        node_controller:add_remote_link(Self, CompoundPid)
    ;   true
    ),
    actor:register_remote_pid(CompoundPid, Target),
    actor:flush_pending_for_pid(NodeURL, RemotePid).

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
%
%   Halt an idle toplevel session and wait for its reply.  Routes
%   cross-node halts through actor:remote_request_halt/3 so that the
%   call no longer hangs when Pid is a compound RemoteId@NodeURL
%   (the local proxy's receive loop does not handle '$halt'/1, and
%   the remote WS layer needs a toplevel_halt action which is now
%   wired in node_ws.pl).
toplevel_halt(RemoteId@NodeURL, Reply) :-
    \+ localhost_node(NodeURL),
    !,
    actor:remote_request_halt(NodeURL, RemoteId, Reply).
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


%  Step 6c: the local proxy actor for remote toplevels
%  (remote_toplevel_proxy/3, remote_proxy_loop/6, and
%  remote_toplevel_proxy_finalize/4) has been removed.  Cross-node
%  toplevel I/O now flows through the controller-driven dispatch in
%  actor.pl: `send/2` for remote pids routes `$call/$next/$stop` as
%  wire messages, `exit/2` routes via safe_remote_kill_send/4, and
%  the controller's remote_target_/3 + remote_monitor_/3 tables drive
%  event delivery on the local side.
