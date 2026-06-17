:- module(actor_io_support, [
    actor_io_prelude_text/1,
    actor_public_guard_prelude_text/1
]).

/** <module> Actor I/O Prelude Support (layer 1)

Source text injected into actor modules to redirect standard textual
I/O predicates through the actor I/O channel (terminal_output/2,
input/2).  The injected clauses reference the `actors` and `isolation`
modules by name; this is call-time data, not a load-time dependency.
*/

actor_io_prelude_text(Text) :-
    atomics_to_string([
        ":- redefine_system_predicate(nl).\n",
        ":- redefine_system_predicate(write(_)).\n",
        ":- redefine_system_predicate(writeq(_)).\n",
        ":- redefine_system_predicate(write_term(_,_)).\n",
        ":- redefine_system_predicate(writeln(_)).\n",
        ":- redefine_system_predicate(print(_)).\n",
        ":- redefine_system_predicate(display(_)).\n",
        ":- redefine_system_predicate(write_canonical(_)).\n",
        ":- redefine_system_predicate(format(_)).\n",
        ":- redefine_system_predicate(format(_,_)).\n",
        ":- redefine_system_predicate(read(_)).\n",
        ":- redefine_system_predicate(time(_)).\n",
        ":- redefine_system_predicate(listing).\n",
        ":- redefine_system_predicate(listing(_)).\n",
        ":- meta_predicate time(0).\n",
        "nl :-\n",
        "    actors:terminal_output(\"\\n\", [source(io)]).\n",
        "write(Term) :-\n",
        "    actors:terminal_output(Term, [source(io)]).\n",
        "writeq(Term) :-\n",
        "    system:format(string(String), '~q', [Term]),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "write_term(Term, Options) :-\n",
        "    system:format(string(String), '~W', [Term, Options]),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "writeln(Term) :-\n",
        "    actors:terminal_output(Term, [source(io)]).\n",
        "print(Term) :-\n",
        "    system:format(string(String), '~p', [Term]),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "display(Term) :-\n",
        "    system:format(string(String), '~W', [Term, [quoted(true), ignore_ops(true)]]),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "write_canonical(Term) :-\n",
        "    system:format(string(String), '~k', [Term]),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "format(Format) :-\n",
        "    reject_format_call_specifier(Format),\n",
        "    system:format(string(String), Format, []),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "format(Format, Args) :-\n",
        "    reject_format_call_specifier(Format),\n",
        "    system:format(string(String), Format, Args),\n",
        "    actors:terminal_output(String, [source(io)]).\n",
        "read(Term) :-\n",
        "    actors:input('|:', Term).\n",
        "reject_format_call_specifier(Format) :-\n",
        "    format_to_atom_safe(Format, Atom),\n",
        "    (   sub_atom(Atom, _, 2, _, '~@')\n",
        "    ->  throw(error(permission_error(use, format_specifier, '~@'),\n",
        "                    context(format/2, 'the ~@ format specifier is disabled for security')))\n",
        "    ;   true\n",
        "    ).\n",
        "format_to_atom_safe(Format, Atom) :-\n",
        "    (   atom(Format)\n",
        "    ->  Atom = Format\n",
        "    ;   string(Format)\n",
        "    ->  atom_string(Atom, Format)\n",
        "    ;   is_list(Format)\n",
        "    ->  catch(atom_codes(Atom, Format), _, Atom = '')\n",
        "    ;   Atom = ''\n",
        "    ).\n",
        "time(Goal) :-\n",
        "    system:call_time(Goal, Time, Result),\n",
        "    actor_time_output(Time),\n",
        "    call(Result).\n",
        "actor_time_output(Time) :-\n",
        "    actor_time_string(Time, String),\n",
        "    actors:terminal_output(timing_report(String), [source(io)]).\n",
        "actor_time_string(Time, String) :-\n",
        "    get_dict(inferences, Time, Inferences0),\n",
        "    get_dict(wall, Time, Wall0),\n",
        "    Inferences is max(0, Inferences0),\n",
        "    Wall is max(0.0, Wall0),\n",
        "    system:format(string(String), '% ~D inferences in ~3f seconds', [Inferences, Wall]).\n",
        "listing :-\n",
        "    isolation:listing_private.\n",
        "listing(Pid) :-\n",
        "    isolation:listing_private(Pid).\n"
    ], "", Text).

actor_public_guard_prelude_text(Text) :-
    atomics_to_string([
        "'$parent'(_) :-\n",
        "    throw(error(existence_error(procedure, '$parent'/1), _)).\n"
    ], "", Text).
