:- module(node_isotope_options, [
    isotope_spawn_options/6
]).

/** <module> ISOTOPE Spawn Option Parsing

Parse and normalize spawn options for ISOTOPE endpoints.
*/

:- use_module(rpc, [text_to_string/2]).
:- use_module(node_input_limits, [
    check_term_text_size/2,
    check_source_text_size/2
]).
:- use_module(node_sandbox, [
    sandbox_prepare_source_options/4
]).
:- use_module(node_auth, [require_source_options_access/2]).

:- use_module(library(error)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_parameters)).


%!  isotope_spawn_options(+Request, +Principal, +EffectiveProfile, -SpawnOptions,
%!                        -InitialLoadText, -TraceEnabled) is det.
%
%   Parse spawn options from JSON POST body or query parameters.
%   Ensures `session(true)` is always set. Shared DB and actor I/O are
%   provided by the actor module setup path.
isotope_spawn_options(Request, Principal, EffectiveProfile, SpawnOptions, InitialLoadText,
                      TraceEnabled) :-
    (   memberchk(method(post), Request),
        catch(http_read_json_dict(Request, Dict), _, fail)
    ->  spawn_options_from_dict(Dict, SpawnOptions0, ExplicitLoadText, TraceEnabled)
    ;   spawn_options_from_query(Request, SpawnOptions0, ExplicitLoadText, TraceEnabled)
    ),
    require_source_options_access(Principal, SpawnOptions0),
    sandbox_prepare_source_options(EffectiveProfile, node_isotope_controller,
                                   SpawnOptions0, PreparedSpawnOptions),
    infer_initial_load_text(PreparedSpawnOptions, ExplicitLoadText, InitialLoadText),
    enforce_session_option(PreparedSpawnOptions, SpawnOptions).


%!  spawn_options_from_query(+Request, -SpawnOptions, -LoadText, -TraceEnabled) is det.
spawn_options_from_query(Request, SpawnOptions, LoadText, TraceEnabled) :-
    http_parameters(Request, [
        options(OptionsAtom, [atom, default('[]')]),
        load_text(LoadText0, [default('')]),
        statechart_trace(StatechartTrace0, [atom, default('')]),
        trace(LegacyTrace0, [atom, default('')])
    ]),
    check_term_text_size(options, OptionsAtom),
    parse_spawn_options_atom(OptionsAtom, SpawnOptions0),
    text_to_string(LoadText0, LoadText),
    check_source_text_size(load_text, LoadText),
    pick_trace_value(StatechartTrace0, LegacyTrace0, TraceRaw),
    parse_trace_value(TraceRaw, TraceEnabled),
    maybe_add_load_text(LoadText, SpawnOptions0, SpawnOptions).


%!  pick_trace_value(+StatechartTrace, +LegacyTrace, -Chosen) is det.
%
%   Prefer the new `statechart_trace` field; fall back to legacy `trace`.
%   Empty atom means "not supplied".  When neither is supplied, default to
%   `false`.
pick_trace_value('', '', false) :- !.
pick_trace_value('', Legacy, Legacy) :- !.
pick_trace_value(Statechart, _, Statechart).


%!  spawn_options_from_dict(+Dict, -SpawnOptions, -LoadText, -TraceEnabled) is det.
spawn_options_from_dict(Dict, SpawnOptions, LoadText, TraceEnabled) :-
    (   get_dict(options, Dict, OptionsValue)
    ->  parse_spawn_options_value(OptionsValue, SpawnOptions0)
    ;   SpawnOptions0 = []
    ),
    (   get_dict(statechart_trace, Dict, TraceValue)
    ->  parse_trace_value(TraceValue, TraceEnabled)
    ;   get_dict(trace, Dict, TraceValue)
    ->  parse_trace_value(TraceValue, TraceEnabled)
    ;   TraceEnabled = false
    ),
    (   get_dict(load_text, Dict, LoadTextValue)
    ->  text_to_string(LoadTextValue, LoadText),
        check_source_text_size(load_text, LoadText),
        maybe_add_load_text(LoadText, SpawnOptions0, SpawnOptions)
    ;   LoadText = '',
        SpawnOptions = SpawnOptions0
    ).


%!  infer_initial_load_text(+SpawnOptions, +ExplicitLoadText,
%!                          -InitialLoadText) is det.
infer_initial_load_text(_, ExplicitLoadText, ExplicitLoadText) :-
    ExplicitLoadText \== '',
    !.
infer_initial_load_text(SpawnOptions, '', InitialLoadText) :-
    (   member(load_text(LoadText0), SpawnOptions)
    ->  text_to_string(LoadText0, InitialLoadText)
    ;   InitialLoadText = ''
    ).


%!  parse_spawn_options_value(+Value, -SpawnOptions:list) is det.
parse_spawn_options_value(SpawnOptions, SpawnOptions) :-
    is_list(SpawnOptions),
    !.
parse_spawn_options_value(OptionsAtom, SpawnOptions) :-
    atom(OptionsAtom),
    !,
    check_term_text_size(options, OptionsAtom),
    parse_spawn_options_atom(OptionsAtom, SpawnOptions).
parse_spawn_options_value(OptionsString, SpawnOptions) :-
    string(OptionsString),
    !,
    check_term_text_size(options, OptionsString),
    atom_string(OptionsAtom, OptionsString),
    parse_spawn_options_atom(OptionsAtom, SpawnOptions).
parse_spawn_options_value(Value, _) :-
    throw(error(type_error(isotope_spawn_options, Value),
                context(node:parse_spawn_options_value/2,
                        'options must be list, atom, or string'))).


%!  parse_spawn_options_atom(+OptionsAtom, -SpawnOptions:list) is det.
parse_spawn_options_atom(OptionsAtom, SpawnOptions) :-
    read_term_from_atom(OptionsAtom, SpawnOptions, []),
    must_be(list, SpawnOptions).


%!  maybe_add_load_text(+LoadText, +SpawnOptions0, -SpawnOptions) is det.
maybe_add_load_text('', SpawnOptions, SpawnOptions) :-
    !.
maybe_add_load_text(LoadText, SpawnOptions0, [load_text(LoadText)|SpawnOptions0]).


%!  enforce_session_option(+SpawnOptions0, -SpawnOptions) is det.
%
%   Replace any existing `session(_)` option with `session(true)`.
enforce_session_option(SpawnOptions0, [session(true)|SpawnOptions]) :-
    exclude(is_session_option, SpawnOptions0, SpawnOptions).

is_session_option(session(_)).


%  Canonical Prolog booleans.
parse_trace_value(true, true) :- !.
parse_trace_value(false, false) :- !.
%  JSON-decoded booleans from http_json.
parse_trace_value(@(true), true) :- !.
parse_trace_value(@(false), false) :- !.
%  Textual forms (atom or string): case-fold, then match.  Earlier
%  versions of this clause recursed back into parse_trace_value/2 with
%  another string, which made parse_trace_value("true", _) loop
%  forever because string_lower of an already-lowercased string is
%  the same string.  Test
%  tests/statechart_trace_options_tests.plt :: parse_string_true
%  pins the non-looping behavior.
parse_trace_value(Value0, Value) :-
    (   atom(Value0)
    ->  atom_string(Value0, S0)
    ;   string(Value0)
    ->  S0 = Value0
    ;   fail
    ),
    !,
    string_lower(S0, Lowered),
    (   Lowered == "true"
    ->  Value = true
    ;   Lowered == "false"
    ->  Value = false
    ;   throw(error(domain_error(boolean, Value0),
                    context(node_isotope_options:parse_trace_value/2,
                            'trace must be true or false')))
    ).
parse_trace_value(Value, _) :-
    throw(error(domain_error(boolean, Value),
                context(node_isotope_options:parse_trace_value/2,
                        'trace must be true or false'))).
