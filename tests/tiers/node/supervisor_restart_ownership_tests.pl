:- module(test_supervisor_restart_ownership, []).
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module('../supervisor_restart_tests.pl', []).
:- use_module('../supervisor_intensity_tests.pl', []).
:- use_module(library(plunit)).

:- begin_tests(supervisor_restart_ownership).

test(restart_failure_cleanup_retains_ordinary_owner_authority,
     [forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]))]) :-
    with_owner_context(principal{id:"restart-owner",capabilities:[execute],unknown:false},
      restart_probe, local,
      test_supervisor_restart:fixture(test_supervisor_restart:automatic(Strategy,normal))).

test(live_group_replacements_remain_reclaimable_after_monitor_failure) :-
    with_owner_context(principal{id:"restart-owner",capabilities:[execute],unknown:false},
      restart_probe, local,
      test_supervisor_restart:fixture(test_supervisor_restart:automatic(one_for_all,monitor_error))).

test(intensity_cleanup_retains_ordinary_owner_authority,
     [forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]))]) :-
    with_owner_context(principal{id:"intensity-owner",capabilities:[execute],unknown:false},
      intensity_probe, local,
      test_supervisor_restart:fixture(test_supervisor_intensity:exhaustion(Strategy,0,normal))).

:- end_tests(supervisor_restart_ownership).
