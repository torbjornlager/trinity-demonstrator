:- module(node_limit_helpers, [
    current_limit_value/4,
    normalize_positive_integer_limit/5
]).

/** <module> Shared Limit Helpers

Common helper predicates used by the node limit modules for:

  - resolving per-node runtime overrides with a settings fallback, and
  - validating positive integer limit values.
*/

:- use_module(library(error)).
:- use_module(library(settings)).

:- use_module(node_runtime_state, [current_node_value/2]).


%!  current_limit_value(+Key, :NormalizePredicate, +DefaultSetting, -Limit) is det.
%
%   Resolve a per-node limit value from runtime state when present, otherwise
%   fall back to the given SWI setting name. The resulting value is then
%   normalized by NormalizePredicate/2.
:- meta_predicate current_limit_value(+, 2, +, -).
current_limit_value(Key, NormalizePredicate, DefaultSetting, Limit) :-
    (   current_node_value(Key, Limit0)
    ->  true
    ;   setting(DefaultSetting, Limit0)
    ),
    call(NormalizePredicate, Limit0, Limit).


%!  normalize_positive_integer_limit(+Domain, +Value0, -Value, +Context, +Message) is det.
%
%   Shared validator for positive integer limit settings.
normalize_positive_integer_limit(Domain, Value0, Value, Context, Message) :-
    must_be(integer, Value0),
    (   Value0 > 0
    ->  Value = Value0
    ;   throw(error(domain_error(Domain, Value0),
                    context(Context, Message)))
    ).
