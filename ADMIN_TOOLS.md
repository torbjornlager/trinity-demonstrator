# Node Admin Tools — User Guide

## Overview

The Admin tools panel in the Web Prolog workbench provides real-time control over a running node's configuration, authentication, and resource management. Changes take effect immediately and apply only to the current runtime session. **They are not persisted across node restarts** unless you update the node's startup configuration separately.

---

## Configuration Status Bar

At the top of the Admin panel, you'll see the current node's identity and operational mode:

### **Principal**

The authenticated user or service making changes. In the workbench, this is typically `dev` (the development principal).

### **Node Profile**

The node's capability level. Determines which operations are allowed:

- **RELATION** — Stateless query-only endpoint (`/call`). Query execution only.
- **ISOBASE** — Stateless execution via `/call`. RPC calls (`rpc/2-3`, `promise/3-4`, `yield/2-3`).
- **ISOTOPE** — HTTP semi-stateful API via `/toplevel_*` endpoints. Session-local I/O and assert/retract.
- **ACTOR** — Full actor runtime. `spawn/3`, WebSocket streaming, full actor control, unlimited capability.
- **WORKBENCH** — Same as ACTOR. Reserved for web-based IDE access.

### **Auth Mode**

The authentication boundary:

- **OPEN** — All requests accepted. No identity checking.
- **DEV** — Development mode. Requests with `X-Web-Prolog-User: dev` header trusted. Useful for localhost testing.
- **PRIVATE** — Production mode. All requests require authentication headers matching registered principals.

---

## Config Section

### Runtime Settings (Read-Only Display)

These fields show the current node configuration. The values shown here were set at startup via `node/2` options. To change them:

1. **Stop the node**
2. **Restart with new options**
   Or use the "Apply Runtime Config" button below to change in-memory values (temporary until next restart)

#### **Self URL**

The canonical node address (e.g., `http://localhost:8081`). Used for global pid construction (`Pid@Node`).

#### **Profile**

Current node profile (read-only). Change via startup options.

#### **Auth**

Current authentication mode (read-only). Change via startup options.

#### **Sandbox**

- **NO SANDBOX** — No language sandbox. All goals allowed (use only for trusted code).
- **WHITELIST SANDBOX** — Current SWI-Prolog safe-goal policy. Strongest existing option.
- **BLACKLIST SANDBOX** — Experimental deny-list over risky runtime and ISO predicates, combined with the existing profile and capability checks.

Legacy config values `on`, `demo`, and `strict` are still accepted and normalize to **WHITELIST SANDBOX**.

#### **Timeout** (seconds)

Hard upper bound on goal execution time. Clients can request lower timeouts; the effective timeout is the **minimum** of requested and owner timeout.

- Default: 2 seconds
- Typical range: 1–30 seconds
- Use case: Prevent runaway computations from consuming resources

#### **Cache Size**

Maximum entries in the `/call` stateless cache. Caches results for repeated queries with identical `goal`, `template`, `offset`, and `load_text`.

- Default: 100
- Increase to reduce repeated computation cost
- Decrease if memory is constrained

#### **Max /call** (concurrent requests)

Maximum number of simultaneous `/call` requests allowed on this node.

- Default: 10
- Increase to handle more parallel clients
- Decrease if CPU is overloaded

#### **Max Sessions**

Maximum number of ISOTOPE session actors per principal.

- Default: 10
- Increase if you need many concurrent sessions per user
- Exceeding this limit causes `toplevel_spawn` to fail with "Too many sessions"

#### **Max WS Actors**

Maximum number of WebSocket actor connections per principal.

- Default: 16
- Increase for high-concurrency workloads
- Each connection consumes memory; monitor resource usage

#### **Max Term Bytes** (load_text)

Maximum size in bytes of term text supplied via `load_text` option.

- Default: 1 MB (1,000,000 bytes)
- Prevents denial-of-service via oversized payloads

#### **Max load_text Bytes** (source code)

Maximum size in bytes of source code text in `load_text` option.

- Default: 10 MB
- Controls memory used for loading Prolog clauses

#### **Max WS Frame Bytes**

Maximum size of a single WebSocket frame.

- Default: 1 MB
- Prevents memory exhaustion from malformed frames

#### **Max Admin JSON Bytes**

Maximum size of JSON payloads sent to admin endpoints (e.g., principals update).

- Default: 100 KB
- Protects against admin payload attacks

#### **Rate Window** (seconds)

Time window for rate limiting buckets.

- Default: 60 seconds
- Controls the measurement period for rate limits below

#### **Max /call Per Window**

Maximum calls to `/call` per principal per rate window.

- Default: 100 per 60 seconds
- Prevents resource exhaustion from rapid-fire queries

#### **Max Spawns Per Window**

Maximum `toplevel_spawn` calls per principal per rate window.

- Default: 20 per 60 seconds
- Controls session/actor spawn rate

#### **Max WS Cmds Per Window**

Maximum WebSocket commands per principal per rate window.

- Default: 1000 per 60 seconds
- Prevents WebSocket-based denial-of-service

### Apply & Reload Buttons

**Apply Runtime Config**
Updates in-memory configuration values (shown in the Config fields above). Changes take effect immediately but are lost on node restart.

**Reload**
Refreshes the displayed values from the server (in case another admin changed them).

---

## Principals Section

### JSON Principal Policy Editor

Defines which principals (users/services) can access this node and what they're allowed to do.

#### Format

```json
[
  {
    "id": "alice",
    "capabilities": ["execute"]
  },
  {
    "id": "bob",
    "capabilities": ["execute", "introspect"]
  }
]
```

#### Fields

**id** (required)
Principal identifier. Matched against the `X-Web-Prolog-User` header in requests.

**capabilities** (array)
List of permissions:

- `execute` — Can run goals via `/call`, spawn actors, create sessions
- `introspect` — Can inspect runtime state (sessions, actors, limit usage)
- `admin` — Can modify node configuration and principals
- `open` — Always succeeds (use for open-access principals)

#### Buttons

**Save Principals**
Persists the edited JSON as the active principal policy.

**Pretty Print**
Auto-formats the JSON for readability.

**Revert**
Discards unsaved edits and reloads the last saved policy.

---

## Runtime Section

Real-time inspection of active sessions, actors, and resource usage. Click **Refresh Runtime** to poll the latest state.

### ISOTOPE Sessions

Lists active ISOTOPE (semi-stateful HTTP) session actors grouped by principal.

Each session entry shows:

- **Session Pid** — Unique identifier for the session actor
- **Principal** — Owner of the session (e.g., `alice`, `dev`)
- **Capability** — Profile granted to this session (ISOTOPE, ACTOR, etc.)

**Terminate** button: Forcibly kill the session and free its resources.

### WebSocket Actors

Lists active WebSocket actor connections grouped by principal.

Each entry shows:

- **Actor Pid** — Unique identifier for the WebSocket actor
- **Principal** — Owner (e.g., `dev`)
- **Capability** — Profile (typically ACTOR or WORKBENCH)

**Terminate** button: Close the WebSocket connection and terminate the actor.

**Use case:** Kill hung or misbehaving actors to free resources.

### Concurrent Limit Usage

Shows how many active sessions/actors each principal currently has vs. their limits.

Format:

```
alice
WS actors 2 · pending 0 · limit 16
```

- **WS actors** — Current count of active WebSocket connections
- **pending** — Spawn requests waiting for capacity
- **limit** — Max allowed (from "Max WS Actors" config)

**Interpretation:**

- If `WS actors == limit`, new actor spawns will be rejected
- If `pending > 0`, requests are queued waiting for an actor to terminate

### Rate Buckets

Shows active fixed-window rate limit buckets. Each principal has buckets for:

- `/call` rate limit
- `toplevel_spawn` rate limit
- WebSocket command rate limit

Format:

```
alice:
  /call: 45 / 100 in window
  spawns: 8 / 20 in window
  ws_cmds: 420 / 1000 in window
```

- **Active requests** — Requests counted in the current window
- **Limit** — Threshold from Config

**Interpretation:**

- If any bucket hits its limit, new requests are rejected with "Too many requests"
- Buckets reset after the rate window expires (default 60 seconds)
- "No active buckets" means no principal has made any requests in the current window

---

## Typical Workflows

### Adjust Timeout for a Slow Query

1. Increase **Timeout** in Config to 10 seconds
2. Click **Apply Runtime Config**
3. Clients' requests will now wait up to 10 seconds (unless they request less)

### Prevent a Runaway Principal from Consuming Resources

1. In Principals, remove `execute` capability from their entry or set capabilities to `[]`
2. Click **Save Principals**
3. That principal's new requests will be denied (existing sessions remain active)

### Kill a Hung WebSocket Actor

1. Find the actor Pid in "WebSocket Actors"
2. Click **Terminate** next to it
3. The client loses the connection; it must reconnect

### Monitor Active Sessions

1. Click **Refresh Runtime**
2. Check "Concurrent Limit Usage" to see if any principal is hitting their limits
3. If approaching limits, either:
   - Increase "Max Sessions" / "Max WS Actors" in Config
   - Manually terminate idle sessions/actors
   - Ask clients to clean up their sessions

---

## Notes

- **Not persisted:** All changes via Admin tools are in-memory only. Restart the node to reset to startup options.
- **No rollback:** Changes take effect immediately with no undo. Use "Revert" in the Principals editor to discard unsaved edits.
- **Access control:** The Admin tools require the `admin` capability. Dev mode (`dev` principal) has this by default.
- **Performance:** Large principal lists or many active sessions may slow the "Refresh Runtime" response. Consider paginating or caching in production.
