:- module(example_text, [native_text/2, bounded_native_text/4, language_text/2]).

% Explicit application/library boundary. Numeric codes, atoms, partial lists
% and multi-character list elements are not substitutes for character text.
native_text(Text, Native) :-
    ( string(Text) -> Native=Text
    ; is_list(Text), maplist(character_atom,Text), string_chars(Native,Text)
    ).

% Check an untrusted service prompt before allocating its native string.
% The bounded walk also rejects cycles and open tails without binding them.
bounded_native_text(Text, Limit, Native, Length) :-
    ( string(Text) -> string_length(Text,Length),Length=<Limit,Native=Text
    ; bounded_chars(Text,Limit,0,Length),string_chars(Native,Text)
    ).
bounded_chars(List, Left, Count, Length) :-
    nonvar(List),
    ( List==[] -> Length=Count
    ; Left>0,List=[Char|Rest],character_atom(Char),
      Next is Left-1,N is Count+1,bounded_chars(Rest,Next,N,Length)
    ).
character_atom(Char) :- atom(Char),atom_length(Char,1).

% Standalone Jev/library users keep native strings. Only a node's explicit
% language configuration selects character lists for application text.
language_text(Native, Text) :-
    ( current_predicate(text_config:text_double_quotes/1),
      text_config:text_double_quotes(chars)
    -> string_chars(Native,Text)
    ; Text=Native
    ).
