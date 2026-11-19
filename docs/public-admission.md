# Configuring public admission budgets

The public deployment preset admits 120 call requests and 120 session
creations per 60 seconds on SWI and Trealla. N7 instead admits 120 fresh
engines per client IP per 60 seconds, shared across its public transports.
GNU's ingress refills at 120 requests/minute with its existing burst allowance.
Concurrency and engine resource ceilings are independent and retain their
previous defaults.

| Deployment | Operator environment | Default |
|---|---|---|
| SWI N1–N4, Trealla N5 | `WP_Nn_RATE_WINDOW_SECONDS` | 60 |
| SWI N1–N4, Trealla N5 | `WP_Nn_MAX_CALLS_PER_WINDOW` | 120 |
| SWI N1–N4, Trealla N5 | `WP_Nn_MAX_SPAWNS_PER_WINDOW` | 120 |
| ECLiPSe N7 | `WP_N7_RATE_WINDOW_SECONDS` | 60 |
| ECLiPSe N7 | `WP_N7_MAX_ENGINE_STARTS_PER_WINDOW` | 120 |
| ECLiPSe N7 | `WP_N7_MAX_PUBLIC_ENGINES` | 4 |
| ECLiPSe N7 | `WP_N7_MAX_PUBLIC_ENGINES_PER_CLIENT` | 2 |
| GNU N6 ingress | `WP_N6_MAX_CALLS_PER_MINUTE` | 120 |
| GNU N6 ingress | `WP_N6_CALL_BURST` | 60 |
| N5/N6 ingress | `WP_Nn_MAX_CONNECTIONS_PER_CLIENT` | 16 |
| N5/N6 ingress | `WP_Nn_MAX_CONNECTIONS_TOTAL` | 32 |

Replace `Nn` with the node number, for example `WP_N3_MAX_SPAWNS_PER_WINDOW=240`.
These are Compose interpolation inputs. Recreate the affected service after
changing them. The generic SWI launcher also accepts `WP_RATE_WINDOW_SECONDS`,
`WP_MAX_CALLS_PER_WINDOW` and `WP_MAX_SPAWNS_PER_WINDOW`; the older SWI
`WP_RATE_WINDOW` remains a fallback. Trealla's launcher uses the same three
unprefixed names. Factory node/2 defaults are separate from this deployment
preset; callers can continue to select their own documented node options.

N7's container wrapper translates its environment to the adapter's
`--public-rate-window-seconds`, `--public-max-engine-starts`,
`--public-max-engines` and `--public-max-engines-per-client` options. Standalone
adapters can use those options directly. The legacy
`--stateless-calls-per-minute` option belongs to a separate preview mode and
does not configure public ACTOR engines. Prepared engines count toward the
same global bound; used engines are still destroyed rather than pooled.

N5/N6 ingress templates substitute only an explicit allowlist of operator
variables. Nginx's own request variables remain intact. Invalid nonpositive
values fail startup. GNU's native query/owner/memory ceilings remain unchanged;
its public timed admission policy belongs to the gateway. The N6 presenter
reports that policy only when `N6_ADMISSION_ENABLED=yes`, set by the host overlay.

Server `/node_info` responses contain public `admission` metadata. Fixed and
rolling budgets report their actual units. GNU reports a `leaky_bucket` rate
and burst, which may admit more than 120 requests in an initial minute. Native
`node_setting/2` settings retain their existing profile applicability. The
browser/WASM execution host has no HTTP server budget; its remote requests are
charged by the destination server.

Use the [shared admission contract](https://github.com/torbjornlager/trinity-conformance/blob/main/profiles/admission-0.1.md)
and `runner/admission.py` for bounded throughput measurements. A successful
finite probe does not prove concurrency, isolation, retained-session or memory
reclamation properties. Preserve refusals and record each run's configuration,
count, pacing and runtime provenance.
