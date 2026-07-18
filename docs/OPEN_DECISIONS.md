# Open Decisions

This document tracks project-wide decisions that have been deliberately
postponed. It records the current behaviour and the question to revisit; it
does not change the implementation or the documented semantics.

## Locality of `register/2`

**Status:** Postponed

Decide whether ordinary actor registration should continue to accept remote
pids or should require a live local actor.

Current behaviour:

- `register/2` accepts local and remote pids and does not check that the pid
  identifies a live actor.
- The manual describes the registered process as local.
- The distributed actor tutorial deliberately registers a remote actor under
  a name in the caller's local registry.
- Local actor termination removes the actor's registration, but remote actor
  termination does not currently remove an ordinary registration and can
  therefore leave a stale name.

Alternatives to consider:

1. Restrict `register/2` to live local actors, matching the manual and making
   its automatic-cleanup guarantee straightforward. Remote aliases would
   either be unsupported or provided through a separate facility.
2. Continue allowing remote pids, clarify that the registration rather than
   the actor is local, and remove ordinary registrations when remote actor
   termination is observed.

Until this is decided, preserve the current remote-capable behaviour under
the project's semantics-freeze rule.
