# Evolving JSON Safely Across Swift, TypeScript and Rust Clients

## Problem

`links.json` is read and rewritten by clients released on different schedules.
A whole-file writer with an older schema can silently erase fields introduced
by a newer client, even when its own edit is unrelated.

## Durable pattern

- Keep shared `Link` additions optional and decode unknown enum values safely.
- TypeScript upserts merge the existing raw object with the typed update.
- Rust records flatten unknown per-link fields and preserve them during upsert.
- Put leases, watermarks and other high-consistency state in a single-owner
  sidecar (`codex-runtime-state.json`) instead of the shared whole-file model.
- Cover every writer with round-trip tests that start from a future-shaped
  fixture, perform an old-client update, and assert unknown fields survive.

## Why this boundary works

Display and navigation metadata benefits from broad cross-client visibility and
can tolerate optional fields. Launch ownership and lifecycle ordering cannot
tolerate last-writer-wins loss, so Swift owns that state behind an actor and
other clients read it without writing it. The CLI may project the sidecar into
its output, but never persists lifecycle mutations.
