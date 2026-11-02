/** <module> English replies for the Box Shop's semantic events

The unchanged boxshop-2.xml owns the dialogue, slots and eight-second retry.
This small grammar translates typed or recognised words into the says/1 events
that the chart already understands. It does not choose the next question.
*/

:- use_module(library(apply)).

%% boxshop_event(+Text, -Event) is det.
%
% Consume the whole utterance. Unrecognised text follows the chart's existing
% says(_) fallback; it is never interpreted as executable Prolog source.
boxshop_event(Text, Event) :-
    string_lower(Text, Lower),
    string_codes(Lower, Codes),
    maplist(word_code, Codes, CleanCodes),
    string_codes(Clean, CleanCodes),
    split_string(Clean, " ", " \t\r\n", Strings),
    maplist(atom_string, Words, Strings),
    (   once(phrase(reply(Value), Words))
    ->  Event = says(Value)
    ;   Event = says(unknown)
    ).

word_code(Code, Code) :-
    between(0'a, 0'z, Code),
    !.
word_code(_, 0' ).

reply(Value) --> reply_prefix, reply_article, reply_item(Value), reply_box, reply_please.

reply_prefix --> [].
reply_prefix --> [please].
reply_prefix --> [i, want].
reply_prefix --> [i, like].
reply_prefix --> [i, would, like].
reply_prefix --> [i, d, like].
reply_prefix --> [can, i, have].

reply_article --> [].
reply_article --> [a].
reply_article --> [the].

reply_item(color(Color)) --> color_label, color(Color).
reply_item(size(Size)) --> size_label, size(Size).

color_label --> [].
color_label --> [color].
color_label --> [colour].
size_label --> [].
size_label --> [size].

color(red) --> [red].
color(blue) --> [blue].
color(green) --> [green].
color(yellow) --> [yellow].
color(purple) --> [purple].
color(orange) --> [orange].
color(black) --> [black].
color(white) --> [white].

size(small) --> [small].
size(small) --> [little].
size(big) --> [big].
size(big) --> [large].

reply_box --> [].
reply_box --> [box].
reply_please --> [].
reply_please --> [please].
