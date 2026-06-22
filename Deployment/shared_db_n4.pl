% n4 is the second public actor-demo node.
% The shared actor predicates are in shared_db_actor_common.pl. This overlay
% holds only n4-specific predicates: the deployment marker and the human/1
% facts that n3's distributed proof tree pulls in over rpc/2-3.


:- dynamic human/1.

human(plato).
human(aristotle).

