# Funxy Agent Manager

Run persistent Codex agents in isolated Git worktrees from a terminal UI or a
small CLI. Each agent gets its own task branch and working directory, while all
worktrees share the repository's Git object database.

Agent Manager uses a persistent local supervisor in front of Codex App Server.
You can detach from the UI, return later, answer approval requests, send more
instructions, or stop and resume a thread without losing its workspace.

## Why use it?

- Run multiple coding agents without making them share one checkout.
- Keep every agent on a normal, inspectable Git branch.
- Leave long-running turns active after closing the dashboard.
- Refuse unsafe workspace deletion when work is dirty or not integrated.
- Use the same workflow in any Git repository; no ticket system or
  repository-specific setup is required.

## Requirements

- Linux or macOS;
- Bash 3.2 or newer;
- Git;
- [Codex CLI](https://developers.openai.com/codex/cli/), installed and authenticated;
- [Funxy](https://github.com/funvibe/funxy).

Codex App Server currently exposes an experimental interface, so a recent
Codex CLI is recommended.

## Install

### 1. Install Codex CLI

On Linux or macOS, use the official standalone installer:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

The installer adds `~/.local/bin` to your shell profile. Open a new terminal,
or update `PATH` in the current one before running `codex`:

```bash
export PATH="$HOME/.local/bin:$PATH"
codex --version
```

Alternatively, install Codex through npm:

```bash
npm install --global @openai/codex
```

Sign in with ChatGPT and confirm the authentication status:

```bash
codex login
codex login status
```

For API-key authentication instead, pass the key through stdin:

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
```

See the [official Codex CLI guide](https://developers.openai.com/codex/cli/)
for other platforms and authentication methods.

### 2. Install Funxy

```bash
curl -sSL https://raw.githubusercontent.com/funvibe/funxy/main/install.sh | bash
```

### 3. Install Agent Manager

Clone this repository, then run from its directory:

```bash
./agent-manager install
agent-manager self-test
```

The installer puts application files in `~/.local/share/agent-manager` and
links the command into `~/.local/bin`. Make sure `~/.local/bin` is on `PATH`.
On Linux with user systemd, it installs restartable services for both App
Server and the authenticated supervisor. On macOS it installs equivalent
`launchd` agents with `KeepAlive`. Systems without either service manager use a
portable `nohup` fallback and start both processes on the first command.
Service templates use the default `~/.local/share/agent-manager` data layout;
a custom `XDG_DATA_HOME` intentionally uses the fallback.

## Quick start

Open any Git repository and start the dashboard:

```bash
cd /path/to/project
agent-manager ui
```

Choose **Start agent**, give it a unique name, and enter the task. The default
`--workspace auto` mode creates a worktree from the current `HEAD` on a branch
named `agent-manager/<task-slug>`.

You can also start an agent without the UI:

```bash
agent-manager start refactor-auth \
  --prompt "Refactor authentication and run the focused tests"
```

Use `--workspace current` when you intentionally want the agent to work in the
checkout you opened:

```bash
agent-manager start local-task --workspace current
```

Only one managed agent can own a given directory. Outside a Git repository,
`auto` uses the current directory and therefore also permits only one agent.
Thread identity includes a short hash of Git's common directory, so the same
task name can be used independently in different repositories and worktrees.
The dashboard keeps the task name short for the repository where it was opened.

## Commands

```text
agent-manager start NAME [options]
agent-manager list
agent-manager show NAME|THREAD
agent-manager send NAME|THREAD MESSAGE
agent-manager stop NAME|THREAD
agent-manager resume NAME|THREAD
agent-manager watch NAME|THREAD
agent-manager events [CURSOR]
agent-manager pending
agent-manager approve TICKET
agent-manager approve-session TICKET
agent-manager decline TICKET
agent-manager cancel TICKET
agent-manager answer TICKET TEXT|JSON
agent-manager reconcile [--fix]
agent-manager remove NAME|THREAD
agent-manager ui
```

`watch` follows live App Server events. `Ctrl+C` only detaches the CLI; it does
not interrupt the active turn. In the TUI event view, press `q` to return to the
dashboard.

Before `remove`, stop the agent. Removal succeeds only when:

1. the worktree has no tracked, untracked, or ignored files; and
2. its task branch is an ancestor of `HEAD` in the original checkout.

This means uncommitted files and unmerged agent commits remain available for
recovery. Merge or cherry-pick the work into the original checkout, then run
`remove` again.

## Options

```text
--model MODEL
--skill SKILL
--prompt TEXT
--approval untrusted|on-request|never
--sandbox read-only|workspace-write|danger-full-access
--workspace auto|current
--vcs git|none
```

Defaults are `approval=on-request`, `sandbox=workspace-write`, and
`workspace=auto`. The launcher detects Git automatically. Use
`danger-full-access` only in a trusted outer sandbox or a disposable
environment.

### Detached approvals

The supervisor owns the upstream WebSocket used for `turn/start`, so approval,
user-input, permissions, and MCP elicitation requests remain available after
the invoking CLI exits. Inspect them with:

```bash
agent-manager pending
agent-manager approve 0a1b2c3d4e5f
agent-manager decline 0a1b2c3d4e5f
agent-manager answer 0a1b2c3d4e5f "the answer"
```

For a single free-text user-input question, `answer` still accepts plain text.
For several questions, pass a JSON object keyed by question ID; every value can
be a string or an array of strings:

```bash
agent-manager answer 0a1b2c3d4e5f \
  '{"environment":"staging","checks":["unit","integration"]}'
```

For MCP form elicitation, `answer` accepts a JSON object matching the requested
schema. For example:

```bash
agent-manager answer 0a1b2c3d4e5f '{"environment":"staging"}'
```

The dashboard exposes the same workflow through **Pending requests**. It asks
all user-input questions, supports secret and selectable answers, and renders
typed MCP string, number, boolean, enum, and array fields. URL elicitations can
be accepted, declined, or cancelled. `approve-session` grants an offered
approval for the current Codex session; `cancel` remains distinct from a user
decline.

Each queue entry records its creation time, expiry, state, and an opaque
`upstreamEpoch`. The default timeout is 24 hours; `autoResolutionMs` from Codex
takes precedence. Expired requests are safely declined/cancelled and desktop
notifications are shown through Notification Center on macOS or `notify-send`
on Linux. When supervisor or App Server is replaced, retained entries become
`stale` and remain visible for audit but cannot be answered on the wrong
WebSocket connection.

The queue and event log live under the manager state directory. A random
capability token protects the local supervisor even though Funxy's WebSocket
listener binds on all interfaces; the launcher accepts only a loopback control
URL and stores the token with mode `0600`.

`--skill SKILL` sends an explicit `$SKILL NAME` invocation to the new Codex
thread. Agent Manager does not install or discover skills; they must already be
available to Codex in the generated worktree or in a user-wide skill directory.

## Workspace layout

Managed worktrees and their small metadata files live under:

```text
${XDG_STATE_HOME:-~/.local/state}/agent-manager/workspaces/
```

Git worktrees are lightweight: repository objects remain in the original
repository and only checked-out files plus per-worktree Git metadata are added.
Starting the same task again reuses its existing managed worktree.

Threads created before version `0.5.0` keep their legacy
`agent-manager:<task>` names and remain addressable by that full name or their
thread ID.

| Repository | `--workspace auto` behavior |
| --- | --- |
| Git | Dedicated branch and `git worktree` |
| Non-Git directory | Current directory, one agent maximum |

### Crash reconciliation

`agent-manager reconcile` compares Codex threads, manager metadata, Git
worktrees, and `agent-manager/*` branches. It reports missing worktrees,
unowned workspaces, managed paths without metadata, unattached task branches,
and worktrees created just before a process crash.

`agent-manager reconcile --fix` only performs guarded repairs: an orphan
worktree is removed only when the normal clean-and-integrated policy permits
it, and an inactive thread whose directory disappeared is archived rather than
deleted. Dirty worktrees and branches with unintegrated commits are preserved
with an explanation.

## Server operations

```text
agent-manager doctor
agent-manager self-test
agent-manager server-start
agent-manager server-status
agent-manager server-stop
agent-manager server-log
```

The default endpoint is `ws://127.0.0.1:14551`. Override it with
`AGENT_MANAGER_SERVER`. The supervisor listens at
`ws://127.0.0.1:14552`; override that with `AGENT_MANAGER_CONTROL`. Both
defaults use loopback URLs. Server status reports the upstream and supervisor
separately and Agent Manager never stops an external service.

The installed systemd/launchd supervisor restarts after an upstream failure and
reconnects when App Server returns. The fallback process remains intentionally
portable; run another Agent Manager command to restart it after a machine-level
process kill.

For example, to reuse another compatible local App Server:

```bash
AGENT_MANAGER_SERVER=ws://127.0.0.1:14550 agent-manager server-status
```

## Development

```bash
make check
make test
```

`make check` validates the Bash launchers and loads the complete Funxy package.
`make test` also exercises Git worktree creation, reuse, guarded removal,
task-commit integration, concurrent workspace/server creation,
owned-versus-external server lifecycle behavior, App Server pagination,
server-initiated request persistence/authentication/response, upstream-session
replacement, request expiry, concurrent response races, rich form payloads,
event cursors, reconciliation inventory, and failed-start rollback.

The current compatibility baseline is Codex CLI `0.146.0` (live `self-test`)
and Funxy `0.7.15` (complete test suite). CI installs the latest Funxy release.
The App Server WebSocket API is experimental, so each new Codex version should
be validated with `agent-manager self-test` before daily use.

## Source layout

- `manager.lang` — flags and executable entrypoint;
- `manager/` — App Server client, lifecycle operations, workspace policy, CLI,
  and TUI;
- `supervisor.lang` — persistent authenticated App Server proxy and request
  queue;
- `agent-manager` — portable launcher and installer;
- `workspace.sh` — Git worktree provider and deletion safeguards;
- `tests/` — workspace integration tests.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines. This project
is available under the [MIT License](LICENSE). Current reliability work is
listed in [ROADMAP.md](ROADMAP.md).

## Known limitations

- The fallback `nohup` supervisor has no external restart monitor; systemd and
  launchd installations do.
- Funxy's current WebSocket server binds all interfaces. A loopback-only URL,
  a random `0600` capability token, and request authentication protect normal
  use, but a local unauthenticated client can still consume connection slots.
- The event log is append-only and scanned by cursor; rotation and indexing are
  not implemented yet.
- The dashboard does not yet multiplex every active thread event in place;
  `watch` and `events` expose the complete persisted stream.
- Repository namespaces use the local absolute Git common-directory path, so
  moving a repository changes the short namespace and separate clones remain
  intentionally distinct.
- Codex App Server WebSocket transport is experimental. The tested baseline is
  listed above; run `agent-manager self-test` after upgrading Codex.
