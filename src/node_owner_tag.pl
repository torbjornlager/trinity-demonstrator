:- module(node_owner_tag, [
    viewer_token/1,
    agent_token/1,
    request_owner_tagged/1,
    request_agent_tagged/1,
    secure_eq_text/2
]).

/** <module> Shared helpers for the secret log viewer and owner tagging.

The viewer token is read from the `WEB_PROLOG_VIEWER_TOKEN` environment
variable.  When unset (or empty) both the viewer routes and the
owner-cookie check are disabled.
*/

:- use_module(library(lists)).


%!  viewer_token(-Token:string) is semidet.
%
%   True when WEB_PROLOG_VIEWER_TOKEN is set to a non-empty value.
viewer_token(Token) :-
    catch(getenv('WEB_PROLOG_VIEWER_TOKEN', Raw), _, fail),
    Raw \== '',
    atom_string(Raw, Token),
    string_length(Token, Len),
    Len > 0.


%!  request_owner_tagged(+Request) is semidet.
%
%   True when the incoming HTTP request carries a `wp_owner` cookie whose
%   value matches the configured viewer token.
request_owner_tagged(Request) :-
    viewer_token(Token),
    request_cookie(Request, wp_owner, Value),
    secure_eq_text(Value, Token).


%!  agent_token(-Token:string) is semidet.
%
%   True when WEB_PROLOG_AGENT_TOKEN is set to a non-empty value.
agent_token(Token) :-
    catch(getenv('WEB_PROLOG_AGENT_TOKEN', Raw), _, fail),
    Raw \== '',
    atom_string(Raw, Token),
    string_length(Token, Len),
    Len > 0.


%!  request_agent_tagged(+Request) is semidet.
%
%   True when the request carries either the `X-WP-Agent` header or the
%   `wp_agent` cookie with a value matching `WEB_PROLOG_AGENT_TOKEN`.
request_agent_tagged(Request) :-
    agent_token(Token),
    (   request_header_value(Request, x_wp_agent, HeaderValue),
        secure_eq_text(HeaderValue, Token)
    ->  true
    ;   request_cookie(Request, wp_agent, CookieValue),
        secure_eq_text(CookieValue, Token)
    ).


request_header_value(Request, NameLower, Value) :-
    Term =.. [NameLower, Raw],
    memberchk(Term, Request),
    !,
    text_to_string(Raw, Value).
request_header_value(Request, NameLower, Value) :-
    atom_string(NameLower, NameLowerS),
    split_string(NameLowerS, "_", "", Parts),
    atomic_list_concat(Parts, '-', HyphenName),
    Term =.. [HyphenName, Raw],
    memberchk(Term, Request),
    text_to_string(Raw, Value).


request_cookie(Request, Name, Value) :-
    memberchk(cookie(Cookies), Request),
    request_cookie_(Cookies, Name, Value).

request_cookie_(Cookies, Name, Value) :-
    is_list(Cookies),
    !,
    member(Pair, Cookies),
    cookie_pair_name_value(Pair, Name, Value).
request_cookie_(Raw, Name, Value) :-
    text_to_string(Raw, RawString),
    split_string(RawString, ";", " \t", Parts),
    member(Part, Parts),
    split_string(Part, "=", "", [KeyString|RestParts]),
    atom_string(Key, KeyString),
    Key == Name,
    atomics_to_string(RestParts, "=", Value0),
    text_to_string(Value0, Value).

cookie_pair_name_value(Name=Value0, Name, Value) :-
    !,
    text_to_string(Value0, Value).
cookie_pair_name_value(Name-Value0, Name, Value) :-
    !,
    text_to_string(Value0, Value).


%!  secure_eq_text(+A, +B) is semidet.
%
%   Constant-time equality check on two text values.  Returns true only
%   when the two values have identical length and identical code points.
secure_eq_text(A, B) :-
    text_to_codes(A, CodesA),
    text_to_codes(B, CodesB),
    length(CodesA, LenA),
    length(CodesB, LenB),
    LenA =:= LenB,
    secure_eq_codes(CodesA, CodesB, 0, Diff),
    Diff =:= 0.

text_to_codes(Text, Codes) :-
    (   is_list(Text)
    ->  Codes = Text
    ;   string(Text)
    ->  string_codes(Text, Codes)
    ;   atom(Text)
    ->  atom_codes(Text, Codes)
    ;   number(Text)
    ->  number_codes(Text, Codes)
    ;   text_to_string(Text, S),
        string_codes(S, Codes)
    ).

secure_eq_codes([], [], D, D).
secure_eq_codes([A|As], [B|Bs], D0, D) :-
    D1 is D0 \/ (A xor B),
    secure_eq_codes(As, Bs, D1, D).
