:- module(node_execution_context, [
    with_public_execution_context/3,
    with_public_execution_profile/2,
    with_public_execution_namespace/2,
    without_public_execution_context/1,
    current_public_execution_profile/1,
    current_public_execution_namespace/1
]).

/** <module> Public Execution Context

Thread-local execution context used to distinguish public client execution from
owner-controlled local runtime activity.
*/

:- use_module(node_profile_policy, [normalize_profile/2]).

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
    findall(Profile,
            current_public_execution_profile_local(Profile),
            Profiles0),
    findall(Namespace,
            current_public_execution_namespace_local(Namespace),
            Namespaces0),
    retractall(current_public_execution_profile_local(_)),
    retractall(current_public_execution_namespace_local(_)),
    setup_call_cleanup(
        true,
        Goal,
        (
            restore_public_execution_profiles(Profiles0),
            restore_public_execution_namespaces(Namespaces0)
        )
    ).

restore_public_execution_profiles(Profiles0) :-
    reverse(Profiles0, Profiles),
    forall(member(Profile, Profiles),
           asserta(current_public_execution_profile_local(Profile), _)).

restore_public_execution_namespaces(Namespaces0) :-
    reverse(Namespaces0, Namespaces),
    forall(member(Namespace, Namespaces),
           asserta(current_public_execution_namespace_local(Namespace), _)).


%!  current_public_execution_profile(-Profile) is semidet.
current_public_execution_profile(Profile) :-
    current_public_execution_profile_local(Profile),
    !.


%!  current_public_execution_namespace(-Namespace) is semidet.
current_public_execution_namespace(Namespace) :-
    current_public_execution_namespace_local(Namespace),
    !.
