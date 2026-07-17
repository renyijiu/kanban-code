# Codex session board

Kanban Code can organize Codex work as a five-stage workflow:

1. Backlog
2. In Progress
3. Waiting
4. In Review
5. Done

The selected runtime applies to the whole board. Existing work is never migrated
or terminated when the mode changes; only the inactive runtime's queued tasks
pause. All Sessions remains available as a separate searchable history.

## Runtime modes

### Codex App

Requirements:

- macOS 26
- Codex.app, for opening a specific thread
- a compatible `codex` executable with the `app-server` capability

Managed tasks use App Server thread and turn identifiers. The board can open a
thread with `codex://threads/<thread-id>`. The deep link is navigation only;
permission and user-input requests remain bound to the App Server connection
that issued them.

### Codex CLI + tmux

Requirements:

- macOS 26
- Codex CLI
- tmux

Each managed task keeps a stable Codex session binding and a persistent tmux
session. Opening the task reconnects to that tmux session. Switching the board
to Codex App does not stop it.

## Automatic movement

Kanban Code stores normalized lifecycle state separately from `links.json` in
`~/.kanban-code/codex-runtime-state.json`. This prevents older CLI or Windows
writers from accidentally erasing launch leases or event watermarks.

- queued → Backlog
- launching or running → In Progress
- permission, input, ordinary stop, fault, disconnect or uncertain launch → Waiting
- explicit `review-ready` lifecycle signal → In Review
- human acceptance, or every linked pull request merged → Done

A normal turn stopping does not mean that its output is ready for review. A
closed but unmerged pull request does not complete a card. Tasks without GitHub
links can still enter In Review through the structured review-ready signal and
finish through human acceptance.

Manual lifecycle corrections remain authoritative until a newer comparable
event arrives. Ambiguous or conflicting event sources are shown as limited
telemetry instead of being presented as precise state.

## Attention strip

The attention strip is global: it includes actionable Waiting sessions from
both runtimes and every project, even when their cards are hidden by the current
board or project filter. Approval and input requests sort ahead of faults,
ordinary stops and disconnects. Running, queued and plain In Review sessions do
not appear there.

## Local files and security

App Server and hook payloads are treated as untrusted input. Event size and
schema are validated; event text is never executed as a shell command. Managed
launches use a durable attempt identifier and capability-bound lifecycle events
to reduce accidental or cross-session event forgery.

Codex authentication remains owned by Codex. Kanban Code does not copy Codex
tokens into settings, card records or lifecycle events. The resolved Codex
executable is retained as an absolute path, capability-probed, and rejected when
it resolves inside the active project.

Important local paths:

- `~/.kanban-code/links.json` — cross-platform card/link metadata
- `~/.kanban-code/codex-runtime-state.json` — Swift-owned lifecycle and leases
- `~/.kanban-code/codex-lifecycle-inbox/` — bounded lifecycle event inbox
- `~/.kanban-code/settings.json` — board runtime and concurrency setting

## Degraded operation and recovery

If lifecycle hooks are not authorized, imported tasks remain visible but use
limited telemetry. Filesystem modification time alone is never considered proof
of Waiting, In Review or Done.

If a launch or resume acknowledgement is lost, Kanban Code keeps the task in an
uncertain Waiting state and offers retry/open actions. It does not automatically
repeat a potentially successful external side effect.

To change runtime or concurrency, open Settings → General → Codex Board. The
diagnostic rows show Codex desktop navigation, App Server, Codex CLI and tmux
availability plus the resolved executable and version.
