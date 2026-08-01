# Funxy Agent Manager

A manager for persistent Codex agents. Funxy provides an interactive TUI and
CLI, Codex App Server owns the threads, and workspace providers isolate agents
that edit files.

Agent Manager is not tied to Portal or a ticket system. For the Portal-specific
`solve-ticket` workflow, see [README_PORTAL.md](README_PORTAL.md).

## Quick start for any project

With Codex CLI already installed, install Funxy and Agent Manager once from the
directory containing the Agent Manager sources:

```bash
curl -sSL https://raw.githubusercontent.com/funvibe/funxy/main/install.sh | bash
/path/to/agent-manager/agent-manager install
agent-manager login-status
agent-manager login       # only if authentication is missing
agent-manager self-test
```

Then open the project you want the agents to work on. In a regular directory
without Arc, agents use that directory directly:

```bash
cd /path/to/project
agent-manager ui --workspace current --setup none
```

Choose `Start agent`, enter a unique agent name, and describe the task in
`Additional instructions`. Because there is no isolated workspace provider in
this mode, only one managed agent can own the directory at a time.

In any Arc project, start the UI from that project's directory instead:

```bash
cd "$(arc root)/path/to/project"
agent-manager ui
```

The default `--workspace auto` mode detects Arc and creates an isolated
`arc-wt` workspace for every agent. Repository-specific skills are optional;
pass one with `--skill NAME` only when Codex can discover it in the new
workspace.

## Requirements

The current implementation targets Linux. It requires:

- Codex CLI installed as `codex` and authenticated with ChatGPT or an API key;
- Bash and Funxy.

Arc and `arc-wt` are required only for isolated per-agent Arc workspaces. They
are not required when Agent Manager runs directly in a regular directory.

Agent Manager uses the experimental WebSocket transport of `codex app-server`.
Outside an Arc checkout it can use the current directory without isolation, but
only one managed agent may own that directory at a time.

## Install

Install Funxy:

```bash
curl -sSL https://raw.githubusercontent.com/funvibe/funxy/main/install.sh | bash
```

Then install and check Agent Manager from a source checkout or a copied
`agent-manager` directory:

```bash
/path/to/agent-manager/agent-manager install
agent-manager login-status
# If needed:
agent-manager login
agent-manager self-test
```

From any Arcadia checkout, the source path is:

```bash
"$(arc root)/portal/ai/tools/agent-manager/agent-manager" install
```

`install` copies the manager to `~/.local/share/agent-manager`, creates
`~/.local/bin/agent-manager`, and enables a user-systemd App Server service when
available. Otherwise the launcher uses a `nohup` fallback.

## Interactive UI

```bash
agent-manager ui
```

The TUI uses Funxy `lib/term` and provides a dashboard plus actions to start,
inspect, message, stop, resume, watch, and remove agents. Press `q` in the live
event view to return to the dashboard. For the standalone `watch` command,
`Ctrl+C` detaches from the manager; the active Codex turn continues in App Server.

Defaults for agents started from the TUI can be supplied when it opens:

```bash
agent-manager ui --skill my-workflow --sandbox danger-full-access
```

## CLI

Start a plain task:

```bash
agent-manager start refactor-auth \
  --prompt "Refactor authentication, run focused tests, and open a review"
```

Start a task through a repository skill:

```bash
agent-manager start TASK-123 --skill my-workflow
```

The task name is passed to the skill as its argument. `--prompt` is optional and
means additional instructions; it does not need to repeat the workflow already
defined by the skill.

Other commands:

```text
agent-manager list
agent-manager show NAME|THREAD
agent-manager send NAME|THREAD MESSAGE
agent-manager stop NAME|THREAD
agent-manager resume NAME|THREAD
agent-manager remove NAME|THREAD
agent-manager watch NAME|THREAD
agent-manager ui
```

## Skill discovery

Agent Manager does not search for or install skills. `--skill SKILL` only sends
an explicit `$SKILL NAME` invocation to the new Codex thread. The skill must
already be available to Codex when that thread starts.

Codex discovers local skills in:

- `.agents/skills` directories from the thread's current working directory up
  to the repository root;
- `$HOME/.agents/skills` for user-wide skills;
- `/etc/codex/skills` for administrator-provided skills;
- bundled system skills and enabled plugins.

For Arc projects with `aisuite.yaml`, the automatic `ya tool aisuite codex .`
setup prepares `.agents/skills` in every generated workspace. A skill stored
elsewhere on the machine is not discovered merely because its name was passed
through `--skill`.

## Workspace modes

`--workspace auto` is the default. The current modes are:

- `arc`: create a dedicated `arc-wt` worktree from `trunk`, acquire a lease for
  the agent, and pass the corresponding project directory to Codex;
- `none`: use the current directory while retaining the one-agent-per-directory
  guard.

For an Arc project with `aisuite.yaml`, `--setup auto` also runs
`ya tool aisuite codex .` in the new workspace. This makes each generated
checkout ready for Codex without repository-specific logic in the manager.
Available setup modes are `auto`, `none`, and `aisuite-codex`.

To deliberately use the current checkout:

```bash
agent-manager start local-task --workspace current --setup none
```

`remove` stops the thread's background terminals, unloads its runtime, asks
`arc-wt` to remove the workspace, and only then deletes the Codex thread.
`arc-wt` refuses removal when a checkout is dirty or contains unpublished
changes, so the thread and files remain available for recovery.

## Runtime options

```text
--model MODEL
--skill SKILL
--prompt TEXT
--approval untrusted|on-request|never
--sandbox read-only|workspace-write|danger-full-access
--workspace auto|current
--setup auto|none|aisuite-codex
--vcs none|arc
```

Defaults are `approval=never`, `sandbox=workspace-write`, `workspace=auto`, and
`setup=auto`. Use `danger-full-access` only inside a trusted outer sandbox or a
disposable environment.

The launcher detects Arc by walking parent directories for `.arcadia.root` or
`.arc`; otherwise it selects `none`. Runtime adaptation is based on capabilities
and VCS, not on a repository, ticket system, or skill name.

## Server operations

```text
agent-manager doctor
agent-manager self-test
agent-manager server-start
agent-manager server-stop
agent-manager server-log
```

The default endpoint is `ws://127.0.0.1:14550`. Override it with
`AGENT_MANAGER_SERVER`. The server listens on loopback only.

## Source layout

`manager.lang` is a thin executable entrypoint. The `manager/` Funxy package is
split by responsibility:

- `app_server.lang` — WebSocket RPC and thread lookup;
- `agents.lang` — agent lifecycle operations;
- `workspace.lang` — runtime policy and workspace-provider integration;
- `tui.lang` — interactive `lib/term` interface;
- `cli.lang` — command dispatch and protocol self-test;
- `json.lang` — App Server JSON helpers;
- `manager.lang` — package exports and shared configuration types.
