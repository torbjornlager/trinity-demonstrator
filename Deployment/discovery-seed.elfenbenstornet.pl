% Discovery hub seed for the elfenbenstornet.se deployment.
%
% Loaded by the n0 hub via WP_DISCOVERY_SEED_FILE (see
% compose.elfenbenstornet.yaml). n0 — the hub itself — is added
% automatically and self-probes localhost, so it is not listed here.
% A seed lists addresses only; everything a card shows comes from each
% node's own /node_info.

% n5 is co-located with the hub in the same compose, so it is PROBED
% over the container network (http://n5:3060) while still DISPLAYED at
% its public URL. A node behind a reverse proxy cannot in general be
% reached at its own public name from inside the same host (NAT hairpin).
seed_node(n5, 'https://n5.elfenbenstornet.se').
seed_probe_url(n5, 'http://n5:3060').

% The public demonstrator nodes n1–n4 live in a separate stack and are
% probed over their public URLs. If this stack runs on the same host and
% public hairpinning is unreliable, switch these to internal
% seed_probe_url/2 targets as in discovery-seed.coexist.pl.
seed_node(n1, 'https://n1.elfenbenstornet.se').
seed_node(n2, 'https://n2.elfenbenstornet.se').
seed_node(n3, 'https://n3.elfenbenstornet.se').
seed_node(n4, 'https://n4.elfenbenstornet.se').
