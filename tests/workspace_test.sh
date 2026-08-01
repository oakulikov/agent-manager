#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
HELPER="$PROJECT_DIR/workspace.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-manager-test.XXXXXX")

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/agent-manager-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    grep -F -- "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

REPOSITORY="$TEST_ROOT/repository"
mkdir -p -- "$REPOSITORY/project/subdir"
git -C "$REPOSITORY" init -q
git -C "$REPOSITORY" config user.name "Agent Manager Test"
git -C "$REPOSITORY" config user.email "test@example.invalid"
printf 'initial\n' >"$REPOSITORY/project/example.txt"
git -C "$REPOSITORY" add .
git -C "$REPOSITORY" commit -qm "initial"

STATE_HOME="$TEST_ROOT/state"
AGENT_CWD=$(XDG_STATE_HOME="$STATE_HOME" "$HELPER" create \
    --task "Example task" --cwd "$REPOSITORY/project" --vcs git)
[[ "$AGENT_CWD" != "$REPOSITORY/project" ]] || fail "Git mode reused the source checkout"
[[ -f "$AGENT_CWD/example.txt" ]] || fail "worktree did not preserve the project subdirectory"
[[ $(git -C "$AGENT_CWD" symbolic-ref --short HEAD) == agent-manager/* ]] || fail "unexpected task branch"

REUSED_CWD=$(XDG_STATE_HOME="$STATE_HOME" "$HELPER" create \
    --task "Example task" --cwd "$REPOSITORY/project" --vcs git)
[[ "$REUSED_CWD" == "$AGENT_CWD" ]] || fail "managed worktree was not reused"

printf 'uncommitted\n' >"$AGENT_CWD/untracked.txt"
if XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$AGENT_CWD" \
    2>"$TEST_ROOT/dirty-removal.log"; then
    fail "dirty worktree removal succeeded"
fi
assert_contains "$TEST_ROOT/dirty-removal.log" "uncommitted changes"
rm -- "$AGENT_CWD/untracked.txt"

printf 'ignored.txt\n' >"$AGENT_CWD/.gitignore"
git -C "$AGENT_CWD" add .gitignore
git -C "$AGENT_CWD" commit -qm "ignore generated file"
printf 'generated\n' >"$AGENT_CWD/ignored.txt"
if XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$AGENT_CWD" \
    2>"$TEST_ROOT/ignored-removal.log"; then
    fail "worktree removal with ignored files succeeded"
fi
assert_contains "$TEST_ROOT/ignored-removal.log" "including ignored files"
rm -- "$AGENT_CWD/ignored.txt"

printf 'agent change\n' >>"$AGENT_CWD/example.txt"
git -C "$AGENT_CWD" add example.txt
git -C "$AGENT_CWD" commit -qm "agent change"
TASK_BRANCH=$(git -C "$AGENT_CWD" symbolic-ref --short HEAD)
if XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$AGENT_CWD" \
    2>"$TEST_ROOT/unmerged-removal.log"; then
    fail "unmerged task branch removal succeeded"
fi
assert_contains "$TEST_ROOT/unmerged-removal.log" "commits not integrated"

git -C "$REPOSITORY" merge --ff-only "$TASK_BRANCH" >/dev/null
XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$AGENT_CWD"
[[ -z $(git -C "$REPOSITORY" branch --list "$TASK_BRANCH") ]] || fail "integrated task branch was not removed"
[[ $(git -C "$REPOSITORY" worktree list --porcelain | grep -c '^worktree ') -eq 1 ]] || fail "worktree registration remains"

CHERRY_CWD=$(XDG_STATE_HOME="$STATE_HOME" "$HELPER" create \
    --task "Cherry-pick task" --cwd "$REPOSITORY/project" --vcs git)
printf 'cherry-picked change\n' >>"$CHERRY_CWD/example.txt"
git -C "$CHERRY_CWD" add example.txt
git -C "$CHERRY_CWD" commit -qm "cherry-picked agent change"
CHERRY_BRANCH=$(git -C "$CHERRY_CWD" symbolic-ref --short HEAD)
CHERRY_COMMIT=$(git -C "$CHERRY_CWD" rev-parse HEAD)
git -C "$REPOSITORY" cherry-pick "$CHERRY_COMMIT" >/dev/null
XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$CHERRY_CWD"
[[ -z $(git -C "$REPOSITORY" branch --list "$CHERRY_BRANCH") ]] || fail "cherry-picked task branch was not removed"

ODD_CWD=$(XDG_STATE_HOME="$STATE_HOME" "$HELPER" create \
    --task "../Feature..Name" --cwd "$REPOSITORY/project" --vcs git)
ODD_BRANCH=$(git -C "$ODD_CWD" symbolic-ref --short HEAD)
git check-ref-format "refs/heads/$ODD_BRANCH" || fail "task name produced an invalid Git branch"
XDG_STATE_HOME="$STATE_HOME" "$HELPER" remove --cwd "$ODD_CWD"

PLAIN_DIR="$TEST_ROOT/plain"
mkdir -p -- "$PLAIN_DIR"
PLAIN_RESULT=$(XDG_STATE_HOME="$STATE_HOME" "$HELPER" create \
    --task "Plain task" --cwd "$PLAIN_DIR" --vcs none)
PLAIN_EXPECTED=$(cd -- "$PLAIN_DIR" && pwd -P)
[[ "$PLAIN_RESULT" == "$PLAIN_EXPECTED" ]] || fail "non-Git mode changed cwd"

printf 'workspace integration tests passed\n'
