%%  
%   The examples below demonstrate asynchronous RPC over
%   stateless HTTP using promise/3-4 and yield/2-3.


asynch_test_1(Answer) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(1)), Ref, [
        template(X)
    ]), 
    writeln('You\'re free to do other things here if you want...'),
    yield(Ref, Answer).


asynch_test_2(Answer) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(2)), Ref),
    yield(Ref, Answer, [
        timeout(1),
        on_timeout(fail)
    ]).
    
    
asynch_test_3(Answer1, Answer2) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(1)), Ref1, [
        template(X)
    ]),
    promise('https://n4.elfenbenstornet.se', (Y=b,sleep(1)), Ref2, [
        template(Y)
    ]),
    yield(Ref1, Answer1),
    yield(Ref2, Answer2).



/** <examples>

?- asynch_test_1(Answer).
    
?- asynch_test_2(Answer).
    
?- time(asynch_test_3(Answer1, Answer2)).

*/