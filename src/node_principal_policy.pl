:- module(node_principal_policy, [
    normalize_principal_policies/2,
    set_principal_policies/1,
    principal_policy/2,
    current_principal_policies/1,
    replace_current_principal_policies/1
]).

/** <module> Node-owned Principal Policy

Configured principal table for authenticated users.
*/

:- use_module(library(error)).

:- use_module(node_client, [text_to_string/2]).
:- use_module(node_capabilities, [
    normalize_capabilities/2,
    policy_capability_allowed/1
]).
:- use_module(node_runtime_state, [
    current_node_value/2,
    update_current_node_runtime/1
]).

:- dynamic configured_principal_policy/2.


%!  normalize_principal_policies(+Policies0, -Policies) is det.
normalize_principal_policies(Policies0, Policies) :-
    must_be(list, Policies0),
    maplist(normalize_principal_policy_info, Policies0, Policies).


%!  set_principal_policies(+Policies) is det.
set_principal_policies(Policies0) :-
    normalize_principal_policies(Policies0, Policies),
    retractall(configured_principal_policy(_, _)),
    maplist(assert_principal_policy, Policies).


%!  principal_policy(+PrincipalId, -Capabilities) is semidet.
principal_policy(PrincipalId0, Capabilities) :-
    normalize_principal_id(PrincipalId0, PrincipalId),
    (   current_node_value(principal_policies, Policies),
        member(Policy, Policies),
        get_dict(id, Policy, PrincipalId)
    ->  get_dict(capabilities, Policy, Capabilities)
    ;   configured_principal_policy(PrincipalId, Capabilities)
    ).


%!  current_principal_policies(-Policies) is det.
current_principal_policies(Policies) :-
    (   current_node_value(principal_policies, Policies0)
    ->  Policies = Policies0
    ;   findall(policy{id:PrincipalId, capabilities:Capabilities},
               configured_principal_policy(PrincipalId, Capabilities),
               Policies)
    ).


%!  replace_current_principal_policies(+Policies0) is det.
replace_current_principal_policies(Policies0) :-
    normalize_principal_policies(Policies0, Policies),
    (   current_node_value(url, _)
    ->  update_current_node_runtime(_{principal_policies:Policies})
    ;   set_principal_policies(Policies)
    ).


assert_principal_policy(Policy) :-
    get_dict(id, Policy, PrincipalId),
    get_dict(capabilities, Policy, Capabilities),
    retractall(configured_principal_policy(PrincipalId, _)),
    assertz(configured_principal_policy(PrincipalId, Capabilities)).


normalize_principal_policy_info(owner(PrincipalId0), Policy) :-
    !,
    normalize_principal_id(PrincipalId0, PrincipalId),
    Policy = policy{
        id:PrincipalId,
        capabilities:[admin, public_read]
    }.
normalize_principal_policy_info(principal(PrincipalId0, Capabilities0),
                                Policy) :-
    !,
    normalize_principal_id(PrincipalId0, PrincipalId),
    normalize_policy_capabilities(Capabilities0, Capabilities),
    Policy = policy{
        id:PrincipalId,
        capabilities:Capabilities
    }.
normalize_principal_policy_info(principal(PrincipalId0, _Capabilities0, _Profile0),
                                _) :-
    !,
    normalize_principal_id(PrincipalId0, PrincipalId),
    throw(error(domain_error(node_principal_profile, PrincipalId),
                context(node_principal_policy:set_principal_policies/1,
                        'principal-specific profiles are no longer supported; use principal(Id, Caps) and set the node profile separately'))).
normalize_principal_policy_info(Dict0, Policy) :-
    is_dict(Dict0),
    !,
    get_dict(id, Dict0, PrincipalId0),
    get_dict(capabilities, Dict0, Capabilities0),
    (   get_dict(profile, Dict0, Profile0)
    ->  normalize_principal_policy_info(principal(PrincipalId0, Capabilities0, Profile0),
                                        Policy)
    ;   normalize_principal_policy_info(principal(PrincipalId0, Capabilities0),
                                        Policy)
    ).
normalize_principal_policy_info(Policy, _) :-
    throw(error(domain_error(node_principal_policy, Policy),
                context(node_principal_policy:set_principal_policies/1,
                        'expected owner(Id) or principal(Id, Caps)'))).


normalize_principal_id(PrincipalId0, PrincipalId) :-
    text_to_string(PrincipalId0, PrincipalId),
    PrincipalId \== "",
    !.
normalize_principal_id(PrincipalId, _) :-
    throw(error(domain_error(principal_id, PrincipalId),
                context(node_principal_policy:set_principal_policies/1,
                        'principal id must be a non-empty atom or string'))).


normalize_policy_capabilities(Capabilities0, Capabilities) :-
    normalize_capabilities(Capabilities0, Capabilities1),
    maplist(require_policy_capability, Capabilities1),
    sort([public_read|Capabilities1], Capabilities).
require_policy_capability(Capability) :-
    policy_capability_allowed(Capability),
    !.
require_policy_capability(Capability) :-
    throw(error(domain_error(node_principal_policy_capability, Capability),
                context(node_principal_policy:set_principal_policies/1,
                        'principal policy capability is reserved for internal transport'))).
