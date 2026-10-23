:- module(test_partition, [partition_test_specs/3, test_class/3]).

/** <module> Explicit test ownership for a native-only checkout

All existing tests stay in their units. Native and integration selections are
exhaustive, with two existing colocated-layout compatibility tests kept as an
explicit third selection. Full tiers continue to execute the original lists.
*/
:- use_module(library(plunit), []).
:- use_module(library(lists), [member/2]).

partition_test_specs(Units,Class,Specs) :-
    memberchk(Class,[native,integration,legacy_layout]),
    forall(member(Unit,Units),
           (plunit:current_test_unit(Unit,_) -> true
            ;throw(error(existence_error(test_unit,Unit),_)))),
    % A stale classification must fail loudly rather than silently lose a test.
    forall(((external_test(Unit,Name);legacy_test(Unit,Name)),memberchk(Unit,Units)),
           (plunit:current_test(Unit,Name,_,_,_) -> true
            ;throw(error(existence_error(classified_test,Unit:Name),_)))),
    findall(Unit:Names,
        (member(Unit,Units),
         findall(Name,(plunit:current_test(Unit,Name,_,_,_),
                       test_class(Unit,Name,Class)),Names),Names\==[]),Specs).

test_class(Unit,Name,Class) :-
    (legacy_test(Unit,Name) -> Class=legacy_layout
    ;external_unit(Unit) -> Class=integration
    ;external_test(Unit,Name) -> Class=integration
    ;Class=native).

external_unit(service_request_example).
external_test(t1_load_options,load_uri_without_user_bang_operator).
external_test(statechart_profile,all_demonstrator_examples_validate).
external_test(statechart_profile_runtime,runtime_statechart_spawn_load_uri_relative_game).
external_test(node,node_tutorial_and_image_routes_served).
external_test(node,node_portal_and_example_routes_served).
external_test(node,node_api_tutorial_routes_served).
external_test(node,node_admin_page_served).
external_test(node,node_manual_page_served).
external_test(node,node_admin_and_portal_pages_include_manual_predicate_link_support).
external_test(node,node_admin_and_portal_pages_include_config_help_controls).
external_test(node,distributed_ping_pong_preserves_causal_output).
external_test(node,browser_terminal_ping_pong_across_two_connections).
external_test(node,ws_mixed_ping_pong_routes_browser_actor_in_spawn_goal).
external_test(node,statechart_spawn_load_uri_node_relative).
external_test(node,statechart_executable_content_uses_node_shared_db_and_local_shadow).
external_test(node,statechart_executable_content_uses_n5_shared_db_overlay).
external_test(node,ws_statechart_spawn_automatically_emits_trace).
external_test(node,node_resident_services_are_discoverable_via_rpc).
external_test(node,node_resident_counter_service_exposes_shared_state).
external_test(node,advertisement_does_not_create_a_live_service).
external_test(node,node_resident_pubsub_service_coordinates_clients).
external_test(node,public_actor_client_sees_service_as_sendable_but_not_client_registered).
legacy_test(node_assets,default_resolvers_preserve_checkout_paths).
legacy_test(node_assets,default_root_is_independent_of_working_directory).
