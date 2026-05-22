/*  Wire-format tests for down/3 standardization.

    Background: prior to this change, the WS layer downgraded the
    canonical 3-arity down(Ref, Pid, Reason) message (manual.html:210/231)
    to 2-arity down(Pid, Reason) before JSON serialization, and a parallel
    2-arity producer/consumer convention had grown inside node_ws.pl.  The
    project standardized on down/3 everywhere; these tests pin the wire
    format so the standardization is not silently reverted.
*/

:- use_module('../node_response.pl', [answer_to_json/2]).
:- use_module('../actor.pl', [op(200, xfx, @)]).

:- use_module(library(plunit)).

:- begin_tests(down_wire_format).

test(down3_includes_ref_pid_reason) :-
    answer_to_json(down(my_ref, 123, normal), JSON),
    assertion(JSON.type == down),
    assertion(JSON.ref == my_ref),
    assertion(JSON.pid == 123),
    %  Reason is term-stringified.
    assertion(string(JSON.reason)).

test(down3_compound_pid_normalized) :-
    answer_to_json(down(456@'https://example.test',
                        456@'https://example.test',
                        kill), JSON),
    %  Compound pids must serialize to strings (atom_json_dict can't
    %  serialize compound terms directly).
    assertion((atom(JSON.pid) ; string(JSON.pid))),
    assertion((atom(JSON.ref) ; string(JSON.ref))).

test(down2_legacy_fallback_still_works) :-
    %  The legacy 2-arity producer path is kept as a fallback during
    %  transition; verify it still produces a valid down event.
    answer_to_json(down(789, terminated), JSON),
    assertion(JSON.type == down),
    assertion(JSON.pid == 789),
    assertion(string(JSON.reason)),
    %  No ref field in the legacy shape.
    assertion(\+ get_dict(ref, JSON, _)).

:- end_tests(down_wire_format).
