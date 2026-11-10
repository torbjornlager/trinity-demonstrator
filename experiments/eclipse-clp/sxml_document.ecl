% SPDX-License-Identifier: MIT
:- module(sxml_document).
:- lib(xml).
:- lib(json).
:- lib(prolog_extras).
:- import text_string/2 from actors.
:- import egress_request/4 from isotope_rpc.

:- export parse_sxml/2, prepare_sxml/5, statechart_validate/2, statechart_validate_text/2.
:- export sxml_delay/2, sxml_targets/2, sxml_prolog_source/3.

prepare_sxml(Options, ParentBase, Document, Trace, SpawnOptions) :-
    ( var(Options) -> throw(error(instantiation_error, statechart_spawn/2))
    ; is_list(Options) -> true
    ; throw(error(type_error(list, Options), statechart_spawn/2))
    ),
    chart_options(Options, Sources, Traces, SpawnOptions),
    ( Sources = [Source] -> true
    ; Sources == [] ->
        throw(error(existence_error(option, src_uri_or_src_text), statechart_spawn/2))
    ; throw(error(domain_error(single_statechart_source_option, Sources), statechart_spawn/2))
    ),
    ( Traces = [Trace|_] -> true ; Trace = true ),
    chart_source(Source, ParentBase, Base, Text),
    parse_sxml(Text, Tree),
    Document = document(Base, Tree).

chart_options([], [], [], []).
chart_options([Option|Options], Sources, Traces, SpawnOptions) :-
    ( var(Option) -> throw(error(instantiation_error, statechart_spawn/2))
    ; ( Option = src_text(_) ; Option = src_uri(_) ) ->
        Sources = [Option|MoreSources],
        MoreTraces = Traces, MoreOptions = SpawnOptions
    ; Option = trace(Trace) ->
        ( var(Trace) -> throw(error(instantiation_error, statechart_spawn/2))
        ; ( Trace == true ; Trace == false ) -> true
        ; throw(error(domain_error(boolean, Trace), statechart_spawn/2))
        ),
        Traces = [Trace|MoreTraces],
        MoreSources = Sources, MoreOptions = SpawnOptions
    ; SpawnOptions = [Option|MoreOptions],
      MoreSources = Sources, MoreTraces = Traces
    ),
    chart_options(Options, MoreSources, MoreTraces, MoreOptions).

chart_source(src_text(Value), Base, Base, Text) :-
    require_text(Value, Text).
chart_source(src_uri(Value), ParentBase, Base, Text) :-
    read_document_source(Value, ParentBase, "sxml", Base, Text).

sxml_prolog_source(Value, ParentBase, Text) :-
    read_document_source(Value, ParentBase, "prolog", _, Text).

read_document_source(Value, ParentBase, Kind, Base, Text) :-
    require_text(Value, Uri),
    ( ParentBase == none -> Params = [kind:Kind]
    ; Params = [kind:Kind, base:ParentBase] ),
    egress_request("chart_source", Uri, Params, Reply),
    setup_call_cleanup(
        open(string(Reply), read, Stream),
        json_read(Stream, {Fields}, [names_as_atoms]),
        close(Stream)
    ),
    memberchk(base:Base, Fields),
    memberchk(text:Text, Fields).

require_text(Value, Text) :-
    ( var(Value) -> throw(error(instantiation_error, sxml_document))
    ; text_string(Value, Text) -> true
    ; throw(error(type_error(text, Value), sxml_document))
    ).

statechart_validate(Uri, Diagnostics) :-
    chart_source(src_uri(Uri), none, _, Text),
    statechart_validate_text(Text, Diagnostics).

statechart_validate_text(Text, Diagnostics) :-
    catch((parse_sxml(Text, _), Diagnostics = []), Error,
          validation_diagnostics(Error, Diagnostics)).

validation_diagnostics(error(sxml_validation_error(Diagnostics), _), Diagnostics) :- !.
validation_diagnostics(Error, [diagnostic(error, unknown, Error)]).

parse_sxml(Value, Tree) :-
    require_text(Value, Text),
    string_length(Text, Size),
    ( Size =< 131072 -> true
    ; throw(error(resource_error(sxml_document_size), sxml_document))
    ),
    ( string_list(Text, Codes0, utf8) -> true
    ; structural_error(malformed_xml, encoding)
    ),
    ( Codes0 = [65279|Codes] -> true ; Codes = Codes0 ),
    ( xml_characters(Codes) -> true
    ; structural_error(malformed_xml, invalid_character)
    ),
    ( phrase(xml_preflight(0, Prepared, []), Codes) -> true
    ; structural_error(malformed_xml, markup)
    ),
    ( xml_parse([format(false), extended_characters(false)], Prepared, xml(_, Content)) -> true
    ; structural_error(malformed_xml, document)
    ),
    ( normalize_nodes(Content, Nodes) -> true
    ; structural_error(malformed_xml, invalid_text)
    ),
    exclude_blank_text(Nodes, Tree),
    validate_sxml_structure(Tree),
    !.

% Preflight rejects declarations before lib(xml) can process them and limits
% nesting. Quote whitespace as references because lib(xml) collapses literal
% attribute whitespace even for SXML CDATA attributes containing Prolog.
xml_preflight(Depth, Output, Tail) -->
    xml_delimiter(comment, Open, Close), !,
    { append(Open, More, Output) },
    xml_section(Close, More, Next), xml_preflight(Depth, Next, Tail).
xml_preflight(Depth, Output, Tail) -->
    xml_delimiter(cdata, Open, Close), !,
    { append(Open, More, Output) },
    xml_section(Close, More, Next), xml_preflight(Depth, Next, Tail).
xml_preflight(Depth, Output, Tail) -->
    xml_delimiter(instruction, Open, Close), !,
    { append(Open, More, Output) },
    xml_section(Close, More, Next), xml_preflight(Depth, Next, Tail).
xml_preflight(_, _, _) -->
    [60,33], !, { structural_error(forbidden_xml_declaration, document) }.
xml_preflight(Depth, [60,47|More], Tail) -->
    [60,47], !, xml_end_tag(More, Next),
    { Depth > 0, Parent is Depth - 1 }, xml_preflight(Parent, Next, Tail).
xml_preflight(Depth, [60|More], Tail) -->
    [60], !,
    { Depth < 128 -> true ; throw(error(resource_error(sxml_document_depth), sxml_document)) },
    xml_name(More, AfterName), xml_tag_tail(Kind, AfterName, Next),
    { Kind == empty -> Child = Depth ; Child is Depth + 1 },
    xml_preflight(Child, Next, Tail).
xml_preflight(Depth, [38|More], Tail) -->
    [38], !, xml_entity(More, Next), xml_preflight(Depth, Next, Tail).
xml_preflight(Depth, [C|More], Tail) --> [C], !, xml_preflight(Depth, More, Tail).
xml_preflight(0, Tail, Tail) --> [].

xml_delimiter(Kind, Open, Close) -->
    { xml_delimiters(Kind, Open, Close) }, xml_prefix(Open).

% Opening and closing sequences for comments, CDATA and processing instructions.
xml_delimiters(comment, [60,33,45,45], [45,45,62]).
xml_delimiters(cdata, [60,33,91,67,68,65,84,65,91], [93,93,62]).
xml_delimiters(instruction, [60,63], [63,62]).

xml_end_tag(Output, Tail) -->
    xml_name(Output, More), xml_layout(More, [62|Tail], _), [62].

xml_tag_tail(Kind, Output, Tail) -->
    xml_layout(Output, More, Space), xml_tag_end(Kind, More, Tail, Space).

xml_tag_end(empty, [47,62|Tail], Tail, _) --> [47,62], !.
xml_tag_end(start, [62|Tail], Tail, _) --> [62], !.
xml_tag_end(Kind, Output, Tail, true) -->
    xml_name(Output, AfterName),
    xml_layout(AfterName, [61|AfterEquals], _), [61],
    xml_layout(AfterEquals, [Quote|AfterQuote], _),
    [Quote], { memberchk(Quote, [34,39]) },
    xml_quoted(Quote, AfterQuote, AfterValue),
    xml_tag_tail(Kind, AfterValue, Tail).

xml_name([C|More], Tail) -->
    [C], { xml_name_start(C) }, xml_name_rest(More, Tail).

xml_name_rest([C|More], Tail) -->
    [C], { xml_name_char(C) }, !, xml_name_rest(More, Tail).
xml_name_rest(Tail, Tail) --> [].

xml_name_start(C) :-
    ( C >= 65, C =< 90 -> true
    ; C >= 97, C =< 122 -> true
    ; C >= 128 -> true
    ; memberchk(C, [58,95])
    ).

xml_name_char(C) :-
    ( xml_name_start(C) -> true
    ; C >= 48, C =< 57 -> true
    ; memberchk(C, [45,46])
    ).

xml_layout([C|More], Tail, true) -->
    [C], { memberchk(C, [9,10,13,32]) }, !, xml_layout(More, Tail, _).
xml_layout(Tail, Tail, false) --> [].

xml_quoted(Quote, [Quote|Tail], Tail) --> [Quote], !.
xml_quoted(Quote, [38|More], Tail) --> [38], !, xml_entity(More, Next), xml_quoted(Quote, Next, Tail).
xml_quoted(Quote, [38,35,51,50,59|More], Tail) -->
    xml_attribute_space, !, xml_quoted(Quote, More, Tail).
xml_quoted(Quote, [38,35,49,54,48,59|More], Tail) -->
    [160], !, xml_quoted(Quote, More, Tail).
xml_quoted(Quote, [C|More], Tail) --> [C], { C \== 60 }, xml_quoted(Quote, More, Tail).

% XML turns literal attribute line breaks and tabs into one space each.
xml_attribute_space --> [13,10], !.
xml_attribute_space --> [C], { memberchk(C, [9,10,13,32]) }.

xml_section(End, Output, Tail) --> xml_prefix(End), !, { append(End, Tail, Output) }.
xml_section(End, [C|More], Tail) --> [C], !, xml_section(End, More, Tail).
xml_section(_, _, _) --> { structural_error(malformed_xml, unterminated_section) }.

xml_prefix([]) --> [].
xml_prefix([C|Rest]) --> [C], xml_prefix(Rest).

% lib(xml) tolerates unknown entities and some invalid numeric references.
% Admit just the five XML predefined entities and valid character references.
xml_entity(Output, Tail) -->
    { predefined_entity(Name) }, xml_prefix(Name), [59], !,
    { append(Name, [59|Tail], Output) }.
xml_entity([35,120|More], Tail) --> [35,120], !, xml_reference(16, More, Tail).
xml_entity([35|More], Tail) --> [35], !, xml_reference(10, More, Tail).
xml_entity(_, _) --> { structural_error(malformed_xml, unknown_entity) }.

predefined_entity([97,109,112]).          % amp
predefined_entity([108,116]).             % lt
predefined_entity([103,116]).             % gt
predefined_entity([113,117,111,116]).     % quot
predefined_entity([97,112,111,115]).      % apos

xml_reference(Base, [C|More], Tail) -->
    xml_reference_digit(Base, C, First),
    xml_reference_digits(Base, First, Code, More, [59|Tail]), [59],
    { xml_character(Code) }.

xml_reference_digits(Base, Acc, Code, [C|More], Tail) -->
    xml_reference_digit(Base, C, Digit), !,
    { Next is Acc * Base + Digit, Next =< 1114111 },
    xml_reference_digits(Base, Next, Code, More, Tail).
xml_reference_digits(_, Code, Code, Tail, Tail) --> [].

xml_reference_digit(Base, C, Digit) -->
    [C],
    { ( C >= 48, C =< 57 -> Digit is C - 48
      ; C >= 65, C =< 70 -> Digit is C - 55
      ; C >= 97, C =< 102 -> Digit is C - 87
      ), Digit < Base
    }.

xml_characters([]).
xml_characters([Code|Rest]) :- xml_character(Code), xml_characters(Rest).

xml_character(Code) :-
    ( memberchk(Code, [9,10,13]) -> true
    ; Code >= 32, Code =< 55295 -> true
    ; Code >= 57344, Code =< 65533 -> true
    ; Code >= 65536, Code =< 1114111
    ).

normalize_nodes([], []).
normalize_nodes([element(Name, Attrs, Children)|Rest],
                [element(Name, NormalAttrs, NormalChildren)|Tail]) :- !,
    normalize_attributes(Attrs, NormalAttrs),
    normalize_nodes(Children, AllChildren),
    ( element_contract(Name, _, _, text) -> NormalChildren = AllChildren
    ; exclude_blank_text(AllChildren, NormalChildren)
    ),
    normalize_nodes(Rest, Tail).
normalize_nodes([pcdata(Codes)|Rest], [Text|Tail]) :- !,
    string_list(Text, Codes, utf8),
    normalize_nodes(Rest, Tail).
normalize_nodes([cdata(Codes)|Rest], [Text|Tail]) :- !,
    string_list(Text, Codes, utf8),
    normalize_nodes(Rest, Tail).
normalize_nodes([comment(_)|Rest], Nodes) :- !,
    normalize_nodes(Rest, Nodes).
normalize_nodes([instructions(_,_)|Rest], Nodes) :- !,
    normalize_nodes(Rest, Nodes).
normalize_nodes([_|_], _) :-
    structural_error(unsupported_xml_node, document).

normalize_attributes([], []).
normalize_attributes([Name=Codes|Rest], [Name=Value|Tail]) :-
    string_list(Text, Codes, utf8),
    atom_string(Value, Text),
    normalize_attributes(Rest, Tail).

exclude_blank_text([], []).
exclude_blank_text([Text|Rest], Tail) :-
    string(Text), string_list(Text, Codes), xml_blank(Codes), !,
    exclude_blank_text(Rest, Tail).
exclude_blank_text([Node|Rest], [Node|Tail]) :-
    exclude_blank_text(Rest, Tail).

xml_blank([]).
xml_blank([Code|Rest]) :-
    memberchk(Code, [9, 10, 13, 32]),
    xml_blank(Rest).

% SXML grammar and cross-reference validation adapted from Trealla-port's
% MIT-licensed sxml_parser.pl, using SWI's SXML 0.2 contract.
validate_sxml_structure(Content) :-
    ( Content = [element(statechart, RootAttrs, RootChildren)]
    -> true
    ;  structural_error(document_root, statechart)
    ),
    validate_element(statechart, RootAttrs, RootChildren),
    required_attribute(version, RootAttrs, Version, statechart),
    ( Version == '0.2' -> true
    ; semantic_error(statechart_version, Version,
                     'the supported SXML version is 0.2')
    ),
    required_attribute(initial, RootAttrs, RootInitial, statechart),
    root_identifier(RootAttrs, RootID),
    collect_identifiers(Content, [RootID-statechart], IdentifierPairs),
    unique_identifiers(IdentifierPairs),
    delete(RootID-statechart, IdentifierPairs, StatePairs),
    pairs_keys(StatePairs, Identifiers),
    validate_reference(RootInitial, Identifiers, initial(statechart)),
    validate_initial_child(RootInitial, RootChildren, statechart),
    validate_semantics(Content, Identifiers).

validate_element(Name, Attrs, Children) :-
    element_contract(Name, Required, Allowed, Content),
    !,
    validate_attributes(Name, Attrs, Required, Allowed),
    validate_content(Content, Name, Children),
    validate_child_elements(Children).
validate_element(Name, _, _) :- structural_error(unknown_element, Name).

validate_child_elements([]).
validate_child_elements([element(Name, Attrs, Children)|Rest]) :- !,
    validate_element(Name, Attrs, Children),
    validate_child_elements(Rest).
validate_child_elements([Text|Rest]) :-
    string(Text),
    validate_child_elements(Rest).

element_contract(statechart, [version,initial], [version,initial,id],
                 elements([datamodel,state,parallel,final])).
element_contract(state, [id], [id,initial],
                 elements([onentry,onexit,go,defer,spawn,datamodel,history,state,parallel,final])).
element_contract(parallel, [id], [id],
                 elements([onentry,onexit,go,defer,spawn,datamodel,history,state,parallel,final])).
element_contract(final, [id], [id], optional_one(onentry)).
element_contract(history, [id], [id,type], exactly_one(go)).
element_contract(go, [], [to,on,if,after], text).
element_contract(onentry, [], [], text).
element_contract(onexit, [], [], text).
element_contract(datamodel, [], [], text).
element_contract(defer, [on], [on,if], empty).
element_contract(spawn, [type], [type,options,goal,callback,state,children], text).

validate_attributes(Name, Attrs, Required, Allowed) :-
    attribute_names(Attrs, Names),
    unique_attribute_names(Names, Name),
    require_attributes(Required, Names, Name),
    allow_attributes(Names, Allowed, Name).

attribute_names([], []).
attribute_names([Name=_|Attrs], [Name|Names]) :- atom(Name), !,
    attribute_names(Attrs, Names).
attribute_names([Attr|_], _) :- structural_error(invalid_attribute, Attr).

unique_attribute_names([], _).
unique_attribute_names([Name|Names], Element) :-
    ( memberchk(Name, Names) -> structural_error(duplicate_attribute, Element-Name) ; true ),
    unique_attribute_names(Names, Element).

require_attributes([], _, _).
require_attributes([Name|Names], Present, Element) :-
    ( memberchk(Name, Present) -> true
    ; semantic_error(missing_attribute, Name, Element)
    ),
    require_attributes(Names, Present, Element).

allow_attributes([], _, _).
allow_attributes([Name|Names], Allowed, Element) :-
    ( memberchk(Name, Allowed) -> true
    ; structural_error(unknown_attribute, Element-Name)
    ),
    allow_attributes(Names, Allowed, Element).

validate_content(empty, Name, Children) :-
    ( Children == [] -> true ; structural_error(nonempty_element, Name) ).
validate_content(text, Name, Children) :-
    ( all_text(Children) -> true ; structural_error(element_not_allowed, Name) ).
validate_content(elements(Allowed), Name, Children) :-
    validate_allowed_children(Children, Allowed, Name).
validate_content(optional_one(Allowed), Name, Children) :-
    validate_allowed_children(Children, [Allowed], Name),
    length(Children, Count),
    ( Count =< 1 -> true ; structural_error(too_many_children, Name) ).
validate_content(exactly_one(Allowed), Name, Children) :-
    validate_allowed_children(Children, [Allowed], Name),
    ( Children = [element(Allowed,_,_)] -> true
    ; structural_error(required_child, Name-Allowed)
    ).

all_text([]).
all_text([Text|Rest]) :- string(Text), all_text(Rest).

validate_allowed_children([], _, _).
validate_allowed_children([element(Name,_,_)|Rest], Allowed, Parent) :-
    ( memberchk(Name, Allowed) -> true
    ; structural_error(misplaced_element, Parent-Name)
    ),
    validate_allowed_children(Rest, Allowed, Parent).
validate_allowed_children([Text|_], _, Parent) :-
    structural_error(text_not_allowed, Parent-Text).


                 /*******************************
                 *       SEMANTIC CHECKS         *
                 *******************************/

root_identifier(Attrs, ID) :- xml_option(id(ID), Attrs, statechart_actor).

collect_identifiers([], Pairs, Pairs).
collect_identifiers([element(Name, Attrs, Children)|Rest], Pairs0, Pairs) :-
    ( memberchk(Name, [state, parallel, final, history])
    -> required_attribute(id, Attrs, ID, Name), Pairs1 = [ID-Name|Pairs0]
    ;  Pairs1 = Pairs0
    ),
    collect_identifiers(Children, Pairs1, Pairs2),
    collect_identifiers(Rest, Pairs2, Pairs).
collect_identifiers([_|Rest], Pairs0, Pairs) :-
    collect_identifiers(Rest, Pairs0, Pairs).

unique_identifiers([]).
unique_identifiers([ID-Kind|Rest]) :-
    ( memberchk(ID-OtherKind, Rest)
    -> semantic_error(duplicate_identifier, ID,
                      duplicate_identifier(Kind, OtherKind))
    ;  true
    ),
    unique_identifiers(Rest).

pairs_keys([], []).
pairs_keys([Key-_|Pairs], [Key|Keys]) :- pairs_keys(Pairs, Keys).

validate_semantics([], _).
validate_semantics([element(state, Attrs, Children)|Rest], Identifiers) :- !,
    ( has_state_child(Children)
    -> required_attribute(initial, Attrs, Initial, state),
       validate_reference(Initial, Identifiers, initial(state)),
       validate_initial_child(Initial, Children, state)
    ;  ( xml_option(initial(Initial), Attrs)
       -> validate_reference(Initial, Identifiers, initial(state)),
          validate_initial_child(Initial, Children, state)
       ;  true
       )
    ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(go, Attrs, Children)|Rest], Identifiers) :- !,
    sxml_targets(Attrs, Targets),
    validate_targets(Targets, Identifiers),
    ( xml_option(after(Value), Attrs) ->
        ( xml_option(on(_), Attrs) -> structural_error(on_and_after, go) ; true ),
        sxml_delay(Value, _)
    ; true ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(history, Attrs, Children)|Rest], Identifiers) :- !,
    xml_option(type(Type), Attrs, shallow),
    ( memberchk(Type, [shallow, deep]) -> true
    ; semantic_error(history_type, Type, 'the history type is shallow or deep')
    ),
    Children = [element(go, GoAttrs, _)],
    ( xml_option(to(_), GoAttrs), \+ xml_option(on(_), GoAttrs), \+ xml_option(after(_), GoAttrs) -> true
    ; structural_error(history_default, go) ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(spawn, Attrs, Children)|Rest], Identifiers) :- !,
    required_attribute(type, Attrs, Type, spawn),
    ( memberchk(Type, [actor, toplevel, server, supervisor, statechart]) -> true
    ; semantic_error(statechart_spawn_type, Type,
                     'supported spawn types are actor, toplevel, server, supervisor, and statechart')
    ),
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([element(_, _, Children)|Rest], Identifiers) :- !,
    validate_semantics(Children, Identifiers),
    validate_semantics(Rest, Identifiers).
validate_semantics([_|Rest], Identifiers) :- validate_semantics(Rest, Identifiers).

sxml_targets(Attrs, Targets) :-
    ( xml_option(to(Value), Attrs) -> target_list(Value, Targets)
    ; Targets = [] ).

sxml_delay(Value, Delay) :-
    atom_string(Value, Text),
    ( number_string(Delay, Text), Delay >= 0, Delay < 1.0Inf -> true
    ; structural_error(after_delay, Value) ).

validate_targets([], _).
validate_targets([Target|Targets], Identifiers) :-
    validate_reference(Target, Identifiers, transition_target),
    validate_targets(Targets, Identifiers).

target_list(Targets, TargetList) :-
    atom_string(Targets, Text),
    split_string(Text, " \t\r\n", " \t\r\n", Parts),
    ( string_list(Text, Codes), xml_blank(Codes) ->
        structural_error(empty_transition_target, to)
    ; true ),
    ( foreach(Part, Parts), foreach(Target, TargetList) do atom_string(Target, Part) ).

validate_reference(Reference, Identifiers, Role) :-
    ( memberchk(Reference, Identifiers) -> true
    ; semantic_error(unknown_identifier, Reference, Role)
    ).

validate_initial_child(Initial, Children, Owner) :-
    ( member(element(Name, Attrs, _), Children),
      memberchk(Name, [state, parallel, final]),
      xml_option(id(Initial), Attrs)
    -> true
    ;  semantic_error(initial_not_direct_child, Initial, Owner)
    ).

has_state_child(Children) :-
    member(element(Name, _, _), Children),
    memberchk(Name, [state, parallel, final]),
    !.

required_attribute(Name, Attrs, Value, Element) :-
    NameValue =.. [Name, Value],
    ( xml_option(NameValue, Attrs) -> true
    ; semantic_error(missing_attribute, Name, Element)
    ).

structural_error(Kind, Detail) :-
    throw(error(sxml_validation_error(
                    [diagnostic(error, unknown, Kind-Detail)]),
                context(sxml_document:validate_sxml_structure/1,
                        'the document does not conform to the SXML 0.2 grammar'))).

semantic_error(Kind, Culprit, Detail) :-
    semantic_exception(Kind, Culprit, Exception),
    !,
    throw(error(Exception,
                context(sxml_document:validate_sxml_structure/1, Detail))).
semantic_error(Kind, Culprit, Detail) :-
    throw(error(sxml_semantic_error(Kind, Culprit),
                context(sxml_document:validate_sxml_structure/1, Detail))).

semantic_exception(missing_attribute, Attribute,
                   existence_error(attribute, Attribute)).
semantic_exception(statechart_version, Version,
                   domain_error(statechart_version, Version)).
semantic_exception(statechart_spawn_type, Type,
                   domain_error(statechart_spawn_type, Type)).


%!  xml_option(?Option, +Attributes) is semidet.
%!  xml_option(?Option, +Attributes, +Default) is det.
%
%   Read an attribute from the `Name=Value` representation returned by SWI's
%   XML parser. Compound `name(Value)` entries are accepted as well, making
%   the helper convenient at the Trealla/SWI model boundary.
xml_option(Option, Attributes) :-
    nonvar(Option),
    Option =.. [Name, Value],
    ( memberchk(Name=Value, Attributes)
    ; memberchk(Option, Attributes)
    ).

xml_option(Option, Attributes, Default) :-
    ( xml_option(Option, Attributes) -> true
    ; arg(1, Option, Default)
    ).
