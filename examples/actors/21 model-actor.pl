%%  Two actors, two conversations, one small language model.
%
%   Select n3 (ACTOR) and load this source. chat_actor(History) carries
%   its conversation in a recursive argument, just as a counter actor
%   carries its count. Every spawned actor starts with a separate [].
%
%   ask(From, Ref, Text) adds a user turn, calls the model, and sends
%   answer(Ref, Text) or model_error(Ref, Reason) back to From. On success
%   the actor remembers both turns; on error it keeps its previous state.
%   reset(From, Ref) clears this actor's history and acknowledges the reset.
%   stop terminates it. These are ordinary, session-owned public actors;
%   the trusted inference service never accepts a reply address.
%
%   The HTTP boundary is model_chat/2, installed in n3's shared database.
%   It converts user(Text)/assistant(Text) terms to Ollama JSON messages
%   and posts them to a fixed private endpoint with stream:false. The
%   model, context and output limits are fixed by the owner. The service
%   stores no conversation history and never executes generated text.
%
%   We retain at most two complete exchanges, within 1500 characters,
%   dropping the oldest pair first. Prompts are at most 500 characters.
%   Ollama also caps context at 1024 tokens; non-English text can consume
%   more tokens, so model-side truncation is still possible. SmolLM2 135M
%   is tiny: it can forget or hallucinate despite receiving the history.
%
%   Allow at least TEN SECONDS between requests, across both actors:
%   the public service permits one generation at a time and six starts
%   per minute globally. busy/rate_limited mean retry later. unavailable
%   means the owner must enable or recover the backend. None of these
%   errors adds a failed exchange to the conversation.

chat_actor(History) :-
    receive({
        ask(From, Ref, Text) ->
            chat_exchange(Text, History, Result, NextHistory),
            chat_reply(From, Ref, Result),
            chat_actor(NextHistory) ;
        reset(From, Ref) ->
            From ! reset(Ref),
            chat_actor([]) ;
        stop ->
            true ;
        _Other ->
            chat_actor(History)
    }).

chat_exchange(Text, History, Result, NextHistory) :-
    ( string(Text), string_length(Text, N), N > 0, N =< 500
    -> append(History, [user(Text)], Messages),
       model_chat(Messages, Result),
       ( Result = answer(Reply)
       -> append(Messages, [assistant(Reply)], Complete),
          chat_trim(Complete, NextHistory)
       ; NextHistory = History )
    ; Result = error(invalid_prompt), NextHistory = History ).

chat_reply(From, Ref, answer(Text)) :-
    From ! answer(Ref, Text).
chat_reply(From, Ref, error(Reason)) :-
    From ! model_error(Ref, Reason).

chat_trim(History, Kept) :-
    length(History, Count),
    chat_size(History, Size),
    ( Count =< 4, Size =< 1500
    -> Kept = History
    ; History = [user(_), assistant(_)|Rest],
      chat_trim(Rest, Kept) ).

chat_size([], 0).
chat_size([Message|Rest], Size) :-
    arg(1, Message, Text), string_length(Text, N),
    chat_size(Rest, Tail), Size is N + Tail.

start_chat(Pid) :-
    spawn(chat_actor([]), Pid, [
        src_predicates([chat_actor/1, chat_exchange/4, chat_reply/3,
                        chat_trim/2, chat_size/2]),
        monitor(true)
    ]).

/** <examples>

% Create two independent conversations. Keep their pids in A and B.

?- start_chat(A), start_chat(B).

% Tell A a name. Sending returns immediately; collect the answer below.

?- self(Me), $A ! ask(Me, a1, "My name is Alice. Please remember my name.").

% Poll without holding the public query open. If it fails, try again
% shortly. A model_error reply explains why an attempt was rejected.

?- receive({answer(a1, Text) -> true ; model_error(a1, Reason) -> true},
           [timeout(0), on_timeout(fail)]).

% At least ten seconds later, give B a different name.

?- self(Me), $B ! ask(Me, b1, "My name is Bob. Please remember my name.").

?- receive({answer(b1, Text) -> true ; model_error(b1, Reason) -> true},
           [timeout(0), on_timeout(fail)]).

% At least ten seconds later, ask A to recall its own conversation.
% Only Alice's exchange is sent with this question; B's history is separate.

?- self(Me), $A ! ask(Me, a2, "What is my name?").

?- receive({answer(a2, Text) -> true ; model_error(a2, Reason) -> true},
           [timeout(0), on_timeout(fail)]).

% At least ten seconds later, ask B the same question.

?- self(Me), $B ! ask(Me, b2, "What is my name?").

?- receive({answer(b2, Text) -> true ; model_error(b2, Reason) -> true},
           [timeout(0), on_timeout(fail)]).

% Reset A only. No inference is needed, so no ten-second wait is required.
% The acknowledgement means the actor has reached the reset operation.

?- self(Me), $A ! reset(Me, reset_a).

?- receive({reset(reset_a) -> true}, [timeout(0), on_timeout(fail)]).

% Ask A its name again after the inference cooldown. Its earlier history
% is gone. The model may say it does not know, or it may invent a name.

?- self(Me), $A ! ask(Me, a3, "What is my name?").

?- receive({answer(a3, Text) -> true ; model_error(a3, Reason) -> true},
           [timeout(0), on_timeout(fail)]).

% Stop both actors when finished. stop/reset are processed between asks;
% they do not interrupt an inference already in progress.

?- $A ! stop, $B ! stop.

*/
