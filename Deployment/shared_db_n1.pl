% n1 is the conservative public node.
% Hosts the human/1 facts that n2's distributed `mortal/1` chain pulls in
% over rpc/2-3.

deployment_node(n1).

human(plato).
human(aristotle).

% Owner-curated contract, surfaced via /node_info (harvested by a discovery hub).
provides(human/1).
