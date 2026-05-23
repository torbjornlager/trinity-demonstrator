:- module(node_input_limits, [
    normalize_max_term_text_bytes/2,
    normalize_max_load_text_bytes/2,
    normalize_max_ws_frame_bytes/2,
    normalize_max_admin_json_bytes/2,
    current_max_term_text_bytes/1,
    current_max_load_text_bytes/1,
    current_max_ws_frame_bytes/1,
    current_max_admin_json_bytes/1,
    check_term_text_size/2,
    check_source_text_size/2,
    check_ws_frame_size/1,
    check_admin_json_size/1
]).

/** <module> Node Input Size Limits

Per-node limits for textual input sizes. These checks are orthogonal to
authorization, profile enforcement, and sandboxing: they reject oversized
payloads before parsing or execution.
*/

:- use_module(library(settings)).
:- use_module(library(utf8)).

:- use_module(node_client, [text_to_string/2]).
:- use_module(node_limit_helpers, [
    current_limit_value/4,
    normalize_positive_integer_limit/5
]).

:- setting(max_term_text_bytes, integer, 32768,
           'Max UTF-8 size of one textual Prolog term input').
:- setting(max_load_text_bytes, integer, 262144,
           'Max UTF-8 size of one load_text source payload').
:- setting(max_ws_frame_bytes, integer, 262144,
           'Max UTF-8 size of one inbound WebSocket text frame').
:- setting(max_admin_json_bytes, integer, 65536,
           'Max UTF-8 size of one admin JSON request body').


%!  normalize_max_term_text_bytes(+Value0, -Value) is det.
normalize_max_term_text_bytes(Value0, Value) :-
    normalize_positive_integer_limit(max_term_text_bytes, Value0, Value,
                                     node_input_limits:normalize_max_term_text_bytes/2,
                                     'max_term_text_bytes must be a positive integer').


%!  normalize_max_load_text_bytes(+Value0, -Value) is det.
normalize_max_load_text_bytes(Value0, Value) :-
    normalize_positive_integer_limit(max_load_text_bytes, Value0, Value,
                                     node_input_limits:normalize_max_load_text_bytes/2,
                                     'max_load_text_bytes must be a positive integer').


%!  normalize_max_ws_frame_bytes(+Value0, -Value) is det.
normalize_max_ws_frame_bytes(Value0, Value) :-
    normalize_positive_integer_limit(max_ws_frame_bytes, Value0, Value,
                                     node_input_limits:normalize_max_ws_frame_bytes/2,
                                     'max_ws_frame_bytes must be a positive integer').


%!  normalize_max_admin_json_bytes(+Value0, -Value) is det.
normalize_max_admin_json_bytes(Value0, Value) :-
    normalize_positive_integer_limit(max_admin_json_bytes, Value0, Value,
                                     node_input_limits:normalize_max_admin_json_bytes/2,
                                     'max_admin_json_bytes must be a positive integer').


%!  current_max_term_text_bytes(-Limit) is det.
current_max_term_text_bytes(Limit) :-
    current_limit_value(max_term_text_bytes,
                        normalize_max_term_text_bytes,
                        node_input_limits:max_term_text_bytes,
                        Limit).


%!  current_max_load_text_bytes(-Limit) is det.
current_max_load_text_bytes(Limit) :-
    current_limit_value(max_load_text_bytes,
                        normalize_max_load_text_bytes,
                        node_input_limits:max_load_text_bytes,
                        Limit).


%!  current_max_ws_frame_bytes(-Limit) is det.
current_max_ws_frame_bytes(Limit) :-
    current_limit_value(max_ws_frame_bytes,
                        normalize_max_ws_frame_bytes,
                        node_input_limits:max_ws_frame_bytes,
                        Limit).


%!  current_max_admin_json_bytes(-Limit) is det.
current_max_admin_json_bytes(Limit) :-
    current_limit_value(max_admin_json_bytes,
                        normalize_max_admin_json_bytes,
                        node_input_limits:max_admin_json_bytes,
                        Limit).


%!  check_term_text_size(+Field, +Text0) is det.
check_term_text_size(Field, Text0) :-
    current_max_term_text_bytes(Limit),
    check_text_size(Field, Text0, Limit,
                    node_input_limits:check_term_text_size/2,
                    'textual term input exceeded the configured size limit').


%!  check_source_text_size(+Field, +Text0) is det.
check_source_text_size(Field, Text0) :-
    current_max_load_text_bytes(Limit),
    check_text_size(Field, Text0, Limit,
                    node_input_limits:check_source_text_size/2,
                    'source text exceeded the configured size limit').


%!  check_ws_frame_size(+Text0) is det.
check_ws_frame_size(Text0) :-
    current_max_ws_frame_bytes(Limit),
    check_text_size(ws_frame, Text0, Limit,
                    node_input_limits:check_ws_frame_size/1,
                    'WebSocket frame exceeded the configured size limit').


%!  check_admin_json_size(+Text0) is det.
check_admin_json_size(Text0) :-
    current_max_admin_json_bytes(Limit),
    check_text_size(admin_json, Text0, Limit,
                    node_input_limits:check_admin_json_size/1,
                    'admin JSON body exceeded the configured size limit').

check_text_size(_Field, Text0, _Limit, _Context, _Message) :-
    text_to_string(Text0, Text),
    Text == "",
    !.
check_text_size(Field, Text0, Limit, Context, Message) :-
    utf8_text_size(Text0, Size),
    (   Size =< Limit
    ->  true
    ;   throw(error(request_size_exceeded(Field, Size, Limit),
                    context(Context, Message)))
    ).


utf8_text_size(Text0, Size) :-
    text_to_string(Text0, Text),
    string_codes(Text, Codes),
    phrase(utf8_codes(Codes), UTF8Bytes),
    length(UTF8Bytes, Size).
