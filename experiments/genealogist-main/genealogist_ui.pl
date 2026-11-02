% SPDX-License-Identifier: MIT

/** <module> Prolog-driven interface for the main-thread Genealogist

The domain program remains in user: it owns the family facts, kinship rules
and validated edits. This module owns the DOM and presentation state.

genealogist.js opens the session and supplies three asynchronous browser
bridges: genealogistAction, genealogistRespond and genealogistSave. Event
handlers request those operations only after their synchronous DOM callback
has returned. The runtime owns the suspended search used by Next and Stop.
*/

:- module(genealogist_ui,
          [ init/0,
            begin/2,
            solve/1,
            completed/3,
            stopped/0,
            output/1,
            input/1,
            close_input/0
          ]).

:- use_module(library(dom)).
:- use_module(library(wasm)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(ugraphs)).

%% init is det.
%
% Bind the static controls once, then draw the initial session facts.
init :-
    nb_setval(genealogist_ui,
              ui{ready:true, busy:false, more:false, count:0, goal:''}),
    submit('query-form', request(ask)),
    submit('relationship-form', mutate(add)),
    on(goal, keydown, Event, query_key(Event)),
    forall(member(Id-Action, [next-next, stop-stop, abort-abort]),
           on(Id, click, _, request(Action))),
    on(clear, click, _, clear),
    on(download, click, _, save),
    on('input-dialog', close, _, input_closed),
    Suggestions := document[querySelectorAll(#'[data-goal]')],
    Count := Suggestions[length],
    Last is Count - 1,
    forall(between(0, Last, Index),
           ( Button := Suggestions[item(#Index)],
             bind(Button, click, _, suggest(Button))
           )),
    render_family,
    controls,
    status('Browser engine ready · choose a question or add a connection.').

% DOM helpers. library(wasm)'s := evaluates a JavaScript expression; #Value
% passes a Prolog value as an argument. Brackets select DOM properties/methods.
el(Id, Element) :-
    Element := document[getElementById(#Id)].

on(Id, EventName, Event, Goal) :-
    el(Id, Element),
    bind(Element, EventName, Event, Goal).

:- meta_predicate on(+,+,-,0), submit(+,0).

submit(Id, Goal) :-
    on(Id, submit, Event,
       ( _ := Event[preventDefault()],
         call(Goal)
       )).

text(Id, Text) :-
    el(Id, Element),
    Element[textContent] := #Text.

empty(Id) :-
    el(Id, Element),
    _ := Element[replaceChildren()].

status(Text) :-
    text(status, Text).

% UI state must survive backtracking through a user's Prolog query.
% Keep it separate from the editable domain database and update it explicitly.
state(State) :-
    nb_getval(genealogist_ui, State).

put(Key, Value) :-
    state(State),
    nb_set_dict(Key, State, Value).

text_atom(Text, Atom) :-
    (   atom(Text)
    ->  Atom = Text
    ;   atom_string(Atom, Text)
    ).

% Trim only the edges: normalize_space/2 would alter spaces in quoted goals.
trim_atom(Atom, TrimmedAtom) :-
    atom_codes(Atom, Codes),
    drop_space(Codes, LeftTrimmed),
    reverse(LeftTrimmed, Reversed),
    drop_space(Reversed, RightTrimmed),
    reverse(RightTrimmed, TrimmedCodes),
    atom_codes(TrimmedAtom, TrimmedCodes).

drop_space([Code|Codes], Rest) :-
    code_type(Code, space),
    !,
    drop_space(Codes, Rest).
drop_space(Codes, Codes).

field(Id, Atom) :-
    el(Id, Element),
    Value := Element[value],
    text_atom(Value, Atom).

attribute(Element, Key, Value) :-
    _ := Element[setAttribute(#Key, #Value)].

% Assign actual JavaScript booleans; the string "false" would be truthy.
boolean(Element, Key, true) :-
    !,
    Element[Key] := true.
boolean(Element, Key, false) :-
    Element[Key] := false.

truth(Goal, true) :-
    call(Goal),
    !.
truth(_, false).

:- meta_predicate truth(0,-).

editable :-
    state(State),
    State.ready == true,
    State.busy == false,
    State.more == false.

% A pending continuation shares the same engine as edits and diagram refreshes.
% Disable conflicting controls until the query finishes or Stop discards it.
controls :-
    state(State),
    truth(editable, Edit),
    truth((State.busy == false, State.more == true), Next),
    truth((State.ready == true, State.busy == true), Abort),
    forall(member(Id-Enabled,
                  [ask-Edit, add-Edit, download-Edit,
                   next-Next, stop-Next, abort-Abort]),
           ( el(Id, Element),
             truth(Enabled == false, Disabled),
             boolean(Element, disabled, Disabled)
           )),
    Buttons := document[querySelectorAll(#'#relationships button')],
    Count := Buttons[length],
    Last is Count - 1,
    forall(between(0, Last, Index),
           ( Button := Buttons[item(#Index)],
             truth(Edit == false, ButtonDisabled),
             boolean(Button, disabled, ButtonDisabled)
           )).

request(Action) :-
    _ := genealogistAction(#Action).

query_key(Event) :-
    KeyValue := Event[key],
    text_atom(KeyValue, Key),
    Shift := Event[shiftKey],
    (   Key == 'Enter',
        Shift \== true
    ->  _ := Event[preventDefault()],
        request(ask)
    ;   true
    ).

suggest(Button) :-
    Goal := Button[dataset][goal],
    el(goal, Element),
    Element[value] := #Goal,
    _ := Element[focus()].

select(Person) :-
    format(string(Goal), 'ancestor_descendant(~q, Who)', [Person]),
    el(goal, Element),
    Element[value] := #Goal,
    _ := Element[focus()].

person_key(Event, Person) :-
    KeyValue := Event[key],
    text_atom(KeyValue, Key),
    (   memberchk(Key, ['Enter', ' '])
    ->  _ := Event[preventDefault()],
        select(Person)
    ;   true
    ).

%% begin(+Action, -Goal) is semidet.
%
% JavaScript asks permission to start an operation. Failure means that the
% control is currently unavailable. Only a new Ask reads the query field;
% Next resumes the existing search even if the field has since been edited.
begin(ask, Goal) :-
    editable,
    field(goal, RawGoal),
    trim_atom(RawGoal, Goal),
    Goal \== '',
    put(goal, Goal),
    put(busy, true),
    controls,
    status('Asking Prolog…').
begin(next, '') :-
    state(State),
    State.busy == false,
    State.more == true,
    put(busy, true),
    controls,
    status('Looking for another answer…').
begin(stop, '') :-
    state(State),
    State.busy == false,
    State.more == true,
    put(busy, true),
    controls.
begin(abort, '') :-
    state(State),
    State.busy == true,
    status('Abort requested…').

%% solve(+Text) is nondet.
%
% Render native bindings before they cross a JavaScript serialization boundary.
% call_cleanup/2 reports whether this solution left a choicepoint, as in the
% runtime's lazy driver. Rendering is committed once per answer; the surrounding
% driver owns suspension, backtracking on Next, and unwinding on Stop/Abort.
solve(Text) :-
    term_string(Goal, Text,
                [variable_names(Bindings), module(user), double_quotes(chars)]),
    call_cleanup(call(user:Goal), Deterministic = true),
    once(solution(Bindings, Deterministic)).

solution(Bindings, Deterministic) :-
    findall(Line,
            ( member(Name=Value, Bindings),
              nonvar(Value),
              format(string(Line), '~w = ~q', [Name, Value])
            ),
            Lines),
    (   Lines = []
    ->  Body = "true"
    ;   atomics_to_string(Lines, "\n", Body)
    ),
    (   Deterministic == true
    ->  Label = 'SUCCESS'
    ;   Label = 'SUCCESS · MORE AVAILABLE'
    ),
    card(success, Label, Body),
    state(State),
    Count is State.count + 1,
    put(count, Count),
    text('answer-count', Count).

card(Type, Label, Body) :-
    Empty := document[querySelector(#'.answer-empty')],
    (   is_object(Empty)
    ->  _ := Empty[remove()]
    ;   true
    ),
    state(State),
    format(string(Query), '?- ~w', [State.goal]),
    (   Type == error
    ->  Class = 'answer error'
    ;   Class = answer
    ),
    el(answers, Answers),
    append_html(Answers,
                article([class=Class],
                        [ small([class='query-label'], Query),
                          small(Label),
                          pre(Body)
                        ])),
    Height := Answers[scrollHeight],
    Answers[scrollTop] := #Height.

%% completed(+Type, +More, +Message) is det.
%
% The asynchronous session call has returned. Successful cards were already
% rendered by solve/1; failures and errors need a terminal card here instead.
completed(TypeValue, MoreValue, Message) :-
    text_atom(TypeValue, Type),
    truth((MoreValue == true ; MoreValue == "true"), More),
    put(more, More),
    put(busy, false),
    (   Type == success
    ->  true
    ;   Type == failure
    ->  card(failure, 'FAILURE', "false")
    ;   upcase_atom(Type, Label),
        (Message == "" -> Body = Type ; Body = Message),
        card(Type, Label, Body)
    ),
    (   More == true
    ->  status('More answers available · choose Next or Stop before editing.')
    ;   catch(render_family, Error, report(Error)),
        completion_status(Type)
    ),
    close_input,
    controls.

completion_status(error) :-
    !,
    status('Prolog reported an error · you can ask another question.').
completion_status(abort) :-
    !,
    status('Query aborted · ready.').
completion_status(_) :-
    status('Query complete · ready for another question.').

stopped :-
    put(more, false),
    put(busy, false),
    catch(render_family, Error, report(Error)),
    controls,
    status('Query stopped · ready to edit or ask again.').

clear :-
    empty(answers),
    empty(output),
    put(count, 0),
    text('answer-count', 0).

output(Text) :-
    el(output, Element),
    Node := document[createTextNode(#Text)],
    _ := Element[appendChild(Node)],
    Parent := Element[parentElement],
    Parent[open] := true.

% Prolog waits on a browser Promise while the input dialog is open. Closing the
% dialog either supplies text to that request or requests cooperative Abort.
input(Prompt) :-
    text('input-prompt', Prompt),
    el('input-value', Value),
    Value[value] := #'',
    el('input-dialog', Dialog),
    Dialog[returnValue] := #'',
    _ := Dialog[showModal()],
    _ := Value[focus()].

close_input :-
    el('input-dialog', Dialog),
    Open := Dialog[open],
    (Open == true -> _ := Dialog[close()] ; true).

input_closed :-
    el('input-dialog', Dialog),
    Result := Dialog[returnValue],
    text_atom(Result, Response),
    (   Response == send
    ->  field('input-value', Value),
        _ := genealogistRespond(#Value)
    ;   _ := genealogistRespond(null),
        request(abort)
    ).

% Edits use native arguments, rather than constructing executable goal text.
% The domain predicates apply the same validation in either execution model.
mutate(Action) :-
    (   editable
    ->  catch(once(edit(Action)), Error, report(Error))
    ;   true
    ).

edit(add) :-
    field(role, Role),
    field(parent, RawParent),
    field(child, RawChild),
    trim_atom(RawParent, Parent),
    trim_atom(RawChild, Child),
    user:add_relationship(Role, Parent, Child),
    render_family,
    controls,
    format(string(Message),
           'Added ~w → ~w. Ask about the new connection.', [Parent, Child]),
    update_message(Message, false),
    status('Family updated · the diagram reflects the running Prolog session.').

remove(Role, Parent, Child) :-
    (   editable
    ->  catch(( user:remove_relationship(Role, Parent, Child),
                render_family,
                controls,
                format(string(Message), 'Removed ~w → ~w.', [Parent, Child]),
                update_message(Message, false),
                status('Family updated · the diagram reflects the running Prolog session.')
              ),
              Error,
              report(Error))
    ;   true
    ).

report(error(domain_error(acyclic_family, _), _)) :-
    !,
    update_message('That connection would create a cycle. A person cannot be their own ancestor.',
                   true),
    status('Relationship update failed · see the message below the form.').
report(Error) :-
    message_to_string(Error, Message),
    update_message(Message, true),
    status('Operation failed · see the message below the form.').

update_message(Message, Error) :-
    text('update-message', Message),
    el('update-message', Element),
    (   Error == true
    ->  Element[className] := #'error'
    ;   Element[className] := #''
    ).

% The saved file contains only the original domain rules and current facts.
% write_term/2 preserves quoting for atoms introduced through the query box.
save :-
    editable,
    with_output_to(string(Text),
                   forall(user:relationship(Role, Parent, Child),
                          ( atom_concat(Role, '_child', Name),
                            Fact =.. [Name, Parent, Child],
                            write_term(Fact, [quoted(true)]),
                            write('.'),
                            nl
                          ))),
    _ := genealogistSave(#Text).

% Diagram layout. Longest-path generation levels are a drawing aid, not a
% second definition of kinship. ugraphs handles topological order and cycles.
render_family :-
    findall(f(Role, Person, Child),
            user:relationship(Role, Person, Child),
            Facts),
    length(Facts, FactCount),
    (   FactCount > 2000
    ->  throw(error(resource_error(family_diagram), _))
    ;   true
    ),
    findall(Person,
            (member(f(_, Parent, Descendant), Facts), member(Person, [Parent, Descendant])),
            AllPeople),
    sort(AllPeople, People),
    length(People, PersonCount),
    format(string(Count), '~d people · ~d facts', [PersonCount, FactCount]),
    text('people-count', Count),
    el('family-graph', Graph),
    _ := Graph[replaceChildren()],
    el('graph-empty', Empty),
    truth(PersonCount > 0, HasPeople),
    boolean(Empty, hidden, HasPeople),
    (   PersonCount =:= 0
    ->  attribute(Graph, hidden, '')
    ;   _ := Graph[removeAttribute(#hidden)]
    ),
    findall(Person-Child, member(f(_, Person, Child), Facts), AllEdges),
    sort(AllEdges, Edges),
    vertices_edges_to_ugraph(People, Edges, FamilyGraph),
    (   top_sort(FamilyGraph, Order)
    ->  foldl(person_depth(Edges), Order, [], Depths),
        text('graph-note', 'Facts and the diagram come from the running Prolog engine.')
    ;   findall(Person-0, member(Person, People), Depths),
        text('graph-note', 'Cycle detected in raw facts. Remove the cycle before running recursive queries.')
    ),
    findall(Depth, member(_-Depth, Depths), AllDepths),
    max_list([0|AllDepths], MaxDepth),
    findall(LevelWidth,
            ( between(0, MaxDepth, Depth),
              people_at(People, Depths, Depth, Level),
              length(Level, LevelCount),
              LevelWidth is LevelCount * 160
            ),
            Widths),
    max_list([640|Widths], Width),
    Height is max(360, (MaxDepth + 1) * 116),
    format(atom(View), '0 0 ~w ~w', [Width, Height]),
    attribute(Graph, viewBox, View),
    findall(pos(Person, X, Y, Depth),
            ( member(Person, People),
              memberchk(Person-Depth, Depths),
              people_at(People, Depths, Depth, Level),
              length(Level, LevelCount),
              nth1(Index, Level, Person),
              X is Width * Index / (LevelCount + 1),
              Y is 48 + Depth * (Height - 96) / max(1, MaxDepth)
            ),
            Positions),
    maplist(draw_edge(Graph, Positions), Facts),
    maplist(draw_person(Graph), Positions),
    empty(relationships),
    maplist(draw_relationship, Facts).

% The fold visits parents before children, so every parent's depth is known.
person_depth(Edges, Person, Before, [Person-Depth|Before]) :-
    findall(NextDepth,
            ( member(Parent-Person, Edges),
              memberchk(Parent-ParentDepth, Before),
              NextDepth is ParentDepth + 1
            ),
            ParentDepths),
    max_list([0|ParentDepths], Depth).

people_at(People, Depths, Depth, Level) :-
    include(at_depth(Depths, Depth), People, Level).

at_depth(Depths, Depth, Person) :-
    memberchk(Person-Depth, Depths).

% library(dom)'s HTML builder creates HTML elements. SVG nodes must be created
% explicitly in the SVG namespace; all labels are assigned as text content.
svg(Tag, Attributes, Text, Element) :-
    Element := document[createElementNS(#'http://www.w3.org/2000/svg', #Tag)],
    forall(member(Key=Value, Attributes), attribute(Element, Key, Value)),
    (Text == none -> true ; Element[textContent] := #Text).

dom_append(Parent, Child) :-
    _ := Parent[appendChild(Child)].

draw_edge(Graph, Positions, f(Role, Parent, Child)) :-
    memberchk(pos(Parent, ParentX, ParentY, _), Positions),
    memberchk(pos(Child, ChildX, ChildY, _), Positions),
    StartY is ParentY + 26,
    MiddleY is (ParentY + ChildY) / 2,
    EndY is ChildY - 26,
    format(atom(Path), 'M ~w ~w C ~w ~w, ~w ~w, ~w ~w',
           [ParentX, StartY, ParentX, MiddleY, ChildX, MiddleY, ChildX, EndY]),
    format(atom(Class), 'family-edge ~w', [Role]),
    svg(path, [d=Path, class=Class], none, Element),
    dom_append(Graph, Element).

display_name(Person, Name) :-
    (atom(Person) -> atom_string(Person, Raw) ; term_string(Person, Raw)),
    split_string(Raw, "_", "", Parts),
    atomics_to_string(Parts, " ", Spaced),
    (   string_chars(Spaced, [First|Rest])
    ->  upcase_atom(First, Upper),
        string_chars(Name, [Upper|Rest])
    ;   Name = ""
    ).

draw_person(Graph, pos(Person, X, Y, Depth)) :-
    display_name(Person, Name),
    format(atom(Label), 'Ask about ~s’s descendants', [Name]),
    TranslateX is X - 65,
    TranslateY is Y - 27,
    format(atom(Transform), 'translate(~w ~w)', [TranslateX, TranslateY]),
    svg(g, [ class=person,
             role=button,
             tabindex=0,
             'aria-label'=Label,
             transform=Transform
           ], none, Group),
    svg(rect, [width=130, height=54, rx=10], none, Rectangle),
    dom_append(Group, Rectangle),
    svg(circle, [cx=25, cy=27, r=15], none, Circle),
    dom_append(Group, Circle),
    sub_string(Name, 0, 1, _, Initial),
    svg(text, [x=25, y=32, 'text-anchor'=middle, class=initial], Initial, InitialText),
    dom_append(Group, InitialText),
    string_length(Name, Length),
    (   Length > 10
    ->  sub_string(Name, 0, 9, _, Prefix),
        string_concat(Prefix, "…", Short)
    ;   Short = Name
    ),
    svg(text, [x=48, y=25, class=name], Short, NameText),
    dom_append(Group, NameText),
    Generation is Depth + 1,
    format(string(Caption), 'GENERATION ~d', [Generation]),
    svg(text, [x=48, y=39, class=role], Caption, RoleText),
    dom_append(Group, RoleText),
    bind(Group, click, _, select(Person)),
    bind(Group, keydown, Event, person_key(Event, Person)),
    dom_append(Graph, Group).

draw_relationship(f(Role, Parent, Child)) :-
    display_name(Parent, ParentName),
    display_name(Child, ChildName),
    format(string(Relation), 'is ~w of', [Role]),
    % Element=Tag(...) binds the newly created node for attributes and events.
    html(li([ span([ParentName, em(Relation), ChildName]),
              Remove=button('×')
            ]), [Item], []),
    format(atom(Label), 'Remove ~w relationship from ~w to ~w', [Role, Parent, Child]),
    attribute(Remove, 'aria-label', Label),
    bind(Remove, click, _, remove(Role, Parent, Child)),
    el(relationships, List),
    dom_append(List, Item).
