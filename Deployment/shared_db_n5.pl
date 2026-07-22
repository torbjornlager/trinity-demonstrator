% n5-specific shared-database overlay.
%
% The generic node database is loaded first by start_node.pl; this file adds
% only the predicates that distinguish the n5 deployment.

% Shared database used by example 13 shared-database.xml.

shared_fact(n5_shared_db).

% The statechart datamodel defines local_label/1 too. Its local definition
% shadows this shared one while the chart is running.
local_label(n5_shared_db).

shared_transition_enabled.
