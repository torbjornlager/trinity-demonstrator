%%  Asynchronous remote calls with promise/3-4 and yield/2-3.
%
%   The ASYNCHRONOUS counterpart to rpc/2-3. Where rpc/2-3 blocks until
%   the remote node answers, promise/3-4 only STARTS the remote work and
%   returns a reference immediately; the caller collects the answer later
%   with yield/2-3. In between, it is free to do other things -- including
%   launching more remote calls.
%
%   That is what makes concurrency across nodes practical. asynch_test_3
%   fires two promises at two different nodes and only then yields both,
%   so the two remote computations overlap and the pair finishes in about
%   the time of one rather than their sum (each is padded with an
%   artificial delay to make this visible). yield/2-3 accepts the same
%   waiting controls as receive -- asynch_test_2 gives up with a timeout
%   if the answer is slow -- and promise/3-4 accepts the same code-shipping
%   options as rpc, plus template/1 to say which term to bring back and
%   offset/1 and limit/1 to slice the remote solution stream
%   (asynch_test_4).
%
%   The transport is stateless HTTP: no long-lived connection is held
%   open between starting a call and collecting its result.
%
%	@author Asynchronous RPC examples, in Web Prolog.


asynch_test_1(Answer) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(0.5)), Ref, [
        template(X)
    ]),
    yield(Ref, Answer).


asynch_test_2(Answer) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(0.5)), Ref),
    yield(Ref, Answer, [
        timeout(0.1),
        on_timeout(fail)
    ]).
    
    
asynch_test_3(Answer1, Answer2) :-
	promise('https://n3.elfenbenstornet.se', (X=a,sleep(0.5)), Ref1, [
        template(X)
    ]),
	promise('https://n4.elfenbenstornet.se', (Y=b,sleep(0.5)), Ref2, [
        template(Y)
    ]),
    yield(Ref1, Answer1),
    yield(Ref2, Answer2).


asynch_test_4(Answer1, Answer2) :-
	promise('https://n3.elfenbenstornet.se', (p(X),sleep(0.2)), Ref1, [
        template(X),
        offset(1),
        src_text("p(a). p(b).")
    ]),
	promise('https://n4.elfenbenstornet.se', (p(Y),sleep(0.1)), Ref2, [
        template(Y),
        limit(1),
        src_list([p(c), p(d)])
    ]),
    yield(Ref1, Answer1),
    yield(Ref2, Answer2).



/** <examples>

% Start one remote call, then collect its result (Answer = a).

?- asynch_test_1(Answer).

% Give up early: yield with a short timeout returns before the slower
% remote result is ready, so this one fails.

?- asynch_test_2(Answer).

% Two nodes at once: both promises are in flight before either yield, so
% the two calls overlap instead of running one after the other.

?- asynch_test_3(Answer1, Answer2).

% As above, but shipping code to each node and slicing the remote
% solution streams with offset/1 and limit/1.

?- asynch_test_4(Answer1, Answer2).

*/

