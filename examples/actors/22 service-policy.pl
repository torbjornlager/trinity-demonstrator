%% Reasoning about service requests, before adding an agent.
%
% These are the policy rules from 18 service-request.xml. They run locally
% on ISOBASE (including n1), ISOTOPE, ACTOR, and SWI-WASM.
%
% classify(+Fields, -Decision) expects validated, ground fields: at most
% one service/1 and one cost/1. Services are laptop, vpn, restricted, or
% training; costs are integers from 0 to 10000000. Either field may be
% missing. The full statechart validates input before calling these rules.
%
% This example only classifies a request; it does not approve or send one.

% Policy

complete(Fields) :-
    memberchk(service(_), Fields),
    memberchk(cost(_), Fields).

permit(Fields) :-
    memberchk(service(Service), Fields),
    memberchk(Service, [laptop, vpn]),
    memberchk(cost(Cost), Fields),
    Cost =< 1000.

forbid(Fields) :-
    memberchk(service(restricted), Fields).
forbid(Fields) :-
    memberchk(service(vpn), Fields).

% Assessment: the order matters.
% Check completeness first, then conflict, prohibition, permission, and gap.

classify(Fields, insufficient(missing_fields)) :-
    \+ complete(Fields), !.
classify(Fields, conflicting) :-
    permit(Fields), forbid(Fields), !.
classify(Fields, forbidden) :-
    forbid(Fields), !.
classify(Fields, permitted) :-
    permit(Fields), !.
classify(_, insufficient(policy_gap)).

/** <examples>

% A laptop within budget is permitted.

?- classify([service(laptop), cost(700)], Decision).

% Restricted services are forbidden.

?- classify([service(restricted), cost(1)], Decision).

% Both rules apply to a low-cost VPN: report the conflict explicitly.

?- classify([service(vpn), cost(10)], Decision).

% A missing cost is an information deficit.

?- classify([service(laptop)], Decision).

% Training has complete fields, but neither policy rule covers it.

?- classify([service(training), cost(500)], Decision).

% Crossing the budget removes permission. It does not establish prohibition.

?- classify([service(laptop), cost(1001)], Decision).

*/
