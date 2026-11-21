# Fixed addresses on `deployment_wp_net` — plan

Drafted 21 November 2026 after the 16:27 UTC Docker restart left public N5 at
502 for about seven minutes. **Step 1 is live** (switched 17:14 UTC); step 2 is pending.

## What happened

After the restart, `deployment-n5_admission-1` exited 128 with "Address already
in use". `oauth2_n5` has no fixed address and started first, so Docker gave it
`172.18.0.2`, the fixed address of admission. Admission was restored by hand
(stop `oauth2_n5`, start admission, start `oauth2_n5`). N5 probes then matched
the pre-release baseline.

A probe on a scratch network confirmed how Docker allocates (Docker Desktop,
21 Nov):

- a container without a fixed address gets the **lowest free** address;
- the fixed address of a **stopped** container is **not reserved**. A dynamic
  container takes it, and the static container then fails to start.

## Why pinning `oauth2_n5` alone is not enough

| Container | Fixed address | Live now |
|---|---|---|
| n5_admission | 172.18.0.2 | .2 |
| caddy | 172.18.0.10 | .10 |
| wp_n5 | 172.18.0.11 | .11 |
| wp_n7 | 172.18.0.70 | .70 |
| wp_admin | — | .3 |
| web-prolog-hub-n0 | — | .4 |
| wp_n3 | — | .5 |
| wp_n2 | — | .6 |
| wp_n4 | — | .7 |
| wp_n1 | — | .8 |
| oauth2_n5 | — (`compose.live.json` says .8) | .9 |

Seven containers are dynamic. On a restart they fill addresses from `.2`
upwards in whatever order they start. Any of them can take `.2` if admission
starts late; `oauth2_n5` happened to win this time. With admission's `.2` held,
the seven fill `.2`–`.8`, one address short of caddy's `.10`.

Every route is by name: Caddy proxies to `n5_admission:8080`, and admission
re-resolves `wp_n5` every 10 s through Docker DNS. `wp_n5` trusts
`172.16.0.0/12`. No configuration depends on a specific address, so moving
one is safe. The release operators only check that a pinned address is
unchanged across a switch.

`Deployment/compose.live.json` is already stale: it pins `oauth2_n5` to `.8`,
which `wp_n1` holds now. Recreating `oauth2_n5` from that file would fail.

## Target

Keep every N5-side fixed address next to N5 and clear of the range dynamic
containers fill:

| Container | Now | Target |
|---|---|---|
| n5_admission | .2 | **172.18.0.12** |
| oauth2_n5 | dynamic (.9) | **172.18.0.13** |

After step 1, only the six SWI containers are dynamic. They fill `.2`–`.7`,
which leaves two spare addresses below the first fixed one (`.10`). After
step 2, nothing on the network is dynamic.

## Step 1 — N5 side, one scoped switch (live 21 November)

Operator: `.trinity/n5-addresses-20261121/deploy.py`, following the release
operators (`--rehearse`, `--execute-live`, `--rollback`, journal, private 0600
models).

1. **Capture**
   - Inspect the predecessor (admission, `oauth2_n5`, `wp_n5`, caddy) and
     take N5 baseline probes.
   - Admission model: copy
     `admission-120-20261119/release-r5/models/n5_admission-candidate.json`
     and change only `ipv4_address`.
   - `oauth2_n5` model: render `compose.yaml` + `compose.trealla-n5.yaml` with
     `.env`. The rendered file contains secrets, so it stays private under
     `.trinity` and never goes to Git.
   - Check the render against the live container field by field (Env,
     command, mounts, labels, aliases). The live container was created by
     Compose 5.5.0, so the config hash may not reproduce under 5.6.1. If it
     doesn't, the field check decides.
2. **Rehearse** on an isolated network that copies the address layout:
   - Containers: clones of admission, `oauth2_n5` and `wp_n5` with fresh
     writable volumes and read-only peer volumes, caddy's address held by a
     placeholder, and seven placeholder dynamic containers.
   - **Reproduce the bug first:** with the current layout, stop everything,
     start the dynamic placeholders first, then the statics. Admission must
     fail with "Address already in use". This proves the test is valid.
   - **Then the fix:** apply the target layout and repeat the same restart
     order. Everything must start, and an N5 probe through admission must
     return 200.
   - **Rollback:** inject a failure and check that it restores the
     predecessor layout.
3. **Live switch**, each with `up -d --no-build --pull never --no-deps
   --force-recreate`:
   1. Recreate `oauth2_n5` on `.13`. This frees `.9`; the sign-in path blips
      for a few seconds.
   2. Recreate `n5_admission` on `.12`. This frees `.2`; public N5 blips for
      a few seconds.
4. **Verify**
   - Addresses, images, Env, mounts, aliases and restart policy are
     unchanged except the address.
   - N5 probes are identical to the baseline; all public nodes answer as
     before; the Caddyfile is unchanged.
5. **Record**
   - Update `compose.live.json`: admission `.12`, `oauth2_n5` `.13`.
   - Add a line to HANDOVER and the deployment record.
6. **Rollback** (automatic on a failed check): recreate admission on `.2`
   from the r5 model and `oauth2_n5` from the captured model with no fixed
   address. Capture logs and state first.

Expected cost: two blips of a few seconds on N5 only. No image, runtime or
setting changes.

### Rehearsal result (21 November): pass

- **Models**
  - `compose.yaml` + `compose.trealla-n5.yaml` no longer render on their own,
    so the `oauth2_n5` model comes from `compose.live.json`, with
    `expose: 4180` added.
  - Both rehearsal clones matched the live containers' configuration
    exactly, except aliases and the admission port binding.
- **Reproduced the bug:** with the current layout and dynamic containers
  started first, `oauth2_n5` took `.2` and admission failed with "Address
  already in use".
- **Switch:** `oauth2_n5` moved to `.13`, then admission to `.12`.
  Configuration was unchanged, and N5 probes through admission were
  identical to the current layout and to live N5.
- **Rollback:** an injected failure was followed by a rollback that restored
  `.2` and a dynamic `oauth2_n5`. Probes were identical.
- **Fix confirmed:** after switching again, the same restart order left
  every container running. The six dynamic placeholders filled `.2`–`.7`,
  and admission came up on `.12` and answered.
- **Production:** no live container changed, and the rehearsal network,
  containers and volumes were removed afterwards.
- **`oauth2_n5` is unused:** Caddy has no route to it, and it logged no
  requests in 72 h. Recreating it affects no visitor.
- **Rollback limit:** the operator refuses to roll back if another container
  has taken `.2` in the meantime, for example after a restart. Admission
  then stays on `.12`, which works.

### Live result (21 November, 17:14 UTC): verified

- **Order:** `oauth2_n5` was recreated on `.13`, then `n5_admission` on `.12`.
- **Configuration:** images, Env, mounts, aliases, limits and restart policy
  are unchanged. The unrelated containers and the Caddyfile are untouched.
- **Answers:** seven N5 probes (`generic`, `n5`, `n5-regression`) were
  identical before and after. N0–N6 answer 200 and N7 its 303, as before.
- **Selection:** `compose.live.json` now pins admission `.12` and
  `oauth2_n5` `.13`. Its previous copy is in `.trinity/n5-addresses-20261121/predecessor/`.
- **Rollback:** `.trinity/n5-addresses-20261121/deploy.py --rollback`.

## Step 2 — SWI side (fold into the next SWI release)

Add `ipv4_address` to the six SWI models at their current addresses
(`wp_admin` .3, n0 .4, `wp_n3` .5, `wp_n2` .6, `wp_n4` .7, `wp_n1` .8). The SWI
operator already preserves pinned addresses. This can run standalone, but it
recreates all six SWI containers and drops their in-memory sessions, so the
next release that recreates them anyway is the cheaper moment.

## Lower risk, recorded only

Caddy also has fixed addresses on two other networks:

- `trinity_n6_host`: `.5`, with three dynamic neighbours on `.2`–`.4`.
- `trinity-n7-https_default`: `.3`, with one dynamic neighbour on `.2`.

Both fill below Caddy's address today. A fourth container on `trinity_n6_host`,
or a second one on `trinity-n7-https_default`, would put Caddy at risk, and
that would take down every site.

## Rejected

- **`ip_range` on the network**, so dynamic addresses come from a separate
  range. This needs the network recreated, which means detaching all eleven
  containers: a full outage of N0–N5, N7 and Caddy.
- **`docker network disconnect`/`connect --ip` on running containers.** It
  needs no recreate, but leaves the live containers different from their
  Compose models and config hashes, and the operators' checks would then
  trip.
