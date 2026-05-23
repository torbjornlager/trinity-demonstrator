:- module(node_capabilities, [
    valid_capability/1,
    normalize_capability/2,
    normalize_capabilities/2,
    capability_granted/2,
    policy_capability_allowed/1
]).

/** <module> Shared Capability Helpers

Normalization and implication rules shared by node auth and principal policy.
*/

:- use_module(library(error)).


valid_capability(public_read).
valid_capability(execute).
valid_capability(source_load_server_predicates).
valid_capability(source_load_uri).
valid_capability(internal_transport).
valid_capability(admin).


%!  normalize_capability(+Capability0, -Capability) is det.
normalize_capability(Capability0, Capability) :-
    (   atom(Capability0)
    ->  Capability = Capability0
    ;   string(Capability0)
    ->  string_lower(Capability0, Lower),
        atom_string(Capability, Lower)
    ),
    valid_capability(Capability),
    !.
normalize_capability(Capability, _) :-
    throw(error(domain_error(node_capability, Capability),
                context(node_capabilities:normalize_capability/2,
                        'unknown node capability'))).


%!  normalize_capabilities(+Capabilities0, -Capabilities) is det.
normalize_capabilities(Capabilities0, Capabilities) :-
    must_be(list, Capabilities0),
    maplist(normalize_capability, Capabilities0, Capabilities1),
    sort(Capabilities1, Capabilities).


%!  policy_capability_allowed(+Capability) is semidet.
policy_capability_allowed(Capability) :-
    Capability \== internal_transport.


%!  capability_granted(+Capabilities, +Capability) is semidet.
capability_granted(Capabilities, _Capability) :-
    memberchk(admin, Capabilities),
    !.
capability_granted(Capabilities, Capability) :-
    memberchk(Capability, Capabilities).
