% Discovery hub seed for COEXIST mode: the n0 hub runs alongside the
% existing demonstrator stack, joined to its `deployment_wp_net` network
% (see compose.hub-attach.yaml). n0 itself is added automatically and
% self-probes localhost, so it is not listed here.
%
% A seed lists addresses only. Everything a card shows (implementation,
% version, description, profile, auth, capabilities) comes from each
% node's own /node_info.
%
% Every peer is DISPLAYED at its public URL but PROBED over the container
% network at its in-stack service name and port — fast, no NAT hairpin,
% and nothing extra exposed publicly. (Demonstrator service names/ports:
% wp_n1:3051, wp_n2:3052, wp_n3:3053, wp_n4:3055, wp_n5:3060.)

seed_node(n1, 'https://n1.elfenbenstornet.se').
seed_probe_url(n1, 'http://wp_n1:3051').

seed_node(n2, 'https://n2.elfenbenstornet.se').
seed_probe_url(n2, 'http://wp_n2:3052').

seed_node(n3, 'https://n3.elfenbenstornet.se').
seed_probe_url(n3, 'http://wp_n3:3053').

seed_node(n4, 'https://n4.elfenbenstornet.se').
seed_probe_url(n4, 'http://wp_n4:3055').

seed_node(n5, 'https://n5.elfenbenstornet.se').
seed_probe_url(n5, 'http://wp_n5:3060').

seed_node(n6, 'https://n6.elfenbenstornet.se').
seed_probe_url(n6, 'http://caddy:8086').

seed_node(n7, 'https://n7.elfenbenstornet.se').
seed_probe_url(n7, 'http://caddy:8087').
