:- module(node_session, [
    rewrite_isotope_goal/2,
    register_isotope_session/1,
    register_isotope_session/2,
    register_isotope_session/3,
    register_isotope_session/4,
    remember_isotope_session_profile/2,
    remember_isotope_session_namespace/2,
    set_isotope_session_trace/2,
    isotope_session_trace_enabled/1,
    is_client_session_pid/1,
    with_isotope_session_public_execution_profile/2,
    cleanup_isotope_session/1,
    isotope_session_queue/2,
    require_isotope_session_owner/2,
    ensure_isotope_ready/3,
    wait_for_session_event/4,
    load_text_into_session/2,
    current_isotope_session_infos/1,
    admin_terminate_isotope_session/1,
    admin_terminate_isotope_session/2
]).

/** <module> ISOTOPE Session Helpers

Session lifecycle and queue/message normalization for node ISOTOPE endpoints.
*/

:- use_module(actor, [actor_module/2, exit/2]).
:- use_module(toplevel_actor, [toplevel_call/3, toplevel_abort/1]).
:- use_module(node_client, [text_to_string/2]).
:- use_module(pid_utils, [canonical_pid/2, local_node_url/1]).
:- use_module(source_loader, [load_source_text/3]).
:- use_module(public_goal_guard, [rewrite_source_text/3]).
:- use_module(dollar_expansion, [clear_session_bindings/1]).
:- use_module(node_limits, [forget_isotope_session_owner/1]).
:- use_module(node_log, [finish_activity/3]).
:- use_module(node_sandbox, [sandbox_check_source_text/3]).
:- use_module(node_execution_context, [
    with_public_execution_profile/2,
    with_public_execution_namespace/2
]).

:- dynamic isotope_session/2.
:- dynamic isotope_loaded_text/2.
:- dynamic isotope_session_profile/2.
:- dynamic isotope_session_namespace/2.
:- dynamic isotope_session_owner/2.
:- dynamic isotope_session_trace/1.
:- dynamic isotope_ready/1.

:- meta_predicate with_isotope_session_public_execution_profile(+, 0).


%!  rewrite_isotope_goal(+Goal0, -Goal) is det.
%
%   Rewrite blocking input goals so session calls do not depend on
%   process-local standard streams. Output predicates are handled by the
%   actor module I/O prelude.
rewrite_isotope_goal(Var, Var) :-
    var(Var),
    !.
rewrite_isotope_goal(read(Term), input('|:', Term)) :-
    !.
rewrite_isotope_goal(actor:input(Prompt, Term), input(Prompt, Term)) :-
    !.
rewrite_isotope_goal(actor:input(Prompt, Term, Options),
                     input(Prompt, Term, Options)) :-
    !.
rewrite_isotope_goal(Module:Goal0, Module:Goal) :-
    atom(Module),
    current_module(Module),
    !,
    rewrite_isotope_goal(Goal0, Goal).
rewrite_isotope_goal(Term0, Term) :-
    compound(Term0),
    !,
    Term0 =.. [F|Args0],
    maplist(rewrite_isotope_goal, Args0, Args),
    Term =.. [F|Args].
rewrite_isotope_goal(Term, Term).


%!  register_isotope_session(+Pid) is det.
%!  register_isotope_session(+Pid, +InitialLoadText) is det.
%
%   Create/replace queue bookkeeping for an ISOTOPE session.
register_isotope_session(Pid) :-
    register_isotope_session(Pid, '').

register_isotope_session(Pid, InitialLoadText0) :-
    register_isotope_session(Pid, InitialLoadText0, isotope).

register_isotope_session(Pid, InitialLoadText0, Profile) :-
    register_isotope_session(Pid, InitialLoadText0, Profile, anonymous).

register_isotope_session(Pid, InitialLoadText0, Profile, OwnerId) :-
    session_pid_key(Pid, SessionPid),
    cleanup_isotope_session(SessionPid),
    text_to_string(InitialLoadText0, InitialLoadText),
    message_queue_create(Queue),
    assertz(isotope_session(SessionPid, Queue)),
    assertz(isotope_loaded_text(SessionPid, InitialLoadText)),
    assertz(isotope_session_owner(SessionPid, OwnerId)),
    remember_isotope_session_profile(SessionPid, Profile).


%!  remember_isotope_session_profile(+Pid, +Profile) is det.
remember_isotope_session_profile(Pid, Profile) :-
    session_pid_key(Pid, SessionPid),
    retractall(isotope_session_profile(SessionPid, _)),
    assertz(isotope_session_profile(SessionPid, Profile)).


%!  remember_isotope_session_namespace(+Pid, +Namespace) is det.
remember_isotope_session_namespace(Pid, Namespace) :-
    session_pid_key(Pid, SessionPid),
    retractall(isotope_session_namespace(SessionPid, _)),
    assertz(isotope_session_namespace(SessionPid, Namespace)).


%!  set_isotope_session_trace(+Pid, +Enabled) is det.
%
%   Remember whether statechart trace output is enabled for the given client
%   session. This setting is client-scoped and survives across later calls on
%   the same session until explicit change or session cleanup.
set_isotope_session_trace(Pid0, Enabled) :-
    must_be(oneof([true, false]), Enabled),
    session_pid_key(Pid0, Pid),
    retractall(isotope_session_trace(Pid)),
    (   Enabled == true
    ->  assertz(isotope_session_trace(Pid))
    ;   true
    ).


%!  isotope_session_trace_enabled(+Pid) is semidet.
isotope_session_trace_enabled(Pid0) :-
    session_pid_key(Pid0, Pid),
    isotope_session_trace(Pid).


%!  is_client_session_pid(+Pid) is semidet.
%
%   True when Pid identifies a live or remembered interactive client session.
%   WebSocket-owned toplevels share this bookkeeping surface with HTTP
%   ISOTOPE sessions.
is_client_session_pid(Pid0) :-
    session_pid_key(Pid0, Pid),
    (   isotope_session(Pid, _)
    ;   isotope_loaded_text(Pid, _)
    ;   isotope_session_profile(Pid, _)
    ;   isotope_session_namespace(Pid, _)
    ;   isotope_session_owner(Pid, _)
    ;   isotope_session_trace(Pid)
    ;   isotope_ready(Pid)
    ),
    !.


%!  with_isotope_session_public_execution_profile(+Pid, :Goal) is det.
%
%   Run Goal inside the public execution profile remembered for the given
%   ISOTOPE session. This preserves public sandbox/source handling across
%   later `/toplevel_call`, `/toplevel_next`, and `/toplevel_respond` steps.
with_isotope_session_public_execution_profile(Pid0, Goal) :-
    session_pid_key(Pid0, Pid),
    isotope_session_profile_or_default(Pid, Profile),
    (   isotope_session_namespace(Pid, Namespace)
    ->  with_public_execution_profile(
            Profile,
            with_public_execution_namespace(Namespace, Goal)
        )
    ;   with_public_execution_profile(Profile, Goal)
    ).


%!  cleanup_isotope_session(+Pid) is det.
%
%   Tear down queue bookkeeping and remembered source for a session.
cleanup_isotope_session(Pid) :-
    session_pid_key(Pid, SessionPid),
    ignore(catch(finish_activity(isotope_session, SessionPid, cleanup),
                 _, true)),
    (   retract(isotope_session(SessionPid, Queue))
    ->  catch(message_queue_destroy(Queue), _, true)
    ;   true
    ),
    retractall(isotope_loaded_text(SessionPid, _)),
    retractall(isotope_session_profile(SessionPid, _)),
    retractall(isotope_session_namespace(SessionPid, _)),
    retractall(isotope_session_owner(SessionPid, _)),
    retractall(isotope_session_trace(SessionPid)),
    retractall(isotope_ready(SessionPid)),
    forget_isotope_session_owner(SessionPid),
    clear_session_bindings(SessionPid).


%!  isotope_session_queue(+Pid, -Queue) is det.
%
%   Resolve session queue or throw a descriptive existence error.
isotope_session_queue(Pid, Queue) :-
    session_pid_key(Pid, SessionPid),
    isotope_session(SessionPid, Queue),
    !.
isotope_session_queue(Pid, _) :-
    throw(error(existence_error(isotope_session, Pid),
                context(node:isotope_session_queue/2,
                        'unknown or expired ISOTOPE session pid'))).


%!  require_isotope_session_owner(+PrincipalId, +Pid) is det.
%
%   Enforce ownership on canonicalized session pids using the same key mapping
%   as queue and cleanup bookkeeping.
require_isotope_session_owner(PrincipalId, Pid) :-
    session_pid_key(Pid, SessionPid),
    (   isotope_session_owner(SessionPid, PrincipalId)
    ->  true
    ;   throw(error(authorization_error(PrincipalId, session(SessionPid)),
                    context(node_session:require_isotope_session_owner/2,
                            'principal does not own this ISOTOPE session')))
    ).


%!  ensure_isotope_ready(+Pid, +Queue, +Timeout) is det.
%
%   Ensure session actor has finished startup before handling first call.
ensure_isotope_ready(Pid, _, _) :-
    session_pid_key(Pid, SessionPid),
    isotope_ready(SessionPid),
    !.
ensure_isotope_ready(Pid, Queue, Timeout) :-
    session_pid_key(Pid, SessionPid),
    toplevel_call(SessionPid, true, [
        template(true),
        limit(1),
        target(Queue)
    ]),
    (   thread_get_message(Queue, Message, [timeout(Timeout)])
    ->  session_message_event(SessionPid, Message, Event),
        (   Event = success(SessionPid, _, _)
        ;   Event = failure(SessionPid)
        ),
        assertz(isotope_ready(SessionPid))
    ;   throw(error(timeout,
                    context(node:ensure_isotope_ready/2,
                            'timeout while waiting for ISOTOPE startup')))
    ).


%!  wait_for_session_event(+Pid, +Queue, +Timeout, -Event) is det.
%
%   Wait for a message from the session queue and map it to the external JSON
%   event vocabulary. On timeout, abort remote computation and return
%   `timeout(Pid)`.
wait_for_session_event(Pid, Queue, Timeout, Event) :-
    session_pid_key(Pid, SessionPid),
    (   thread_get_message(Queue, Message, [timeout(Timeout)])
    ->  session_message_event(SessionPid, Message, Event)
    ;   catch(toplevel_abort(SessionPid), _, true),
        Event = timeout(SessionPid)
    ).


%!  session_message_event(+Pid, +Message, -Event) is det.
%
%   Normalize internal actor messages to the endpoint event model.
session_message_event(Pid, success(Pid, Slice, More), success(Pid, Slice, More)).
session_message_event(Pid, failure(Pid), failure(Pid)).
session_message_event(Pid, error(Pid, Error), error(Pid, Error)).
session_message_event(Pid, output(Pid, Data), output(Pid, Data)).
session_message_event(Pid, terminal_io_output(Pid, Data), terminal_io_output(Pid, Data)).
session_message_event(Pid, terminal_output(Pid, Data), terminal_output(Pid, Data)).
session_message_event(Pid, prompt(Pid, Prompt), prompt(Pid, Prompt)).
session_message_event(Pid, '$abort_goal', abort(Pid)).
session_message_event(Pid, down(_, Pid, _), abort(Pid)) :-
    cleanup_isotope_session(Pid).
session_message_event(Pid, Message, error(Pid, Unexpected)) :-
    Unexpected = error(unexpected_session_message(Message),
                       context(node:wait_for_session_event/4,
                               'unexpected session event')).


%!  load_text_into_session(+Pid, +LoadText) is det.
%
%   Replace session private code when source changed since last successful load.
load_text_into_session(Pid, LoadText0) :-
    session_pid_key(Pid, SessionPid),
    text_to_string(LoadText0, LoadText),
    (   LoadText == ""
    ->  true
    ;   isotope_loaded_text(SessionPid, LoadText)
    ->  true
    ;   rewrite_isotope_source_text(LoadText, RewrittenLoadText),
        actor_module(SessionPid, Module),
        isotope_session_profile_or_default(SessionPid, Profile),
        sandbox_check_source_text(Profile, Module, RewrittenLoadText),
        (   current_predicate(node_sandbox:sandbox_mode/1),
            node_sandbox:sandbox_mode(SandboxMode),
            SandboxMode == blacklist
        ->  rewrite_source_text(Module, RewrittenLoadText, GuardedLoadText)
        ;   GuardedLoadText = RewrittenLoadText
        ),
        isotope_load_source_id(Module, SourceId),
        load_source_text(GuardedLoadText, Module, SourceId),
        remember_isotope_loaded_text(SessionPid, LoadText)
    ).


%!  current_isotope_session_infos(-Infos) is det.
%
%   Enumerate active HTTP-owned ISOTOPE sessions for the current node.
current_isotope_session_infos(Infos) :-
    findall(
        json{
            pid:PidString,
            owner:OwnerId,
            profile:Profile,
            ready:Ready
        },
        current_isotope_session_info(PidString, OwnerId, Profile, Ready),
        Infos
    ).


%!  admin_terminate_isotope_session(+Pid) is det.
%
%   Force-stop a session actor and clear its bookkeeping immediately.
admin_terminate_isotope_session(Pid) :-
    admin_terminate_isotope_session(Pid, kill).

%!  admin_terminate_isotope_session(+Pid, +Reason) is det.
%
%   Force-stop a session actor with an explicit reason and clear its
%   bookkeeping immediately.
admin_terminate_isotope_session(Pid, Reason) :-
    isotope_session_queue(Pid, _),
    catch(exit(Pid, Reason), _, true),
    cleanup_isotope_session(Pid).


%!  rewrite_isotope_source_text(+SourceIn, -SourceOut) is det.
%
%   Parse source and apply rewrite_isotope_goal/2 to clause bodies and
%   directives before loading into session module.
rewrite_isotope_source_text(SourceIn, SourceOut) :-
    setup_call_cleanup(
        open_string(SourceIn, In),
        read_rewritten_isotope_terms(In, Terms),
        close(In)
    ),
    with_output_to(string(SourceOut),
                   forall(member(Term, Terms),
                          write_term(Term, [
                              quoted(true),
                              fullstop(true),
                              nl(true)
                          ]))).


%!  read_rewritten_isotope_terms(+In, -Terms:list) is det.
read_rewritten_isotope_terms(In, Terms) :-
    read_term(In, Term0, []),
    (   Term0 == end_of_file
    ->  Terms = []
    ;   rewrite_isotope_source_term(Term0, Term),
        Terms = [Term|Rest],
        read_rewritten_isotope_terms(In, Rest)
    ).


%!  rewrite_isotope_source_term(+Term0, -Term) is det.
rewrite_isotope_source_term((Head :- Body0), (Head :- Body)) :-
    !,
    rewrite_isotope_goal(Body0, Body).
rewrite_isotope_source_term((:- Directive0), (:- Directive)) :-
    !,
    rewrite_isotope_goal(Directive0, Directive).
rewrite_isotope_source_term(Term, Term).


%!  isotope_load_source_id(+Module, -SourceId) is det.
%
%   Deterministic source id used when reloading session code into its module.
isotope_load_source_id(Module, SourceId) :-
    format(atom(SourceId), '~w_isotope_call_load', [Module]).


%!  remember_isotope_loaded_text(+Pid, +LoadText) is det.
remember_isotope_loaded_text(Pid, LoadText) :-
    session_pid_key(Pid, SessionPid),
    retractall(isotope_loaded_text(SessionPid, _)),
    assertz(isotope_loaded_text(SessionPid, LoadText)).


isotope_session_profile_or_default(Pid, Profile) :-
    (   isotope_session_profile(Pid, Profile0)
    ->  Profile = Profile0
    ;   Profile = isotope
    ).

%!  session_pid_key(+Pid0, -Pid) is det.
%
%   Normalize pid values so integer and canonical `Id@Node` forms resolve to
%   the same ISOTOPE session bookkeeping key.
session_pid_key(Pid0, Pid) :-
    (   catch(canonical_pid(Pid0, CanonPid), _, fail)
    ->  Pid = CanonPid
    ;   Pid = Pid0
    ).


current_isotope_session_info(PidString, OwnerId, Profile, Ready) :-
    isotope_session(SessionPid, _Queue),
    session_pid_local(SessionPid),
    pid_string(SessionPid, PidString),
    isotope_session_owner_or_default(SessionPid, OwnerId),
    isotope_session_profile_or_default(SessionPid, Profile),
    (   isotope_ready(SessionPid)
    ->  Ready = true
    ;   Ready = false
    ).


isotope_session_owner_or_default(Pid, OwnerId) :-
    (   isotope_session_owner(Pid, OwnerId0)
    ->  OwnerId = OwnerId0
    ;   OwnerId = anonymous
    ).


session_pid_local(Pid0) :-
    nonvar(Pid0),
    Pid0 =.. ['@', Pid, Node],
    integer(Pid),
    local_node_url(Node),
    !.
session_pid_local(Pid) :-
    integer(Pid).


pid_string(Pid, PidString) :-
    term_string(Pid, PidString).
