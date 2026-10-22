:- module(remote_protocol, [
    protocol_version/1,
    transportable_term/1,
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

The protocol itself is specified in docs/CROSS_NODE_ARCHITECTURE.md.
*/

:- op(200, xfx, @).

:- use_module(actors, [transportable_term/1]).
:- use_module(wire_text, [term_to_wire_text/2, terms_to_wire_texts/2,
                          wire_text_to_term/2]).

%!  protocol_version(-Version) is det.
%
%   The version of the JSON-over-WebSocket cross-node wire protocol
%   (and the message vocabulary the /ws ACTOR endpoint speaks).  The
%   single source of truth: surfaced at /version and announced on
%   outbound cross-node connections via the X-Web-Prolog-Protocol
%   header, so peers and clients can detect the version.  Version 1 is
%   bit-compatible with the trinity-demonstrator's protocol (which does
%   not carry a version field — see docs/CROSS_NODE_ARCHITECTURE.md).
%   Bump this only on an incompatible wire change.
protocol_version(1).


%!  term_to_wire_atom(+Term, -Atom) is det.
%
%   Serialize a term preserving variable sharing and quoting.
term_to_wire_atom(Term, Atom) :-
    (   transportable_term(Term)
    ->  true
    ;   throw(error(type_error(transportable_term, Term),
                    context(remote_protocol:term_to_wire_atom/2,
                            'term is outside the portable wire-term subset')))
    ),
    term_to_wire_text(Term, Atom).


%!  goal_template_to_wire_atoms(+Goal, +Template, -GoalAtom, -TemplateAtom) is det.
%
%   Serialize Goal and Template with shared variable naming preserved across
%   both atoms so they can be parsed back together remotely.
goal_template_to_wire_atoms(Goal, Template, GoalAtom, TemplateAtom) :-
    strip_module(Goal, _, PlainGoal),
    strip_module(Template, _, PlainTemplate),
    terms_to_wire_texts([PlainGoal, PlainTemplate], [GoalAtom, TemplateAtom]).


%!  ws_json_down_reason(+Dict, -Reason) is semidet.
ws_json_down_reason(Dict, Reason) :-
    get_dict(type, Dict, "down"),
    (   get_dict(reason, Dict, ReasonStr)
    ->  (   catch(term_string(Reason, ReasonStr, [double_quotes(string)]), _, fail)
        ->  true
        ;   atom_string(Reason, ReasonStr)
        )
    ;   Reason = unknown
    ).

ws_json_is_io_output(Dict) :-
    % Legacy inbound compatibility only.  Current nodes suppress this
    % internal event at the originating relay and never emit source:"io".
    get_dict(type, Dict, "output"),
    get_dict(source, Dict, "io").


%!  ws_json_to_actor_event(+Dict, +CompoundPid, -Event) is semidet.
%
%   Convert a JSON dict received from `/ws` into a local actor event term.
%   A peer node that received our X-Web-Prolog-Protocol header adds a
%   `term` field with the canonical text of the solution list or the
%   exception (Semantic Contracts D5); the exact terms are then restored.
%   A present canonical field must be valid; correlated success/error replies
%   require it. Only uncorrelated answers without it retain legacy decoding.
ws_json_to_actor_event(Dict, CompoundPid, '$toplevel_reply'(Ref, Answer)) :-
    get_dict(toplevel_correlation, Dict, RefText), !,
    wire_text_to_term(RefText, Ref), ground(Ref),
    del_dict(toplevel_correlation, Dict, _, Plain),
    (   get_dict(type, Plain, Type), memberchk(Type, ["success", "error"]),
        \+ get_dict(term, Plain, _)
    ->  Answer = error(CompoundPid, remote_answer_protocol_error(missing_term))
    ;   ws_json_to_actor_event(Plain, CompoundPid, Answer)
    ).
ws_json_to_actor_event(Dict, CompoundPid, Event) :-
    get_dict(type, Dict, Type), memberchk(Type, ["success", "error"]),
    get_dict(term, Dict, _), !,
    (   event_term(Dict, Payload),
        canonical_answer(Type, Dict, CompoundPid, Payload, Parsed)
    ->  Event = Parsed
    ;   Event = error(CompoundPid, remote_answer_protocol_error(invalid_term))
    ).
ws_json_to_actor_event(Dict, CompoundPid, success(CompoundPid, Rows, More)) :-
    get_dict(type, Dict, "success"),
    !,
    (get_dict(more, Dict, true) -> More = true ; More = false),
    get_dict(data, Dict, DataList),
    maplist(reify_json_row, DataList, Rows).
ws_json_to_actor_event(Dict, CompoundPid, failure(CompoundPid)) :-
    get_dict(type, Dict, "failure"),
    !.
ws_json_to_actor_event(Dict, CompoundPid, error(CompoundPid, Error)) :-
    get_dict(type, Dict, "error"),
    !,
    (get_dict(data, Dict, ErrorStr) -> true ; ErrorStr = "Unknown remote error"),
    Error = remote_error(ErrorStr).
ws_json_to_actor_event(Dict, CompoundPid, output(CompoundPid, Term)) :-
    get_dict(type, Dict, "output"),
    !,
    (   get_dict(data, Dict, DataStr)
    ->  (   catch(term_string(Term, DataStr, [double_quotes(string)]), _, fail)
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


canonical_answer("success", Dict, Pid, Rows, success(Pid, Rows, More)) :-
    is_list(Rows),
    (get_dict(more, Dict, true) -> More = true ; More = false).
canonical_answer("error", _, Pid, Error, error(Pid, Error)).

event_term(Dict, Term) :-
    get_dict(term, Dict, Text),
    string(Text),
    catch(wire_text_to_term(Text, Term), _, fail).

%!  reify_json_row(+JSONRow, -PrologRow) is det.
reify_json_row(Str, Term) :-
    string(Str),
    !,
    (   catch(term_string(Term, Str, [double_quotes(string)]), _, fail)
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
    (   catch(term_string(VOut, V, [double_quotes(string)]), _, fail)
    ->  true
    ;   VOut = V
    ).
reify_json_pair(KV, KV).
