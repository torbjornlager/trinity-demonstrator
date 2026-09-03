:- module(sxml_schema, [
    load_sxml_structure/2,
    sxml_validate_text/2,
    sxml_validate_stream/2,
    validate_sxml_structure/1,
    sxml_dtd_text/1
]).

/** <module> SXML 0.2 structural validation

The DTD rejects unknown or misplaced XML vocabulary.  The semantic pass
checks relationships that a DTD cannot express reliably: document-wide
identifier uniqueness, reference existence, and direct-child initial states.

The DTD text is embedded so that the same validator works in native SWI and
SWI-WASM.  `sxml-0.2.dtd` is the distributable copy; the test suite verifies
that it is byte-for-byte identical to this source.
*/

:- use_module(library(option)).
:- use_module(library(sgml)).

:- thread_local sxml_parse_message/3.

:- multifile prolog:error_message//1.

prolog:error_message(sxml_validation_error(
                         [diagnostic(_Severity, Line, Detail)])) -->
    [ 'SXML validation failed at line ~w: ~w'-[Line, Detail] ].
prolog:error_message(sxml_validation_error(Diagnostics)) -->
    [ 'SXML validation failed: ~p'-[Diagnostics] ].


%!  load_sxml_structure(+Stream, -Content) is det.
%
%   Parse and validate one SXML 0.2 document.  Stream remains open.  DTD
%   diagnostics are collected rather than printed.  A fresh DTD is used for
%   every document because SWI's SGML parser may extend a DTD while recovering
%   from invalid input.
load_sxml_structure(Stream, Content) :-
    setup_call_cleanup(
        new_sxml_dtd(DTD),
        load_with_dtd(Stream, DTD, Content),
        free_dtd(DTD)),
    validate_sxml_structure(Content),
    !.


%!  sxml_validate_text(+Text, -Diagnostics) is det.
%
%   Diagnostics is [] for a structurally valid document.  Otherwise it is a
%   nonempty list of diagnostic(Severity, Line, Detail) terms.  This predicate
%   never builds or modifies a running statechart model.
sxml_validate_text(Text, Diagnostics) :-
    setup_call_cleanup(
        open_string(Text, Stream),
        sxml_validate_stream(Stream, Diagnostics),
        close(Stream)).


%!  sxml_validate_stream(+Stream, -Diagnostics) is det.
%
%   Stream variant of sxml_validate_text/2.  Stream remains open.
sxml_validate_stream(Stream, Diagnostics) :-
    catch(load_sxml_structure(Stream, _),
          Error,
          validation_diagnostics(Error, Diagnostics0)),
    (   var(Diagnostics0)
    ->  Diagnostics = []
    ;   Diagnostics = Diagnostics0
    ).


validation_diagnostics(error(sxml_validation_error(Diagnostics), _), Diagnostics) :-
    !.
validation_diagnostics(Error, [diagnostic(error, unknown, Error)]).


load_with_dtd(Stream, DTD, Content) :-
    retractall(sxml_parse_message(_, _, _)),
    thread_self(Thread),
    asserta((user:thread_message_hook(sgml(_Parser, _File, Line, Message), Kind, _) :-
        thread_self(Thread),
        (Kind == error ; Kind == warning),
        assertz(sxml_schema:sxml_parse_message(Kind, Line, Message))), Ref),
    catch(
        load_structure(Stream, Content, [
            dialect(xml),
            dtd(DTD),
            space(remove)
        ]),
        Error,
        (   erase(Ref),
            collect_parse_diagnostics(Diagnostics),
            retractall(sxml_parse_message(_, _, _)),
            (   Diagnostics == []
            ->  throw(Error)
            ;   throw_validation_error(Diagnostics)
            )
        )),
    erase(Ref),
    collect_parse_diagnostics(Diagnostics),
    retractall(sxml_parse_message(_, _, _)),
    (   Diagnostics == []
    ->  true
    ;   throw_validation_error(Diagnostics)
    ).


collect_parse_diagnostics(Diagnostics) :-
    findall(diagnostic(Kind, Line, Message),
            sxml_parse_message(Kind, Line, Message),
            Diagnostics).


throw_validation_error(Diagnostics) :-
    throw(error(sxml_validation_error(Diagnostics),
                context(sxml_schema:load_sxml_structure/2,
                        'the document does not conform to the SXML 0.2 grammar'))).


new_sxml_dtd(DTD) :-
    new_dtd(statechart, DTD),
    catch(
        setup_call_cleanup(
            open_dtd(DTD, [dialect(xml)], Stream),
            ( sxml_dtd_text(Text),
              format(Stream, '~s', [Text])
            ),
            close(Stream)),
        Error,
        ( free_dtd(DTD),
          throw(Error)
        )).


%!  validate_sxml_structure(+Content) is det.
%
%   Check the cross-element constraints of the SXML grammar without executing
%   any embedded Prolog.
validate_sxml_structure(Content) :-
    (   Content = [element(statechart, RootAttrs, RootChildren)]
    ->  true
    ;   semantic_error(document_root, statechart,
                       'an SXML document has exactly one <statechart> root element')
    ),
    required_attribute(version, RootAttrs, Version, statechart),
    (   Version == '0.2'
    ->  true
    ;   semantic_error(statechart_version, Version,
                       'the supported SXML version is 0.2')
    ),
    required_attribute(initial, RootAttrs, RootInitial, statechart),
    root_identifier(RootAttrs, RootID),
    collect_identifiers(Content, [RootID-statechart], IdentifierPairs),
    unique_identifiers(IdentifierPairs),
    pairs_keys(IdentifierPairs, Identifiers),
    validate_reference(RootInitial, Identifiers, initial(statechart)),
    validate_initial_child(RootInitial, RootChildren, statechart),
    validate_elements(Content, Identifiers).


root_identifier(Attrs, ID) :-
    option(id(ID), Attrs, statechart_actor).


collect_identifiers([], Pairs, Pairs).
collect_identifiers([element(Name, Attrs, Children)|Rest], Pairs0, Pairs) :-
    (   memberchk(Name, [state, parallel, final, history])
    ->  required_attribute(id, Attrs, ID, Name),
        Pairs1 = [ID-Name|Pairs0]
    ;   Pairs1 = Pairs0
    ),
    collect_identifiers(Children, Pairs1, Pairs2),
    collect_identifiers(Rest, Pairs2, Pairs).
collect_identifiers([_|Rest], Pairs0, Pairs) :-
    collect_identifiers(Rest, Pairs0, Pairs).


unique_identifiers([]).
unique_identifiers([ID-Kind|Rest]) :-
    (   memberchk(ID-OtherKind, Rest)
    ->  semantic_error(duplicate_identifier, ID,
                       duplicate_identifier(Kind, OtherKind))
    ;   true
    ),
    unique_identifiers(Rest).


pairs_keys([], []).
pairs_keys([Key-_|Pairs], [Key|Keys]) :-
    pairs_keys(Pairs, Keys).


validate_elements([], _).
validate_elements([element(state, Attrs, Children)|Rest], Identifiers) :-
    !,
    (   has_state_child(Children)
    ->  required_attribute(initial, Attrs, Initial, state),
        validate_reference(Initial, Identifiers, initial(state)),
        validate_initial_child(Initial, Children, state)
    ;   (   option(initial(Initial), Attrs)
        ->  validate_reference(Initial, Identifiers, initial(state)),
            validate_initial_child(Initial, Children, state)
        ;   true
        )
    ),
    validate_elements(Children, Identifiers),
    validate_elements(Rest, Identifiers).
validate_elements([element(go, Attrs, Children)|Rest], Identifiers) :-
    !,
    validate_go_targets(Attrs, Identifiers),
    validate_elements(Children, Identifiers),
    validate_elements(Rest, Identifiers).
validate_elements([element(history, Attrs, Children)|Rest], Identifiers) :-
    !,
    option(type(Type), Attrs, shallow),
    (   memberchk(Type, [shallow, deep])
    ->  true
    ;   semantic_error(history_type, Type,
                       'the history type is shallow or deep')
    ),
    validate_elements(Children, Identifiers),
    validate_elements(Rest, Identifiers).
validate_elements([element(spawn, Attrs, Children)|Rest], Identifiers) :-
    !,
    required_attribute(type, Attrs, Type, spawn),
    (   memberchk(Type, [actor, toplevel, server, supervisor, statechart])
    ->  true
    ;   semantic_error(statechart_spawn_type, Type,
                       'supported spawn types are actor, toplevel, server, supervisor, and statechart')
    ),
    validate_elements(Children, Identifiers),
    validate_elements(Rest, Identifiers).
validate_elements([element(_Name, _Attrs, Children)|Rest], Identifiers) :-
    !,
    validate_elements(Children, Identifiers),
    validate_elements(Rest, Identifiers).
validate_elements([_|Rest], Identifiers) :-
    validate_elements(Rest, Identifiers).


validate_go_targets(Attrs, Identifiers) :-
    (   option(to(Targets), Attrs)
    ->  target_list(Targets, TargetList),
        maplist(validate_target(Identifiers), TargetList)
    ;   true
    ).


validate_target(Identifiers, Target) :-
    validate_reference(Target, Identifiers, transition_target).


target_list(Targets, TargetList) :-
    (   is_list(Targets)
    ->  TargetList = Targets
    ;   atomic_list_concat(TargetList, ' ', Targets)
    ).


validate_reference(Reference, Identifiers, Role) :-
    (   memberchk(Reference, Identifiers)
    ->  true
    ;   semantic_error(unknown_identifier, Reference, Role)
    ).


validate_initial_child(Initial, Children, Owner) :-
    (   member(element(Name, Attrs, _), Children),
        memberchk(Name, [state, parallel, final]),
        option(id(Initial), Attrs)
    ->  true
    ;   semantic_error(initial_not_direct_child, Initial, Owner)
    ).


has_state_child(Children) :-
    member(element(Name, _Attrs, _Grandchildren), Children),
    memberchk(Name, [state, parallel, final]),
    !.


required_attribute(Name, Attrs, Value, Element) :-
    NameValue =.. [Name, Value],
    (   option(NameValue, Attrs)
    ->  true
    ;   semantic_error(missing_attribute, Name, Element)
    ).


semantic_error(Kind, Culprit, Detail) :-
    semantic_exception(Kind, Culprit, Exception),
    !,
    throw(error(Exception,
                context(sxml_schema:validate_sxml_structure/1, Detail))).
semantic_error(Kind, Culprit, Detail) :-
    throw(error(sxml_semantic_error(Kind, Culprit),
                context(sxml_schema:validate_sxml_structure/1, Detail))).


semantic_exception(missing_attribute, Attribute,
                   existence_error(attribute, Attribute)).
semantic_exception(statechart_version, Version,
                   domain_error(statechart_version, Version)).
semantic_exception(statechart_spawn_type, Type,
                   domain_error(statechart_spawn_type, Type)).


% Keep this text byte-for-byte identical to ../sxml-0.2.dtd.  It is embedded
% because browser workers load Prolog modules over HTTP but have no ordinary
% filesystem path from which load_dtd/2 could read the distributable file.
sxml_dtd_text(`<!-- SXML 0.2 document grammar.

     The demonstrator supplies this DTD to the XML parser; documents do not
     need a DOCTYPE declaration.  Constraints involving Prolog terms or
     relationships in the state hierarchy are checked by the semantic
     validator after DTD validation.
-->

<!ELEMENT statechart (datamodel|state|parallel|final)*>
<!ATTLIST statechart
          version CDATA #REQUIRED
          initial IDREF #REQUIRED
          id      ID    #IMPLIED>

<!ELEMENT state (onentry|onexit|go|defer|spawn|datamodel|history|state|parallel|final)*>
<!ATTLIST state
          id      ID    #REQUIRED
          initial IDREF #IMPLIED>

<!ELEMENT parallel (onentry|onexit|go|defer|spawn|datamodel|history|state|parallel|final)*>
<!ATTLIST parallel
          id ID #REQUIRED>

<!ELEMENT final (onentry?)>
<!ATTLIST final
          id ID #REQUIRED>

<!ELEMENT history (go)>
<!ATTLIST history
          id   ID    #REQUIRED
          type CDATA "shallow">

<!ELEMENT go (#PCDATA)>
<!ATTLIST go
          to    IDREFS #IMPLIED
          on    CDATA  #IMPLIED
          if    CDATA  #IMPLIED
          after CDATA  #IMPLIED>

<!ELEMENT onentry (#PCDATA)>
<!ELEMENT onexit (#PCDATA)>
<!ELEMENT datamodel (#PCDATA)>

<!ELEMENT defer EMPTY>
<!ATTLIST defer
          on CDATA #REQUIRED
          if CDATA #IMPLIED>

<!ELEMENT spawn (#PCDATA)>
<!ATTLIST spawn
          type           CDATA #REQUIRED
          options        CDATA #IMPLIED
          goal           CDATA #IMPLIED
          callback       CDATA #IMPLIED
          state          CDATA #IMPLIED
          children       CDATA #IMPLIED>
`).
