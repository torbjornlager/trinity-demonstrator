% Portable ACTOR checks: stale replies and prompt_ref/2-shaped payloads.
prompt_correlation_check :-
    toplevel_spawn(P, [session(true)]),
    toplevel_call(P, (input(first,X),input(prompt_ref(literal,payload),Y)),
                  [template(pair(X,Y)),limit(1),once(true)]),
    receive({prompt(P,R1,first) -> true},
            [timeout(5),on_timeout(throw(missing_first_prompt))]),
    respond(P,R1,one),
    receive({prompt(P,R2,prompt_ref(literal,payload)) -> true},
            [timeout(5),on_timeout(throw(missing_second_prompt))]),
    R1 \== R2,
    respond(P,R1,stale),
    respond(P,R2,two),
    receive({success(P,[pair(one,two)],false) -> true},
            [timeout(5),on_timeout(throw(missing_correlated_answer))]),
    toplevel_halt(P).

% Exercise backtracking, private source facts, and fresh actor state using
% deterministic partners. The teaching simulation intentionally uses randomness.
expert_example_check :-
    example_conversation([], [yes,yes,no,yes,yes], proved, Questions),
    Questions == ['Does it have feathers?', 'Does it tweet?', 'Is it small?',
                  'Is it cuddly?', 'Is it yellow?'],
    example_conversation([yellow(tweety)], [yes,yes,no,yes], proved, Known),
    \+ member('Is it yellow?', Known),
    example_conversation([], [yes,yes,no,yes,no], not_proved, Fresh),
    member('Is it yellow?', Fresh),
    example_conversation([], [yes,yes,yes], proved, Three),
    Three == ['Does it have feathers?', 'Does it tweet?', 'Is it small?'].

example_conversation(Facts, Answers, Outcome, Questions) :-
    expert_ask(good_pet(tweety), Pid, [src_list(Facts)]),
    catch(( example_answers(Pid, Answers, Outcome, Questions) -> exit(Pid, kill)
          ; exit(Pid, kill), fail ),
          Error, (exit(Pid, kill), throw(Error))).

example_answers(Pid, Answers, Outcome, Questions) :-
    receive({
        prompt(Pid, Ref, Question) ->
            Answers = [Answer|Rest], Questions = [Question|Tail],
            respond(Pid, Ref, Answer),
            example_answers(Pid, Rest, Outcome, Tail) ;
        success(Pid, _, false) -> Outcome = proved, Questions = [] ;
        failure(Pid) -> Outcome = not_proved, Questions = [] ;
        error(Pid, Error) -> throw(Error)
    }, [timeout(5), on_timeout(throw(expert_example_timeout))]).
