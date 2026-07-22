% n3 is the public actor-demo node.
% The shared actor predicates are in shared_db_actor_common.pl. This overlay
% holds only n3-specific predicates: the deployment marker and the
% mortal/human chain that the tutorial's distributed proof tree pulls
% through to n4.

:- dynamic mortal/1, human/1.

mortal(X) :- human(X).

human(socrates).
human(X) :- rpc('https://n4.elfenbenstornet.se', human(X)).

% Shared database used by example 13 shared-database.xml.

shared_fact(n3_shared_db).

% The statechart datamodel defines local_label/1 too.  Its local definition
% shadows this shared one while the chart is running.
local_label(n3_shared_db).

shared_transition_enabled.
