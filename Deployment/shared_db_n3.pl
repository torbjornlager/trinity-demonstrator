% n3 is the public actor-demo node.
% The shared actor predicates are in shared_db_actor_common.pl. This overlay
% holds only n3-specific predicates: the deployment marker and the
% mortal/human chain that the tutorial's distributed proof tree pulls
% through to n4.

deployment_node(n3).

:- dynamic mortal/1, human/1.

mortal(X) :- human(X).

human(socrates).
human(X) :- rpc('https://n4.elfenbenstornet.se', human(X)).

% Owner-curated contract, surfaced via /node_info (harvested by a discovery hub).
provides(human/1).
provides(mortal/1).
