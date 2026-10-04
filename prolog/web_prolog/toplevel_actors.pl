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
     toplevel_abort/2,
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

Every abort is acknowledged with `abort(Pid)`, sent to the toplevel's
current client after the aborted query's own answers.  When a call is
accepted, stray `'$next'`, `'$stop'` and `'$input'` messages left over from
an earlier query are discarded, so each query starts from a clean mailbox.
A toplevel serves one controlling client at a time.

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
    receive/2,
    monitor/2,
    demonitor/2,
    exit/2,
    register/2,
    with_io_target/2,
    actor_terminating/0
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
    option(io_target(DefaultIoTarget), Options, follow_result_target),
    exclude(is_toplevel_spawn_opt, Options, SpawnOptions),
    Lifecycle = ptcp_options(Session, TimeLimit, IdleLimit, DefaultIoTarget),
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
is_toplevel_spawn_opt(io_target(_)).

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
    ptcp_lifecycle(SessionOrLifecycle, Session, TimeLimit, IdleLimit,
                   DefaultIoTarget),
    catch(ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit,
                       DefaultIoTarget),
          '$ptcp_idle_limit',
          true).

ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit, DefaultIoTarget) :-
    catch(state_1(Pid, Target, Session, TimeLimit, IdleLimit,
                  DefaultIoTarget),
          '$abort_goal',
          after_abort(Pid, Target, Session, TimeLimit, IdleLimit,
                      DefaultIoTarget)).

%   An abort never resumes a toplevel whose termination is already
%   committed, and a one-shot (session(false)) toplevel ends when aborted
%   instead of waiting idle for a call that will not come.
after_abort(Pid, Target, Session, TimeLimit, IdleLimit, DefaultIoTarget) :-
    (   actor_terminating
    ->  true
    ;   send_abort_ack(Pid, Target),
        (   Session == false
        ->  true
        ;   ptcp_running(Pid, Target, Session, TimeLimit, IdleLimit,
                         DefaultIoTarget)
        )
    ).

%   The acknowledgement goes to the target named by the abort request, if
%   any, else to the client of the most recent call, else to the spawn-time
%   target.  It is sent by the toplevel itself, so every answer the aborted
%   query produced precedes it in the client's mailbox.
:- thread_local ptcp_current_client/1, ptcp_abort_ack_target/1.

send_abort_ack(Pid, DefaultTarget) :-
    (   retract(ptcp_abort_ack_target(Out))
    ->  true
    ;   ptcp_current_client(Out)
    ->  true
    ;   Out = DefaultTarget
    ),
    send(Out, abort(Pid)).

set_current_client(Target) :-
    retractall(ptcp_current_client(_)),
    assertz(ptcp_current_client(Target)).

%   Discard control and input messages left over from an earlier query:
%   those that arrived before the call and were skipped while the toplevel
%   waited for it.  A command sent after the call is kept, so a client may
%   send its next request without waiting for the first answer.
%   actors:discard_deferred/1 is a layer-0 internal, called qualified.
drain_stale_commands :-
    actors:discard_deferred(toplevel_actors:stale_command).

stale_command('$next'(_)).
stale_command('$stop').
stale_command('$input'(_, _)).

ptcp_lifecycle(ptcp_options(Session, TimeLimit0, IdleLimit0, DefaultIoTarget),
               Session, TimeLimit, IdleLimit, DefaultIoTarget) :-
    !,
    normalize_ptcp_limit(time_limit, TimeLimit0, TimeLimit),
    normalize_ptcp_limit(idle_limit, IdleLimit0, IdleLimit).
ptcp_lifecycle(ptcp_options(Session, TimeLimit0, IdleLimit0),
               Session, TimeLimit, IdleLimit, follow_result_target) :-
    !,
    normalize_ptcp_limit(time_limit, TimeLimit0, TimeLimit),
    normalize_ptcp_limit(idle_limit, IdleLimit0, IdleLimit).
ptcp_lifecycle(Session, Session, infinite, infinite, follow_result_target).


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

%!  state_1(+Pid, +DefaultTarget, +SessionMode, +TimeLimit, +IdleLimit,
%!          +DefaultIoTarget) is det.
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

state_1(Pid, Target0, Session, TimeLimit, IdleLimit, DefaultIoTarget) :-
    receive_idle({
        '$call'(Goal, Options) ->
            drain_stale_commands,
            option(template(Template0), Options, Goal),
            strip_module(Template0, _, Template),
            option(offset(Offset), Options, 0),
            ( option(limit(Limit0), Options)
            -> must_be(positive_integer, Limit0), Limit = count(Limit0)
            ;  Limit = all
            ),
            option(once(Once), Options, false),
            option(target(Target1), Options, Target0),
            set_current_client(Target1),
            call_io_target(Options, DefaultIoTarget, Target1, IoTarget),
            Target = target(Target1),
            run_call(Goal, Template, Offset, Limit, Once, Target, IoTarget, Pid,
                     TimeLimit, IdleLimit)
        }, IdleLimit),
    (   Session == false
    ->  true
    ;   state_1(Pid, Target0, Session, TimeLimit, IdleLimit, DefaultIoTarget)
    ).

call_io_target(Options, _DefaultIoTarget, _ResultTarget, IoTarget) :-
    option(io_target(IoTarget), Options),
    !.
call_io_target(_Options, follow_result_target, ResultTarget, ResultTarget) :-
    !.
call_io_target(_Options, DefaultIoTarget, _ResultTarget, DefaultIoTarget).


%!  run_call(+Goal, +Template, +Offset, +Limit, +Once, +TargetBox,
%!           +IoTarget, +Pid, +TimeLimit, +IdleLimit) is det.
%
%   Run a pageable call with a reusable alarm. The alarm is armed while the
%   query is computing in s2, disarmed while its choice point is suspended in
%   s3, and rearmed immediately before `next` resumes that choice point.

run_call(Goal, Template, Offset, Limit, Once, Target, IoTarget, Pid,
         TimeLimit, IdleLimit) :-
    setup_call_cleanup(
        create_time_limit_alarm(TimeLimit, Alarm),
        catch(
            run_call_answers(Goal, Template, Offset, Limit, Once, Target,
                             IoTarget, Pid,
                             TimeLimit, IdleLimit, Alarm),
            '$ptcp_time_limit',
            send_time_limit_error(Target, Pid)
        ),
        remove_time_limit_alarm(Alarm)
    ).

run_call_answers(Goal, Template, Offset, Limit, Once, Target, IoTarget, Pid,
                 TimeLimit, IdleLimit, Alarm) :-
    arm_time_limit_alarm(Alarm, TimeLimit),
    state_2(Goal, Template, Offset, Limit, Once, IoTarget, Pid, Answer),
    disarm_time_limit_alarm(Alarm),
    arg(1, Target, Out),
    (   Answer = pending_error(Pid, Slice, Error)
    ->  %  Solutions found before an exception are delivered as a page
        %  with more to come; the error answers the next request.
        send(Out, success(Pid, Slice, true)),
        state_3_error(Pid, Error, Target, IdleLimit)
    ;   send(Out, Answer),
        (   arg(3, Answer, true)
        ->  state_3(Limit, Target, IdleLimit, Alarm, TimeLimit)
        ;   true
        )
    ).

state_3_error(Pid, Error, Target, IdleLimit) :-
    receive_idle({
        '$next'(Options) ->
            (   option(target(NewTarget), Options)
            ->  nb_setarg(1, Target, NewTarget),
                set_current_client(NewTarget)
            ;   true
            ),
            arg(1, Target, Out),
            send(Out, error(Pid, Error)) ;
        '$stop' -> true
    }, IdleLimit).

send_time_limit_error(Target, Pid) :-
    arg(1, Target, Out),
    send(Out, error(Pid, error(resource_error(time), _))).

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

%!  state_2(+Goal, +Template, +Offset, +Limit, +Once, +IoTarget, +Pid,
%!          -Answer) is det.
%
%   Execute one query slice in the actor module and package answer with pid.

state_2(Goal0, Template, Offset, Limit, Once, IoTarget, Pid, Answer) :-
    strip_module(Goal0, _, PlainGoal),
    actor_module(Pid, Module),
    prepared_goal(Module, PlainGoal, RewrittenGoal),
    with_io_target(IoTarget,
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
            ->  must_be(positive_integer, NewLimit),
                nb_setarg(1, Limit, NewLimit)
            ;   true
            ),
            (   option(target(NewTarget), Options2)
            ->  nb_setarg(1, Target, NewTarget),
                set_current_client(NewTarget)
            ;   true
            ),
            arm_time_limit_alarm(Alarm, TimeLimit),
            fail ;
        '$stop' -> true
    }, IdleLimit).

%!  answer(+Goal, +Template, +Offset, +Limit, -Answer) is det.
%
%   Collect all solutions or a finite slice and map execution outcome to
%   `success/failure/error`.
%
%   - nondeterministic remainder -> `success(Slice, true)`
%   - deterministic completion   -> `success(Slice, false)`
%   - empty slice                -> `failure`
%   - exception                  -> `error(Exception)`

answer(Goal, Template, Offset, Limit, Answer) :-
    answer_(Goal, Template, Offset, Limit, Answer0),
    portable_answer(Answer0, Answer).

answer_(Goal, Template, Offset, Limit, Answer) :-
    Pending = pending(none),
    catch(
       call_cleanup(slice(capture_error(Goal, Pending), Template, Offset,
                          Limit, Slice),
                    Det = true),
           Error, true),
    arg(1, Pending, Captured),
    (   nonvar(Error),
        ptcp_control_exception(Error)
    ->  throw(Error)
    ;   Captured \== none,
        Slice \== [],
        Limit \== all
    ->  normalize_resource_error(Captured, PublicError),
        Answer = pending_error(Slice, PublicError)
    ;   Captured \== none
    ->  normalize_resource_error(Captured, PublicError),
        Answer = error(PublicError)
    ;   nonvar(Error)
    ->  normalize_resource_error(Error, PublicError),
        Answer = error(PublicError)
    ;   Slice == []
    ->  Answer = failure
    ;   var(Det)
    ->  Answer = success(Slice, true)
    ;   Det == true
    ->  Answer = success(Slice, false)
    ).

%   An answer is a plain Herbrand term (Semantic Contracts D5).  A slice
%   whose solutions carry constraints (attributed variables, as left by
%   dif/2, freeze/2 or CLP(FD)) cannot be represented: printing it would
%   drop the constraints and present a conditional answer as an
%   unconditional one.  It is therefore replaced by a representation error,
%   which ends the query.  The rule is the same for a local and a remote
%   client, so a toplevel's answers do not depend on where its client is.
portable_answer(Answer0, Answer) :-
    answer_slice(Answer0, Slice),
    \+ term_attvars(Slice, []),
    !,
    Answer = error(error(representation_error(constraints),
                         context(toplevel_actors:answer/5,
                                 'answer contains constrained variables'))).
portable_answer(Answer, Answer).

answer_slice(success(Slice, _), Slice).
answer_slice(pending_error(Slice, _), Slice).

%   Run Goal, recording an ordinary exception instead of letting it discard
%   the solutions already collected for the current page.  With a finite
%   limit, the recorded error is reported after those solutions (see
%   answer/5); a request for all solutions at once reports the error alone,
%   as before.  Control exceptions propagate.
capture_error(Goal, Pending) :-
    catch(Goal, E, record_goal_error(E, Pending)).

record_goal_error(E, _) :-
    (   ptcp_control_exception(E)
    ;   E = unwind(_)
    ),
    !,
    throw(E).
record_goal_error(E, Pending) :-
    nb_setarg(1, Pending, E),
    fail.

% Public resource categories hide backend-specific memory names and context.
normalize_resource_error(error(resource_error(Resource), _),
                         error(resource_error(space), _)) :-
    nonvar(Resource),
    memberchk(Resource, [space, stack, memory, heap, trail, global_stack, local_stack]),
    !.
normalize_resource_error(time_limit_exceeded, error(resource_error(time), _)) :- !.
normalize_resource_error(error(resource_error(time), _), error(resource_error(time), _)) :- !.
normalize_resource_error(Error, Error).

ptcp_control_exception('$abort_goal').
ptcp_control_exception('$ptcp_time_limit').

apply_once_answer(true, success(Slice, _), success(Slice, false)) :-
    !.
apply_once_answer(true, pending_error(Slice, _), success(Slice, false)) :-
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
            collect_slice(Limit, Template, offset(Offset, Goal), Slice0),
            InfLimit, Result),
        (   Result == inference_limit_exceeded
        ->  throw(error(resource_error(inferences),
                        context(toplevel_actors:slice/5,
                                'per-call inference limit exceeded')))
        ;   Slice = Slice0
        )
    ;   collect_slice(Limit, Template, offset(Offset, Goal), Slice)
    ).

% The marker all is internal; the public API represents it by omission.
collect_slice(all, Template, Goal, Slice) :-
    !,
    findall(Template, Goal, Slice).
collect_slice(Limit, Template, Goal, Slice) :-
    findnsols(Limit, Template, Goal, Slice).

validate_solution_limit(Options) :-
    ( option(limit(N), Options) -> must_be(positive_integer, N) ; true ).

%!  add_pid(+Answer0, +Pid, -Answer) is det.
%
%   Add actor pid to outward-facing answer terms.

add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).
add_pid(failure, Pid, failure(Pid)).
add_pid(error(Term), Pid, error(Pid, Term)).
add_pid(pending_error(Slice, Term), Pid, pending_error(Pid, Slice, Term)).


%!  toplevel_call(+Pid, :Goal) is det.
%!  toplevel_call(+Pid, :Goal, +Options) is det.

toplevel_call(Pid, Goal) :-
    toplevel_call(Pid, Goal, []).

toplevel_call(Pid, Goal, Options) :-
    validate_solution_limit(Options),
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
    validate_solution_limit(Options),
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
%   by the caller; the second argument retains the historical value `true`.
toplevel_halt(Pid, true) :-
    setup_call_cleanup(
        monitor(Pid, Ref),
        (   toplevel_halt(Pid),
            receive({
                down(Pid, Ref, _) ->
                    true
            })
        ),
        demonitor(Ref, [flush])
    ).

%!  toplevel_stop(+Pid) is det.

toplevel_stop(Pid) :-
    send(Pid, '$stop').


%   Runs in the target thread.  An abort that arrives after termination has
%   been committed is ignored.
abort_signal :-
    (   actor_terminating
    ->  true
    ;   throw('$abort_goal')
    ).

abort_signal(AckTarget) :-
    (   actor_terminating
    ->  true
    ;   retractall(ptcp_abort_ack_target(_)),
        assertz(ptcp_abort_ack_target(AckTarget)),
        throw('$abort_goal')
    ).

%!  toplevel_abort(+Pid) is det.
%
%   Abort the currently running goal in toplevel actor Pid using thread_signal/2.

toplevel_abort(Pid) :-
    toplevel_abort_signal(Pid, toplevel_actors:abort_signal).

%!  toplevel_abort(+Pid, +AckTarget) is det.
%
%   As toplevel_abort/1, but send the `abort(Pid)` acknowledgement to
%   AckTarget.  Used by the node bindings, whose client is a session queue.

toplevel_abort(Pid, AckTarget) :-
    toplevel_abort_signal(Pid, toplevel_actors:abort_signal(AckTarget)).

toplevel_abort_signal(Pid, Signal) :-
    %  Sibling-layer internal access; deliberately not exported by
    %  actors.
    (   actors:resolve_thread(Pid, ThreadId)
    ->  catch(thread_signal(ThreadId, Signal),
              error(existence_error(_,_), _),
              true)
    ;   true
    ).
