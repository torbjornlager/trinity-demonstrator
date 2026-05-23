:- module(node_isotope_controller, [
    isotope_spawn_event/5,
    isotope_call_event/11,
    isotope_respond_event/3,
    parse_isotope_wait_request/4
]).

/** <module> ISOTOPE Controller Helpers

Build endpoint events and parse shared ISOTOPE wait-request parameters.
*/

:- use_module(actor, [respond/2, actor_module/2, make_id/1]).
:- use_module(toplevel_actor, [toplevel_spawn/2, toplevel_call/3]).
:- use_module(node_client, [
    text_to_string/2,
    normalize_requested_timeout/2
]).
:- use_module(pid_utils, [parse_pid_or_throw/4]).
:- use_module(node_call_context, [parse_call_context/9]).
:- use_module(node_session, [
    rewrite_isotope_goal/2,
    register_isotope_session/4,
    remember_isotope_session_namespace/2,
    set_isotope_session_trace/2,
    isotope_session_queue/2,
    ensure_isotope_ready/3,
    wait_for_session_event/4,
    load_text_into_session/2,
    read_response_input/3,
    with_isotope_session_public_execution_profile/2
]).
:- use_module(node_log, [request_client_meta/3, start_activity/3]).
:- use_module(node_isotope_options, [isotope_spawn_options/6]).
:- use_module(node_limits, [
    reserve_isotope_session_capacity/2,
    commit_isotope_session_capacity/2,
    release_capacity_reservation/1
]).
:- use_module(node_profile_policy, [profile_check_route/1]).
:- use_module(node_sandbox, [sandbox_check_goal/2, sandbox_check_goal_in_module/3]).
:- use_module(node_execution_context, [with_public_execution_context/3]).
:- use_module(dollar_expansion, [
    expand_dollar_vars/3,
    capture_answer_bindings/1,
    session_bindings/2
]).

:- use_module(library(http/http_parameters)).


%!  parse_isotope_wait_request(+Request, -Pid, -Format, -Timeout) is det.
%
%   Parse common wait parameters used by `/toplevel_next` and `/toplevel_poll`.
%   The returned Timeout is already capped by node owner timeout policy.
parse_isotope_wait_request(Request, Pid, Format, Timeout) :-
    http_parameters(Request, [
        pid(Pid0, [atom]),
        format(Format, [atom, default(json)]),
        timeout(RequestedTimeout0, [number, optional(true)])
    ]),
    parse_pid_or_throw(Pid0, node:parse_isotope_wait_request/4,
                       'pid must be an integer, atom name, or Id@Node term', Pid),
    normalize_requested_timeout(RequestedTimeout0, RequestedTimeout),
    node:effective_timeout(RequestedTimeout, Timeout).


%!  isotope_spawn_event(+Request, +Principal, +PrincipalId, +EffectiveProfile,
%!                     -Event) is det.
%
%   Build spawn event for `/toplevel_spawn` by parsing spawn options,
%   injecting prelude source, creating the session actor, and registering
%   session bookkeeping.  Shared DB is accessed through module imports.
isotope_spawn_event(Request, Principal, PrincipalId, EffectiveProfile, Event) :-
    profile_check_route(toplevel_spawn),
    isotope_spawn_options(Request, Principal, EffectiveProfile, SpawnOptions,
                          InitialLoadText, TraceEnabled),
    make_id(NamespaceId),
    Namespace = isotope_session(NamespaceId),
    reserve_isotope_session_capacity(Principal, Reservation),
    catch(
        (
            with_public_execution_context(
                EffectiveProfile,
                Namespace,
                toplevel_spawn(Pid, SpawnOptions)
            ),
            register_isotope_session(Pid, InitialLoadText, EffectiveProfile,
                                     PrincipalId),
            request_client_meta(Request, Principal, ClientMeta),
            put_dict(_{pid:Pid, profile:EffectiveProfile}, ClientMeta,
                     SessionMeta),
            ignore(catch(start_activity(isotope_session, Pid, SessionMeta),
                         _, true)),
            remember_isotope_session_namespace(Pid, Namespace),
            set_isotope_session_trace(Pid, TraceEnabled),
            commit_isotope_session_capacity(Reservation, Pid),
            Event = spawned(Pid)
        ),
        Error,
        (
            release_capacity_reservation(Reservation),
            throw(Error)
        )
    ).


%!  isotope_call_event(+Pid, +EffectiveProfile, +GoalAtom, +TemplateAtom0, +Offset, +Limit,
%!                     +Format, +LoadText0, +Once0, +RequestedTimeout0,
%!                     -Event) is det.
%
%   Build one call event for `/toplevel_call`.
%   Parses goal/template context, rewrites I/O goals for actor transport,
%   ensures session startup completion, optionally loads session source, then
%   issues `toplevel_call/3` and waits for one normalized session event.
%   Load-text failures are returned as `error(Pid, Error)` events.
isotope_call_event(Pid, EffectiveProfile, GoalAtom0, TemplateAtom0, Offset, Limit, Format,
                   LoadText0, Once0, RequestedTimeout0, Event) :-
    profile_check_route(toplevel_call),
    session_bindings(Pid, Bindings),
    expand_dollar_vars(GoalAtom0, Bindings, GoalAtom),
    parse_call_context(GoalAtom, TemplateAtom0, Format, Once0,
                       RequestedTimeout0, Goal, Template, Once,
                       RequestedTimeout),
    rewrite_isotope_goal(Goal, RewrittenGoal),
    isotope_session_queue(Pid, Queue),
    node:effective_timeout(none, StartupTimeout),
    ensure_isotope_ready(Pid, Queue, StartupTimeout),
    text_to_string(LoadText0, LoadText),
    catch(load_text_into_session(Pid, LoadText), LoadError, true),
    (   var(LoadError)
    ->  actor_module(Pid, Module),
        sandbox_check_goal_in_module(EffectiveProfile, Module, RewrittenGoal),
        with_isotope_session_public_execution_profile(
            Pid,
            toplevel_call(Pid, RewrittenGoal, [
                template(Template),
                offset(Offset),
                limit(Limit),
                once(Once),
                target(Queue)
            ])
        ),
        node:effective_timeout(RequestedTimeout, Timeout),
        wait_for_session_event(Pid, Queue, Timeout, Event)
    ;   Event = error(Pid, load_text_error(LoadError))
    ),
    capture_answer_bindings(Event).


%!  isotope_respond_event(+Pid, +InputAtom, -Event) is det.
%
%   Parse input term and deliver it to a waiting session prompt.
isotope_respond_event(Pid, InputAtom, Event) :-
    profile_check_route(toplevel_respond),
    read_response_input(Pid, InputAtom, Input),
    with_isotope_session_public_execution_profile(Pid, respond(Pid, Input)),
    Event = responded(Pid).
