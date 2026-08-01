# Contributing

Thanks for helping improve Funxy Agent Manager.

## Development setup

Install Git, Bash, Funxy, and Codex CLI, then clone the repository. No generated
dependencies are checked in.

Run the local checks before opening a pull request:

```bash
make test
```

The workspace integration test creates only temporary repositories below
`${TMPDIR:-/tmp}` and removes them on exit. Testing a live App Server connection
requires an authenticated Codex CLI:

```bash
./agent-manager self-test
```

## Pull requests

- Keep changes focused and explain user-visible behavior.
- Add or update tests for workspace lifecycle changes.
- Preserve the deletion safeguards: dirty worktrees and unintegrated commits
  must remain recoverable.
- Update the README when commands, flags, requirements, or state layout change.
- Avoid repository-specific workflow assumptions in the core manager.

By contributing, you agree that your contributions are licensed under the MIT
License.
