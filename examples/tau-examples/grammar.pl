%%  s(+Tree, +List, -Rest)
%
%   A DCG grammar for a fragment of English, producing parse trees.
%   The example is syntactically ambiguous, so has two parse trees.
%
%	@param	Tree - parse tree for the sentence
%	@author
%
%   Note: DCG is broken in Tau-JS!

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

% This isn't working:

?- phrase(s(Tree), [john,sees,a,man,with,a,telescope]).

% This freezes the browser:

?- forall((between(1,8,N), length(S,N), phrase(s(_),S)), 
   writeln(S)).

*/
