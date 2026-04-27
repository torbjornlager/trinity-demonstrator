% Promise/yield over stateless HTTP from Tau-Prolog.

/** <examples>

?- promise('https://n1.elfenbenstornet.se', member(X, [a,b,c]), Ref,
       [template(X), limit(2)]),
   yield(Ref, Answer).

?- promise('https://n1.elfenbenstornet.se', between(1, 3, X), Ref,
       [template(X), offset(1), limit(1)]),
   yield(Ref, Answer).

?- yield(9999999999, _Answer,
       [timeout(0.01), on_timeout(Result = timed_out)]).

*/
