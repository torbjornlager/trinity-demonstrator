% Owner-curated publication of node-resident services.

service(counter, meta(actor, protocol(count_v1))).
service(pubsub_service, meta(actor, protocol(pubsub_v1))).
service(linda, meta(actor, protocol(linda_v1))).

% Owner-installed local service address; callers use linda_out/1 etc.
linda_local_address(linda@Node) :- self_node_url(Node).
