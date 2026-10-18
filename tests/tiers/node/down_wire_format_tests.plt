/*  Wire-format tests for down/3 standardization.

    Background: prior to this change, the WS layer downgraded the
    canonical 3-arity down(Pid, Ref, Reason) message (manual.html:210/231)
    to 2-arity down(Pid, Reason) before JSON serialization, and a parallel
    2-arity producer/consumer convention had grown inside node_ws.pl.  The
    project standardized on down/3 everywhere; these tests pin the wire
    format so the standardization is not silently reverted.
*/

:- use_module('../../../prolog/web_prolog/node_response.pl', [answer_to_json/2]).
:- use_module('../../../prolog/web_prolog/actor_api.pl', [op(200, xfx, @)]).

:- use_module(library(plunit)).

:- begin_tests(down_wire_format).

test(down3_includes_pid_ref_reason) :-
    answer_to_json(down(123, my_ref, normal), JSON),
    assertion(JSON.type == down),
    assertion(JSON.ref == my_ref),
    assertion(JSON.pid == 123),
    %  Reason is term-stringified.
    assertion(string(JSON.reason)).

test(down3_compound_pid_normalized) :-
    answer_to_json(down(456@'https://example.test',
                        my_ref,
                        kill), JSON),
    %  Compound pids must serialize to strings (atom_json_dict can't
    %  serialize compound terms directly).
    assertion((atom(JSON.pid) ; string(JSON.pid))),
    assertion(JSON.ref == my_ref).

test(down2_legacy_fallback_still_works) :-
    %  The legacy 2-arity producer path is kept as a fallback during
    %  transition; verify it still produces a valid down event.
    answer_to_json(down(789, terminated), JSON),
    assertion(JSON.type == down),
    assertion(JSON.pid == 789),
    assertion(string(JSON.reason)),
    %  No ref field in the legacy shape.
    assertion(\+ get_dict(ref, JSON, _)).


% A reference is an opaque term, even if it has the shape of a local pid.
with_reference_wire_node(Goal) :-
    setup_call_cleanup(
        assertz(node_runtime_state:node_runtime(-77123,
                    _{url:'http://monitor.test:3053'}), Runtime),
        node_runtime_state:with_node_port_context(-77123, Goal),
        erase(Runtime)).
:- meta_predicate with_reference_wire_node(0).

test(local_pid_shaped_ref_preserves_node) :-
    with_reference_wire_node((
        Ref = 123@'http://monitor.test:3053',
        answer_to_json(down(Ref, Ref, kill), JSON),
        assertion(JSON.pid == 123),
        assertion(atom(JSON.ref)),
        read_term_from_atom(JSON.ref, Restored, [module(node_response)]),
        assertion(Restored == Ref),
        assertion(JSON.reason == "kill")
    )).

test(reference_node_is_not_normalized) :-
    with_reference_wire_node((
        Ref = 123@'http://monitor.test:3053/',
        answer_to_json(down(Ref, Ref, true), JSON),
        assertion(JSON.pid == 123),
        read_term_from_atom(JSON.ref, Restored, [module(node_response)]),
        assertion(Restored == Ref)
    )).

test(nonlocal_pid_serialization_unchanged) :-
    with_reference_wire_node((
        Pid = 456@'http://another.test:3053',
        answer_to_json(down(Pid, 789, false), JSON),
        read_term_from_atom(JSON.pid, Restored, [module(node_response)]),
        assertion(Restored == Pid),
        assertion(JSON.ref == 789),
        assertion(JSON.reason == "false")
    )).

test(ordinary_integer_and_atom_refs_unchanged) :-
    forall(member(Ref, [0,123,-123,my_ref,"string_ref"]),
           (answer_to_json(down(456, Ref, true), JSON),
            assertion(JSON.ref == Ref))).

test(large_integer_refs_remain_exact) :-
    forall(member(Ref, [9007199254740992,-9007199254740992]),
           (answer_to_json(down(456, Ref, true), JSON),
            number_string(Ref, Expected),
            assertion(JSON.ref == Expected))).

test(compound_reference_roundtrips_through_json) :-
    Ref = ref('a\'b', 9007199254740993, [x,y], '$VAR'(1)),
    answer_to_json(down(456, Ref, true), JSON),
    http_json:atom_json_dict(Text, JSON, []),
    http_json:atom_json_dict(Text, Decoded, []),
    term_string(Restored, Decoded.ref, [module(node_response)]),
    assertion(Restored == Ref).

:- end_tests(down_wire_format).
