# Funxy Agent Manager

Run persistent Codex agents in isolated Git worktrees from a terminal UI or a
small CLI. Each agent gets its own task branch and working directory, while all
worktrees share the repository's Git object database.

Agent Manager talks directly to Codex App Server. You can detach from the UI,
return later, send more instructions, or stop and resume a thread without
losing its workspace.

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
On Linux with user systemd, it also installs an App Server service. On macOS or
systems without user systemd, the launcher starts App Server with `nohup`.

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

## Commands

```text
agent-manager start NAME [options]
agent-manager list
agent-manager show NAME|THREAD
agent-manager send NAME|THREAD MESSAGE
agent-manager stop NAME|THREAD
agent-manager resume NAME|THREAD
agent-manager watch NAME|THREAD
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

| Repository | `--workspace auto` behavior |
| --- | --- |
| Git | Dedicated branch and `git worktree` |
| Non-Git directory | Current directory, one agent maximum |

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
`AGENT_MANAGER_SERVER`. The default server listens on loopback only. Server
status reports whether the endpoint belongs to a manager-owned process,
systemd, or an external compatible service. Agent Manager never stops an
external service.

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
task-commit integration, and owned-versus-external server lifecycle behavior.

## Source layout

- `manager.lang` — flags and executable entrypoint;
- `manager/` — App Server client, lifecycle operations, workspace policy, CLI,
  and TUI;
- `agent-manager` — portable launcher and installer;
- `workspace.sh` — Git worktree provider and deletion safeguards;
- `tests/` — workspace integration tests.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines. This project
is available under the [MIT License](LICENSE).
