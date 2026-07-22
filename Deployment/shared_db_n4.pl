% n4 is the second public actor-demo node.
% The shared actor predicates are in shared_db_actor_common.pl. This overlay
% holds only n4-specific predicates: the deployment marker and the human/1
% facts that n3's distributed proof tree pulls in over rpc/2-3.

:- dynamic human/1.

human(plato).
human(aristotle).

% Shared database used by example 13 shared-database.xml.

shared_fact(n4_shared_db).

% The statechart datamodel defines local_label/1 too.  Its local definition
% shadows this shared one while the chart is running.
local_label(n4_shared_db).

shared_transition_enabled.
