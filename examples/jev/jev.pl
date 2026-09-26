:- module(jev, [
    jev_decide/2,
    jev_decide/3,
    jev_decide/4
]).

/** <module> Typed probabilistic Jev decisions as Prolog data

Questions are ordinary Prolog terms whose final argument is bound to a typed
answer:

  * `choice(Id, Instructions, Option-Description pairs, Answer)`
  * `score(Id, Instructions, ordered level descriptions, Answer)`
  * `noul(Id, Instructions, Answer)`
  * `noul(Id, Instructions, [true-Description,false-Description], Answer)`

Choice answers are `choice(Value, Probabilities, Confidence)`, Score answers
are `score(Value, Legend, Probabilities, Confidence)`, and Noul answers are
`noul(Probability)`.  `jev_decide/3` and `jev_decide/4` also return the complete
provider response, so new or provider-specific fields are never discarded.
*/

:- use_module(jev_http).
:- use_module(library(option)).
:- use_module(library(error)).

%!  jev_decide(+State, +Questions) is det.
%!  jev_decide(+State, +Questions, -Response) is det.
%!  jev_decide(+State, +Questions, -Response, +Options) is det.
%
%   Evaluate all Questions against State in one Jev request.  `model/1` is a
%   high-level option (default `jev-latest`); remaining options are passed to
%   jev_http_request/3.

jev_decide(State, Questions) :-
    jev_decide(State, Questions, _Response).

jev_decide(State, Questions, Response) :-
    jev_decide(State, Questions, Response, []).

jev_decide(State, Questions, Response, Options0) :-
    must_be(list, Questions),
    must_be(list, Options0),
    select_option(model(Model0), Options0, HttpOptions, 'jev-latest'),
    text_string(Model0, Model),
    maplist(question_json, Questions, Pairs, Bindings),
    dict_create(QuestionDict, questions, Pairs),
    Payload = _{model:Model, state:State, questions:QuestionDict},
    jev_http_request(Payload, Response, HttpOptions),
    response_answers(Response, Answers),
    maplist(bind_answer(Answers), Bindings).

question_json(choice(Id0, Instructions, Criteria0, Answer),
              Id-Question, binding(Id, choice, Answer)) :-
    !,
    question_id(Id0, Id),
    pair_dict(choice_criteria, Criteria0, Criteria),
    Question = _{type:"choice", instructions:Instructions, criteria:Criteria}.
question_json(score(Id0, Instructions, Criteria, Answer),
              Id-Question, binding(Id, score, Answer)) :-
    !,
    question_id(Id0, Id),
    must_be(list, Criteria),
    Question = _{type:"score", instructions:Instructions, criteria:Criteria}.
question_json(noul(Id0, Instructions, Answer),
              Id-Question, binding(Id, noul, Answer)) :-
    !,
    question_id(Id0, Id),
    Question = _{type:"noul", instructions:Instructions}.
question_json(noul(Id0, Instructions, Criteria0, Answer),
              Id-Question, binding(Id, noul, Answer)) :-
    !,
    question_id(Id0, Id),
    pair_dict(noul_criteria, Criteria0, Criteria),
    Question = _{type:"noul", instructions:Instructions, criteria:Criteria}.
question_json(Question, _, _) :-
    domain_error(jev_question, Question).

question_id(Id, Id) :- atom(Id), !.
question_id(Id0, Id) :- string(Id0), !, atom_string(Id, Id0).
question_id(Id, _) :- type_error(atom_or_string, Id).

pair_dict(Context, Pairs0, Dict) :-
    must_be(list, Pairs0),
    maplist(json_pair(Context), Pairs0, Pairs),
    dict_create(Dict, json, Pairs).

json_pair(_Context, Key0-Value, Key-Value) :-
    !,
    question_id(Key0, Key).
json_pair(Context, Pair, _) :-
    throw(error(domain_error(Context, Pair), _)).

response_answers(Response, Answers) :-
    (   get_dict(answers, Response, Answers), is_dict(Answers)
    ->  true
    ;   throw(error(domain_error(jev_response, Response),
                    context(jev:jev_decide/4, 'Response has no answers object')))
    ).

bind_answer(Answers, binding(Id, ExpectedType, Target)) :-
    (   get_dict(Id, Answers, Raw)
    ->  bind_typed_answer(ExpectedType, Raw, Target)
    ;   throw(error(existence_error(jev_answer, Id),
                    context(jev:jev_decide/4, 'Jev omitted a requested answer')))
    ).

bind_typed_answer(choice, Raw, choice(Choice, Probabilities, Confidence)) :-
    require_answer_type(choice, Raw),
    required_field(choice, Raw, Choice0),
    required_field(probabilities, Raw, Probabilities),
    required_field(confidence, Raw, Confidence),
    symbolic_atom(Choice0, Choice).
bind_typed_answer(score, Raw,
                  score(Score, Legend, Probabilities, Confidence)) :-
    require_answer_type(score, Raw),
    required_field(score, Raw, Score),
    required_field(legend, Raw, Legend),
    required_field(probabilities, Raw, Probabilities),
    required_field(confidence, Raw, Confidence).
bind_typed_answer(noul, Raw, noul(Probability)) :-
    require_answer_type(noul, Raw),
    required_field(noul, Raw, Probability).

require_answer_type(Expected, Raw) :-
    required_field(type, Raw, Type0),
    symbolic_atom(Type0, Type),
    (   Type == Expected
    ->  true
    ;   throw(error(type_error(jev_answer(Expected), Raw), _))
    ).

required_field(Name, Dict, Value) :-
    (   \+ is_dict(Dict)
    ->  throw(error(domain_error(jev_response, Dict),
                    context(jev:jev_decide/4, 'Answer must be a JSON object')))
    ;   get_dict(Name, Dict, Value)
    ->  true
    ;   throw(error(existence_error(jev_answer_field, Name),
                    context(jev:jev_decide/4, Dict)))
    ).

symbolic_atom(Value, Atom) :-
    (   atom(Value) -> Atom = Value
    ;   string(Value) -> atom_string(Atom, Value)
    ;   type_error(atom_or_string, Value)
    ).

text_string(Value, String) :-
    (   string(Value) -> String = Value
    ;   atom(Value) -> atom_string(Value, String)
    ;   type_error(text, Value)
    ).
