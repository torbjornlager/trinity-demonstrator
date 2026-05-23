:- module(remote_protocol, [
    term_to_wire_atom/2,
    goal_template_to_wire_atoms/4,
    ws_json_down_reason/2,
    ws_json_is_io_output/1,
    ws_json_to_actor_event/3,
    reify_json_row/2
]).

/** <module> Remote Wire Protocol Helpers

Shared helpers for actor/toplevel remote WebSocket transport:

  - serializing Prolog terms for the wire,
  - decoding JSON actor events from `/ws`.
*/

:- op(200, xfx, @).


%!  term_to_wire_atom(+Term, -Atom) is det.
%
%   Serialize a term preserving variable sharing and quoting.
term_to_wire_atom(Term, Atom) :-
    copy_term(Term, Copy),
    numbervars(Copy, 0, _),
    with_output_to(atom(Atom),
                   write_term(Copy, [numbervars(true), quoted(true)])).


%!  goal_template_to_wire_atoms(+Goal, +Template, -GoalAtom, -TemplateAtom) is det.
%
%   Serialize Goal and Template with shared variable naming preserved across
%   both atoms so they can be parsed back together remotely.
goal_template_to_wire_atoms(Goal, Template, GoalAtom, TemplateAtom) :-
    strip_module(Goal, _, PlainGoal),
    strip_module(Template, _, PlainTemplate),
    copy_term(PlainGoal+PlainTemplate, CopyGoal+CopyTemplate),
    numbervars(CopyGoal+CopyTemplate, 0, _),
    with_output_to(atom(GoalAtom),
                   write_term(CopyGoal, [numbervars(true), quoted(true)])),
    with_output_to(atom(TemplateAtom),
                   write_term(CopyTemplate, [numbervars(true), quoted(true)])).


%!  ws_json_down_reason(+Dict, -Reason) is semidet.
ws_json_down_reason(Dict, Reason) :-
    get_dict(type, Dict, "down"),
    (   get_dict(reason, Dict, ReasonStr)
    ->  (   catch(term_string(Reason, ReasonStr), _, fail)
        ->  true
        ;   atom_string(Reason, ReasonStr)
        )
    ;   Reason = unknown
    ).

ws_json_is_io_output(Dict) :-
    get_dict(type, Dict, "output"),
    get_dict(source, Dict, "io").


%!  ws_json_to_actor_event(+Dict, +CompoundPid, -Event) is semidet.
%
%   Convert a JSON dict received from `/ws` into a local actor event term.
ws_json_to_actor_event(Dict, CompoundPid, success(CompoundPid, Rows, More)) :-
    get_dict(type, Dict, "success"),
    !,
    get_dict(data, Dict, DataList),
    (get_dict(more, Dict, true) -> More = true ; More = false),
    maplist(reify_json_row, DataList, Rows).
ws_json_to_actor_event(Dict, CompoundPid, failure(CompoundPid)) :-
    get_dict(type, Dict, "failure"),
    !.
ws_json_to_actor_event(Dict, CompoundPid, error(CompoundPid, remote_error(ErrorStr))) :-
    get_dict(type, Dict, "error"),
    !,
    (get_dict(data, Dict, ErrorStr) -> true ; ErrorStr = "Unknown remote error").
ws_json_to_actor_event(Dict, CompoundPid, output(CompoundPid, Term)) :-
    get_dict(type, Dict, "output"),
    !,
    (   get_dict(data, Dict, DataStr)
    ->  (   catch(term_string(Term, DataStr), _, fail)
        ->  true
        ;   Term = DataStr
        )
    ;   Term = ''
    ).
ws_json_to_actor_event(Dict, CompoundPid, prompt(CompoundPid, Prompt)) :-
    get_dict(type, Dict, "prompt"),
    !,
    (   get_dict(data, Dict, PromptStr)
    ->  atom_string(Prompt, PromptStr)
    ;   Prompt = ''
    ).
ws_json_to_actor_event(Dict, CompoundPid, stop(CompoundPid)) :-
    get_dict(type, Dict, "stop"),
    !.
ws_json_to_actor_event(Dict, CompoundPid, abort(CompoundPid)) :-
    get_dict(type, Dict, "abort"),
    !.
ws_json_to_actor_event(Dict, CompoundPid, responded(CompoundPid)) :-
    get_dict(type, Dict, "responded"),
    !.


%!  reify_json_row(+JSONRow, -PrologRow) is det.
reify_json_row(Str, Term) :-
    string(Str),
    !,
    (   catch(term_string(Term, Str), _, fail)
    ->  true
    ;   Term = Str
    ).
reify_json_row(DictIn, DictOut) :-
    is_dict(DictIn),
    !,
    dict_pairs(DictIn, Tag, Pairs),
    maplist(reify_json_pair, Pairs, PairsOut),
    dict_pairs(DictOut, Tag, PairsOut).
reify_json_row(V, V).

reify_json_pair(K-V, K-VOut) :-
    string(V),
    !,
    (   catch(term_string(VOut, V), _, fail)
    ->  true
    ;   VOut = V
    ).
reify_json_pair(KV, KV).
