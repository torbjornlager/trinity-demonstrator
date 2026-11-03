% The speech and keyboard paths share this pure language-to-event mapping.
:- begin_tests(boxshop_input).
:- consult(boxshop).

test(simple_colour) :- boxshop_event('blue', says(color(blue))).
test(polite_colour) :-
    boxshop_event('I would like a blue box please', says(color(blue))).
test(colour_label) :- boxshop_event('The colour green', says(color(green))).
test(case_and_punctuation) :- boxshop_event('RED, please!', says(color(red))).
test(contraction) :-
    boxshop_event("I'd like a blue box", says(color(blue))).
test(numeric_token_rejected) :-
    boxshop_event("blue 123", says(unknown)).
test(large_alias) :- boxshop_event('a large box', says(size(big))).
test(small_size) :- boxshop_event('small please', says(size(small))).
test(unknown_text) :- boxshop_event('a sandwich', says(unknown)).
test(whole_utterance_required) :- boxshop_event('blue and large', says(unknown)).
test(no_goal_injection) :- boxshop_event("blue'); halt.", says(unknown)).

:- end_tests(boxshop_input).
