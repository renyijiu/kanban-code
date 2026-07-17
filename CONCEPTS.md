# Project Concepts

## Codex Runtime Backend

Where Codex work actually runs: the Codex App Server, or Codex CLI inside a
managed tmux session. This is separate from the card's coding-assistant label.

## Managed and Observed Sessions

A managed session was created by the board and has a durable launch lease and
precise execution binding. An observed session was created elsewhere and is
imported from App Server or local session discovery; its telemetry may be
limited until a structured event arrives.

## Execution Binding

The stable identifiers needed to return to the original work: App Server thread
and turn IDs, Codex session ID, or the owned tmux session name. Bindings carry
runtime provenance and telemetry quality.

## Canonical Lifecycle

The normalized, persisted state derived from structured App Server and hook
events. It drives Backlog, In Progress, Waiting, In Review and Done. It is not
the same as transient filesystem activity or terminal liveness.

## Launch Lease

A per-card, per-generation claim persisted before creating external work. It
allows restart recovery to reconcile uncertain launches without duplicating a
thread or killing a session that might belong to someone else.
