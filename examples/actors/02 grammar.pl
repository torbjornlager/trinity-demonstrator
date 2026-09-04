%%  s(?Tree)//
%
%   A definite clause grammar (DCG) for a small fragment of English that
%   builds a parse tree as it recognises a sentence. Another pure-Prolog
%   example -- no actors -- showing off one of Prolog's oldest and most
%   characteristic tools.
%
%   Each nonterminal carries a Num feature so that subject and verb must
%   agree in number, and returns a term recording what it matched, so a
%   successful parse yields a full parse tree. The grammar is
%   deliberately ambiguous: "john sees a man with a telescope" has two
%   readings (who has the telescope?), and both parse trees are produced
%   on backtracking. Because a DCG is just a relation, the same rules run
%   backwards to GENERATE sentences when the word list is left unbound.
%
%   The two hidden difference-list arguments a DCG threads through every
%   nonterminal are supplied by phrase/2, so the head reads as s(Tree)//.
%
%	@param	Tree - the parse tree built for the recognised sentence.
%	@author A textbook fragment, in Web Prolog.

s(s(NP,VP)) --> np(NP, Num), vp(VP, Num).

np(NP, Num) --> pn(NP, Num).
np(np(Det,N), Num) --> det(Det, Num), n(N, Num).
np(np(Det,N,PP), Num) --> det(Det, Num), n(N, Num), pp(PP).

vp(vp(V,NP), Num) --> v(V, Num), np(NP, _).
vp(vp(V,NP,PP), Num) --> v(V, Num), np(NP, _), pp(PP).

pp(pp(P,NP)) --> p(P), np(NP, _).

det(det(a), sg) --> [a].
det(det(the), _) --> [the].

pn(pn(john), sg) --> [john].

n(n(man), sg) --> [man].
n(n(men), pl) --> [men].
n(n(telescope), sg) --> [telescope].

v(v(sees), sg) --> [sees].
v(v(see), pl) --> [see].
v(v(saw), _) --> [saw].

p(p(with)) --> [with].


/** <examples>

% Parse an ambiguous sentence: ask for more solutions to see both
% readings (the telescope attaches to either "sees" or "man").

?- phrase(s(Tree), [john,sees,a,man,with,a,telescope]).

% Run the same grammar backwards to GENERATE sentences it accepts.

?- phrase(s(_), Sentence).

*/
