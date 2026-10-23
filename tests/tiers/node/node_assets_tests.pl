:- module(test_node_assets, []).

:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/node_assets.pl').
:- use_module(library(plunit)).
:- use_module(library(settings)).
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).

:- meta_predicate with_assets(+, +, 0), with_server(1).
with_assets(Root, Wasm, Goal) :-
    setting(node_assets:root, OldRoot),
    setting(node_assets:wasm_directory, OldWasm),
    setup_call_cleanup(
        (set_setting(node_assets:root, Root), set_setting(node_assets:wasm_directory, Wasm)),
        Goal,
        (set_setting(node_assets:root, OldRoot), set_setting(node_assets:wasm_directory, OldWasm))).

page('/portal', 'web/demonstrator.html').
page('/demonstrator', 'web/demonstrator.html').
page('/discovery-hub', 'web/discovery-hub.html').
page('/tutorial', 'web/tutorial.html').
page('/swi-wasm-tutorial', 'web/swi-wasm-tutorial.html').
page('/isobase-profile-tutorial', 'web/isobase-profile-tutorial.html').
page('/isotope-profile-tutorial', 'web/isotope-profile-tutorial.html').
page('/actor-profile-tutorial', 'web/actor-profile-tutorial.html').
page('/isobase-api-tutorial', 'web/isobase-api-tutorial.html').
page('/isotope-api-tutorial', 'web/isotope-api-tutorial.html').
page('/actor-api-tutorial', 'web/actor-api-tutorial.html').
page('/jev-sxml-tutorial', 'web/jev-sxml-tutorial.html').
page('/manual', 'web/manual.html').
page('/editor_frame', 'web/editor_frame.html').
page('/admin', 'web/admin.html').
page('/swi_wasm_actor_worker.js', 'web/swi_wasm_actor_worker.js').
page('/swipl-bundle.js', 'web/swipl-bundle.js').
page('/admin/tabler.min.css', 'web/tabler.min.css').
page('/vendor/probe.js', 'web/vendor/probe.js').
page('/img/probe.svg', 'img/probe.svg').
page('/examples/actors/probe.pl', 'examples/actors/probe.pl').
page('/examples/statecharts/probe.xml', 'examples/statecharts/probe.xml').
page('/statecharts/probe.xml', 'examples/statecharts/probe.xml').

wasm('shared_db.pl').
wasm('sxml_schema.pl').
wasm('statechart_wasm.pl').
wasm('statechart_wasm_model.pl').
wasm('statechart_wasm_exec.pl').
wasm('statechart_wasm_runtime.pl').

fixture(Root) :-
    tmp_file(node_asset_root, Root), make_directory(Root),
    forall(page(_, Rel), write_fixture(Root, Rel)),
    forall(wasm(Name),
           (atom_concat('prolog/web_prolog/wasm/', Name, Rel), write_fixture(Root, Rel))).
write_fixture(Root, Rel) :-
    directory_file_path(Root, Rel, File), file_directory_name(File, Dir),
    make_directory_path(Dir),
    setup_call_cleanup(open(File, write, S, [encoding(utf8)]),
                       format(S, 'relocated ~w', [Rel]), close(S)).

with_server(Goal) :-
    tmp_file(node_asset_log, Log),
    setting(node_interaction_log:interaction_log_file, Previous),
    setup_call_cleanup(
        (set_setting(node_interaction_log:interaction_log_file, Log),
         http_server(http_dispatch, [port(Port), workers(2)])),
        call(Goal, Port),
        (http_stop_server(Port, []),
         set_setting(node_interaction_log:interaction_log_file, Previous),
         (exists_file(Log) -> delete_file(Log); true))).

fetch(Port, Path, Status, Type, Cache, Body) :-
    format(atom(URL), 'http://localhost:~w~w', [Port, Path]),
    setup_call_cleanup(
        http_open(URL, S, [status_code(Status), timeout(5), redirect(false),
                           header(content_type, Type), header(cache_control, Cache)]),
        read_string(S, _, Body), close(S)).

relocated_pages(Port) :-
    forall(page(Path, Rel),
           (fetch(Port, Path, Status, _, _, Body),
            assertion(Status == 200),
            format(string(Expected), 'relocated ~w', [Rel]),
            assertion(Body == Expected))),
    forall(wasm(Name),
           (atom_concat('/wasm/', Name, Path), fetch(Port, Path, Status, Type, _, Body),
            assertion(Status == 200), assertion(sub_atom(Type, 0, _, _, 'text/plain')),
            format(string(Expected), 'relocated prolog/web_prolog/wasm/~w', [Name]),
            assertion(Body == Expected))),
    fetch(Port, '/manual', _, _, Cache, _),
    assertion(sub_atom(Cache, _, _, _, 'no-store')),
    fetch(Port, '/swi_wasm_actor_worker.js', _, WorkerType, WorkerCache, _),
    assertion(sub_atom(WorkerType, 0, _, _, 'text/javascript')),
    assertion(sub_atom(WorkerCache, _, _, _, 'no-store')),
    fetch(Port, '/vendor/probe.js', _, VendorType, _, _),
    assertion(sub_atom(VendorType, 0, _, _, 'text/javascript')),
    fetch(Port, '/statecharts/probe.xml', _, XMLType, _, _),
    assertion(sub_atom(XMLType, 0, _, _, 'text/xml')),
    fetch(Port, '/examples_index', IndexStatus, _, _, IndexText),
    assertion(IndexStatus == 200), atom_json_dict(IndexText, Index, []),
    assertion(member(_{name:"probe.pl",url:"/examples/actors/probe.pl",kind:"prolog"}, Index.actors)),
    assertion(member(_{name:"probe.xml",url:"/examples/statecharts/probe.xml",kind:"statechart"}, Index.statecharts)).

override_wasm(Directory, Port) :-
    fetch(Port, '/wasm/shared_db.pl', Status, _, _, Body),
    assertion(Status == 200), assertion(Body == "relocated shared_db.pl"),
    fetch(Port, '/wasm/statechart_wasm.pl', Missing, _, _, _),
    assertion(Missing == 500), % Explicit source directory must not fall back.
    node:node_wasm_module_file('shared_db.pl', Actual),
    directory_file_path(Directory, 'shared_db.pl', Expected), assertion(Actual == Expected).

% Existing missing-file/failed-handler replies are 500. Keep that behavior;
% this batch only changes file lookup, not HTTP error mapping.
missing_asset(Port) :-
    fetch(Port, '/manual', Status, _, _, _), assertion(Status == 500),
    fetch(Port, '/wasm/node.pl', Denied, _, _, _), assertion(Denied == 500).

:- begin_tests(node_assets).

test(default_resolvers_preserve_checkout_paths) :-
    with_assets('', '',
      (module_property(node, file(NodeFile)), file_directory_name(NodeFile, Dir),
       forall(page(_, Rel),
              (node_asset_file(Rel, Actual),
               directory_file_path(Dir, '../..', Root), directory_file_path(Root, Rel, Expected),
               assertion(same_file(Actual, Expected)))),
       forall(wasm(Name),
              (node:node_wasm_module_file(Name, Actual),
               directory_file_path(Dir, wasm, WasmDir), directory_file_path(WasmDir, Name, Expected),
               assertion(same_file(Actual, Expected)))))).

test(relocated_tree_serves_existing_urls,
     [setup(fixture(Root)), cleanup(delete_directory_and_contents(Root))]) :-
    with_assets(Root, '', with_server(relocated_pages)).

test(explicit_wasm_directory_is_authoritative,
     [setup((fixture(Root), tmp_file(wasm_sources, Wasm), make_directory(Wasm),
             write_fixture(Wasm, 'shared_db.pl'))),
      cleanup((delete_directory_and_contents(Wasm), delete_directory_and_contents(Root)))]) :-
    with_assets(Root, Wasm, with_server(override_wasm(Wasm))).

test(explicit_root_does_not_fall_back_to_checkout,
     [setup((fixture(Root), directory_file_path(Root, 'web/manual.html', File), delete_file(File))),
      cleanup(delete_directory_and_contents(Root))]) :-
    with_assets(Root, '', with_server(missing_asset)).

test(default_root_is_independent_of_working_directory,
     [setup((tmp_file(asset_cwd, Dir), make_directory(Dir))),
      cleanup(delete_directory(Dir))]) :-
    with_assets('', '',
      (node:node_manual_file(Before),
       setup_call_cleanup(working_directory(Previous, Dir), node:node_manual_file(After),
                          working_directory(_, Previous)),
       assertion(Before == After), assertion(exists_file(After)))).

test(prefix_guards_and_wasm_allowlist_remain_in_force,
     [setup(fixture(Root)), cleanup(delete_directory_and_contents(Root))]) :-
    with_assets(Root, '',
      (node:node_examples_dir(Dir),
       assertion(\+node:safe_asset_file(Dir, '../web/manual.html', _)),
       assertion(\+node:safe_asset_file(Dir, '/etc/passwd', _)),
       assertion(\+node:node_wasm_module_file('../node.pl', _)),
       assertion(\+node:node_wasm_module_file('node.pl', _)))).

:- end_tests(node_assets).
