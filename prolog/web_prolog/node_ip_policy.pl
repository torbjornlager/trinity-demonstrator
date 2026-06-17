:- module(node_ip_policy, [
    ip_access_denied/1,         % +Request   (true iff the client IP is barred)
    record_ip_offense/1,        % +Request   (note a rate-limit offense; maybe ban)
    ip_temp_banned/1,           % +IPString
    clear_ip_bans/0,
    ip_matches/2,               % +IPString, +CidrOrIP
    valid_ip_pattern/1,         % +CidrOrIP   (config-time validation)
    set_ip_blocklist/1,         % +ListOfCidrAtoms
    set_ip_allowlist/1,
    current_ip_blocklist/1,
    current_ip_allowlist/1,
    auto_ban_threshold/1,       % -N   (0 = auto-ban off)
    auto_ban_window_seconds/1,  % -N
    auto_ban_seconds/1          % -N
]).

/** <module> IP / CIDR access control

Open-web abuse resistance: bar (or restrict to) client IP ranges, and
temporarily auto-ban an IP that keeps tripping the rate limit. Everything
is off by default — empty lists deny nothing and a zero auto-ban
threshold disables banning — so behavior is unchanged unless an operator
opts in.

The client IP is resolved spoof-resistantly by node_auth:client_ip/2
(X-Forwarded-For honoured only from a trusted proxy peer). IPv4 CIDRs and
exact IPv4/IPv6 addresses are supported; IPv6 CIDR matching is not (use
exact IPv6 addresses).
*/

:- use_module(library(settings)).
:- use_module(library(lists)).
:- use_module(library(aggregate)).
:- use_module(node_auth, [client_ip/2]).
:- use_module(node_runtime_state, [current_node_value/2, current_node_port/1]).

:- setting(ip_blocklist, list(atom), [],
           'Client IPs / CIDRs barred from execution. Empty = none.').
:- setting(ip_allowlist, list(atom), [],
           'If non-empty, ONLY these client IPs / CIDRs may execute (still subject to the blocklist). Empty = allow all.').
:- setting(auto_ban_threshold, integer, 0,
           'Rate-limit offenses from one client IP within auto_ban_window_seconds that trigger a temporary ban. 0 = auto-ban off.').
:- setting(auto_ban_window_seconds, integer, 60,
           'Window over which rate-limit offenses accumulate toward an auto-ban.').
:- setting(auto_ban_seconds, integer, 900,
           'How long a temporary auto-ban lasts.').

%   ip_strike(Scope, IP, Timestamp), ip_ban(Scope, IP, ExpiresAt)
:- dynamic ip_strike/3.
:- dynamic ip_ban/3.


%!  ip_access_denied(+Request) is semidet.
%
%   True when the request's client IP is on the blocklist, temporarily
%   auto-banned, or excluded by a configured allowlist. All controls off
%   ⇒ always fails (off by default).
ip_access_denied(Request) :-
    client_ip(Request, IP),
    IP \== "",
    (   ip_in_list(IP, blocklist)
    ->  true
    ;   ip_temp_banned(IP)
    ->  true
    ;   current_ip_allowlist(Allow),
        Allow \== []
    ->  \+ ip_matches_any(IP, Allow)
    ;   fail
    ).

ip_in_list(IP, blocklist) :-
    current_ip_blocklist(List),
    ip_matches_any(IP, List).

ip_matches_any(IP, Patterns) :-
    member(Pattern, Patterns),
    ip_matches(IP, Pattern),
    !.


                 /*******************************
                 *          AUTO-BAN            *
                 *******************************/

%!  record_ip_offense(+Request) is det.
%
%   Note a rate-limit offense from the request's client IP. When enough
%   accumulate within auto_ban_window_seconds, the IP is temporarily
%   auto-banned, after which ip_access_denied/1 denies it (403) until the
%   ban expires. No-op when auto-ban is off (threshold 0), the IP is
%   unknown, or the IP is explicitly allowlisted — operator-trusted IPs
%   are never auto-banned.
record_ip_offense(Request) :-
    (   auto_ban_threshold(Threshold),
        Threshold > 0,
        client_ip(Request, IP),
        IP \== "",
        \+ ip_allowlisted(IP)
    ->  ban_scope(Scope),
        get_time(Now),
        with_mutex(node_ip_policy, record_strike(Scope, IP, Now, Threshold))
    ;   true
    ).

record_strike(Scope, IP, Now, Threshold) :-
    auto_ban_window_seconds(Window),
    Cutoff is Now - Window,
    forall(( ip_strike(Scope, IP, T), T < Cutoff ),
           retract(ip_strike(Scope, IP, T))),
    assertz(ip_strike(Scope, IP, Now)),
    aggregate_all(count, ip_strike(Scope, IP, _), Count),
    (   Count >= Threshold
    ->  auto_ban_seconds(BanSeconds),
        ExpiresAt is Now + BanSeconds,
        retractall(ip_ban(Scope, IP, _)),
        assertz(ip_ban(Scope, IP, ExpiresAt)),
        retractall(ip_strike(Scope, IP, _)),     % reset after banning
        sweep_expired_bans(Scope, Now)
    ;   true
    ).

%!  ip_temp_banned(+IP) is semidet.
ip_temp_banned(IP) :-
    ban_scope(Scope),
    ip_ban(Scope, IP, ExpiresAt),
    get_time(Now),
    ExpiresAt > Now.

sweep_expired_bans(Scope, Now) :-
    forall(( ip_ban(Scope, BannedIP, ExpiresAt), ExpiresAt =< Now ),
           retract(ip_ban(Scope, BannedIP, ExpiresAt))).

%!  clear_ip_bans is det.
clear_ip_bans :-
    with_mutex(node_ip_policy,
               ( retractall(ip_strike(_, _, _)),
                 retractall(ip_ban(_, _, _)) )).

ip_allowlisted(IP) :-
    current_ip_allowlist(Allow),
    Allow \== [],
    ip_matches_any(IP, Allow).

ban_scope(Scope) :-
    (   current_node_port(Port)
    ->  Scope = node_port(Port)
    ;   Scope = global
    ).

auto_ban_threshold(N) :-
    ( current_node_value(auto_ban_threshold, N) -> true ; setting(auto_ban_threshold, N) ).
auto_ban_window_seconds(N) :-
    ( current_node_value(auto_ban_window_seconds, N) -> true ; setting(auto_ban_window_seconds, N) ).
auto_ban_seconds(N) :-
    ( current_node_value(auto_ban_seconds, N) -> true ; setting(auto_ban_seconds, N) ).


                 /*******************************
                 *         MATCHING             *
                 *******************************/

%!  ip_matches(+IP:string, +Pattern) is semidet.
%
%   Pattern is an IPv4 CIDR (`10.0.0.0/8`) or an exact IP (v4 or v6).
ip_matches(IP, Pattern) :-
    to_text(Pattern, PatternText),
    (   sub_string(PatternText, _, _, _, "/")
    ->  ipv4_cidr_match(IP, PatternText)
    ;   to_text(IP, IPText),
        IPText == PatternText
    ).

ipv4_cidr_match(IP, CIDR) :-
    split_string(CIDR, "/", "", [NetString, PrefixString]),
    number_string(Prefix, PrefixString),
    integer(Prefix), Prefix >= 0, Prefix =< 32,
    ipv4_to_int(NetString, NetInt),
    to_text(IP, IPText),
    ipv4_to_int(IPText, IpInt),
    Mask is (\(0) << (32 - Prefix)) /\ 0xFFFFFFFF,
    (IpInt /\ Mask) =:= (NetInt /\ Mask).

ipv4_to_int(String, Int) :-
    split_string(String, ".", "", Parts),
    Parts = [_, _, _, _],
    maplist(octet, Parts, [A, B, C, D]),
    Int is (A << 24) \/ (B << 16) \/ (C << 8) \/ D.

octet(Part, N) :-
    number_string(N, Part),
    integer(N), N >= 0, N =< 255.

%!  valid_ip_pattern(+Pattern) is semidet.
%
%   True when Pattern is a well-formed IPv4 CIDR, or an exact IPv4 or
%   (loosely) IPv6 address. For config-time validation so a typo'd
%   blocklist entry fails loudly instead of silently matching nothing.
valid_ip_pattern(Pattern) :-
    to_text(Pattern, Text),
    (   sub_string(Text, _, _, _, "/")
    ->  split_string(Text, "/", "", [NetString, PrefixString]),
        ipv4_to_int(NetString, _),
        number_string(Prefix, PrefixString),
        integer(Prefix), Prefix >= 0, Prefix =< 32
    ;   ipv4_to_int(Text, _)
    ->  true
    ;   sub_string(Text, _, _, _, ":")        % loose IPv6
    ).


                 /*******************************
                 *          CONFIG              *
                 *******************************/

current_ip_blocklist(List) :-
    (   current_node_value(ip_blocklist, List)
    ->  true
    ;   setting(ip_blocklist, List)
    ).

current_ip_allowlist(List) :-
    (   current_node_value(ip_allowlist, List)
    ->  true
    ;   setting(ip_allowlist, List)
    ).

set_ip_blocklist(List) :-
    set_setting(ip_blocklist, List).

set_ip_allowlist(List) :-
    set_setting(ip_allowlist, List).


to_text(X, Text) :-
    (   string(X) -> Text = X
    ;   atom(X)   -> atom_string(X, Text)
    ;   number(X) -> number_string(X, Text)
    ;   term_string(X, Text)
    ).
