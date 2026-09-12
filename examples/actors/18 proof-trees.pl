%% From answers to explanations, locally and across nodes.
%
% The first two queries need no remote service. The last uses n3 and n4.
% This follows the proof-producing meta-interpreter in the AI chapter.
%
% A/Proof records a goal and its justification. true is a proved leaf;
% (ProofA,ProofB) records a conjunction. A@URI/Proof marks a remote step.
% These are ordinary Prolog terms, not a separate explanation language.

% Knowledge base

:- dynamic mortal/1, human/1.

mortal(X) :- human(X).
human(socrates).

% Interpreter

prove(true, true) :- !.
prove(rpc(URI, A), Proof) :- !,
    prove(rpc(URI, A, []), Proof).
prove(rpc(URI, A, Options), Query@URI/Proof) :- !,
    rpc(URI, prove(A, Query/Proof), [
        src_predicates([prove/2])
      | Options
    ]).
prove((A, B), (ProofA, ProofB)) :- !,
    prove(A, ProofA), prove(B, ProofB).
prove(A, A/Proof) :- clause(A, B), prove(B, Proof).

/** <examples>

% An answer: Who = socrates.

?- mortal(Who).

% An explanation: mortal(socrates)/(human(socrates)/true).

?- prove(mortal(Who), Proof).

% The same interpreter follows the remote call and ships itself to n3.
% n3 has mortal/1 and human(socrates); its other human/1 rule calls n4,
% which hosts human(plato) and human(aristotle). Ask for more answers.
% The returned proofs mark n3, and also n4 when that node contributes.
% Only prove/2 is shipped: the local human(socrates) fact stays here.

?- prove(rpc('https://n3.elfenbenstornet.se', mortal(Who)), Proof).

*/
