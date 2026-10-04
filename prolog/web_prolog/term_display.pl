:- module(term_display, [
    term_to_display_string/2,
    term_to_display_string/3
]).

/** <module> User-Facing Term Rendering

Helpers for rendering Prolog terms for browser and shell display. Variables
that are not explicitly named by the query template are rendered as anonymous
`_` placeholders so remote answers resemble the SWI-Prolog toplevel.
*/

term_to_display_string(Term, String) :-
    term_to_display_string(Term, [], String).

term_to_display_string(Term, VarNames, String) :-
    explicitly_named_vars(VarNames, NamedVars),
    term_variables(Term, Vars),
    include(var_not_named(NamedVars), Vars, AnonymousVars),
    maplist(anonymous_name, AnonymousVars, AnonymousNames),
    append(VarNames, AnonymousNames, DisplayVarNames),
    with_output_to(
        string(String),
        write_term(Term, [
            quoted(true),
            portray(false),
            numbervars(false),
            variable_names(DisplayVarNames)
        ])
    ).

%   An unnamed variable is shown as `_`.  The name is given through
%   variable_names/1 rather than by binding the variable to '$VAR'('_'),
%   so a term that really contains '$VAR'(N) is shown as that term.
anonymous_name(Var, '_'=Var).

explicitly_named_vars(VarNames, NamedVars) :-
    explicitly_named_vars_(VarNames, [], NamedVars).

explicitly_named_vars_([], NamedVars, NamedVars).
explicitly_named_vars_([Binding|Rest], NamedVars0, NamedVars) :-
    (   binding_named_var(Binding, Var)
    ->  NamedVars1 = [Var|NamedVars0]
    ;   NamedVars1 = NamedVars0
    ),
    explicitly_named_vars_(Rest, NamedVars1, NamedVars).

binding_named_var(_Name=Var, Var) :-
    var(Var),
    !.
binding_named_var(_Name-Var, Var) :-
    var(Var).

var_not_named(NamedVars, Var) :-
    \+ member_var_eq(NamedVars, Var).

member_var_eq([Candidate|_], Var) :-
    Candidate == Var,
    !.
member_var_eq([_|Rest], Var) :-
    member_var_eq(Rest, Var).
