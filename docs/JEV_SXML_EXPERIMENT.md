# Jev semantic observations: two-stage experiment

This companion experiment now develops the architecture in two stages rather
than assuming a statechart at the outset.

## Stage 1: Observe–Think–Act without SXML

```text
natural-language input
        -> bounded Choice, Score and Noul questions to Jev
        -> typed probabilistic decision
        -> Trinity semantic observation
        -> ordinary Prolog reasoning in a Web Prolog actor
        -> conversational or simulated action
```

`examples/jev/jev_actor.pl` and drawer example `23 jev-agent.pl` show that Jev
plus an ordinary actor already forms a complete neuro-symbolic
Observe–Think–Act loop. The main success paths are `request_deploy` and
`status`; neither needs a pending confirmation state.

## Stage 2: explicit behavioural state

The second stage introduces `affirm` and `deny`. The observation `affirm` does
not determine its own behavioural meaning:

```text
idle + affirm                   -> explain; stay idle
awaiting_confirmation + affirm -> simulate confirmation; return to idle
awaiting_confirmation + deny   -> cancel; return to idle
```

`examples/jev/jev_sxml_demo.pl`, drawer example `24 jev-sxml-agent.pl`, and
statechart `20 jev-deployment-assistant.xml` reuse the same observation term.
SXML is a refinement of behavioural organisation, not a prerequisite for the
agent loop. The chart retains a small pending proposal—reference, original
text, and intent—so a later affirmation confirms a concrete referent without
retaining the full provider response in interaction state.

## Shared boundary

`examples/jev/deployment_observation.pl` converts Jev's typed probabilistic
decision into the shared Trinity semantic observation:

```prolog
observation(IntentChoice,
            UrgencyScore,
            QuestionNoul,
            provenance(RawResponse))
```

Failures remain distinct:

```prolog
unavailable(configuration)
unavailable(timeout)
unavailable(rate_limited)
unavailable(malformed_response)
unavailable(transport)
```

The application never consumes provider JSON fields, and no model result is
treated as authority for an external effect.

## Provider contract checked on 2026-09-25

The current TypeSafe OpenAPI document specifies bearer authentication,
`POST /v1/systemone`, model discovery through `GET /v1/models`, and request
fields `model`, `state`, and named typed questions. Choice returns a winner,
probabilities, and confidence; Score returns an expected rubric position,
legend, probabilities, and confidence; Noul returns a yes/true probability.
The complete response also carries model identity and usage.

The schema currently publishes a Score rubric minimum of one item. It does not
publish the earlier experimental “2–10 levels” description. Provider details
remain isolated behind `jev_http.pl` and should be rechecked when the API
version changes.

Authoritative sources:

- <https://api.typesafe.ai/openapi.json>
- <https://api.typesafe.ai/docs>

## Run and evidence

Exact commands are in `examples/jev/README.md`. The ordinary suite is fully
offline:

```sh
swipl -q -s tests/jev_tests.pl -g 'run_tests(jev)' -t halt
```

The optional live probe and live contract test are separate and require
`TYPESAFE_API_KEY`.

Detailed implementation findings and Chapter 8 implications are maintained in
`examples/jev/FINDINGS.md`.
