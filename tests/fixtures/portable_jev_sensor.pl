% Deterministic sensor for cross-engine example regression tests.

jev_deployment_observation(Text,Result) :-
 ( Text == "crash" -> throw(fixture_crash)
 ; Text == "malformed" -> Result = observation(choice(affirm,json([]),2),score(1,json([]),json([]),0.9),noul(0.1),provenance(json([])))
 ; Text == "unavailable" -> Result = unavailable(configuration)
 ; (Text == "Please prepare a deployment" -> Intent=request_deploy ; Text == "What is the deployment status?" -> Intent=status ; Intent=affirm),
   Result=observation(choice(Intent,json([]),0.95),score(1,json([]),json([]),0.8),noul(0.1),provenance(json([string([116,101,120,116])=string([91,93]),string([97,114,114])=[]]))) ).
