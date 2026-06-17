:- module(node_relation_policy, [
    normalize_relation_patterns/2,
    relation_patterns/1,
    relation_check_call/3
]).

/** <module> RELATION Query Policy

RELATION nodes do not accept arbitrary Prolog goals. They answer only
advertised query patterns over `/call`.

This module is for Prolog-backed RELATION nodes in this codebase. A
non-Prolog RELATION node would implement the same `/call` contract outside
this module.
*/

:- use_module(library(error)).

:- use_module(rpc, [text_to_string/2]).
:- use_module(node_profile_policy, [normalize_profile/2]).
:- use_module(node_runtime_state, [current_node_value/2]).


%!  normalize_relation_patterns(+Patterns0, -Patterns) is det.
normalize_relation_patterns(Patterns0, Patterns) :-
    must_be(list, Patterns0),
    maplist(normalize_relation_pattern, Patterns0, Patterns).


%!  relation_patterns(-Patterns) is det.
%
%   Determine advertised relation patterns for the current node. Preference is:
%
%     1. explicit `relations([...])` startup option
%     2. `relation_filter/1` declarations in the shared DB module
%     3. owner-defined predicate heads parsed from shared DB source text
%
%   The shared-source fallback reparses the current shared DB text on demand.
%   That is acceptable for this PoC, but it should be cached if RELATION
%   filtering becomes performance-sensitive.
relation_patterns(Patterns) :-
    (   current_node_value(relation_patterns, ExplicitPatterns),
        ExplicitPatterns \== []
    ->  Patterns = ExplicitPatterns
    ;   relation_patterns_from_shared_db_filter(FilterPatterns),
        FilterPatterns \== []
    ->  Patterns = FilterPatterns
    ;   relation_patterns_from_shared_db_source(SourcePatterns),
        SourcePatterns \== []
    ->  Patterns = SourcePatterns
    ;   Patterns = []
    ).


%!  relation_check_call(+Profile, +Goal, +LoadText) is det.
%
%   This check is only meaningful for `/call`. Route-level profile gating
%   should already have rejected non-`/call` access on RELATION nodes.
relation_check_call(Profile0, Goal, LoadText0) :-
    normalize_profile(Profile0, Profile),
    (   Profile == relation
    ->  relation_check_call_1(Goal, LoadText0)
    ;   true
    ).


relation_check_call_1(Goal, LoadText0) :-
    relation_check_load_text(LoadText0),
    relation_check_goal(Goal).


relation_check_load_text(LoadText0) :-
    text_to_string(LoadText0, LoadText1),
    normalize_space(string(LoadText), LoadText1),
    (   LoadText == ""
    ->  true
    ;   throw(error(relation_violation(load_text),
                    context(node_relation_policy:relation_check_call/3,
                            'source loading is not available in the RELATION profile')))
    ).


%   A RELATION query may be a single advertised relation OR a CONJUNCTION
%   of advertised relations (a relational join over the published schema):
%   each conjunct must itself be advertised.  Only `,/2` composes them —
%   disjunction, if-then, negation, and any unadvertised predicate are
%   refused, so this admits joins without admitting arbitrary goals.
relation_check_goal(Goal) :-
    (   var(Goal)
    ->  throw(error(instantiation_error,
                    context(node_relation_policy:relation_check_call/3,
                            'relation query must be instantiated')))
    ;   Goal = (A, B)
    ->  relation_check_goal(A),
        relation_check_goal(B)
    ;   relation_goal_allowed(Goal)
    ->  true
    ;   goal_proc_indicator(Goal, Proc),
        % Keep the standard "Unknown procedure" UX in clients by reporting
        % filtered-out relations through the usual procedure existence error.
        throw(error(existence_error(procedure, Proc),
                    context(node_relation_policy:relation_check_call/3,
                            'relation is not served by this node')))
    ).


relation_goal_allowed(Goal) :-
    relation_patterns(Patterns),
    member(Pattern0, Patterns),
    copy_term(Pattern0, Pattern),
    Goal = Pattern,
    !.


relation_patterns_from_shared_db_filter(Patterns) :-
    current_node_value(shared_db_module, Module),
    current_predicate(Module:relation_filter/1),
    !,
    findall(Pattern,
            ( Module:relation_filter(Pattern0),
              normalize_relation_pattern(Pattern0, Pattern)
            ),
            Patterns).
relation_patterns_from_shared_db_filter([]).


relation_patterns_from_shared_db_source(Patterns) :-
    current_node_value(shared_db_source, Source0),
    text_to_string(Source0, Source),
    setup_call_cleanup(
        open_string(Source, Stream),
        read_relation_source_patterns(Stream, Patterns),
        close(Stream)
    ).
% If there is no shared DB source in the current node runtime, there are no
% fallback relation patterns. Parse errors from an existing source are not
% swallowed by this clause; they still propagate.
relation_patterns_from_shared_db_source([]).


read_relation_source_patterns(Stream, Patterns) :-
    read_term(Stream, Term0, []),
    (   Term0 == end_of_file
    ->  Patterns = []
    ;   relation_source_pattern(Term0, Pattern)
    ->  Patterns = [Pattern|Rest],
        read_relation_source_patterns(Stream, Rest)
    ;   read_relation_source_patterns(Stream, Patterns)
    ).


relation_source_pattern((:- _Directive), _) :-
    !,
    fail.
relation_source_pattern((Head :- _Body), Pattern) :-
    !,
    relation_source_head_pattern(Head, Pattern).
relation_source_pattern(Term, Pattern) :-
    relation_source_head_pattern(Term, Pattern).


relation_source_head_pattern(relation_filter(_), _) :-
    !,
    fail.
%  provides/1 is an owner-curated capability list surfaced via /node_info,
%  not a queryable relation — keep it out of the advertised patterns.
relation_source_head_pattern(provides(_), _) :-
    !,
    fail.
relation_source_head_pattern(Head, Pattern) :-
    callable(Head),
    !,
    normalize_relation_pattern(Head, Pattern).
relation_source_head_pattern(_, _) :-
    fail.


normalize_relation_pattern(Name/Arity, Pattern) :-
    atom(Name),
    integer(Arity),
    Arity >= 0,
    !,
    functor(Pattern, Name, Arity).
normalize_relation_pattern(Pattern0, Pattern) :-
    callable(Pattern0),
    !,
    % Full callable patterns may constrain arguments, e.g. wife(socrates, _).
    % The relation pre-check unifies the submitted goal with a fresh copy of
    % such a pattern, which narrows the query to the advertised relation
    % shape before execution.
    Pattern = Pattern0.
normalize_relation_pattern(Pattern, _) :-
    throw(error(domain_error(node_relation_pattern, Pattern),
                context(node_relation_policy:normalize_relation_patterns/2,
                        'relation patterns must be callables or Name/Arity indicators'))).


goal_proc_indicator(Module:Goal, Proc) :-
    atom(Module),
    !,
    goal_proc_indicator(Goal, Proc).
goal_proc_indicator(Goal, Proc) :-
    callable(Goal),
    !,
    functor(Goal, Name, Arity),
    Proc = Name/Arity.
goal_proc_indicator(Goal, _) :-
    throw(error(type_error(callable, Goal),
                context(node_relation_policy:relation_check_call/3,
                        'relation query must be callable'))).
