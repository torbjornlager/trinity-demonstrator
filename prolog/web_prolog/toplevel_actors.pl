:- module(toplevel_actors,
   [ toplevel_spawn/1,
     toplevel_spawn/2,
     toplevel_call/2,
     toplevel_call/3,
     toplevel_next/1,
     toplevel_next/2,
     toplevel_halt/1,
     toplevel_halt/2,
     toplevel_stop/1,
     toplevel_abort/1,
     normalize_ptcp_limit/3
   ]).

/** <module> Toplevel Actors (layer 2)

A toplevel actor is the execution engine behind both:

  - stateless `/call` queries (ephemeral toplevel), and
  - semi-stateful ISOTOPE sessions (long-lived toplevel).

The actor speaks a small command protocol over mailbox messages:

  - `'$call'(Goal, Options)` to start a query,
  - `'$next'(Options)` to fetch additional solutions,
  - `'$stop'` to stop paging.

Replies are sent as `success/failure/error` terms enriched with `Pid`.

Extracted from the demonstrator's toplevel_actor.pl.  Cross-node
toplevel spawns are claimed by the distribution layer through a hook:

  - hook_toplevel_spawn(-Pid, +SourceModule, +Options): take over a
    toplevel spawn entirely (distribution claims spawns whose node(N)
    option names a non-local node).

Halting uses the ordinary actor exit and monitor machinery, including
for remote pids.

Per-'$call' goal guarding goes through isolation's prepare_goal/3 hook
(via isolation:prepared_goal/3), exactly where the demonstrator called
rewrite_goal_if_needed/3.
*/

:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(library(error)).
:- use_module(library(time), [
    alarm/4,
    install_alarm/2,
    uninstall_alarm/1,
    remove_alarm/1
]).
:- use_module(actors, [
    spawn/3,
    self/1,
    send/2,
    receive/1,
    monitor/2,
    demonitor/2,
    exit/2,
    register/2,
    with_io_target/2
]).
:- use_module(isolation, [
    actor_module/2,
    prepared_goal/3
]).

:- multifile
    hook_toplevel_spawn/3,
    hook_ptcp_limits/4,
    hook_inference_limit/1.

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
%     - node(+Node)
%       Spawn the toplevel on Node.  Handled by the distribution
%       layer through hook_toplevel_spawn/3.

toplevel_spawn(Pid) :-
    toplevel_spawn(Pid, []).

toplevel_spawn(Pid, Options0) :-
    strip_module(Options0, SourceModule, Options),
    (   hook_toplevel_spawn(Pid, SourceModule, Options)
    ->  true
    ;   local_toplevel_spawn(Pid, SourceModule, Options)
    ).

local_toplevel_spawn(Pid, SourceModule, Options) :-
    self(Self),
    option(session(Session), Options, false),
    option(time_limit(TimeLimit0), Options, infinite),
    option(idle_limit(IdleLimit0), Options, infinite),
    normalize_ptcp_limit(time_limit, TimeLimit0, RequestedTimeLimit),
    normalize_ptcp_limit(idle_limit, IdleLimit0, RequestedIdleLimit),
    effective_ptcp_limits(RequestedTimeLimit, RequestedIdleLimit,
                          TimeLimit, IdleLimit),
    option(target(Target), Options, Self),
    exclude(is_toplevel_spawn_opt, Options, SpawnOptions),
    Lifecycle = ptcp_options(Session, TimeLimit, IdleLimit),
    spawn(ptcp(Pid, Target, Lifecycle), Pid,
          [source_module(SourceModule)|SpawnOptions]),
    maybe_register_toplevel_name(Options, Pid).

effective_ptcp_limits(TimeLimit0, IdleLimit0, TimeLimit, IdleLimit) :-
    (   hook_ptcp_limits(TimeLimit0, IdleLimit0, TimeLimit1, IdleLimit1)
    ->  normalize_ptcp_limit(time_limit, TimeLimit1, TimeLimit),
        normalize_ptcp_limit(idle_limit, IdleLimit1, IdleLimit)
    ;   TimeLimit = TimeLimit0,
        IdleLimit = IdleLimit0
    ).

is_toplevel_spawn_opt(name(_)).
is_toplevel_spawn_opt(session(_)).
is_toplevel_spawn_opt(time_limit(_)).
is_toplevel_spawn_opt(idle_limit(_)).

maybe_register_toplevel_name(Options, Pid) :-
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).

%!  ptcp(+Pid, +Target, +SessionOrLifecycle) is det.
%
%   Main process loop entry point for one toplevel actor.
%
%   The loop catches `'$abort_goal'` so external abort requests do not kill the
%   actor process itself; only the currently running goal is interrupted. An
%   idle-limit expiry is caught outside that restart loop so it ends the actor
%   normally (and therefore produces a normal `down` reason when monitored).

ptcp(Pid, Target, SessionOrLifecycle) :-
    ptcp_lifecycle(SessionOrLifecycle, Session, TimeLimit, IdleLimit),
    catch(ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit),
          '$ptcp_idle_limit',
          true).

ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit) :-
    catch(state_1(Pid, Target, Session, TimeLimit, IdleLimit),
          '$abort_goal',
          ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit)).

ptcp_lifecycle(ptcp_options(Session, TimeLimit0, IdleLimit0),
               Session, TimeLimit, IdleLimit) :-
    !,
    normalize_ptcp_limit(time_limit, TimeLimit0, TimeLimit),
    normalize_ptcp_limit(idle_limit, IdleLimit0, IdleLimit).
ptcp_lifecycle(Session, Session, infinite, infinite).


%!  normalize_ptcp_limit(+Kind, +Limit0, -Limit) is det.
%
%   Normalize a PTCP wall-time or idle limit. `infinite` disables the limit;
%   finite limits are positive numbers of seconds.

normalize_ptcp_limit(_, infinite, infinite) :-
    !.
normalize_ptcp_limit(Kind, Limit0, Limit) :-
    must_be(number, Limit0),
    (   Limit0 > 0
    ->  Limit = Limit0
    ;   throw(error(domain_error(Kind, Limit0),
                    context(toplevel_actors:toplevel_spawn/2,
                            'PTCP limits must be positive seconds or infinite')))
    ).

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

state_1(Pid, Target0, Session, TimeLimit, IdleLimit) :-
    receive_idle({
        '$call'(Goal, Options) ->
            option(template(Template0), Options, Goal),
            strip_module(Template0, _, Template),
            option(offset(Offset), Options, 0),
            option(limit(Limit0), Options, 10 000 000 000),
            option(once(Once), Options, false),
            option(target(Target1), Options, Target0),
            Limit = count(Limit0),
            Target = target(Target1),
            run_call(Goal, Template, Offset, Limit, Once, Target, Pid,
                     TimeLimit, IdleLimit)
        }, IdleLimit),
    (   Session == false
    ->  true
    ;   state_1(Pid, Target0, Session, TimeLimit, IdleLimit)
    ).


%!  run_call(+Goal, +Template, +Offset, +Limit, +Once, +TargetBox, +Pid,
%!           +TimeLimit, +IdleLimit) is det.
%
%   Run a pageable call with a reusable alarm. The alarm is armed while the
%   query is computing in s2, disarmed while its choice point is suspended in
%   s3, and rearmed immediately before `next` resumes that choice point.

run_call(Goal, Template, Offset, Limit, Once, Target, Pid,
         TimeLimit, IdleLimit) :-
    setup_call_cleanup(
        create_time_limit_alarm(TimeLimit, Alarm),
        catch(
            run_call_answers(Goal, Template, Offset, Limit, Once, Target, Pid,
                             TimeLimit, IdleLimit, Alarm),
            '$ptcp_time_limit',
            send_time_limit_error(Target, Pid)
        ),
        remove_time_limit_alarm(Alarm)
    ).

run_call_answers(Goal, Template, Offset, Limit, Once, Target, Pid,
                 TimeLimit, IdleLimit, Alarm) :-
    arm_time_limit_alarm(Alarm, TimeLimit),
    state_2(Goal, Template, Offset, Limit, Once, Target, Pid, Answer),
    disarm_time_limit_alarm(Alarm),
    arg(1, Target, Out),
    send(Out, Answer),
    (   arg(3, Answer, true)
    ->  state_3(Limit, Target, IdleLimit, Alarm, TimeLimit)
    ;   true
    ).

send_time_limit_error(Target, Pid) :-
    arg(1, Target, Out),
    send(Out, error(Pid, time_limit_exceeded)).

create_time_limit_alarm(infinite, none) :-
    !.
create_time_limit_alarm(TimeLimit, alarm(AlarmId)) :-
    alarm(TimeLimit, throw('$ptcp_time_limit'), AlarmId,
          [install(false)]).

arm_time_limit_alarm(none, _) :-
    !.
arm_time_limit_alarm(alarm(AlarmId), TimeLimit) :-
    install_alarm(AlarmId, TimeLimit).

disarm_time_limit_alarm(none) :-
    !.
disarm_time_limit_alarm(alarm(AlarmId)) :-
    uninstall_alarm(AlarmId).

remove_time_limit_alarm(none) :-
    !.
remove_time_limit_alarm(alarm(AlarmId)) :-
    catch(remove_alarm(AlarmId), _, true).

receive_idle(Clauses, infinite) :-
    !,
    receive(Clauses).
receive_idle(Clauses, IdleLimit) :-
    receive(Clauses, [
        timeout(IdleLimit),
        on_timeout(throw('$ptcp_idle_limit'))
    ]).

%!  state_2(+Goal, +Template, +Offset, +Limit, +Once, +TargetBox, +Pid, -Answer) is det.
%
%   Execute one query slice in the actor module and package answer with pid.

state_2(Goal0, Template, Offset, Limit, Once, TargetBox, Pid, Answer) :-
    strip_module(Goal0, _, PlainGoal),
    actor_module(Pid, Module),
    prepared_goal(Module, PlainGoal, RewrittenGoal),
    arg(1, TargetBox, Target),
    with_io_target(Target,
        (   Once == true
        ->  once(answer(Module:RewrittenGoal, Template, Offset, Limit, Answer0))
        ;   answer(Module:RewrittenGoal, Template, Offset, Limit, Answer0)
        )),
    apply_once_answer(Once, Answer0, Answer1),
    add_pid(Answer1, Pid, Answer).

%!  state_3(+LimitBox, +TargetBox, +IdleLimit, +Alarm, +TimeLimit) is det.
%
%   Paging state after a `success(..., true)` answer.
%
%   `LimitBox` and `TargetBox` are mutable one-argument compounds used as
%   in-place cells (`nb_setarg/3`) so subsequent `'$next'` commands may update
%   limit/target without rebuilding all call state.

state_3(Limit, Target, IdleLimit, Alarm, TimeLimit) :-
    receive_idle({
        '$next'(Options2) ->
            (   option(limit(NewLimit), Options2)
            ->  nb_setarg(1, Limit, NewLimit)
            ;   true
            ),
            (   option(target(NewTarget), Options2)
            ->  nb_setarg(1, Target, NewTarget)
            ;   true
            ),
            arm_time_limit_alarm(Alarm, TimeLimit),
            fail ;
        '$stop' -> true
    }, IdleLimit).

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
        ptcp_control_exception(Error)
    ->  throw(Error)
    ;   Slice == []
    ->  Answer = failure
    ;   nonvar(Error)
    ->  Answer = error(Error)
    ;   var(Det)
    ->  Answer = success(Slice, true)
    ;   Det == true
    ->  Answer = success(Slice, false)
    ).

ptcp_control_exception('$abort_goal').
ptcp_control_exception('$ptcp_time_limit').

apply_once_answer(true, success(Slice, _), success(Slice, false)) :-
    !.
apply_once_answer(_, Answer, Answer).

%!  slice(+Goal, +Template, +Offset, +Limit, -Slice) is det.
%
%   Compute one page of solutions from Goal.  When the node layer
%   supplies an inference ceiling through hook_inference_limit/1, the
%   page computation is bounded by call_with_inference_limit/3 — a
%   tighter CPU bound than the caller-side wall-clock timeout, and the
%   defence against fast-but-infinite goals (e.g. `between(1,inf,_),
%   fail`) that never yield a solution.  Hitting the ceiling raises
%   `resource_error(inferences)`, which the answer/5 catch turns into
%   an ordinary error answer (the toplevel survives).  No clause ⇒
%   unbounded, exactly the demonstrator's behaviour.

slice(Goal, Template, Offset, Limit, Slice) :-
    (   hook_inference_limit(InfLimit),
        integer(InfLimit),
        InfLimit > 0
    ->  call_with_inference_limit(
            findnsols(Limit, Template, offset(Offset, Goal), Slice0),
            InfLimit, Result),
        (   Result == inference_limit_exceeded
        ->  throw(error(resource_error(inferences),
                        context(toplevel_actors:slice/5,
                                'per-call inference limit exceeded')))
        ;   Slice = Slice0
        )
    ;   findnsols(Limit, Template, offset(Offset, Goal), Slice)
    ).

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
    %  No explicit copy_term/2 here: send/2 to a local pid resolves
    %  to thread_send_message/2, which places a copy of the term in
    %  the receiver's mailbox; send/2 to a remote pid serializes
    %  via the wire format.  In either path the sender's term
    %  is independent of what the receiver consumes.
    send(Pid, '$call'(Goal, Options)).


%!  toplevel_next(+Pid) is det.
%!  toplevel_next(+Pid, +Options) is det.

toplevel_next(Pid) :-
    toplevel_next(Pid, []).

toplevel_next(Pid, Options) :-
    send(Pid, '$next'(Options)).


%!  toplevel_halt(+Pid) is det.
%
%   Ask the actor runtime to terminate a toplevel from any protocol state.
toplevel_halt(Pid) :-
    exit(Pid, true).

%!  toplevel_halt(+Pid, -Reply) is det.
%
%   Terminate a toplevel and wait until its termination has been observed.
%   The private monitor is distinct from any spawn-time monitor already owned
%   by the caller; Reply retains the historical value `true`.
toplevel_halt(Pid, Reply) :-
    monitor(Pid, Ref),
    setup_call_cleanup(
        true,
        (   toplevel_halt(Pid),
            receive({
                down(Pid, Ref, _) ->
                    Reply = true
            })
        ),
        demonitor(Ref, [flush])
    ).

%!  toplevel_stop(+Pid) is det.

toplevel_stop(Pid) :-
    send(Pid, '$stop').


%!  toplevel_abort(+Pid) is det.
%
%   Abort the currently running goal in toplevel actor Pid using thread_signal/2.

toplevel_abort(Pid) :-
    %  Sibling-layer internal access; deliberately not exported by
    %  actors.
    (   actors:resolve_thread(Pid, ThreadId)
    ->  catch(thread_signal(ThreadId, throw('$abort_goal')),
              error(existence_error(_,_), _),
              true)
    ;   true
    ).
