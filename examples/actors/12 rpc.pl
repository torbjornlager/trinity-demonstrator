% Local predicates -- sent to a remote node via load_predicates.

edge(a, b).
edge(b, c).
edge(c, d).
edge(a, d).

path(X, Y) :- edge(X, Y).
path(X, Y) :- edge(X, Z), path(Z, Y).


/** <examples>

?- rpc('https://n1.elfenbenstornet.se', member(X, [a,b,c])).

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       load_list([p(a),p(b),p(c)])
   ]).

?- rpc('https://n1.elfenbenstornet.se', p(X), [
       load_text('p(a). p(b). p(c).')
   ]).

?- rpc('https://n1.elfenbenstornet.se', path(a, X), [
       load_predicates([edge/2, path/2])
   ]).

?- rpc(localhost, ancestor_descendant(X,Y),[
       load_uri('https://n1.elfenbenstornet.se')
   ]).


*/
