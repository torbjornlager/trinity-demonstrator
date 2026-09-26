# Tentative Jev tutorial capability

Examples `23 jev-agent.pl`, `24 jev-sxml-agent.pl`, and
`20 jev-deployment-assistant.xml`, plus the **Jev agent experiment** tutorial,
use one fixed owner-installed capability on N3. Uploaded actor source cannot
select the provider endpoint, model, questions, or credential.

The capability is disabled by default. Set these values in the git-ignored
`Deployment/.env`:

```sh
WP_JEV_SERVICE=yes
TYPESAFE_API_KEY=your-key-from-the-typesafe-console
```

`TYPESAFE_ENDPOINT` may be set only by the node owner when testing a compatible
gateway; otherwise the official `https://api.typesafe.ai/v1/systemone`
endpoint is used. Never put a credential in an example, shared database,
tutorial page, browser storage, query, or committed Compose file.

Rebuild N3 after changing the opt-in:

```sh
docker compose -f Deployment/compose.yaml up -d --no-deps --build wp_n3
```

This interrupts current N3 actor sessions. The examples remain visible on
other ACTOR runtimes but return the explicit unavailable result because the
capability is not installed there.

## Bounds

- Fixed model alias and fixed Choice, Score, and Noul questions.
- Nonempty string messages up to 500 characters.
- One request in flight for the N3 process; no waiting queue.
- At most four admissions per second for the process.
- Provider failures become explicit `unavailable(Reason)` values; busy and
  rate-limited calls remain distinguishable.
- The full typed probabilistic decision and raw response are returned to the
  caller, but the API key is never returned or logged by this service.

These are tutorial spending/resource bounds, not a fair multi-tenant quota.
Provider-side spending limits and normal node rate limits still matter.
