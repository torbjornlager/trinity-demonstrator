:- module(all_tests_runner, []).

:- use_module(library(plunit), [run_tests/0]).
:- user:load_files('./tests/goal_walker_tests.pl', []).
:- user:load_files('./tests/server_actor_tests.pl', []).
:- user:load_files('./tests/parallel_tests.pl', []).
:- use_module('./tests/supervisor_actor_tests.pl', []).
:- use_module('./tests/statechart_actor_tests.pl', []).
:- use_module('./tests/node_tests.pl', []).
:- user:load_files('./tests/actor_tests.pl', []).
:- user:load_files('./tests/toplevel_actor_tests.pl', []).

install_user_test_entrypoint :-
    (   current_predicate(user:test/0)
    ->  abolish(user:test/0)
    ;   true
    ),
    assertz((user:test :- all_tests_runner:run_all_tests_from_root)).

run_all_tests_from_root :-
    source_file(all_tests_runner:install_user_test_entrypoint, ThisFile),
    file_directory_name(ThisFile, BaseDir),
    directory_file_path(BaseDir, tests, TestsDir),
    setup_call_cleanup(
        working_directory(OldWD, TestsDir),
        run_all_tests,
        working_directory(_, OldWD)
    ).

run_all_tests :-
    run_tests.

:- initialization(install_user_test_entrypoint, after_load).
