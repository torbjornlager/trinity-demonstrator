# Jev semantic observations in Web Prolog

This experiment is a small vertical slice, not a general neuro-symbolic
framework. It develops one architecture in two stages:

1. **Jev + Web Prolog:** a complete Observe–Think–Act actor using ordinary
   Prolog clauses.
2. **Jev + Web Prolog + SXML:** the same semantic observation gains
   state-dependent meaning in a two-state confirmation protocol.

Jev answers bounded semantic questions with typed probabilistic decisions.
The Trinity layer treats those decisions as semantic observations. In Stage 1,
ordinary Prolog performs Think and Act; Stage 2 adds SXML only when interaction
state needs explicit behavioural control.

## Layers

- `jev_http.pl` owns the TypeSafe HTTP protocol, authentication and raw JSON.
- `jev.pl` maps Choice, Score and Noul questions to typed probabilistic
  decisions represented as Prolog data.
- `deployment_observation.pl` defines the one application-facing boundary used
  by both stages:

  ```prolog
  observation(IntentChoice, UrgencyScore, QuestionNoul, provenance(Raw))
  ```

- `jev_actor.pl` is Stage 1. It observes through Jev, thinks with ordinary
  clauses and acts by sending a simulated/conversational reply.
- `jev_sxml_demo.pl` and the canonical
  `../statecharts/20 jev-deployment-assistant.xml` are Stage 2. External
  inference completes in a serial gateway before `observed/4` enters SXML.
- `live_demo.pl` is opt-in and consumes real API requests.
- `FINDINGS.md` records evidence relevant to the later Chapter 8 revision.

The public drawer examples are `23 jev-agent.pl`, `24 jev-sxml-agent.pl`, and
`20 jev-deployment-assistant.xml`. They call a narrow capability installed by
the N3 owner; browser code never receives the API credential.

## Run Stage 1 locally

Set `TYPESAFE_API_KEY` in the process environment, then from the repository
root:

```sh
swipl
```

```prolog
?- [load].
?- use_module('examples/jev/jev_actor.pl').
?- deployment_actor_spawn(Pid).
?- self(Me), $Pid ! say(Me, deploy, "Please prepare a deployment"),
   receive({agent_reply(deploy, Report) -> true}, [timeout(20)]).
?- self(Me), $Pid ! say(Me, status, "What is the deployment status?"),
   receive({agent_reply(status, Report) -> true}, [timeout(20)]).
?- $Pid ! stop.
```

The `request_deploy` path prepares only a simulated preview. Stage 1 is already
a complete Observe–Think–Act loop and contains no statechart.

## Run Stage 2 locally

In a fresh process with `TYPESAFE_API_KEY` set:

```prolog
?- [load].
?- use_module('examples/jev/jev_sxml_demo.pl').
?- demo_spawn(Pid).
?- self(Me), $Pid ! say(Me, first, "yes"),
   receive({demo_reply(first, Report) -> true}, [timeout(20)]).
?- self(Me), $Pid ! say(Me, deploy, "Please prepare a deployment"),
   receive({demo_reply(deploy, Report) -> true}, [timeout(20)]).
?- self(Me), $Pid ! say(Me, confirm, "ja"),
   receive({demo_reply(confirm, Report) -> true}, [timeout(20)]).
?- $Pid ! stop.
```

The first affirmation has no pending referent. The second confirms only after
`request_deploy` has made `awaiting_confirmation` explicit.

## Run the offline tests

```sh
swipl -q -s tests/jev_tests.pl -g 'run_tests(jev)' -t halt
```

These tests use a local HTTP fixture and deterministic sensors. They require no
account, internet connection or stable model probabilities.

## Run the optional live experiment

This consumes live TypeSafe requests. Keep the credential in a private
environment file, never in source or terminal history:

```sh
set -a
. Deployment/.env
set +a
swipl -q -s examples/jev/live_demo.pl -g live_probe -t halt
```

Run the live contract smoke test separately:

```sh
swipl -q -s tests/jev_live_tests.pl -g run_tests -t halt
```

Without `TYPESAFE_API_KEY`, the live test is skipped and the normal suite is
unaffected.
