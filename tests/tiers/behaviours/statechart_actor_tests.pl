/*  Statechart profile tests */

:- module(test_statechart_profile,
          [ test_statechart_profile/0,
            test_statechart_profile_semantics/0,
            test_statechart_profile_runtime/0
          ]).

:- use_module(library(plunit)).
:- use_module('../../../prolog/web_prolog/statechart_actor.pl').
:- use_module('../../../prolog/web_prolog/composition.pl', []).
:- use_module('../../../prolog/web_prolog/actors.pl', [
    spawn/2,
    spawn/3,
    self/1,
    monitor/2,
    send/2,
    receive/1,
    receive/2,
    register/2,
    whereis/2,
    unregister/1,
    exit/2
]).
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl', [
    toplevel_spawn/2,
    toplevel_call/3
]).

:- dynamic statechart_tests_directory/1.
:- prolog_load_context(directory, BehavioursDir),
   %  This adapted copy lives two levels below the original tests/
   %  directory; fixtures (test_statecharts/, examples/) resolve
   %  relative to tests/ as before.
   file_directory_name(BehavioursDir, TiersDir),
   file_directory_name(TiersDir, StatechartTestsDirectory),
   asserta(statechart_tests_directory(StatechartTestsDirectory)).


test_statechart_profile :-
    run_tests([statechart_profile]).

test_statechart_profile_semantics :-
    run_tests([statechart_profile_semantics]).

test_statechart_profile_runtime :-
    run_tests([statechart_profile_runtime]).


:- begin_tests(statechart_profile).

test(api_exposes_only_source_aware_spawn) :-
    predicate_property(statechart_actor:statechart_spawn(_, _), exported),
    predicate_property(statechart_actor:raise(_), exported),
    predicate_property(statechart_actor:in(_), exported),
    \+ current_predicate(statechart_actor:statechart_spawn/1).

test(statechart_spawn_rejects_load_source_alias,
     [throws(error(existence_error(option, src_uri_or_src_text), _))]) :-
    statechart_model:statechart_spawn_source([load_text(ignored)], _, _).

test(parse_simple_root, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-simple.statechart'),
    statechart_actor:state(statechart_actor, null),
    statechart_actor:initial(s1).

test(rejects_initial_element,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(sxml_validation_error(_), _))
     ]) :-
    parse_statechart_fixture('test_statecharts/statechart-initial-element.statechart').

test(requires_root_initial_attribute,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(existence_error(attribute, initial), _))
    ]) :-
    statechart_model:statechart_actor_parse_text(
        "<statechart version=\"0.2\"><state id=\"s\"/></statechart>").

test(requires_version_attribute,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(existence_error(attribute, version), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        "<statechart initial=\"s\"><state id=\"s\"/></statechart>").

test(rejects_unsupported_version,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(domain_error(statechart_version, '0.1'), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        "<statechart version=\"0.1\" initial=\"s\"><state id=\"s\"/></statechart>").

test(requires_compound_state_initial_attribute,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(existence_error(attribute, initial), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        "<statechart version=\"0.2\" initial=\"outer\"><state id=\"outer\"><state id=\"inner\"/></state></statechart>").

test(parse_spawn, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-spawn-toplevel.statechart'),
    statechart_actor:to_be_invoked('spawn-ask-collect', toplevel, Options),
    memberchk(src_text(_), Options).

test(parse_spawn_typed_goal_options_and_source,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"s\"><state id=\"s\">",
        "<spawn type=\"actor\" goal=\"worker(1)\" ",
        "options=\"[monitor(true), link(false), src_uri('common.pl')]\">",
        "worker(_) :- true.",
        "</spawn></state></statechart>"
    ], Text),
    statechart_model:statechart_actor_parse_text(Text),
    statechart_actor:to_be_invoked(s, actor, Options),
    assertion(memberchk(goal(worker(1)), Options)),
    assertion(memberchk(monitor(true), Options)),
    assertion(memberchk(link(false), Options)),
    assertion(memberchk(src_uri('common.pl'), Options)),
    assertion(memberchk(src_text('worker(_) :- true.'), Options)).

test(parse_spawn_direct_attributes_are_typed,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"s\"><state id=\"s\">",
        "<spawn type=\"toplevel\" session=\"true\" time_limit=\"5\"/>",
        "</state></statechart>"
    ], Text),
    statechart_model:statechart_actor_parse_text(Text),
    statechart_actor:to_be_invoked(s, toplevel, Options),
    assertion(memberchk(session(true), Options)),
    assertion(memberchk(time_limit(5), Options)).

test(parse_spawn_rejects_unknown_type,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(domain_error(statechart_spawn_type, daemon), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="daemon"/></state></statechart>').

test(parse_spawn_server_operands_and_options,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="server" callback="counter" state="0" options="[name(counting)]">counter(inc,N,N1,N1):-N1 is N+1.</spawn></state></statechart>'),
    statechart_actor:to_be_invoked(s, server, Options),
    assertion(memberchk(callback(counter), Options)),
    assertion(memberchk(state(0), Options)),
    assertion(memberchk(name(counting), Options)),
    assertion(memberchk(src_text(_), Options)).

test(parse_spawn_supervisor_operands_and_options,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="supervisor" children="[child(worker,[start(true),restart(temporary)])]" strategy="one_for_all" intensity="3" period="10"/></state></statechart>'),
    statechart_actor:to_be_invoked(s, supervisor, Options),
    assertion(memberchk(children([child(worker, _)]), Options)),
    assertion(memberchk(strategy(one_for_all), Options)),
    assertion(memberchk(intensity(3), Options)),
    assertion(memberchk(period(10), Options)).

test(parse_spawn_nested_statechart_requires_exactly_one_source,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="statechart" src_uri="\'child.xml\'" options="[monitor(true)]"/></state></statechart>'),
    statechart_actor:to_be_invoked(s, statechart, Options),
    assertion(memberchk(src_uri('child.xml'), Options)),
    assertion(memberchk(monitor(true), Options)).

test(parse_spawn_nested_statechart_rejects_missing_source,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(existence_error(option, src_uri_or_src_text), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="statechart"/></state></statechart>').

test(parse_spawn_actor_requires_goal,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(existence_error(attribute, goal), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="actor"/></state></statechart>').

test(parse_spawn_rejects_unknown_option,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(sxml_validation_error(_), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="toplevel" exit="false"/></state></statechart>').

test(parse_spawn_options_must_be_ground_list,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(domain_error(statechart_spawn_option(actor), monitor(_)), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="worker" options="[monitor(X)]"/></state></statechart>').

test(parse_after_transition,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">",
        "<state id=\"waiting\"><go to=\"done\" after=\"0.25\"/></state>",
        "<state id=\"done\"/>",
        "</statechart>"
    ], Text),
    statechart_model:statechart_actor_parse_text(Text),
    statechart_actor:after_transition(waiting, _Key, 0.25,
                                      true, [done], []).

test(parse_space_separated_targets,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    Text = '<statechart version="0.2" initial="s"><state id="s"><go to="a   b" on="split"/></state><state id="a"/><state id="b"/></statechart>',
    statechart_model:statechart_actor_parse_text(Text),
    assertion(statechart_actor:transition(s, split, true, [a, b], [])).

test(parse_after_rejects_on,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(domain_error(statechart_transition_trigger,
                                 on_and_after), _))
     ]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">",
        "<state id=\"waiting\">",
        "<go to=\"done\" on=\"go\" after=\"1\"/>",
        "</state>",
        "<state id=\"done\"/>",
        "</statechart>"
    ], Text),
    statechart_model:statechart_actor_parse_text(Text).

test(parse_spawn_rejects_load_source_alias,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(domain_error(statechart_spawn_option(actor), load_text(source)), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="worker" options="[load_text(source)]"/></state></statechart>').

test(parse_defer,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">",
        "<state id=\"waiting\">",
        "<defer on=\"command(C)\" if=\"C == later\"/>",
        "</state>",
        "</statechart>"
    ], Text),
    statechart_model:statechart_actor_parse_text(Text),
    statechart_actor:defer(waiting, command(C), C==later).

test(parse_rejects_invalid_embedded_prolog,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(syntax_error(_), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><go if="broken("/></state></statechart>').

test(parse_rejects_invalid_typed_spawn_attribute,
     [ setup(statechart_actor:clean),
       cleanup(statechart_actor:clean),
       throws(error(syntax_error(_), _))
     ]) :-
    statechart_model:statechart_actor_parse_text(
        '<statechart version="0.2" initial="s"><state id="s"><spawn type="actor" goal="broken("/></state></statechart>').

test(validation_api_is_side_effect_free,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    Text = '<statechart version="0.2" initial="s"><state id="s"/></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics == []),
    assertion(\+ statechart_actor:state(_, _)).

test(validation_rejects_unknown_element) :-
    Text = '<statechart version="0.2" initial="s"><state id="s"><mispelt/></state></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics = [diagnostic(error, _, _)|_]).

test(validation_rejects_unknown_attribute) :-
    Text = '<statechart version="0.2" initial="s"><state id="s" bogus="true"/></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics = [diagnostic(warning, _, _)|_]).

test(validation_rejects_misplaced_element) :-
    Text = '<statechart version="0.2" initial="s"><go to="s"/><state id="s"/></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics \== []).

test(validation_rejects_duplicate_identifiers) :-
    Text = '<statechart version="0.2" initial="s"><state id="s"/><final id="s"/></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics = [diagnostic(error, unknown,
                                        error(sxml_semantic_error(duplicate_identifier, s), _))]).

test(validation_rejects_unknown_transition_target) :-
    Text = '<statechart version="0.2" initial="s"><state id="s"><go to="missing"/></state></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics = [diagnostic(error, unknown,
                                        error(sxml_semantic_error(unknown_identifier, missing), _))]).

test(validation_requires_initial_to_be_direct_child) :-
    Text = '<statechart version="0.2" initial="nested"><state id="outer"><state id="nested"/></state></statechart>',
    statechart_model:statechart_validate_text(Text, Diagnostics),
    assertion(Diagnostics = [diagnostic(error, unknown,
                                        error(sxml_semantic_error(initial_not_direct_child, nested), _))]).

test(distributable_dtd_matches_embedded_schema) :-
    module_property(sxml_schema, file(SchemaModule)),
    file_directory_name(SchemaModule, WasmDir),
    file_directory_name(WasmDir, WebPrologDir),
    directory_file_path(WebPrologDir, 'sxml-0.2.dtd', DTDFile),
    read_file_to_codes(DTDFile, FileText, []),
    sxml_schema:sxml_dtd_text(EmbeddedText),
    assertion(FileText == EmbeddedText).

test(all_demonstrator_examples_validate) :-
    statechart_tests_directory(TestsDir),
    file_directory_name(TestsDir, RepositoryDir),
    directory_file_path(RepositoryDir, 'examples/statecharts/*.xml', Pattern),
    expand_file_name(Pattern, Files),
    assertion(Files \== []),
    forall(member(File, Files),
           ( statechart_model:statechart_validate(File, Diagnostics),
             assertion(Diagnostics == [])
           )).

:- end_tests(statechart_profile).


:- begin_tests(statechart_profile_runtime).

test(runtime_simple) :-
    init_interpreter('test_statecharts/statechart-simple.statechart'),
    statechart_actor:configuration(Config0),
    memberchk(s1, Config0),
    \+ memberchk(s2, Config0),
    statechart_actor:in(s1),
    \+ statechart_actor:in(s2),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk(s2, Config1),
    statechart_actor:in(s2),
    \+ statechart_actor:in(s1),
    step_event(reset),
    statechart_actor:configuration(Config2),
    memberchk(s1, Config2),
    statechart_actor:in(s1).

test(runtime_history) :-
    init_interpreter('test_statecharts/statechart-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Play', Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    \+ memberchk('Play', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('Play', Config3),
    memberchk('S2', Config3).

test(runtime_parallel_entry) :-
    init_interpreter('test_statecharts/statechart-parallel-idle.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Start', Config0),
    memberchk('Left', Config0),
    memberchk('Right', Config0).

test(runtime_gcd_finishes) :-
    init_interpreter('test_statecharts/statechart-gcd.statechart'),
    run_eventless(50),
    statechart_actor:configuration(Config1),
    memberchk('Stop', Config1),
    findall(X, statechart_actor:int(X), Xs),
    Xs \= [],
    sort(Xs, [5]).

test(runtime_gcd_output) :-
    init_interpreter('test_statecharts/statechart-gcd.statechart'),
    with_output_to(string(Output), run_eventless(50)),
    sub_string(Output, _, _, _, "5"),
    !.

test(runtime_spawn_toplevel_finishes, [setup(start_statechart_actor('test_statecharts/statechart-spawn-toplevel.statechart', Pid)),
                                      cleanup(stop_statechart_actor(Pid)),
                                      condition((current_predicate(toplevel_actors:toplevel_spawn/2),
                                                 current_predicate(actors:make_ref/1)))]) :-
    await_down(Pid, 3.0).

test(runtime_spawn_toplevel_supports_explicit_target) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"run\">",
        "<state id=\"run\">",
        "<spawn type=\"toplevel\" target=\"statechart_spawn_test_target\" options=\"[monitor(true)]\"/>",
        "<go on=\"spawned(Pid)\">",
        "toplevel_call(Pid,true,[template(true),limit(1)])",
        "</go>",
        "</state>",
        "</statechart>"
    ], Text),
    self(Self),
    setup_call_cleanup(
        register(statechart_spawn_test_target, Self),
        setup_call_cleanup(
            statechart_spawn(Pid, [src_text(Text), monitor(true)]),
            receive({
                success(_ToplevelPid, [true], false) -> true
            }, [timeout(2), on_timeout(fail)]),
            catch(exit(Pid, stop), _, true)
        ),
        catch(unregister(statechart_spawn_test_target), _, true)
    ).

test(runtime_spawn_actor_accepts_compound_goal_and_raw_source) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"run\">\n",
        "  <state id=\"run\">\n",
        "    <spawn type=\"actor\" goal=\"worker(1)\" options=\"[link(false)]\">\n",
        "      :- op(500, xfx, likes).\n",
        "      worker(1) :- alice likes bob.\n",
        "      alice likes bob.\n",
        "    </spawn>\n",
        "    <go to=\"done\" on=\"spawned(_)\"/>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        await_down(Pid, 2.0),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_spawn_server_supports_callback_state_and_source) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"server_owner\">\n",
        "  <state id=\"server_owner\" initial=\"run\">\n",
        "    <spawn type=\"server\" callback=\"counter\" state=\"0\" options=\"[name(spawn_counter)]\">\n",
        "      counter(inc, N, N1, N1) :- N1 is N+1.\n",
        "    </spawn>\n",
        "    <state id=\"run\"><go to=\"check\" on=\"spawned(_)\"/></state>\n",
        "    <state id=\"check\">\n",
        "      <onentry>server_request(spawn_counter, inc, 1), raise(ok)</onentry>\n",
        "      <go to=\"done\" on=\"ok\"/>\n",
        "    </state>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        await_down(Pid, 2.0),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_spawn_supervisor_supports_children_and_policy) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"supervisor_owner\">\n",
        "  <state id=\"supervisor_owner\" initial=\"run\">\n",
        "    <spawn type=\"supervisor\" children=\"[]\" options=\"[name(spawn_supervisor),strategy(one_for_all),intensity(2),period(5)]\"/>\n",
        "    <state id=\"run\"><go to=\"check\" on=\"spawned(_)\"/></state>\n",
        "    <state id=\"check\">\n",
        "      <onentry>supervisor_count_children(spawn_supervisor, [specs-0,active-0,supervisors-0,workers-0]), raise(ok)</onentry>\n",
        "      <go to=\"done\" on=\"ok\"/>\n",
        "    </state>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        await_down(Pid, 2.0),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_spawn_nested_statechart_with_extended_options) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"nested_owner\">\n",
        "  <state id=\"nested_owner\" initial=\"run\">\n",
        "    <spawn type=\"statechart\" options=\"[monitor(true),node(localhost),io_target(main),trace(false),src_list([spawn_support_list(from_list)]),src_predicates([spawn_support_predicate/1])]\"><![CDATA[\n",
        "      <statechart version=\"0.2\" initial=\"waiting\">\n",
        "        <state id=\"waiting\">\n",
        "          <onentry>spawn_support_list(A),spawn_support_predicate(B),writeln(child_io(A,B)),raise(finish)</onentry>\n",
        "          <go to=\"done\" on=\"finish\"/>\n",
        "        </state>\n",
        "        <final id=\"done\"/>\n",
        "      </statechart>\n",
        "    ]]></spawn>\n",
        "    <state id=\"run\"><go to=\"done\" on=\"down(_, _, _)\"/></state>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [
            src_text(Text),
            src_list([spawn_support_predicate(from_predicates)]),
            monitor(true)
        ]),
        (
            receive({
                terminal_io_output(_ChildPid,
                                   child_io(from_list, from_predicates)) -> true
            }, [timeout(2), on_timeout(fail)]),
            await_down(Pid, 2.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_statechart_spawn_load_uri_relative_game) :-
    statechart_tests_directory(TestsDir),
    file_directory_name(TestsDir, RepoDir),
    working_directory(Old, RepoDir),
    setup_call_cleanup(
        true,
        (
            statechart_spawn(Pid, [
                monitor(true),
                src_uri('examples/statecharts/game.xml')
            ]),
            await_output(Pid, 'IDLE', 1.0),
            send(Pid, play),
            await_output(Pid, 'PLAYING', 1.0),
            exit(Pid, stop),
            await_down(Pid, 2.0)
        ),
        working_directory(_, Old)
    ).


test(runtime_statechart_spawn_from_toplevel_load_text) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [src_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([success(ToplevelPid, [StatechartPid], false)], 2.0),
            sleep(0.05),
            toplevel_call(ToplevelPid,
                          flush,
                          [template(true), limit(1)]),
            await_messages([
                terminal_output(ToplevelPid, FlushMsg),
                success(ToplevelPid, [true], false)
            ], 2.0),
            sub_string(FlushMsg, _, _, _, "Shell got output("),
            sub_string(FlushMsg, _, _, _, ",'IDLE')"),
            catch(exit(StatechartPid, stop), _, true),
            !
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_spawn_name_registers_pid) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [
            src_text(Text),
            monitor(true),
            name(test_named_statechart)
        ]),
        (
            whereis(test_named_statechart, Visible),
            assertion(Pid =@= Visible)
        ),
        (
            unregister(test_named_statechart),
            catch(exit(Pid, stop), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_halt_reply_and_shutdown) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 1),
            assertion(Reply == true),
            await_down(Pid, 2.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_statechart_halt_timeout_defaults_reply_true) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>sleep(2)</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 0.1),
            assertion(Reply == killed)
        ),
        (
            catch(exit(Pid, kill), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_halt_timeout_honors_custom_on_timeout) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>sleep(2)</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 0.1),
            assertion(Reply == killed)
        ),
        (
            catch(exit(Pid, kill), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_writeln_uses_actor_io_path) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>writeln('IDLE')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [src_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([
                success(ToplevelPid, [StatechartPid], false),
                terminal_output(StatechartPid, 'IDLE')
            ], 2.0),
            catch(exit(StatechartPid, stop), _, true)
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_automatically_emits_terminal_trace_messages) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    once(statechart_spawn(Pid, [src_text(Text), monitor(true)])),
    once(receive({
        terminal_output(Pid, statechart_trace(_Trace0)) -> true
    }, [timeout(2), on_timeout(fail)])),
    once(send(Pid, play)),
    once(receive({
        terminal_output(Pid, statechart_trace(transition('Idle', ['Running'], _, _))) -> true
    }, [timeout(2), on_timeout(fail)])),
    once(exit(Pid, stop)),
    await_down(Pid, 2.0).

test(runtime_statechart_trace_routes_through_client_session_automatically) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [src_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([
                success(ToplevelPid, [StatechartPid], false),
                terminal_output(StatechartPid, statechart_trace(_))
            ], 2.0),
            catch(exit(StatechartPid, stop), _, true)
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_trace_false_suppresses_trace) :-
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text("<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"/></statechart>"),
                               trace(false), monitor(true)]),
        \+ receive({
               terminal_output(Pid, statechart_trace(_)) -> true
           }, [timeout(0.1), on_timeout(fail)]),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_statechart_supplemental_list_and_predicate_sources,
     [ setup(assertz(plunit_statechart_profile_runtime:spawn_support_predicate(from_predicates))),
       cleanup(retractall(plunit_statechart_profile_runtime:spawn_support_predicate(_)))
     ]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"run\">",
        "<state id=\"run\"><onentry>",
        "spawn_support_list(A),spawn_support_predicate(B),",
        "output(support(A,B)),raise(done)",
        "</onentry><go to=\"final\" on=\"done\"/></state>",
        "<final id=\"final\"/></statechart>"
    ], Text),
    statechart_spawn(Pid, [
        src_text(Text),
        src_list([spawn_support_list(from_list)]),
        src_predicates([spawn_support_predicate/1]),
        monitor(true)
    ]),
    receive({
        output(Pid, support(from_list, from_predicates)) -> true
    }, [timeout(2), on_timeout(fail)]),
    await_down(Pid, 2.0).

test(runtime_statechart_raise_onentry_triggers_internal_transition) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"Start\">\n",
        "  <parallel id=\"Start\">\n",
        "    <state id=\"Pinger\">\n",
        "      <onentry>raise(hello)</onentry>\n",
        "      <go on=\"hello\">writeln('PING')</go>\n",
        "    </state>\n",
        "    <state id=\"Ponger\"/>\n",
        "  </parallel>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            actors:receive({
                terminal_output(Pid, 'PING') -> true
            }, [timeout(2), on_timeout(fail)]),
            catch(exit(Pid, stop), _, true),
            await_down(Pid, 2.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_after_transition_fires) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">\n",
        "  <state id=\"waiting\">\n",
        "    <go to=\"done\" after=\"0.02\"/>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        await_down(Pid, 1.0),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_after_transition_cancelled_on_exit) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">\n",
        "  <state id=\"waiting\">\n",
        "    <go to=\"timed_out\" after=\"0.10\"/>\n",
        "    <go to=\"left\" on=\"leave\"/>\n",
        "  </state>\n",
        "  <final id=\"timed_out\"/>\n",
        "  <state id=\"left\">\n",
        "    <go to=\"done\" on=\"finish\"/>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            send(Pid, leave),
            receive({
                down(Pid, _) -> fail;
                down(Pid, _, _) -> fail
            }, [timeout(0.20), on_timeout(true)]),
            send(Pid, finish),
            await_down(Pid, 1.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_deferred_event_reoffered_after_state_change) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">\n",
        "  <state id=\"waiting\">\n",
        "    <defer on=\"finish\"/>\n",
        "    <go to=\"ready\" on=\"start\"/>\n",
        "  </state>\n",
        "  <state id=\"ready\">\n",
        "    <go to=\"done\" on=\"finish\"/>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            send(Pid, finish),
            send(Pid, start),
            await_down(Pid, 1.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_enabled_transition_precedes_deferral) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">\n",
        "  <state id=\"waiting\">\n",
        "    <defer on=\"finish\"/>\n",
        "    <go to=\"done\" on=\"finish\"/>\n",
        "  </state>\n",
        "  <final id=\"done\"/>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [src_text(Text), monitor(true)]),
        (
            send(Pid, finish),
            await_down(Pid, 1.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

:- end_tests(statechart_profile_runtime).


:- begin_tests(statechart_profile_semantics).

test(exit_set_pause, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-history.statechart'),
    Config = ['Play','S2'],
    Transition = t('Play', ['Interrupted'], []),
    statechart_actor:compute_exit_set([Transition], Config, ExitSet),
    sort(ExitSet, Sorted),
    sort(['Play','S2'], Expected),
    Sorted == Expected.

test(entry_set_resume_history, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-history.statechart'),
    statechart_actor:retractall(statechart_actor:historyValue(_,_)),
    statechart_actor:assertz(statechart_actor:historyValue('H', ['S2'])),
    Transition = t('Interrupted', ['H'], []),
    statechart_actor:compute_entry_set([Transition], EntrySet),
    sort(EntrySet, Sorted),
    sort(['Play','S2'], Expected),
    Sorted == Expected.

test(entry_set_parallel_initial, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-parallel-idle.statechart'),
    statechart_actor:state(Root, null),
    statechart_actor:assertz(statechart_actor:state(dummy, Root)),
    Transition = t(dummy, ['Start'], []),
    statechart_actor:compute_entry_set([Transition], EntrySet),
    sort(EntrySet, Sorted),
    sort(['Start','Left','Right'], Expected),
    Sorted == Expected.

test(exit_set_parallel_exit, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-parallel-exit.statechart'),
    Config = ['Start','Left','Right'],
    Transition = t('Left', ['Done'], []),
    statechart_actor:compute_exit_set([Transition], Config, ExitSet),
    sort(ExitSet, Sorted),
    sort(['Start','Left','Right'], Expected),
    Sorted == Expected.

test(trace_golden_simple, [setup(enable_trace_capture),
                           cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(go),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    collected_trace(Traces),
    memberchk(microstep(Exit, Entry), Traces),
    same_set(Exit, ['S1']),
    same_set(Entry, ['S2']),
    !.

test(trace_golden_history_pause_resume, [setup(enable_trace_capture),
                                         cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('S2', Config3),
    collected_trace(Traces0),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces0), Steps),
    length(Steps, 3),
    nth1(2, Steps, microstep(ExitPause, EntryPause)),
    same_set(ExitPause, ['Play','S2']),
    same_set(EntryPause, ['Interrupted']),
    nth1(3, Steps, microstep(ExitResume, EntryResume)),
    same_set(ExitResume, ['Interrupted']),
    same_set(EntryResume, ['Play','S2']),
    !.

test(trace_golden_parallel_exit, [setup(enable_trace_capture),
                                  cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-exit.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Left', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('Done', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['Start','Left','Right']),
    same_set(EntrySet, ['Done']),
    !.

test(trace_golden_deep_history, [setup(enable_trace_capture),
                                 cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-deep-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('S2', Config3),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    length(Steps, 3),
    nth1(3, Steps, microstep(ExitResume, EntryResume)),
    same_set(ExitResume, ['Interrupted']),
    same_set(EntryResume, ['Play','Inner','S2']),
    !.

test(trace_golden_parallel_conflict, [setup(enable_trace_capture),
                                      cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-conflict.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('A1', Config0),
    memberchk('B1', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('Done', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['Start','A','A1','B','B1']),
    same_set(EntrySet, ['Done']),
    !.

test(trace_golden_parallel_compatible, [setup(enable_trace_capture),
                                        cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-compatible.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('L1', Config0),
    memberchk('R1', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('L2', Config1),
    memberchk('R2', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['L1','R1']),
    same_set(EntrySet, ['L2','R2']),
    !.

test(after_reentry_ignores_stale_firing,
     [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    atomics_to_string([
        "<statechart version=\"0.2\" initial=\"waiting\">\n",
        "  <state id=\"waiting\">\n",
        "    <go to=\"timed_out\" after=\"100\"/>\n",
        "    <go to=\"away\" on=\"leave\"/>\n",
        "  </state>\n",
        "  <state id=\"away\"><go to=\"waiting\" on=\"back\"/></state>\n",
        "  <state id=\"timed_out\"/>\n",
        "</statechart>\n"
    ], Text),
    init_interpreter_text(Text),
    statechart_actor:after_timer(waiting, Key, Ref1),
    step_event(leave),
    step_event(back),
    statechart_actor:after_timer(waiting, Key, Ref2),
    assertion(Ref1 \=@= Ref2),
    \+ statechart_actor:select_transitions(
           '$statechart_after'(waiting, Key, Ref1), _),
    assertion(statechart_actor:in(waiting)),
    assertion(statechart_actor:after_timer(waiting, Key, Ref2)),
    step_event('$statechart_after'(waiting, Key, Ref2)),
    assertion(statechart_actor:in(timed_out)).

:- end_tests(statechart_profile_semantics).

start_statechart_actor(File, Pid) :-
    resolve_statechart_fixture(File, Source),
    spawn(statechart_actor:interpret(Source), Pid, [monitor(true)]),
    sleep(0.05).

stop_statechart_actor(Pid) :-
    exit(Pid, stop),
    sleep(0.05).

start_statechart_actor_with_stdout(File, Pid, OldStdout) :-
    self(Self),
    set_stdout_capture(Self, OldStdout),
    resolve_statechart_fixture(File, Source),
    spawn(statechart_actor:interpret(Source), Pid, [monitor(true)]),
    sleep(0.05).

parse_statechart_fixture(File) :-
    resolve_statechart_fixture(File, Source),
    statechart_actor:statechart_actor_parse(Source).

resolve_statechart_fixture(File, Source) :-
    (   statechart_tests_directory(TestDir),
        absolute_file_name(File, Source, [
            relative_to(TestDir),
            access(read),
            file_errors(fail)
        ])
    ->  true
    ;   Source = File
    ).

stop_statechart_actor_with_stdout(Pid, OldStdout) :-
    exit(Pid, stop),
    reset_stdout_capture(OldStdout),
    sleep(0.05).

await_down(Pid, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_down_until(Pid, Deadline).

await_down_until(Pid, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        down(Pid, _) -> true;
        down(Pid, _, _) -> true;
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_down_until(Pid, Deadline)
    }).

await_echo(Expected, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_echo_until(Expected, Deadline).

await_echo_until(Expected, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        echo(Expected) -> true;
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_echo_until(Expected, Deadline)
    }).

await_output(Pid, Data, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_output_until(Pid, Data, Deadline).

await_output_until(Pid, Data, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        output(Pid, Data) -> true;
        terminal_output(Pid, Data) -> true;
        output(_, _) -> test_statechart_profile:await_output_until(Pid, Data, Deadline);
        terminal_output(_, _) -> test_statechart_profile:await_output_until(Pid, Data, Deadline);
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_output_until(Pid, Data, Deadline)
    }).

await_messages(Patterns, Timeout) :-
    thread_self(Self),
    get_time(Now),
    Deadline is Now + Timeout,
    await_messages_until(Self, Patterns, Deadline).

await_messages_until(_, [], _) :-
    !.
await_messages_until(Self, Patterns0, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    thread_get_message(Self, Message, [timeout(Remaining)]),
    (   select(Pattern, Patterns0, Patterns),
        Message = Pattern
    ->  await_messages_until(Self, Patterns, Deadline)
    ;   await_messages_until(Self, Patterns0, Deadline)
    ).

set_stdout_capture(Self, OldStdout) :-
    (   actors:stdout(OldStdout)
    ->  true
    ;   OldStdout = none
    ),
    retractall(actors:stdout(_)),
    assertz(actors:stdout(Self)).

reset_stdout_capture(OldStdout) :-
    retractall(actors:stdout(_)),
    (   OldStdout \= none
    ->  assertz(actors:stdout(OldStdout))
    ;   true
    ).

:- dynamic collected_trace/1.

enable_trace_capture :-
    retractall(collected_trace(_)),
    asserta(collected_trace([])),
    retractall(statechart_actor:trace_hook(_)),
    assertz(statechart_actor:trace_hook(test_statechart_profile:capture_trace)).

disable_trace_capture :-
    retractall(statechart_actor:trace_hook(_)),
    retractall(collected_trace(_)).

capture_trace(microstep(Exit, Entry)) :-
    append_trace(microstep(Exit, Entry)).
capture_trace(_).

append_trace(Trace) :-
    retract(collected_trace(Traces)),
    append(Traces, [Trace], NewTraces),
    assertz(collected_trace(NewTraces)).

same_set(A, B) :-
    sort(A, SA),
    sort(B, SB),
    SA == SB.

step_event(Event) :-
    statechart_actor:update_eventdata(Event),
    statechart_actor:select_transitions(Event, EnabledTransitions),
    statechart_actor:microstep(EnabledTransitions).

init_interpreter(File) :-
    statechart_actor:clean,
    parse_statechart_fixture(File),
    init_parsed_interpreter.

init_interpreter_text(Text) :-
    statechart_actor:clean,
    statechart_model:statechart_actor_parse_text(Text),
    init_parsed_interpreter.

init_parsed_interpreter :-
    statechart_actor:root_state(Root),
    assertz(statechart_actor:configuration([])),
    assertz(statechart_actor:states_to_invoke([])),
    assertz(statechart_actor:running),
    assertz(statechart_actor:state(dummy, Root)),
    statechart_actor:initial_state(Root, Initial),
    message_queue_create(Internal),
    assertz(statechart_actor:internal_queue(Internal)),
    statechart_actor:enter_states([t(dummy, [Initial], [])]).

run_eventless(0) :- !.
run_eventless(Limit) :-
    (   statechart_actor:select_transitions(null, Enabled)
    ->  statechart_actor:microstep(Enabled),
        Limit1 is Limit - 1,
        run_eventless(Limit1)
    ;   true
    ).
