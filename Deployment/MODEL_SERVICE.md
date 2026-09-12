# Public model example (19)

Example `21 model-actor.pl` runs on **n3**, using the owner-installed
`model_chat/2` shared-database predicate. The drawer source implements
`chat_actor(History)`: it receives asks, appends successful user/assistant
turns, replies to its caller, and loops with its own history. Reset clears
only that actor; stop terminates it. Two actors demonstrate independent
conversations against the same model. The protected service receives no
reply address and stores no history; replies travel through the caller's
own execution. `model_answer/2` remains as a single-prompt compatibility
wrapper.

The SXML drawer also contains `19 model-statechart.xml`, using the same
capability. It keeps history in its private datamodel and uses `ready` and
`thinking` states plus a `stopped` final state. A linked adapter runs the
blocking model call so the chart can process reset/stop while waiting.
Reset cancels the pending reply and clears only that chart's history;
correlation guards discard stale results. Its 45-second SXML timer returns
`model_error(Ref, timeout)` without changing conversation history. A second
ask while thinking gets `model_error(Ref, busy)` immediately.

The public program cannot choose an endpoint, model or generation options.
The HTTP implementation lives in `examples/services/model_service.pl`,
loaded by the n3 launcher, rather than in uploaded public source. The
existing sandbox is unchanged. This capability is disabled by default.

## Enable on this Mac

Ollama must already be running natively on the Mac with `smollm2:135m`
installed, listening only on **127.0.0.1:11434**. Keep cloud features
disabled (`OLLAMA_NO_CLOUD=1`). Docker Desktop forwards
`host.docker.internal` to the host service; do not change Ollama's bind
address to `0.0.0.0` or publish its port through Caddy.

Check host reachability from the existing n3 container first:

```sh
docker exec deployment-wp_n3-1 swipl -q -g "use_module(library(http/http_open)), setup_call_cleanup(http_open('http://host.docker.internal:11434/api/version', S, [timeout(3)]), (read_string(S, _, V), writeln(V)), close(S)), halt"
```

For a persistent opt-in, set `WP_MODEL_SERVICE=yes` in the git-ignored
`Deployment/.env`. This is configured on the current Mac. Normal Compose
redeployments then retain the setting. Set it to `no` to disable inference.

From the repository root, the following explicitly deploys **n3 only**:

```sh
docker compose -f Deployment/compose.yaml up -d --no-deps --build wp_n3
```

This recreates n3 and ends its current actor sessions. Schedule it when
that interruption is acceptable. It does not recreate Caddy, other nodes,
or the authentication sidecar. No new container is added.

Open n3's portal and choose `21 model-actor.pl` under Web Prolog source.
The n3 image contains the new source; other nodes' drawers receive it only
when their images are updated. Example 21 is intended to execute on n3.
The optional `compose.model.yaml` override can also enable the capability,
but the `.env` setting is preferable for ordinary ongoing deployment.

## Bounds and failure behavior

- One generation in flight for the entire n3 process; no waiting queue.
- At least ten seconds between accepted starts (six starts per minute).
  This global limit applies across all visitors and cannot be bypassed by
  opening a new session. It provides a resource ceiling, not fair sharing:
  an abusive visitor can consume that small allowance.
- Nonempty string prompts, at most 500 characters. The capability accepts
  one, three or five alternating `user(Text)` / `assistant(Text)` messages,
  ending in a user turn, at most 2000 characters total. System roles, tool
  calls and arbitrary JSON fields are rejected.
- The example retains at most two complete exchanges within 1500
  characters, dropping oldest pairs first. Failed requests leave history
  unchanged. A single exchange exceeding the budget is not retained.
- Fixed 1024-token context, 80-token generation limit and temperature zero.
  Character budgets do not guarantee token counts; Ollama may truncate
  unusually token-heavy input. Tiny-model recall is not guaranteed.
- Backend replies are read up to 16,385 characters and rejected above
  16,384 characters. Answer text is capped at 4000 characters.
- HTTP redirects are not followed. HTTP inactivity timeout is 30 seconds;
  the independent worker has a 35-second wall-clock deadline.
- Cancelling or disconnecting the requesting actor does not cancel the
  inference worker or release the slot early. Its result is discarded if
  the requesting actor's private result queue has gone away.
- Any failed, oversized or malformed backend response latches a fault.
  Subsequent requests return `error(unavailable)`. This is deliberate:
  an HTTP timeout does not prove inference stopped inside Ollama.

After a fault, the owner should check Ollama and verify that no stale
generation is still running before restarting n3. Restarting n3 also
resets the budget, so do not automate repeated restarts as a retry policy.

Enable the capability on only one node. These limits are process-wide,
not distributed across multiple nodes or other clients using Ollama.
The model service does not log prompts, but the demonstrator's existing
interaction logging can record submitted source and queries. Do not
invite visitors to submit secrets. Model responses are untrusted text;
they are not executed or used for authorization.

This is a bounded capability added to the existing public-node security
model, not a replacement for its sandbox and OS containment. In particular,
the documented limitations of blacklist mode still apply.

## Verification

From the repository root:

```sh
./tools/test.sh MODEL
./tools/test.sh MODEL_SXML
```

Tests use a local mock HTTP backend (no Ollama download required) and cover
conversation validation, independent actor histories, reset, history trimming,
error-state preservation, fixed settings, global throttling, caller cancellation,
fault latching, oversized responses, owner-only configuration, continued
HTTP sandbox rejection, and the exact drawer source through an anonymous
public WebSocket. A real-model WebSocket smoke test was also performed
against the Mac's installed SmolLM2 model during implementation.
