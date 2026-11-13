% Portable JSON values and character-list codec. No engine-specific terms.
% Objects: json([string(KeyCodes)=Value,...]); arrays: lists.
% Strings (including keys): string(Codes); literals: @(true), @(false), @(null).
% Object order and duplicate keys are preserved; get/3 returns the first match.
% This file can be loaded as ordinary client source on every node.

portable_json_chars(JSON, Chars) :-
    ( nonvar(Chars) ->
        ( ground(Chars), acyclic_term(Chars), pj_chars_codes(Chars, Codes) -> true
        ; throw(error(type_error(character_list, Chars), portable_json_chars/2)) ),
        ( phrase(pj_document(Parsed), Codes) -> JSON = Parsed
        ; throw(error(syntax_error(json), portable_json_chars/2)) )
    ; var(JSON) -> throw(error(instantiation_error, portable_json_chars/2))
    ; portable_json_value(JSON) ->
        phrase(pj_emit(JSON), Codes), pj_chars_codes(Chars, Codes)
    ; throw(error(domain_error(json_value, JSON), portable_json_chars/2))
    ).

portable_json_value(JSON) :-
    ground(JSON), acyclic_term(JSON), pj_value_valid(JSON).

portable_json_object(JSON) :-
    nonvar(JSON), JSON = json(_), portable_json_value(JSON).

portable_json_get(JSON, Key, Value) :-
    portable_json_object(JSON), ground(Key), acyclic_term(Key), pj_lookup_key(Key, Codes),
    JSON = json(Pairs), pj_first_member(string(Codes), Pairs, Value).

pj_lookup_key(string(Codes), Codes) :- !, pj_codes_valid(Codes).
pj_lookup_key(Key, Codes) :- atom(Key), !, atom_chars(Key, Chars), pj_chars_codes(Chars,Codes).
pj_lookup_key(Chars, Codes) :- pj_chars_codes(Chars,Codes).
pj_first_member(Key, [Key=First|_], Value) :- !, Value=First.
pj_first_member(Key, [_|Pairs], Value) :- pj_first_member(Key, Pairs, Value).

pj_value_valid(json(Pairs)) :- !, pj_pairs_valid(Pairs).
pj_value_valid(string(Codes)) :- !, pj_codes_valid(Codes).
pj_value_valid('@'(true)) :- !.
pj_value_valid('@'(false)) :- !.
pj_value_valid('@'(null)) :- !.
pj_value_valid(Value) :- number(Value), !, pj_number_valid(Value).
pj_value_valid(Values) :- pj_values_valid(Values).
pj_pairs_valid([]).
pj_pairs_valid([string(Codes)=Value|Pairs]) :-
    pj_codes_valid(Codes), pj_value_valid(Value), pj_pairs_valid(Pairs).
pj_values_valid([]).
pj_values_valid([Value|Values]) :- pj_value_valid(Value), pj_values_valid(Values).
pj_number_valid(Number) :-
    catch(number_codes(Number, Codes), _, fail), phrase(pj_number_token, Codes).

pj_codes_valid([]).
pj_codes_valid([Code|Codes]) :- pj_scalar(Code), pj_codes_valid(Codes).

pj_chars_codes([], []).
pj_chars_codes([Char|Chars], [Code|Codes]) :-
    ( nonvar(Char) -> atom(Char), atom_chars(Char, [_]), char_code(Char, Code)
    ; integer(Code), char_code(Char, Code) ),
    pj_scalar(Code), pj_chars_codes(Chars, Codes).
pj_scalar(Code) :- integer(Code), Code >= 0, Code =< 1114111,
    ( Code < 55296 -> true ; Code > 57343 ).

pj_document(Value) --> pj_space, pj_value(Value), pj_space.
pj_space --> [C], {pj_whitespace(C)}, !, pj_space.
pj_space --> [].
pj_whitespace(32). pj_whitespace(9). pj_whitespace(10). pj_whitespace(13).
pj_value(json(Pairs)) --> [123], !, pj_space, pj_members(Pairs), [125].
pj_value(string(Codes)) --> [34], !, pj_string_codes(Codes).
pj_value(Values) --> [91], !, pj_space, pj_elements(Values), [93].
pj_value('@'(true)) --> [116,114,117,101], !.
pj_value('@'(false)) --> [102,97,108,115,101], !.
pj_value('@'(null)) --> [110,117,108,108], !.
pj_value(Number) --> pj_number(Number).
pj_members([], [125|S], [125|S]) :- !.
pj_members([string(Key)=Value|Pairs]) -->
    [34], pj_string_codes(Key), pj_space,
    [58], pj_space, pj_value(Value), pj_space, pj_more_members(Pairs).
pj_more_members([string(Key)=Value|Pairs]) --> [44], !, pj_space,
    [34], pj_string_codes(Key), pj_space,
    [58], pj_space, pj_value(Value), pj_space, pj_more_members(Pairs).
pj_more_members([]) --> [].
pj_elements([], [93|S], [93|S]) :- !.
pj_elements([Value|Values]) --> pj_value(Value), pj_space, pj_more_elements(Values).
pj_more_elements([Value|Values]) --> [44], !, pj_space,
    pj_value(Value), pj_space, pj_more_elements(Values).
pj_more_elements([]) --> [].

pj_string_codes([], [34|S], S) :- !.
pj_string_codes([Code|Codes], [92,Escape|S0], S) :- !,
    pj_escape(Escape, Code, S0, S1), pj_string_codes(Codes, S1, S).
pj_string_codes([Code|Codes], [Code|S0], S) :-
    Code >= 32, Code =\= 34, Code =\= 92, pj_scalar(Code),
    pj_string_codes(Codes, S0, S).
pj_escape(34,34,S,S). pj_escape(92,92,S,S). pj_escape(47,47,S,S).
pj_escape(98,8,S,S). pj_escape(102,12,S,S). pj_escape(110,10,S,S).
pj_escape(114,13,S,S). pj_escape(116,9,S,S).
pj_escape(117,Code,S0,S) :-
    pj_hex4(First,S0,S1),
    ( First >= 55296, First =< 56319 ->
        S1=[92,117|S2], pj_hex4(Low,S2,S), Low>=56320, Low=<57343,
        Code is 65536+(First-55296)*1024+Low-56320
    ; pj_scalar(First), Code=First, S=S1 ).
pj_hex4(Code,[A,B,C,D|S],S) :-
    pj_hex(A,W),pj_hex(B,X),pj_hex(C,Y),pj_hex(D,Z),Code is W*4096+X*256+Y*16+Z.
pj_hex(C,D) :- C>=48,C=<57,!,D is C-48.
pj_hex(C,D) :- C>=65,C=<70,!,D is C-55.
pj_hex(C,D) :- C>=97,C=<102,D is C-87.

pj_number(Number,S0,S) :-
    pj_number_token(S0,S), pj_prefix(S0,S,Codes),
    pj_number_normalize(Codes,Normalized),
    catch(number_codes(Number,Normalized),_,fail), pj_number_valid(Number).
pj_prefix(S0,S,[]) :- S0==S, !.
pj_prefix([C|Cs],S,[C|Codes]) :- pj_prefix(Cs,S,Codes).
pj_number_normalize(Codes,Normalized) :-
    ( pj_split_exponent(Codes,Mantissa,Exponent), \+ pj_has_dot(Mantissa) ->
        append(Mantissa,[46,48|Exponent],Normalized)
    ; Normalized=Codes ).
pj_split_exponent([E|Cs],[],[E|Cs]) :- (E=:=101;E=:=69),!.
pj_split_exponent([C|Cs],[C|Ms],Es) :- pj_split_exponent(Cs,Ms,Es).
pj_has_dot([46|_]) :- !.
pj_has_dot([_|Cs]) :- pj_has_dot(Cs).
pj_number_token --> pj_sign, pj_integer, pj_fraction, pj_exponent.
pj_sign --> [45], !.
pj_sign --> [].
pj_integer --> [48], !.
pj_integer --> [C], {C>=49,C=<57}, pj_digits.
pj_digits --> [C], {C>=48,C=<57}, !, pj_digits.
pj_digits --> [].
pj_one_digit --> [C], {C>=48,C=<57}.
pj_fraction --> [46], !, pj_one_digit, pj_digits.
pj_fraction --> [].
pj_exponent --> [E], {E=:=101;E=:=69}, !, pj_exponent_sign, pj_one_digit, pj_digits.
pj_exponent --> [].
pj_exponent_sign --> [C], {C=:=43;C=:=45}, !.
pj_exponent_sign --> [].

pj_emit(json(Pairs)) --> [123], pj_emit_pairs(Pairs), [125].
pj_emit(string(Codes)) --> [34], pj_emit_string(Codes), [34].
pj_emit('@'(true)) --> [116,114,117,101].
pj_emit('@'(false)) --> [102,97,108,115,101].
pj_emit('@'(null)) --> [110,117,108,108].
pj_emit(Number) --> {number(Number),number_codes(Number,Codes)}, pj_codes(Codes).
pj_emit([]) --> [91,93].
pj_emit([Value|Values]) --> [91], pj_emit_values([Value|Values]), [93].
pj_emit_pairs([]) --> [].
pj_emit_pairs([string(Key)=Value|Pairs]) -->
    pj_emit(string(Key)), [58], pj_emit(Value), pj_emit_pair_tail(Pairs).
pj_emit_pair_tail([]) --> [].
pj_emit_pair_tail([Pair|Pairs]) --> [44], pj_emit_pairs([Pair|Pairs]).
pj_emit_values([]) --> [].
pj_emit_values([Value|Values]) --> pj_emit(Value), pj_emit_value_tail(Values).
pj_emit_value_tail([]) --> [].
pj_emit_value_tail([Value|Values]) --> [44], pj_emit_values([Value|Values]).
pj_emit_string([]) --> [].
pj_emit_string([C|Cs]) --> pj_emit_char(C), pj_emit_string(Cs).
pj_emit_char(34) --> [92,34], !.
pj_emit_char(92) --> [92,92], !.
pj_emit_char(C) --> {C<32}, !, [92,117,48,48],
    {Hi is C//16,Lo is C mod 16,pj_hex_char(Hi,A),pj_hex_char(Lo,B)}, [A,B].
pj_emit_char(C) --> [C].
pj_hex_char(N,C) :- (N<10 -> C is N+48 ; C is N+87).
pj_codes([]) --> [].
pj_codes([C|Cs]) --> [C], pj_codes(Cs).
