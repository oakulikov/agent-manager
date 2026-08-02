# Reliability roadmap

Agent Manager is a technical preview. This file separates guarantees already
covered by tests from architecture that is still being built.

## Completed reliability work

- Roll back a created thread and workspace when naming, goal setup, or the
  initial turn fails.
- Follow every `thread/list` cursor before filtering managed threads.
- Serialize Git workspace create/remove and manager-owned App Server
  start/stop operations with filesystem locks.
- Reserve a repository atomically across uniqueness/workspace checks and
  `thread/start`, including `--workspace current`; abandoned leases expire.
- Validate both PID and process start time before stopping an owned server.
- Namespace new thread identities by Git common directory while retaining
  legacy thread lookup and short local display names.
- Restore terminal mode after interactive-watch errors and surface WebSocket
  failures instead of looping forever.
- Exercise pagination, server requests, rollback, concurrency, and PID reuse
  with local protocol/lifecycle fixtures.

## Completed in 0.5: durable request supervisor

The process that calls `turn/start` now remains connected while Codex can issue
server-initiated requests. The local supervisor:

1. owns the upstream App Server WebSocket used by every manager RPC;
2. rewrites concurrent client request IDs and routes responses correctly;
3. persists approval, user-input, permissions, and MCP elicitation requests;
4. exposes `pending`, `approve`, `decline`, and `answer` through CLI and TUI;
5. persists upstream notifications for detached `watch` clients;
6. authenticates local clients with a random capability token;
7. tests disconnect, invalid-token, pagination, and approval-response behavior.

The default approval policy is therefore `on-request` again.

## Completed in 0.6: recovery and request lifecycle

- Bind every pending request to an opaque upstream epoch and mark retained
  requests stale after reconnect instead of sending a response to the wrong
  transport connection.
- Expire unanswered requests with a safe decline/cancel policy, respect Codex
  `autoResolutionMs`, and notify the desktop when attention is required.
- Serialize each ticket response so concurrent clients have exactly one winner.
- Support multi-question user input, session approvals, explicit cancel, and
  schema-driven MCP form fields in CLI and TUI.
- Reconcile threads, metadata, worktrees, and task branches after interrupted
  starts while preserving dirty or unintegrated work.
- Install restartable supervisor services for systemd and launchd, retaining a
  portable fallback on other systems.

## Next

- Multiplex active-thread events in the dashboard instead of receiving them
  only in `watch`.
- Add indexed event-log retention/rotation; `watch` currently scans the local
  append-only log.
- Expand the compatibility matrix as Codex App Server and Funxy releases move.
