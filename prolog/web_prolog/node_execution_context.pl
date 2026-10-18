:- module(node_execution_context, [
    with_public_execution_context/3,
    with_public_execution_profile/2,
    with_public_execution_namespace/2,
    without_public_execution_context/1,
    current_public_execution_profile/1,
    current_public_execution_namespace/1,
    open_client_namespace/1, close_client_namespace/1,
    open_client_connection/2, close_client_connection/1,
    client_namespace_status/2
]).

/** <module> Public Execution Context

Thread-local execution context used to distinguish public client execution from
owner-controlled local runtime activity.
*/

:- use_module(node_profile_policy, [normalize_profile/2]).
:- use_module(actors, []).
:- use_module(library(error)).

:- thread_local current_public_execution_profile_local/1.
:- thread_local current_public_execution_namespace_local/1.

:- meta_predicate
    with_public_execution_context(+, +, 0),
    with_public_execution_profile(+, 0),
    with_public_execution_namespace(+, 0),
    without_public_execution_context(0).


%!  with_public_execution_context(+Profile, +Namespace, :Goal) is det.
with_public_execution_context(Profile, Namespace, Goal) :-
    with_public_execution_profile(
        Profile,
        with_public_execution_namespace(Namespace, Goal)
    ).


%!  with_public_execution_profile(+Profile, :Goal) is det.
with_public_execution_profile(Profile0, Goal) :-
    normalize_profile(Profile0, Profile),
    setup_call_cleanup(
        asserta(current_public_execution_profile_local(Profile), Ref),
        Goal,
        erase(Ref)
    ).


%!  with_public_execution_namespace(+Namespace, :Goal) is det.
with_public_execution_namespace(Namespace, Goal) :-
    setup_call_cleanup(
        asserta(current_public_execution_namespace_local(Namespace), Ref),
        Goal,
        erase(Ref)
    ).


%!  without_public_execution_context(:Goal) is det.
without_public_execution_context(Goal) :-
    setup_call_cleanup(
        (   asserta(current_public_execution_profile_local('$suppressed'),
                    ProfileRef),
            asserta(current_public_execution_namespace_local('$suppressed'),
                    NamespaceRef)
        ),
        Goal,
        (   erase(NamespaceRef),
            erase(ProfileRef)
        )
    ).


%!  current_public_execution_profile(-Profile) is semidet.
current_public_execution_profile(Profile) :-
    current_public_execution_profile_local(Value),
    !,
    Value \== '$suppressed',
    Profile = Value.


%!  current_public_execution_namespace(-Namespace) is semidet.
current_public_execution_namespace(Namespace) :-
    current_public_execution_namespace_local(Value),
    !,
    Value \== '$suppressed',
    Namespace = Value.


% Runtime-only namespace admission. No per-client tombstone is needed:
% missing open namespaces reject writes; delegated closure markers live only
% until their owning connection ends. All access is under actors_registry.
:- dynamic open_namespace/1, namespace_connection/2, closed_lineage/2.
:- multifile hook_namespace_closed/1, hook_connection_closed/1.

open_client_namespace(Namespace) :-
    must_be(ground, Namespace),
    with_mutex(actors_registry,
        (open_namespace(Namespace) -> true; assertz(open_namespace(Namespace)))).

open_client_connection(Queue, Namespace) :-
    with_mutex(actors_registry,
        (open_client_namespace(Namespace), assertz(namespace_connection(Queue, Namespace)))).

close_client_namespace(Namespace) :-
    must_be(ground, Namespace),
    setup_call_cleanup(with_mutex(actors_registry,
        (   retractall(open_namespace(Namespace)),
            (Namespace = ws_lineage(Queue, Token), namespace_connection(Queue, _)
            -> (closed_lineage(Queue,Token) -> true; assertz(closed_lineage(Queue,Token)))
            ;  true),
            actors:retire_registry_namespace(Namespace),
            forall(hook_namespace_closed(Namespace),true)
        )), true, true).

close_client_connection(Queue) :-
    setup_call_cleanup(with_mutex(actors_registry,
        (   forall(retract(namespace_connection(Queue, Namespace)),
                   close_client_namespace(Namespace)),
            actors:retire_registry_namespace(ws_lineage(Queue, _)),
            retractall(closed_lineage(Queue, _)),
            forall(hook_connection_closed(Queue),true)
        )), true, true).

client_namespace_status(Namespace, Status) :-
    managed_namespace(Namespace),
    (   namespace_is_open(Namespace) -> Status = open; Status = closed).
managed_namespace(ws_client(_)).
managed_namespace(isotope_session(_)).
managed_namespace(ws_lineage(_, _)).
namespace_is_open(ws_lineage(Queue, Token)) :-
    namespace_connection(Queue, _), \+ closed_lineage(Queue, Token).
namespace_is_open(ws_client(Id)) :- open_namespace(ws_client(Id)).
namespace_is_open(isotope_session(Id)) :- open_namespace(isotope_session(Id)).
