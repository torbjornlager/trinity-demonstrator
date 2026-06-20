% Discovery hub — the public shared-database read side (slice 1).
%
% This file is loaded as the discovery hub node's shared database
% (load_shared_db_file/1), so its predicates are reachable through the
% same `/call` API every node already speaks.  Discovery is then a
% query: finding a node is running a goal against this database.
%
%     ?- node_profile(N, actor), node_status(N, up).
%
% The facts behind these rules — node_record_gen/3 and current_gen/1 —
% are *not* authored here.  They are a denormalized read replica that
% the registry custodian (discovery_hub.pl) republishes on every state
% change.  This file is the stateless reader; discovery_hub.pl is the
% single writer.  See docs/DISCOVERY_HUB_PLAN.md §3.4.

:- dynamic node_record_gen/3.        % Gen, Id, Record (status-free dict)
:- dynamic current_gen/1.            % the live generation pointer


% --- RELATION profile: the advertised public query surface ----------
%
% When the hub runs at WP_PROFILE=relation, these relation_filter/1
% declarations are the *only* relations a client may query over /call;
% the relation goal guard refuses everything else — internal helpers
% (record_with_status/2, node_live_status/4), arbitrary goals, and
% conjunctions alike.  Declaring them explicitly keeps the helpers out
% of the advertised schema (the source-parse fallback would otherwise
% expose every clause head).  Inert at the other profiles.

relation_filter(node_record(_, _)).
relation_filter(node_id(_)).
relation_filter(node_url(_, _)).
relation_filter(node_profile(_, _)).
relation_filter(node_auth(_, _)).
relation_filter(node_status(_, _)).
relation_filter(node_card(_, _, _, _, _, _)).
relation_filter(node_directory_row(_, _, _, _, _, _, _, _, _)).
relation_filter(node_service(_, _)).
relation_filter(node_provides(_, _)).
relation_filter(node_self_contained(_, _)).
relation_filter(node_profile_at_least(_, _)).


% --- The hub's own owner-curated contract -----------------------------
% Surfaced via /node_info and harvested back into node_provides(n0, _),
% so the hub advertises the discovery relations it serves (n0 appears in
% its own directory with a capability list, self-referential and honest).

provides(node_record/2).
provides(node_directory_row/9).
provides(node_profile/2).
provides(node_auth/2).
provides(node_status/2).
provides(node_service/2).
provides(node_provides/2).


%!  node_record(?Id, -Record) is nondet.
%
%   The composed public record for a node, as a dict.  The stable
%   fields come straight from the replica; `status` is *derived at read
%   time* (never stored) from the observed timestamps, so a node that
%   died between sweeps cannot leave a stale `up` stranded in the store.
%
%   The cut commits each query to a single generation: during the brief
%   double-buffer overlap two current_gen/1 facts may coexist, and the
%   cut takes the first (older, still-complete) one until it is retired,
%   so no query ever spans two generations (plan §3.4).

node_record(Id, Record) :-
    current_gen(Gen),
    !,
    node_record_gen(Gen, Id, Rec0),
    record_with_status(Rec0, Record).

record_with_status(Rec0, Record) :-
    get_time(NowF),
    Now is integer(NowF),
    get_dict(last_seen, Rec0, Seen),
    get_dict(last_error, Rec0, Err),
    (   get_dict(maintenance, Rec0, Maintenance)
    ->  true
    ;   Maintenance = false
    ),
    node_live_status(Now, Seen, Err, Maintenance, Status),
    put_dict(status, Rec0, Status, Record).

%!  node_live_status(+Now, +LastSeen, +LastError, +Maintenance, -Status) is det.
%
%   `up` needs a *fresh* success that is not superseded by a newer
%   error; one missed probe after a good one is the amber `unreachable`
%   band; an alive node whose `/readyz` reports not-ready is
%   `maintenance`; anything stale (or never seen) is `down`.  TTL = 75s
%   ≈ 2×30s sweep, wide enough that a single dropped probe never flaps
%   a healthy node to down (plan §4).

node_live_status(Now, Seen, Err, Maintenance, Status) :-
    (   Seen > 0,
        Now - Seen =< 75
    ->  (   Maintenance == true -> Status = maintenance
        ;   Err > Seen          -> Status = unreachable
        ;   Status = up
        )
    ;   Status = down
    ).


%!  node_id(?Id) is nondet.
%!  node_url(?Id, -Url) is nondet.
%!  node_profile(?Id, -Profile) is nondet.
%!  node_auth(?Id, -Auth) is nondet.
%!  node_status(?Id, -Status) is nondet.
%
%   The normalized query relations.  Discovery in Web Prolog is a
%   program, not a protocol stack: these let a client compose
%   `?- node_profile(N, actor), node_status(N, up).` over plain `/call`.
%   `profile`/`auth` read `unknown` until the first successful probe, so
%   the relations only succeed once the node has actually self-reported.
%
%   (The plan §2.2 sketches the membership relation as `node/1`; here it
%   is `node_id/1` because the node server already owns `node/1` — the
%   hub's shared module would otherwise shadow it.)

node_id(Id) :-
    current_gen(Gen),
    !,
    node_record_gen(Gen, Id, _).

node_url(Id, Url) :-
    node_record(Id, Record),
    get_dict(url, Record, Url).

node_profile(Id, Profile) :-
    node_record(Id, Record),
    get_dict(profile, Record, Profile),
    Profile \== unknown.

node_auth(Id, Auth) :-
    node_record(Id, Record),
    get_dict(auth, Record, Auth),
    Auth \== unknown.

node_status(Id, Status) :-
    node_record(Id, Record),
    get_dict(status, Record, Status).


%!  node_card(?Id, -Status, -Profile, -Auth, -LatencyMs, -LastSeen) is nondet.
%
%   The flat, JSON-friendly projection the directory UI enumerates over
%   `/call`: the *dynamic* fields keyed by id (the static seed tier —
%   description, links — the client already holds).  One row per node;
%   `profile`/`auth` are `unknown` until the node is first probed.

node_card(Id, Status, Profile, Auth, LatencyMs, LastSeen) :-
    node_record(Id, Record),
    get_dict(status, Record, Status),
    get_dict(profile, Record, Profile),
    get_dict(auth, Record, Auth),
    get_dict(latency_ms, Record, LatencyMs),
    get_dict(last_seen, Record, LastSeen).


%!  node_directory_row(?Id, -Status, -Profile, -Auth, -LatencyMs,
%!                      -LastSeen, -Url, -Description, -Note) is nondet.
%
%   The full flat projection the /discovery-hub directory page renders:
%   the dynamic fields plus the seed tier (url, description, note), all
%   JSON-friendly, one row per node.  node_card/6 stays the minimal
%   status-only projection; this one carries enough to draw a card.

node_directory_row(Id, Status, Profile, Auth, LatencyMs, LastSeen,
                   Url, Description, Note) :-
    node_record(Id, Record),
    get_dict(status, Record, Status),
    get_dict(profile, Record, Profile),
    get_dict(auth, Record, Auth),
    get_dict(latency_ms, Record, LatencyMs),
    get_dict(last_seen, Record, LastSeen),
    get_dict(url, Record, Url),
    get_dict(description, Record, Description),
    get_dict(note, Record, Note).


%!  node_service(?Id, ?Service) is nondet.
%!  node_provides(?Id, ?Predicate) is nondet.
%
%   The harvested capability tier, one row per (node, capability): the
%   node-resident services a node publishes, and the owner-curated
%   predicates it advertises (its `provides/1` contract).  These let a
%   client compose, over a single /call, the discovery payoff:
%
%       ?- node_profile(N, actor), node_status(N, up),
%          node_provides(N, 'human/1').

node_service(Id, Service) :-
    node_record(Id, Record),
    get_dict(services, Record, Services),
    member(Service, Services).

node_provides(Id, Predicate) :-
    node_record(Id, Record),
    get_dict(provides, Record, Provides),
    member(Predicate, Provides).


%!  node_self_contained(?Id, -SelfContained) is nondet.
%
%   The portability axis a node reports through /node_info, harvested
%   into the replica: `true` if its shared DB is self-contained,
%   `false` if dependent, `unknown` until first probed (or if an older
%   record predates the field).
node_self_contained(Id, SelfContained) :-
    node_record(Id, Record),
    (   get_dict(self_contained, Record, SC)
    ->  SelfContained = SC
    ;   SelfContained = unknown
    ).


%!  node_profile_at_least(?Id, +Min) is nondet.
%
%   The profile lattice as a first-class relation (plan §2.4): nodes
%   whose profile is Min or more capable.  Discovery wants "≥ isotope",
%   not "= isotope", so the ordering is served, not left to callers.

profile_rank(relation, 0).
profile_rank(isobase,  1).
profile_rank(isotope,  2).
profile_rank(actor,    3).

node_profile_at_least(Id, Min) :-
    node_profile(Id, Profile),
    profile_rank(Profile, Rank),
    profile_rank(Min, MinRank),
    Rank >= MinRank.
