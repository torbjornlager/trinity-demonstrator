:- module(dollar_expansion, [
    expand_dollar_vars/3,
    capture_answer_bindings/1,
    session_bindings/2,
    clear_session_bindings/1
]).

/** <module> Dollar Variable Expansion

Shell-level variable substitution: if a variable name in a query is prefixed
with `$`, the shell replaces it with that variable's most recent binding.

Example session:

==
?- self(Self).
Self = 85234512.
?- $Self ! hello.
true.
==

Here `$Self` is expanded to `85234512` before the query is parsed.

The module provides:

  - expand_dollar_vars/3  — text-level `$Var` substitution
  - capture_answer_bindings/1 — extract and remember bindings from success events
  - session_bindings/2 — retrieve stored bindings for a session pid
  - clear_session_bindings/1 — cleanup on session teardown
*/

:- use_module(term_display, [term_to_display_string/3]).


                /*******************************
                *       BINDING STORAGE        *
                *******************************/

%   session_last_bindings(Pid, Pairs)
%   Pairs is a list of Name-Value where Name is an atom (variable name)
%   and Value is the Prolog term it was bound to.
:- dynamic session_last_bindings/2.

%!  capture_answer_bindings(+Answer) is det.
%
%   If Answer is a `success(Pid, Slice, _More)` whose first row is a dict,
%   extract named variable bindings and merge them into the session store.
%   Merging uses unification so that shared variables in existing bindings
%   (e.g. `X = f(a,B)` with B unbound) are automatically updated when the
%   new result binds those variables (e.g. `B = b` makes X become `f(a,b)`).
%   Harmless no-op for non-success answers.
capture_answer_bindings(success(Pid, [Row|_], _)) :-
    is_dict(Row),
    !,
    dict_pairs(Row, _, NewPairs0),
    copy_term(NewPairs0, NewPairs),
    (   retract(session_last_bindings(Pid, OldPairs))
    ->  merge_session_bindings(OldPairs, NewPairs, MergedPairs)
    ;   MergedPairs = NewPairs
    ),
    assertz(session_last_bindings(Pid, MergedPairs)).
capture_answer_bindings(_).

%!  merge_session_bindings(+OldPairs, +NewPairs, -MergedPairs) is det.
%
%   Fold NewPairs into OldPairs.  For each new Name-Value pair, if Name
%   already appears in OldPairs, unify the stored (possibly unbound)
%   variable with the new value so that any terms containing that
%   variable are updated automatically, then replace the entry.
%   New names not yet in OldPairs are appended.
merge_session_bindings(OldPairs, NewPairs, MergedPairs) :-
    foldl(merge_one_binding, NewPairs, OldPairs, MergedPairs).

merge_one_binding(Name-NewVal, Pairs0, Pairs) :-
    (   select(Name-OldVal, Pairs0, Rest)
    ->  copy_term(NewVal, MergeVal),
        ignore(OldVal = MergeVal),
        Pairs = [Name-NewVal|Rest]
    ;   Pairs = [Name-NewVal|Pairs0]
    ).

%!  session_bindings(+Pid, -Pairs:list) is det.
%
%   Retrieve the most recently stored bindings for session Pid.
%   Returns `[]` when no bindings have been captured yet.
session_bindings(Pid, Pairs) :-
    session_last_bindings(Pid, Pairs),
    !.
session_bindings(_, []).

%!  clear_session_bindings(+Pid) is det.
%
%   Remove stored bindings for a session.
clear_session_bindings(Pid) :-
    retractall(session_last_bindings(Pid, _)).


                /*******************************
                *        TEXT EXPANSION        *
                *******************************/

%!  expand_dollar_vars(+Text0, +Bindings, -Text) is det.
%
%   Replace every `$VarName` token in Text0 with the corresponding value
%   from Bindings.  Bindings is a list of `Name-Value` or `Name=Value`
%   pairs.  Unmatched `$VarName` tokens are left verbatim.
%
%   VarName must follow Prolog variable conventions: start with an
%   uppercase letter or underscore, followed by alphanumeric/underscore.
%
%   The output preserves the type of the input (atom in → atom out,
%   string in → string out).
expand_dollar_vars(Text0, [], Text) :-
    !,
    Text = Text0.
expand_dollar_vars(Text0, Bindings, Text) :-
    (   atom(Text0)
    ->  atom_string(Text0, S0)
    ;   S0 = Text0
    ),
    string_codes(S0, Codes0),
    expand_codes(Codes0, Bindings, Codes),
    string_codes(S, Codes),
    (   atom(Text0)
    ->  atom_string(Text, S)
    ;   Text = S
    ).

%!  expand_codes(+Codes0, +Bindings, -Codes) is det.
%
%   Expand only in actual Prolog code. Quoted atoms/strings and comments are
%   copied verbatim so shell-style `$Var` substitution does not leak into
%   payload text such as XML source.
expand_codes([], _, []).
expand_codes([Quote|Rest0], Bindings, [Quote|Rest]) :-
    quote_char(Quote),
    !,
    take_quoted(Quote, Rest0, QuotedTail, After),
    append(QuotedTail, ExpandedAfter, Rest),
    expand_codes(After, Bindings, ExpandedAfter).
expand_codes([0'%|Rest0], Bindings, [0'%|Rest]) :-
    !,
    take_line_comment(Rest0, CommentTail, After),
    append(CommentTail, ExpandedAfter, Rest),
    expand_codes(After, Bindings, ExpandedAfter).
expand_codes([0'/,0'*|Rest0], Bindings, [0'/,0'*|Rest]) :-
    !,
    take_block_comment(Rest0, CommentTail, After),
    append(CommentTail, ExpandedAfter, Rest),
    expand_codes(After, Bindings, ExpandedAfter).
expand_codes([0'$|Rest0], Bindings, Result) :-
    var_name_codes(Rest0, NameCodes, After),
    NameCodes \== [],
    atom_codes(VarName, NameCodes),
    lookup_binding(VarName, Bindings, Value),
    !,
    bindings_to_var_names(Bindings, VarNames),
    term_to_display_string(Value, VarNames, ValueString),
    atom_string(ValueAtom, ValueString),
    atom_codes(ValueAtom, ValueCodes),
    append(ValueCodes, ExpandedAfter, Result),
    expand_codes(After, Bindings, ExpandedAfter).
expand_codes([C|Rest0], Bindings, [C|Rest]) :-
    expand_codes(Rest0, Bindings, Rest).

quote_char(0'').
quote_char(0'").
quote_char(0'`).

take_quoted(Quote, Codes0, Quoted, Rest) :-
    take_quoted_(Codes0, Quote, Quoted, Rest).

take_quoted_([], _Quote, [], []).
take_quoted_([0'\\, C|Codes0], Quote, [0'\\, C|Quoted], Rest) :-
    !,
    take_quoted_(Codes0, Quote, Quoted, Rest).
take_quoted_([Quote, Quote|Codes0], Quote, [Quote, Quote|Quoted], Rest) :-
    !,
    take_quoted_(Codes0, Quote, Quoted, Rest).
take_quoted_([Quote|Codes0], Quote, [Quote], Codes0) :-
    !.
take_quoted_([C|Codes0], Quote, [C|Quoted], Rest) :-
    take_quoted_(Codes0, Quote, Quoted, Rest).

take_line_comment([], [], []).
take_line_comment([C|Codes0], [C|Comment], Rest) :-
    line_ending_char(C),
    !,
    Rest = Codes0,
    Comment = [].
take_line_comment([C|Codes0], [C|Comment], Rest) :-
    take_line_comment(Codes0, Comment, Rest).

take_block_comment([], [], []).
take_block_comment([0'*,0'/|Codes0], [0'*,0'/], Codes0) :-
    !.
take_block_comment([C|Codes0], [C|Comment], Rest) :-
    take_block_comment(Codes0, Comment, Rest).

line_ending_char(0'\n).
line_ending_char(0'\r).

%!  bindings_to_var_names(+Bindings, -VarNames) is det.
%
%   Convert Name-Value or Name=Value binding pairs to the `Name=Value`
%   list expected by write_term's `variable_names` option.  Entries
%   where Value is not an unbound variable are included harmlessly;
%   write_term simply ignores them.
bindings_to_var_names(Bindings, VarNames) :-
    maplist(binding_to_var_name, Bindings, VarNames).

binding_to_var_name(Name-Value, Name=Value) :- !.
binding_to_var_name(Name=Value, Name=Value).


                /*******************************
                *       NAME PARSING           *
                *******************************/

%!  var_name_codes(+Codes, -NameCodes, -Rest) is det.
%
%   Extract leading Prolog variable name characters from Codes.
var_name_codes([C|Rest], [C|NameRest], After) :-
    var_start_char(C),
    !,
    var_continue_codes(Rest, NameRest, After).
var_name_codes(Rest, [], Rest).

var_continue_codes([C|Rest], [C|NameRest], After) :-
    var_continue_char(C),
    !,
    var_continue_codes(Rest, NameRest, After).
var_continue_codes(Rest, [], Rest).

var_start_char(C) :- C >= 0'A, C =< 0'Z.
var_start_char(0'_).

var_continue_char(C) :- C >= 0'A, C =< 0'Z.
var_continue_char(C) :- C >= 0'a, C =< 0'z.
var_continue_char(C) :- C >= 0'0, C =< 0'9.
var_continue_char(0'_).


                /*******************************
                *       BINDING LOOKUP         *
                *******************************/

%!  lookup_binding(+Name, +Bindings, -Value) is semidet.
%
%   Find the value for Name in a list of Name-Value or Name=Value pairs.
lookup_binding(Name, Bindings, Value) :-
    member(Name-Value, Bindings),
    !.
lookup_binding(Name, Bindings, Value) :-
    member(Name=Value, Bindings),
    !.
