% Local predicates -- sent to a remote node via src_predicates.

edge(a, b).
edge(b, c).
edge(c, d).
edge(a, d).

path(X, Y) :- edge(X, Y).
path(X, Y) :- edge(X, Z), path(Z, Y).


/** <examples>

?- rpc('https://n1.elfenbenstornet.se', member(X, [a,b,c])).

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       src_list([p(a),p(b),p(c)])
   ]).

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       src_text('p(a). p(b). p(c).')
   ]).

?- rpc('https://n1.elfenbenstornet.se', path(a, X), [
       src_predicates([edge/2, path/2])
   ]).

?- rpc('https://n3.elfenbenstornet.se', ancestor_descendant(X,Y), [
       src_uri('https://n2.elfenbenstornet.se')
   ]).

?- rpc(localhost, ancestor_descendant(X,Y),
       [src_uri('https://n2.elfenbenstornet.se')
   ]).

*/
