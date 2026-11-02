% SPDX-License-Identifier: MIT
% The main-thread UI owns its DOM, event bindings and presentation state.
% The unchanged genealogist.pl in user owns all kinship and edit rules.
:- module(genealogist_ui, [init/0, begin/2, solve/1, completed/3,
                          stopped/0, output/1, input/1, close_input/0]).
:- use_module(library(dom)).
:- use_module(library(wasm)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(ugraphs)).

init :-
    nb_setval(genealogist_ui, ui{ready:true,busy:false,more:false,count:0,goal:''}),
    submit('query-form', request(ask)), submit('relationship-form', mutate(add)),
    on(goal, keydown, E, query_key(E)),
    forall(member(Id-Action, [next-next,stop-stop,abort-abort]), on(Id,click,_,request(Action))),
    on(clear,click,_,clear), on(download,click,_,save),
    on('input-dialog',close,_,input_closed),
    Suggestions := document[querySelectorAll(#'[data-goal]')],
    N := Suggestions[length], Last is N-1,
    forall(between(0,Last,I), (B := Suggestions[item(#I)], bind(B,click,_,suggest(B)))),
    render_family, controls,
    status('Browser engine ready · choose a question or add a connection.').

el(Id, E) :- E := document[getElementById(#Id)].
on(Id, Event, E, Goal) :- el(Id, Element), bind(Element,Event,E,Goal).
:- meta_predicate on(+,+,-,0), submit(+,0).
submit(Id, Goal) :- on(Id,submit,E,(_ := E[preventDefault()],call(Goal))).
text(Id, Text) :- el(Id,E), E[textContent] := #Text.
empty(Id) :- el(Id,E), _ := E[replaceChildren()].
status(Text) :- text(status,Text).
state(S) :- nb_getval(genealogist_ui,S).
put(Key,Value) :- state(S), nb_set_dict(Key,S,Value).
text_atom(Text,A) :- (atom(Text) -> A=Text ; atom_string(A,Text)).
trim_atom(A,T) :- atom_codes(A,Codes),drop_space(Codes,Left),reverse(Left,R),drop_space(R,Right),reverse(Right,Trimmed),atom_codes(T,Trimmed).
drop_space([C|Cs],Rest) :- code_type(C,space), !,drop_space(Cs,Rest).
drop_space(Cs,Cs).
field(Id, A) :- el(Id,E), V := E[value], text_atom(V,A).
attribute(E,K,V) :- _ := E[setAttribute(#K,#V)].
boolean(E,Key,true) :- !, E[Key] := true.
boolean(E,Key,false) :- E[Key] := false.
truth(Goal,true) :- call(Goal), !.
truth(_,false).
:- meta_predicate truth(0,-).
editable :- state(S), S.ready==true, S.busy==false, S.more==false.
controls :-
    state(S), truth(editable,Edit), truth((S.busy==false,S.more==true),Next),
    truth((S.ready==true,S.busy==true),Abort),
    forall(member(Id-Enabled,[ask-Edit,add-Edit,download-Edit,next-Next,stop-Next,abort-Abort]),
           (el(Id,E),truth(Enabled==false,Disabled),boolean(E,disabled,Disabled))),
    Buttons := document[querySelectorAll(#'#relationships button')], N := Buttons[length], Last is N-1,
    forall(between(0,Last,I),(B := Buttons[item(#I)],truth(Edit==false,D),boolean(B,disabled,D))).
request(Action) :- _ := genealogistAction(#Action).
query_key(E) :-
    K := E[key], text_atom(K,Key), Shift := E[shiftKey],
    (Key=='Enter', Shift\==true -> _ := E[preventDefault()], request(ask) ; true).
suggest(B) :- Goal := B[dataset][goal], el(goal,E), E[value] := #Goal, _ := E[focus()].
select(Person) :- format(string(Goal),'ancestor_descendant(~q, Who)',[Person]),
    el(goal,E), E[value] := #Goal, _ := E[focus()].
person_key(Event,Person) :-
    K := Event[key], text_atom(K,Key),
    (memberchk(Key,['Enter',' ']) -> _ := Event[preventDefault()],select(Person) ; true).

begin(ask, Goal) :- editable, field(goal,A), trim_atom(A,Goal), Goal\=='',
    put(goal,Goal), put(busy,true), controls, status('Asking Prolog…').
begin(next, '') :- state(S), S.busy==false,S.more==true,
    put(busy,true), controls, status('Looking for another answer…').
begin(stop, '') :- state(S), S.busy==false,S.more==true, put(busy,true),controls.
begin(abort, '') :- state(S),S.busy==true,status('Abort requested…').

% Render the native bindings before crossing any JS serialization boundary.
% call_cleanup reports whether this solution left a choicepoint, as in the
% runtime's own lazy driver. The surrounding driver handles Next and Stop.
solve(Text) :-
    term_string(Goal,Text,[variable_names(Bindings),module(user),double_quotes(chars)]),
    call_cleanup(call(user:Goal),Det=true),
    once(solution(Bindings,Det)).
solution(Bindings,Det) :-
    findall(Line,(member(Name=Value,Bindings),nonvar(Value),
                  format(string(Line),'~w = ~q',[Name,Value])),Lines),
    (Lines=[] -> Body="true" ; atomics_to_string(Lines,"\n",Body)),
    (Det==true -> Label='SUCCESS' ; Label='SUCCESS · MORE AVAILABLE'),
    card(success,Label,Body), state(S),Count is S.count+1,put(count,Count),text('answer-count',Count).
card(Type,Label,Body) :-
    Empty := document[querySelector(#'.answer-empty')],
    (is_object(Empty) -> _ := Empty[remove()] ; true),
    state(S), format(string(Query),'?- ~w',[S.goal]),
    (Type==error -> Class='answer error' ; Class=answer),
    el(answers,Answers), append_html(Answers,
        article([class=Class],[small([class='query-label'],Query),small(Label),pre(Body)])),
    Height := Answers[scrollHeight], Answers[scrollTop] := #Height.
completed(Type0,More0,Message) :-
    text_atom(Type0,Type), truth((More0==true;More0=="true"),More),
    put(more,More),put(busy,false),
    (Type==success -> true ; Type==failure -> card(failure,'FAILURE',"false")
    ; upcase_atom(Type,Label), (Message=="" -> Body=Type ; Body=Message),card(Type,Label,Body)),
    (More==true -> status('More answers available · choose Next or Stop before editing.')
    ; catch(render_family,E,report(E)), completion_status(Type)),
    close_input,controls.
completion_status(error) :- !,status('Prolog reported an error · you can ask another question.').
completion_status(abort) :- !,status('Query aborted · ready.').
completion_status(_) :- status('Query complete · ready for another question.').
stopped :- put(more,false),put(busy,false),catch(render_family,E,report(E)),controls,
    status('Query stopped · ready to edit or ask again.').
clear :- empty(answers),empty(output),put(count,0),text('answer-count',0).
output(Text) :- el(output,E), Node := document[createTextNode(#Text)],_ := E[appendChild(Node)],
    Parent := E[parentElement], Parent[open] := true.
input(Prompt) :- text('input-prompt',Prompt),el('input-value',V), V[value] := #'',
    el('input-dialog',D),D[returnValue] := #'',_ := D[showModal()],_ := V[focus()].
close_input :- el('input-dialog',D),Open := D[open],(Open==true -> _ := D[close()] ; true).
input_closed :-
    el('input-dialog',D),Result := D[returnValue],text_atom(Result,R),
    (R==send -> field('input-value',Value),_ := genealogistRespond(#Value)
    ; _ := genealogistRespond(null), request(abort)).

mutate(Action) :-
    (editable -> catch(once(edit(Action)),E,report(E)) ; true).
edit(add) :- field(role,Role),field(parent,P0),field(child,C0),
    trim_atom(P0,Parent),trim_atom(C0,Child),
    % Native arguments go straight to the existing validation predicates.
    user:add_relationship(Role,Parent,Child),render_family,controls,
    format(string(Message),'Added ~w → ~w. Ask about the new connection.',[Parent,Child]),
    update_message(Message,false),status('Family updated · the diagram reflects the running Prolog session.').
remove(Role,Parent,Child) :-
    (editable -> catch((user:remove_relationship(Role,Parent,Child),render_family,controls,
      format(string(Message),'Removed ~w → ~w.',[Parent,Child]),update_message(Message,false),
      status('Family updated · the diagram reflects the running Prolog session.')),E,report(E)) ; true).
report(error(domain_error(acyclic_family,_),_)) :- !,
    update_message('That connection would create a cycle. A person cannot be their own ancestor.',true),
    status('Relationship update failed · see the message below the form.').
report(E) :- message_to_string(E,Message),update_message(Message,true),
    status('Operation failed · see the message below the form.').
update_message(Message,Error) :- text('update-message',Message),el('update-message',E),
    (Error==true -> E[className] := #'error' ; E[className] := #'').
save :- editable,
    with_output_to(string(Text),forall(user:relationship(Role,P,C),
        (atom_concat(Role,'_child',Name),Fact=..[Name,P,C],write_term(Fact,[quoted(true)]),write('.'),nl))),
    _ := genealogistSave(#Text).

% Layout uses the same longest-path generation levels as the JS version.
% ugraphs supplies cycle detection and topological ordering; it adds no kinship rules.
render_family :-
    findall(f(R,P,C),user:relationship(R,P,C),Facts),length(Facts,NF),
    (NF>2000 -> throw(error(resource_error(family_diagram),_)) ; true),
    findall(P,(member(f(_,A,B),Facts),member(P,[A,B])),Ps),sort(Ps,People),length(People,NP),
    format(string(Count),'~d people · ~d facts',[NP,NF]),text('people-count',Count),
    el('family-graph',Graph),_ := Graph[replaceChildren()],
    el('graph-empty',Empty),truth(NP>0,HasPeople),boolean(Empty,hidden,HasPeople),
    (NP=:=0 -> attribute(Graph,hidden,'') ; _ := Graph[removeAttribute(#hidden)]),
    findall(P-C,member(f(_,P,C),Facts),Es),sort(Es,Edges),vertices_edges_to_ugraph(People,Edges,G),
    (top_sort(G,Order) -> foldl(person_depth(Edges),Order,[],Depths),
       text('graph-note','Facts and the diagram come from the running Prolog engine.')
    ; findall(P-0,member(P,People),Depths),
      text('graph-note','Cycle detected in raw facts. Remove the cycle before running recursive queries.')),
    findall(D,member(_-D,Depths),Ds),max_list([0|Ds],MaxDepth),
    findall(Width,(between(0,MaxDepth,D),people_at(People,Depths,D,Level),length(Level,N),Width is N*160),Widths),
    max_list([640|Widths],W),H is max(360,(MaxDepth+1)*116),
    format(atom(View),'0 0 ~w ~w',[W,H]),attribute(Graph,viewBox,View),
    findall(pos(P,X,Y,D),(member(P,People),memberchk(P-D,Depths),people_at(People,Depths,D,Level),
      length(Level,N),nth1(I,Level,P),X is W*I/(N+1),Y is 48+D*(H-96)/max(1,MaxDepth)),Positions),
    maplist(draw_edge(Graph,Positions),Facts),maplist(draw_person(Graph),Positions),
    empty(relationships),maplist(draw_relationship,Facts).
person_depth(Edges,P,Before,[P-D|Before]) :-
    findall(Next,(member(A-P,Edges),memberchk(A-AD,Before),Next is AD+1),Parents),max_list([0|Parents],D).
people_at(People,Depths,D,Level) :- include(at_depth(Depths,D),People,Level).
at_depth(Depths,D,P) :- memberchk(P-D,Depths).
svg(Tag,Attrs,Text,E) :-
    E := document[createElementNS(#'http://www.w3.org/2000/svg',#Tag)],
    forall(member(K=V,Attrs),attribute(E,K,V)),
    (Text==none -> true ; E[textContent] := #Text).
dom_append(Parent,Child) :- _ := Parent[appendChild(Child)].
draw_edge(Graph,Positions,f(Role,P,C)) :-
    memberchk(pos(P,X1,Y1,_),Positions),memberchk(pos(C,X2,Y2,_),Positions),
    A is Y1+26,B is (Y1+Y2)/2,Z is Y2-26,
    format(atom(Path),'M ~w ~w C ~w ~w, ~w ~w, ~w ~w',[X1,A,X1,B,X2,B,X2,Z]),
    format(atom(Class),'family-edge ~w',[Role]),svg(path,[d=Path,class=Class],none,E),dom_append(Graph,E).
display_name(Person,Name) :-
    (atom(Person) -> atom_string(Person,S) ; term_string(Person,S)),
    split_string(S,"_","",Parts),atomics_to_string(Parts," ",Spaced),
    (string_chars(Spaced,[First|Rest]) -> upcase_atom(First,Upper),string_chars(Name,[Upper|Rest]) ; Name="").
draw_person(Graph,pos(P,X,Y,D)) :-
    display_name(P,Name),format(atom(Label),'Ask about ~s’s descendants',[Name]),
    TX is X-65,TY is Y-27,format(atom(Transform),'translate(~w ~w)',[TX,TY]),
    svg(g,[class=person,role=button,tabindex=0,'aria-label'=Label,transform=Transform],none,Group),
    svg(rect,[width=130,height=54,rx=10],none,R),dom_append(Group,R),
    svg(circle,[cx=25,cy=27,r=15],none,C),dom_append(Group,C),
    sub_string(Name,0,1,_,Initial),svg(text,[x=25,y=32,'text-anchor'=middle,class=initial],Initial,I),dom_append(Group,I),
    string_length(Name,L),(L>10 -> sub_string(Name,0,9,_,Prefix),string_concat(Prefix,"…",Short) ; Short=Name),
    svg(text,[x=48,y=25,class=name],Short,T),dom_append(Group,T),
    Generation is D+1,format(string(Caption),'GENERATION ~d',[Generation]),
    svg(text,[x=48,y=39,class=role],Caption,Role),dom_append(Group,Role),
    bind(Group,click,_,select(P)),bind(Group,keydown,Event,person_key(Event,P)),dom_append(Graph,Group).
draw_relationship(f(Role,P,C)) :-
    display_name(P,Parent),display_name(C,Child),format(string(Relation),'is ~w of',[Role]),
    html(li([span([Parent,em(Relation),Child]),Remove=button('×')]),[Item],[]),
    format(atom(Label),'Remove ~w relationship from ~w to ~w',[Role,P,C]),attribute(Remove,'aria-label',Label),
    bind(Remove,click,_,remove(Role,P,C)),el(relationships,List),dom_append(List,Item).
