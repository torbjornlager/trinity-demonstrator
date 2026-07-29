:- module(actor_io_template,
   [ nl/0,
     write/1,
     writeq/1,
     write_term/2,
     writeln/1,
     print/1,
     display/1,
     write_canonical/1,
     format/1,
     format/2,
     read/1,
     time/1,
     listing/0,
     listing/1
   ]).

/** <module> Precompiled actor I/O template

This module avoids compiling the actor I/O prelude in every private actor
module.  Its exported predicates have the same behaviour as the generated
prelude in actor_io_support.  Actor-specific state remains outside this
module: output, input, and private listing are resolved from the calling
actor's pid at run time.

The isolation layer imports this module by default.  The former generated
prelude remains available through the internal `isolation_io(generated)` spawn
option as a compatibility and benchmarking path.
*/

:- redefine_system_predicate(nl).
:- redefine_system_predicate(write(_)).
:- redefine_system_predicate(writeq(_)).
:- redefine_system_predicate(write_term(_,_)).
:- redefine_system_predicate(writeln(_)).
:- redefine_system_predicate(print(_)).
:- redefine_system_predicate(display(_)).
:- redefine_system_predicate(write_canonical(_)).
:- redefine_system_predicate(format(_)).
:- redefine_system_predicate(format(_,_)).
:- redefine_system_predicate(read(_)).
:- redefine_system_predicate(time(_)).
:- redefine_system_predicate(listing).
:- redefine_system_predicate(listing(_)).

:- meta_predicate time(0).

nl :-
    actors:terminal_output("\n", [source(io)]).

write(Term) :-
    actors:terminal_output(Term, [source(io)]).

writeq(Term) :-
    system:format(string(String), '~q', [Term]),
    actors:terminal_output(String, [source(io)]).

write_term(Term, Options) :-
    system:format(string(String), '~W', [Term, Options]),
    actors:terminal_output(String, [source(io)]).

writeln(Term) :-
    actors:terminal_output(Term, [source(io)]).

print(Term) :-
    system:format(string(String), '~p', [Term]),
    actors:terminal_output(String, [source(io)]).

display(Term) :-
    system:format(string(String), '~W',
                  [Term, [quoted(true), ignore_ops(true)]]),
    actors:terminal_output(String, [source(io)]).

write_canonical(Term) :-
    system:format(string(String), '~k', [Term]),
    actors:terminal_output(String, [source(io)]).

format(Format) :-
    reject_format_call_specifier(Format),
    system:format(string(String), Format, []),
    actors:terminal_output(String, [source(io)]).

format(Format, Args) :-
    reject_format_call_specifier(Format),
    system:format(string(String), Format, Args),
    actors:terminal_output(String, [source(io)]).

read(Term) :-
    actors:input('|:', Term).

reject_format_call_specifier(Format) :-
    format_to_atom_safe(Format, Atom),
    (   sub_atom(Atom, _, 2, _, '~@')
    ->  throw(error(permission_error(use, format_specifier, '~@'),
                    context(format/2,
                            'the ~@ format specifier is disabled for security')))
    ;   true
    ).

format_to_atom_safe(Format, Atom) :-
    (   atom(Format)
    ->  Atom = Format
    ;   string(Format)
    ->  atom_string(Atom, Format)
    ;   is_list(Format)
    ->  catch(atom_codes(Atom, Format), _, Atom = '')
    ;   Atom = ''
    ).

time(Goal) :-
    system:call_time(Goal, Time, Result),
    actor_time_output(Time),
    call(Result).

actor_time_output(Time) :-
    actor_time_string(Time, String),
    actors:terminal_output(timing_report(String), [source(io)]).

actor_time_string(Time, String) :-
    get_dict(inferences, Time, Inferences0),
    get_dict(wall, Time, Wall0),
    Inferences is max(0, Inferences0),
    Wall is max(0.0, Wall0),
    system:format(string(String), '% ~D inferences in ~3f seconds',
                  [Inferences, Wall]).

listing :-
    isolation:listing_private.

listing(What) :-
    isolation:listing_private(What).
