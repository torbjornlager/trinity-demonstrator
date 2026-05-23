# Demonstrator

This document describes the current browser demonstrator at `/demonstrator`.

This is the current unified browser UI
for editing, tutorial-driven exploration, terminal interaction, logging,
settings, and admin access.

## Current Role

The demonstrator combines several surfaces that were previously separate or only
partly sketched:

- tutorial browsing and guided example execution
- Prolog source editing
- Statechart XML editing and execution
- terminal interaction with the node
- protocol/runtime logging
- user settings and appearance controls
- node admin controls when the admin API is available

The implementation remains deliberately direct: a served HTML page with Vue for
state management, existing browser widgets where they already work well, and no
mandatory frontend build pipeline.

## Current Surface

### Project and Example Browser

The left-side project drawer currently exposes:

- tutorial sections
- Web Prolog code examples
- Statechart XML examples

This lets the demonstrator act as both an editor shell and a guided tutorial
frontend.

### Main Workspace

The center workspace currently switches between:

- a Prolog editor
- a statechart editor
- the tutorial view

The tutorial is loaded in an iframe and is bridged to the surrounding
demonstrator so examples can be pasted, consulted, or run against the terminal.

### Runtime Dock

The right-side dock currently provides these tools:

- `Terminal`
- `Logger`
- `Help`
- `Settings`
- `Admin`

The terminal remains based on `jquery.terminal`, while the surrounding state,
layout, and tool coordination are handled by Vue.

## Current Implementation Structure

### Editors

The editor surfaces are hosted through `/editor_frame` iframes and use
CodeMirror-based editing modes.

Current editor-facing concerns include:

- Prolog source buffers
- Statechart XML buffers
- dirty-state tracking
- code-coloring preferences
- run/halt controls for statechart execution

### Tutorial Integration

The tutorial is not a passive document. The demonstrator installs a bridge object
used by `tutorial.html` so the tutorial can:

- paste queries into the terminal
- ask queries directly
- consult source blocks
- jump between sections
- expose example sets to the terminal UI

That bridge is an important part of the current demonstrator architecture.

### Terminal and Logger

The terminal is still an adapter over node APIs rather than a fully custom UI
component. The logger records transport and UI events and supports filtering,
including statechart-trace filtering.

The logger is therefore not just a debug panel; it is part of the current
runtime-observability story of the demonstrator.

### Settings

The demonstrator now includes a settings surface with sections for:

- font
- display
- terminal
- startup
- links
- code coloring
- session

These settings control live demonstrator behavior such as typography, theme,
terminal presentation, startup greeting behavior, and code-coloring modes.

### Admin Panel

The admin surface is integrated directly into the demonstrator and mirrors the
runtime admin API when available.

Current capabilities include viewing and editing:

- node config
- auth/profile/sandbox settings
- principal policies
- runtime/session/actor state
- rate-limit buckets and related runtime information

## Architectural Boundary

Even in its current single-file form, the demonstrator has a meaningful internal
split between:

- UI state and layout management
- editor bridges
- tutorial bridge
- terminal integration
- logger/event handling
- admin API interaction

That is the architectural boundary worth preserving if the frontend is later
split into more files or moved behind a build step.

## Current Limitations

The current demonstrator still has deliberate rough edges:

- much of the frontend remains in one served HTML/JS file
- transport and state concerns are only partly separated into distinct modules
- some behaviors are still easiest to understand by reading the source rather
  than a dedicated frontend API layer
- the UI is a demonstrator-quality tool, not a polished product frontend


## Near-Term Documentation Goal

The right next step for the demonstrator documentation is not another long-term
plan. It is to keep this document aligned with the UI that actually exists.

When the demonstrator changes materially, this file should be updated as a current
status document rather than allowed to drift back into a speculative design
note.
