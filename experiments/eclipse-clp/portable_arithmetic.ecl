:- module(portable_arithmetic).
:- export (is)/2, (<)/2, (>)/2, (=<)/2, (>=)/2, (=:=)/2, (=\=)/2.

:- tool((is)/2, portable_is/3).
:- tool((<)/2, portable_lt/3).
:- tool((>)/2, portable_gt/3).
:- tool((=<)/2, portable_le/3).
:- tool((>=)/2, portable_ge/3).
:- tool((=:=)/2, portable_eq/3).
:- tool((=\=)/2, portable_ne/3).

portable_is(Result, Expression, Module) :-
    arithmetic_value(Expression, Value, Module),
    eclipse_language:(Result is Value)@Module.

portable_lt(A, B, M) :- arithmetic_comparison(<, A, B, M).
portable_gt(A, B, M) :- arithmetic_comparison(>, A, B, M).
portable_le(A, B, M) :- arithmetic_comparison(=<, A, B, M).
portable_ge(A, B, M) :- arithmetic_comparison(>=, A, B, M).
portable_eq(A, B, M) :- arithmetic_comparison(=:=, A, B, M).
portable_ne(A, B, M) :- arithmetic_comparison(=\=, A, B, M).

arithmetic_comparison(Operator, A, B, Module) :-
    arithmetic_value(A, Left, Module),
    arithmetic_value(B, Right, Module),
    Goal =.. [Operator, Left, Right],
    call(Goal)@eclipse_language.

% Native floating division can produce infinity for a zero divisor. Evaluate
% arithmetic arguments left to right so errors from operands retain priority.
% Leave ECLiPSe extensions with non-arithmetic arguments to the native evaluator.
arithmetic_value(Expression, Value, Module) :-
    ( nonvar(Expression), Expression = Numerator/Denominator ->
        arithmetic_value(Numerator, Left, Module),
        arithmetic_value(Denominator, Right, Module),
        ( eclipse_language:(Right =:= 0) ->
            throw(error(evaluation_error(zero_divisor), (is)/2))
        ; eclipse_language:(Value is Left/Right)@Module )
    ; compound(Expression), sepia_kernel:arith_builtin(Expression) ->
        Expression =.. [Name|Arguments],
        arithmetic_arguments(Arguments, Values, Module),
        Evaluated =.. [Name|Values],
        eclipse_language:(Value is Evaluated)@Module
    ; eclipse_language:(Value is Expression)@Module ).

arithmetic_arguments([], [], _).
arithmetic_arguments([Expression|Expressions], [Value|Values], Module) :-
    arithmetic_value(Expression, Value, Module),
    arithmetic_arguments(Expressions, Values, Module).
