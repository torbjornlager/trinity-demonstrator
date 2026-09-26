# Findings: Jev semantic observations in Web Prolog

Status: two-stage implementation and deterministic tests completed on
2026-09-25. The live API contract was checked against TypeSafe's current
OpenAPI document on the same date. Live linguistic probes are recorded below
with their date and must not be read as an accuracy evaluation.

## 1. Observe–Think–Act

Stage 1 genuinely fits the useful operational reading of the loop:

```text
Observe  deployment_observation/2 obtains a typed Jev reading
Think    stage1_decision/3 applies deterministic Prolog clauses
Act      the actor sends a conversational reply describing a simulated effect
```

The boundaries are engineering boundaries, not metaphysical ones. The actor
owns the whole loop. “Act” begins where the chosen Prolog consequence becomes
an actor message or effect request; in this example it is only a reply and a
simulated preview. Nothing in Jev authorises that action.

This implementation therefore contradicts the earlier presentation in one
important respect: SXML is not required to obtain a complete neuro-symbolic
Observe–Think–Act agent.

## 2. Observation boundary

Both stages consume exactly:

```prolog
observation(IntentChoice, UrgencyScore, QuestionNoul, provenance(Raw))
```

The intent Choice is sufficient for the current decisions. Score and Noul are
retained to demonstrate and inspect the real primitive shapes, but the
deployment policy does not presently use them. `provenance(Raw)` preserves the
complete provider response, including model and usage. `OriginalText` and a
caller-supplied reference remain in the actor event envelope rather than being
duplicated inside the observation.

Failures cross the same boundary as `unavailable(Reason)`. They are not
semantic observations and are never rewritten as `other`, `deny`, or `false`.

## 3. Jev primitives and current API

The provider-specific client remains behind `jev_http.pl`; `jev.pl` owns the
typed question abstraction. The TypeSafe OpenAPI schema retrieved on
2026-09-25 describes:

- `POST /v1/systemone` with bearer authentication;
- required request fields `model`, `state`, and a non-empty question map;
- Choice answers with winner, full probability map, and confidence;
- Score answers with a probability-weighted expected rubric position, legend,
  level probabilities, and confidence;
- Noul answers as the probability of yes/true, with no second confidence;
- response model identity and input/output token usage;
- `GET /v1/models` as the authoritative source of accepted model names.

One earlier assumption changed: the current OpenAPI schema publishes a Score
rubric minimum of one item. It does not publish the earlier “2–10 levels”
bound. Volatile provider details belong in the tutorial/client documentation,
not in the durable architectural claim.

Choice is the only primitive required by the current application policy.
Score and Noul remain useful evidence for experimentation, but including all
three is not evidence that an application ought to use all three.

## 4. Uncertainty

Choice and Score probability maps and confidence values remain ordinary
Prolog data. Noul's returned probability is already its uncertainty-bearing
answer. Stage 1 clauses and Stage 2 guards make deterministic decisions over
those values. Neither implementation maintains a probability distribution
over Prolog worlds or SXML control states; this is not probabilistic logic
programming.

The `0.70` intent threshold is an explicitly illustrative reject policy. It is
not known to be calibrated for deployment language, populations, or losses.
A low-confidence winner causes clarification and no simulated consequential
action.

## 5. Why add SXML?

The plain actor can implement interaction state with recursive arguments or
dynamic predicates. SXML does not make stateful behaviour possible. It adds a
declarative, inspectable representation once temporal structure matters.

The `affirm` example is a genuine minimal motivation:

```text
idle + affirm                   -> explain; no transition
awaiting_confirmation + affirm -> simulate; return to idle
awaiting_confirmation + deny   -> cancel; return to idle
```

The semantic observation describes the current utterance. The chart owns a
`pending_proposal(Ref, OriginalText, IntentChoice)` fact as well as the control
state, so a later affirmation has a concrete referent. This remains transient
tutorial state, not a durable deployment record. With only two states either
implementation style is manageable; SXML's advantage is
visibility of permitted next moves, transitions, and later extensions such as
timeouts, history, or parallel activity—not safety by itself.

## 6. Run-to-completion

Inspection of `statechart_exec.pl` confirms the intended boundary. The serial
gateway finishes the provider request, constructs one complete observation,
and then sends `observed/4`. The statechart receives that external event and
begins a macrostep; enabled, internal, and eventless transitions are exhausted
before it receives another mailbox event. The chart source contains no Jev,
HTTP, or `jev_decide/3` call, and a regression test enforces that fact.

Thus external inference occurs before, rather than literally “inside” or as
part of, the SXML macrostep. Scheduling between the gateway and chart remains
ordinary actor scheduling; run-to-completion does not make the upstream HTTP
operation atomic with event delivery.

## 7. Actor behaviour and correlation

The gateway receives one utterance, blocks for its semantic reading, and only
then recurs. This preserves arrival order but creates head-of-line blocking.
It is acceptable for a tutorial with one user and a sub-second service; it is
not a production concurrency policy.

Production work would use correlated linked workers, define ordering and
cancellation, and reject obsolete results. The current serial gateway already
retains `From`, `Ref`, and `OriginalText` in `observed/4`, so replies remain
attributable. A stale-result test would be artificial here because the serial
design has no concurrently outstanding observation whose result can become
stale.

Links provide lifetime ownership for the gateway's chart; monitoring is used
by the public spawning example. A supervisor is unnecessary for this minimal
slice, though a production long-lived agent could place the gateway and worker
policy under one.

## 8. Multilingual experiment

The optional live probe on 2026-09-25 returned model `jev-1.13.0`:

| Input | Choice | Confidence | Behavioural context |
| --- | --- | ---: | --- |
| `yes` | `affirm` | 1.00 | idle: explanation only |
| `no` | `deny` | 1.00 | awaiting: cancellation |
| `ja` | `affirm` | 0.99 | awaiting: simulated confirmation |
| `nej` | `deny` | 1.00 | awaiting: cancellation |

The full Choice distributions were respectively concentrated at `affirm=1.00`,
`deny=1.00`, `affirm=0.99` (with `other=0.01`), and `deny=1.00`.
Deterministic tests additionally construct English- and Swedish-derived
`affirm` observations and prove that both symbolic layers treat them
identically. This demonstrates language independence above the observation
boundary, not general multilingual model performance.

## 9. Ambiguous input

On 2026-09-25 the live input:

```text
Yes, deploy it -- actually no, do not deploy it.
```

returned `deny` with probabilities `deny=0.74`, `other=0.24`,
`request_deploy=0.02`, and confidence `0.66`. Under the illustrative `0.70`
policy, both stages choose clarification. In Stage 2 the chart makes no state
change, so a pending confirmation remains pending. Exact probabilities are not
hard-coded in tests.

## 10. Implications for Chapter 8

The eventual Section 8.4 revision should:

- strengthen the claim that typed uncertain observations form a useful,
  inspectable learned/symbolic boundary;
- begin with Jev as one semantic sensor in a complete Web Prolog
  Observe–Think–Act actor;
- remove or reformulate the claim that all three of Jev, Web Prolog, and SXML
  are needed for the basic architecture;
- introduce SXML only when `affirm` exposes state-dependent behavioural
  meaning;
- qualify “between macrosteps” as external inference completing before event
  delivery, with normal actor scheduling between components;
- say explicitly that ordinary Prolog could also represent the two-state
  protocol and explain what the chart makes visible;
- keep confidence calibration, multilingual performance, and provider
  reliability as empirical questions;
- retain the separation between semantic-assessment authority and effect
  authority;
- keep the larger service-request example separate because it adds identity,
  revisions, human review, dispatch and reconciliation concerns absent here.

## Open questions

- Which parts of the full provider response should be retained durably, and
  under what privacy/redaction policy?
- Should operational handling distinguish more provider status classes after
  observing real 401/422/429/5xx response bodies?
- Does Score or Noul earn a role in the deployment example, or would removing
  them improve the tutorial after their shapes have been introduced?
- What evaluation data and loss model would justify an acceptance threshold?
- If concurrency is added, should mailbox order, completion order, or explicit
  user cancellation determine which observation the chart sees next?
