:- module(node_call_context, [
    http_parse_call_request/10,
    parse_call_context/9
]).

/** <module> Node Call Request Parsing

Shared request parsing and execution context normalization for stateless
`/call` and session `/toplevel_call` endpoints.
*/

:- op(800, xfx, !).
:- op(200, xfx, @).
:- op(1000, xfy, if).

:- use_module(library(apply)).
:- use_module(library(http/http_parameters)).
:- use_module(actor, []).
:- use_module(node_client, [
    normalize_requested_timeout/2,
    normalize_once/2
]).
:- use_module(node_input_limits, [
    check_term_text_size/2,
    check_source_text_size/2
]).

%!  http_parse_call_request(+Request, +ExtraSpecs, -GoalAtom, -TemplateAtom0,
%!                          -Offset, -Limit, -Format, -LoadText,
%!                          -Once0, -RequestedTimeout0) is det.
%
%   Parse common call-query parameters used by both `/call` and
%   `/toplevel_call`, plus endpoint-specific `ExtraSpecs`.
http_parse_call_request(Request, ExtraSpecs,
                        GoalAtom, TemplateAtom0, Offset, Limit, Format,
                        LoadText, Once0, RequestedTimeout0) :-
    call_parameter_specs(GoalAtom, TemplateAtom0, Offset, Limit, Format,
                         LoadText, Once0, RequestedTimeout0, BaseSpecs),
    append(ExtraSpecs, BaseSpecs, Specs),
    http_parameters(Request, Specs),
    check_term_text_size(goal, GoalAtom),
    (   nonvar(TemplateAtom0)
    ->  check_term_text_size(template, TemplateAtom0)
    ;   true
    ),
    check_source_text_size(load_text, LoadText).

%!  call_parameter_specs(-GoalAtom, -TemplateAtom0, -Offset, -Limit, -Format,
%!                       -LoadText, -Once0, -RequestedTimeout0, -Specs) is det.
call_parameter_specs(GoalAtom, TemplateAtom0, Offset, Limit, Format, LoadText,
                     Once0, RequestedTimeout0, Specs) :-
    Specs = [
        goal(GoalAtom, [atom]),
        template(TemplateAtom0, [optional(true)]),
        offset(Offset, [integer, default(0)]),
        limit(Limit, [integer, default(10 000 000 000)]),
        format(Format, [atom, default(json)]),
        load_text(LoadText, [default('')]),
        once(Once0, [atom, default(false)]),
        timeout(RequestedTimeout0, [number, optional(true)])
    ].

%!  parse_call_context(+GoalAtom, +TemplateAtom0, +Format, +Once0,
%!                     +RequestedTimeout0, -Goal, -Template, -Once,
%!                     -RequestedTimeout) is det.
%
%   Build normalized execution context shared by `/call` and `/toplevel_call`.
parse_call_context(GoalAtom, TemplateAtom0, Format, Once0, RequestedTimeout0,
                   Goal, Template, Once, RequestedTimeout) :-
    template_atom(TemplateAtom0, GoalAtom, TemplateAtom),
    parse_goal_template(GoalAtom, TemplateAtom, Goal, Template0, Bindings),
    fix_template(Format, Goal, Template0, Bindings, Template),
    normalize_once(Once0, Once),
    normalize_requested_timeout(RequestedTimeout0, RequestedTimeout).

%!  template_atom(+TemplateAtom0, +GoalAtom, -TemplateAtom) is det.
%
%   Default template to goal when template parameter is omitted.
template_atom(TemplateAtom, _, TemplateAtom) :-
    nonvar(TemplateAtom),
    !.
template_atom(_, GoalAtom, GoalAtom).

%!  parse_goal_template(+GoalAtom, +TemplateAtom, -Goal, -Template, -Bindings) is det.
%
%   Parse goal/template together so template can refer to goal variables.
parse_goal_template(GoalAtom, TemplateAtom, Goal, Template, Bindings) :-
    atomic_list_concat(['(', GoalAtom, ')+(', TemplateAtom, ')'], QTAtom),
    read_term_from_atom(QTAtom, Goal+Template,
                        [ module(actor),
                          variable_names(Bindings)
                        ]).

%!  fix_template(+Format, +Goal, +Template0, +Bindings, -Template) is det.
%
%   For JSON formats, ignore caller template and instead build a dict template
%   from named query variables.
fix_template(Format, Goal, _Template, Bindings, NewTemplate) :-
    json_lang(Format),
    !,
    exclude(anon_binding, Bindings, NamedBindings0),
    visible_named_bindings(Goal, Bindings, NamedBindings0, NamedBindings),
    dict_create(NewTemplate, json, NamedBindings).
fix_template(_, _, Template, _, Template).

visible_named_bindings(Goal, Bindings, NamedBindings0, NamedBindings) :-
    anon_binding_vars(Bindings, AnonVars),
    exposed_helper_vars(Goal, AnonVars, ExposedHelpers),
    visible_goal_vars(Goal, AnonVars, ExposedHelpers, VisibleVars),
    include(binding_var_visible(VisibleVars), NamedBindings0, NamedBindings).

anon_binding_vars(Bindings, AnonVars) :-
    include(anon_binding, Bindings, AnonBindings),
    maplist(binding_var_, AnonBindings, AnonVars).

binding_var_visible(VisibleVars, _Name=Var) :-
    member_var_(VisibleVars, Var).

exposed_helper_vars(Goal, AnonVars, ExposedHelpers) :-
    helper_data_refs_(Goal, AnonVars, goal, [], ExposedHelpers0),
    list_to_set(ExposedHelpers0, ExposedHelpers).

visible_goal_vars(Goal, AnonVars, ExposedHelpers, VisibleVars) :-
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, [], VisibleVars0),
    list_to_set(VisibleVars0, VisibleVars).

helper_data_refs_(Var, AnonVars, data, Refs0, [Var|Refs0]) :-
    var(Var),
    member_var_(AnonVars, Var),
    !.
helper_data_refs_(Var, _AnonVars, _Context, Refs, Refs) :-
    var(Var),
    !.
helper_data_refs_(Left=Right, AnonVars, _Context, Refs0, Refs) :-
    helper_binding_side_(AnonVars, Left, Right, _HelperVar, OtherSide),
    !,
    helper_data_refs_(OtherSide, AnonVars, data, Refs0, Refs).
helper_data_refs_((Left, Right), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Left, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(Right, AnonVars, goal, Refs1, Refs).
helper_data_refs_((Left; Right), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Left, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(Right, AnonVars, goal, Refs1, Refs).
helper_data_refs_((If -> Then), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(If, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(Then, AnonVars, goal, Refs1, Refs).
helper_data_refs_(catch(Goal, Catcher, Recover), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(Catcher, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(Recover, AnonVars, goal, Refs2, Refs).
helper_data_refs_(once(Goal), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs).
helper_data_refs_(ignore(Goal), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs).
helper_data_refs_(\+(Goal), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs).
helper_data_refs_(time(Goal), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs).
helper_data_refs_(call(Goal), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs).
helper_data_refs_(call(Goal, A1), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs).
helper_data_refs_(call(Goal, A1, A2), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs).
helper_data_refs_(call(Goal, A1, A2, A3), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs3),
    helper_data_refs_(A3, AnonVars, data, Refs3, Refs).
helper_data_refs_(call(Goal, A1, A2, A3, A4), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs3),
    helper_data_refs_(A3, AnonVars, data, Refs3, Refs4),
    helper_data_refs_(A4, AnonVars, data, Refs4, Refs).
helper_data_refs_(call(Goal, A1, A2, A3, A4, A5), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs3),
    helper_data_refs_(A3, AnonVars, data, Refs3, Refs4),
    helper_data_refs_(A4, AnonVars, data, Refs4, Refs5),
    helper_data_refs_(A5, AnonVars, data, Refs5, Refs).
helper_data_refs_(call(Goal, A1, A2, A3, A4, A5, A6), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs3),
    helper_data_refs_(A3, AnonVars, data, Refs3, Refs4),
    helper_data_refs_(A4, AnonVars, data, Refs4, Refs5),
    helper_data_refs_(A5, AnonVars, data, Refs5, Refs6),
    helper_data_refs_(A6, AnonVars, data, Refs6, Refs).
helper_data_refs_(call(Goal, A1, A2, A3, A4, A5, A6, A7), AnonVars, _Context, Refs0, Refs) :-
    !,
    helper_data_refs_(Goal, AnonVars, goal, Refs0, Refs1),
    helper_data_refs_(A1, AnonVars, data, Refs1, Refs2),
    helper_data_refs_(A2, AnonVars, data, Refs2, Refs3),
    helper_data_refs_(A3, AnonVars, data, Refs3, Refs4),
    helper_data_refs_(A4, AnonVars, data, Refs4, Refs5),
    helper_data_refs_(A5, AnonVars, data, Refs5, Refs6),
    helper_data_refs_(A6, AnonVars, data, Refs6, Refs7),
    helper_data_refs_(A7, AnonVars, data, Refs7, Refs).
helper_data_refs_(Term, AnonVars, _Context, Refs0, Refs) :-
    compound(Term),
    !,
    compound_name_arguments(Term, _Name, Args),
    helper_data_refs_list_(Args, AnonVars, data, Refs0, Refs).
helper_data_refs_(_Atomic, _AnonVars, _Context, Refs, Refs).

helper_data_refs_list_([], _AnonVars, _Context, Refs, Refs).
helper_data_refs_list_([Arg|Args], AnonVars, Context, Refs0, Refs) :-
    helper_data_refs_(Arg, AnonVars, Context, Refs0, Refs1),
    helper_data_refs_list_(Args, AnonVars, Context, Refs1, Refs).

visible_goal_vars_(Var, _AnonVars, _ExposedHelpers, _Context, Vars0, [Var|Vars0]) :-
    var(Var),
    !.
visible_goal_vars_(Left=Right, AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    helper_binding_side_(AnonVars, Left, Right, HelperVar, OtherSide),
    !,
    (   member_var_(ExposedHelpers, HelperVar)
    ->  visible_goal_vars_(OtherSide, AnonVars, ExposedHelpers, data, Vars0, Vars)
    ;   Vars = Vars0
    ).
visible_goal_vars_((Left, Right), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Left, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(Right, AnonVars, ExposedHelpers, goal, Vars1, Vars).
visible_goal_vars_((Left; Right), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Left, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(Right, AnonVars, ExposedHelpers, goal, Vars1, Vars).
visible_goal_vars_((If -> Then), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(If, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(Then, AnonVars, ExposedHelpers, goal, Vars1, Vars).
visible_goal_vars_(Left=Right, AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Left, AnonVars, ExposedHelpers, data, Vars0, Vars1),
    visible_goal_vars_(Right, AnonVars, ExposedHelpers, data, Vars1, Vars).
visible_goal_vars_(catch(Goal, Catcher, Recover), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(Catcher, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(Recover, AnonVars, ExposedHelpers, goal, Vars2, Vars).
visible_goal_vars_(once(Goal), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars).
visible_goal_vars_(ignore(Goal), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars).
visible_goal_vars_(\+(Goal), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars).
visible_goal_vars_(time(Goal), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars).
visible_goal_vars_(call(Goal), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars).
visible_goal_vars_(call(Goal, A1), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars).
visible_goal_vars_(call(Goal, A1, A2), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars).
visible_goal_vars_(call(Goal, A1, A2, A3), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars3),
    visible_goal_vars_(A3, AnonVars, ExposedHelpers, data, Vars3, Vars).
visible_goal_vars_(call(Goal, A1, A2, A3, A4), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars3),
    visible_goal_vars_(A3, AnonVars, ExposedHelpers, data, Vars3, Vars4),
    visible_goal_vars_(A4, AnonVars, ExposedHelpers, data, Vars4, Vars).
visible_goal_vars_(call(Goal, A1, A2, A3, A4, A5), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars3),
    visible_goal_vars_(A3, AnonVars, ExposedHelpers, data, Vars3, Vars4),
    visible_goal_vars_(A4, AnonVars, ExposedHelpers, data, Vars4, Vars5),
    visible_goal_vars_(A5, AnonVars, ExposedHelpers, data, Vars5, Vars).
visible_goal_vars_(call(Goal, A1, A2, A3, A4, A5, A6), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars3),
    visible_goal_vars_(A3, AnonVars, ExposedHelpers, data, Vars3, Vars4),
    visible_goal_vars_(A4, AnonVars, ExposedHelpers, data, Vars4, Vars5),
    visible_goal_vars_(A5, AnonVars, ExposedHelpers, data, Vars5, Vars6),
    visible_goal_vars_(A6, AnonVars, ExposedHelpers, data, Vars6, Vars).
visible_goal_vars_(call(Goal, A1, A2, A3, A4, A5, A6, A7), AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    !,
    visible_goal_vars_(Goal, AnonVars, ExposedHelpers, goal, Vars0, Vars1),
    visible_goal_vars_(A1, AnonVars, ExposedHelpers, data, Vars1, Vars2),
    visible_goal_vars_(A2, AnonVars, ExposedHelpers, data, Vars2, Vars3),
    visible_goal_vars_(A3, AnonVars, ExposedHelpers, data, Vars3, Vars4),
    visible_goal_vars_(A4, AnonVars, ExposedHelpers, data, Vars4, Vars5),
    visible_goal_vars_(A5, AnonVars, ExposedHelpers, data, Vars5, Vars6),
    visible_goal_vars_(A6, AnonVars, ExposedHelpers, data, Vars6, Vars7),
    visible_goal_vars_(A7, AnonVars, ExposedHelpers, data, Vars7, Vars).
visible_goal_vars_(Term, AnonVars, ExposedHelpers, _Context, Vars0, Vars) :-
    compound(Term),
    !,
    compound_name_arguments(Term, _Name, Args),
    visible_goal_vars_list_(Args, AnonVars, ExposedHelpers, data, Vars0, Vars).
visible_goal_vars_(_Atomic, _AnonVars, _ExposedHelpers, _Context, Vars, Vars).

visible_goal_vars_list_([], _AnonVars, _ExposedHelpers, _Context, Vars, Vars).
visible_goal_vars_list_([Arg|Args], AnonVars, ExposedHelpers, Context, Vars0, Vars) :-
    visible_goal_vars_(Arg, AnonVars, ExposedHelpers, Context, Vars0, Vars1),
    visible_goal_vars_list_(Args, AnonVars, ExposedHelpers, Context, Vars1, Vars).

helper_binding_side_(AnonVars, Left, Right, Left, Right) :-
    var(Left),
    member_var_(AnonVars, Left),
    !.
helper_binding_side_(AnonVars, Left, Right, Right, Left) :-
    var(Right),
    member_var_(AnonVars, Right).

member_var_([Candidate|_], Var) :-
    Candidate == Var,
    !.
member_var_([_|Candidates], Var) :-
    member_var_(Candidates, Var).

binding_var_(_Name=Var, Var).

%!  anon_binding(+NameValue) is semidet.
%
%   True when variable name follows anonymous-like convention `_X`.
anon_binding(Name=_) :-
    atom(Name),
    sub_atom(Name, 0, _, _, '_'),
    sub_atom(Name, 1, 1, _, Next),
    char_type(Next, prolog_var_start).

%!  json_lang(+Format) is semidet.
%
%   Accept JSON variants (`json`, `json-*`) used by legacy clients.
json_lang(json) :-
    !.
json_lang(Format) :-
    atom(Format),
    sub_atom(Format, 0, _, _, 'json-').
