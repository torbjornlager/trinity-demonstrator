% n1 is the conservative public node.
% Hosts the human/1 facts that n2's distributed `mortal/1` chain pulls in
% over rpc/2-3.

:- dynamic human/1.

human(plato).
human(aristotle).


% A tiny grammar:

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



/* Here's a first version of a set of exercises for practising the querying
of a simple Prolog database, in this case a movie database (see below).
Modified from exercises found on the web. Not sure who first made them.  */


/* EXERCISES

Part 1: Write queries to answer the following questions.

    a. In which year was the movie American Beauty released?
    b. Find the movies released in the year 2000.
    c. Find the movies released before 2000.
    d. Find the movies released after 1990.
    e. Find an actor who has appeared in more than one movie.
    f. Find a director of a movie in which Scarlett Johansson appeared.
    g. Find an actor who has also directed a movie.
    h. Find an actor or actress who has also directed a movie.
    i. Find the movie in which John Goodman and Jeff Bridges were co-stars.

Part 2: Add rules to the database to do the following,

    a. released_after(M, Y) <- the movie was released after the given year.
    b. released_before(M, Y) <- the movie was released before the given year.
    c. same_year(M1, M2) <- the movies are released in the same year.
    d. co_star(A1, A2) <- the actor/actress are in the same movie.

*/

/** <examples> (Remove these if you want to give the exercises to students!)

?- movie(american_beauty, Y).
?- movie(M, 2000).
?- movie(M, Y), Y < 2000.
?- movie(M, Y), Y > 1999.
?- actor(M1, A, _), actor(M2, A, _), M1 @> M2.
?- actress(M, scarlett_johansson, _), director(M, D).
?- actor(_, A, _), director(_, A).
?- (actor(_, A, _) ; actress(_, A, _)), director(_, A).
?- actor(M, john_goodman, _), actor(M, jeff_bridges, _).
*/

/* DATABASE

    movie(M, Y) <- movie M came out in year Y
    director(M, D) <- movie M was directed by director D
    actor(M, A, R) <- actor A played role R in movie M
    actress(M, A, R) <- actress A played role R in movie M

*/

% The movie database lives in a separate module, imported here. This makes
% n1's shared DB *dependent* (not self-contained): the movie facts are not
% carried in this file, so /node_info reports self_contained:false and the
% discovery hub flags n1 as "dependent". The n1_overlay search-path alias
% is registered by start_n1.pl (points at this Deployment directory).

:- use_module(n1_overlay(movie_db), [movie/2, director/2, actor/3, actress/3]).
