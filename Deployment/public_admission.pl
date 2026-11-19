% Public execution entry budgets. Resource/concurrency ceilings are separate.
:- module(public_admission, [public_admission_options/1]).

public_admission_options([rate_window_seconds(Window),
                          max_call_requests_per_window(Calls),
                          max_session_spawns_per_window(Spawns)]) :-
    admission_integer('WP_RATE_WINDOW_SECONDS', 60, Window),
    admission_integer('WP_MAX_CALLS_PER_WINDOW', 120, Calls),
    admission_integer('WP_MAX_SPAWNS_PER_WINDOW', 120, Spawns).

admission_integer(Name, Default, Value) :-
    ( getenv(Name, Text), Text \== '' ->
        ( catch(atom_number(Text, Number), _, fail), integer(Number), Number > 0
        -> Value = Number
        ; throw(error(domain_error(positive_integer_environment, Name-Text),
                      public_admission_options/1)) )
    ; Value = Default ).
