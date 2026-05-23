/*  Tests for statechart_trace option parsing.

    Pins:
      - parse_trace_value/2 accepts atom, string, and JSON-boolean (@(true)/@(false)) forms.
      - spawn_options_from_dict/4 prefers the new `statechart_trace` key over the legacy `trace` key.
      - Both keys absent => default false.
*/

:- use_module('../src/node_isotope_options.pl').

:- use_module(library(plunit)).

:- begin_tests(statechart_trace_options).

%  ---------------- parse_trace_value/2 ----------------

test(parse_atom_true) :-
    node_isotope_options:parse_trace_value(true, V),
    assertion(V == true).

test(parse_atom_false) :-
    node_isotope_options:parse_trace_value(false, V),
    assertion(V == false).

test(parse_string_true) :-
    node_isotope_options:parse_trace_value("true", V),
    assertion(V == true).

test(parse_string_false) :-
    node_isotope_options:parse_trace_value("false", V),
    assertion(V == false).

test(parse_json_boolean_true) :-
    %  http_json decodes JSON `true` to the term @(true).
    node_isotope_options:parse_trace_value(@(true), V),
    assertion(V == true).

test(parse_json_boolean_false) :-
    node_isotope_options:parse_trace_value(@(false), V),
    assertion(V == false).

test(parse_bad_value_throws,
     [throws(error(domain_error(boolean, bogus), _))]) :-
    node_isotope_options:parse_trace_value(bogus, _).

%  ---------------- spawn_options_from_dict key preference ----------------

test(statechart_trace_key_used) :-
    Dict = _{statechart_trace: @(true)},
    node_isotope_options:spawn_options_from_dict(Dict, _Opts, _LoadText, TraceEnabled),
    assertion(TraceEnabled == true).

test(legacy_trace_key_fallback) :-
    %  No statechart_trace; legacy `trace` key should be honored.
    Dict = _{trace: @(true)},
    node_isotope_options:spawn_options_from_dict(Dict, _Opts, _LoadText, TraceEnabled),
    assertion(TraceEnabled == true).

test(statechart_trace_wins_over_legacy) :-
    %  Both supplied: new key wins.
    Dict = _{statechart_trace: @(false), trace: @(true)},
    node_isotope_options:spawn_options_from_dict(Dict, _Opts, _LoadText, TraceEnabled),
    assertion(TraceEnabled == false).

test(default_false_when_absent) :-
    Dict = _{},
    node_isotope_options:spawn_options_from_dict(Dict, _Opts, _LoadText, TraceEnabled),
    assertion(TraceEnabled == false).

:- end_tests(statechart_trace_options).
