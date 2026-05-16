# Profile Enforcement Status

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This document records the current profile-enforcement model of the Web Prolog
PoC node.

It supersedes the earlier plan text that treated profile as partly
principal-relative. The implementation now follows the book semantics more
closely: profile is a node-level advertised contract.


## Final Model

The node currently recognizes four profiles:

- `relation`
- `isobase`
- `isotope`
- `actor`

Profile is a property of the node deployment, not of the principal.

That means:

- the node advertises one profile
- authorized clients may rely on the capabilities implied by that profile
- authorization may deny access to the node or a resource
- authorization does not narrow the node's advertised profile for ordinary
  execution

The profile consumed by execution checks is therefore:

- `EffectiveProfile = min(NodeProfile, EndpointProfile)`

not a principal-relative minimum.


## Implemented

For the current contract matrix across routes, predicates, and source-loading
surfaces, see
[PROFILE_MATRIX.md](PROFILE_MATRIX.md).

### Route ceilings

Route and transport ceilings are enforced in
[node_profile_policy.pl](node_profile_policy.pl)
and checked from the HTTP and WS controllers.

Current route matrix:

- `relation`: `/call`
- `isobase`: `/call`
- `isotope`: `/call`, `/toplevel_*`
- `actor`: `/call`, `/toplevel_*`, `/ws`

Out-of-profile routes fail with explicit `profile_violation` errors.


### Goal, source, and option checks

Profile checks are implemented for:

- submitted goals
- loaded source text
- source-loading options
- toplevel/spawn option structures

The main policy entry points are:

- [node_profile_policy.pl](node_profile_policy.pl)
- [node_sandbox.pl](node_sandbox.pl)

The profile checker and sandbox checker are separate:

- profile checker answers "is this in-profile?"
- sandbox checker answers "is this safe?"


### Node contract semantics

The implemented model matches the current book interpretation:

- profile is node-scoped
- auth decides whether a principal may execute at all
- ownership decides whether a principal may control a given pid
- sandbox decides whether code is safe

The earlier idea of per-principal profile ceilings has been removed from the
live execution model.


### Demonstrator behavior

The demonstrator reads `/node_info` and clamps its profile selector to the
announced node profile. It is a demonstrator, not part of profile
conformance.

The legacy standalone shell has been removed from the repo.


## Not Implemented

The following profile-related items are still deferred:

- there is no separate forked sandbox per profile
- profile purity for built-in predicates still relies on node-owned policy
  plus stock SWI sandbox, not on fully separate profile-specific analyzers
- there is no complete machine-readable predicate matrix exported from the
  node


## Deferred Design Choices

These choices were considered and intentionally deferred or rejected:

- per-principal profile ceilings
  rejected for the main model because they conflict with profile as an
  advertised node contract
- three separate forks of `library(sandbox)`
  deferred because the maintenance cost is not justified yet
- opaque session handles instead of pids
  deferred as defense-in-depth rather than part of first profile enforcement


## Remaining Backlog

The main profile backlog is now documentation and completeness work:

1. align the exact profile matrix in the book with the code, especially for
   the predicate subsets
2. decide whether `relation` should be implemented as a real fourth profile
3. tighten any remaining built-in-subset ambiguities if they prove important
4. keep the demonstrator's profile hints aligned with the backend as the matrix
   evolves


## Practical Summary

The current repo should be read as:

- strict route-level profile enforcement is implemented
- profile checks for goals and loaded source are implemented
- auth and ownership are implemented, but are separate from profile
- the final semantics are node-profile semantics, not user-profile semantics
