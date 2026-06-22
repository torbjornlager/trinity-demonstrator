% n2 is the richer isotope node.

:- dynamic mortal/1, human/1.

mortal(X) :-
    human(X).

human(socrates).
human(X) :-
    rpc('https://n4.elfenbenstornet.se', human(X)).

