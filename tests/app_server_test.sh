#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-manager-app-server-test.XXXXXX")
SERVER_PID=""

cleanup() {
    if [[ "$SERVER_PID" =~ ^[0-9]+$ ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/agent-manager-app-server-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

funxy "$PROJECT_DIR/tests/fake_app_server.lang" >"$TEST_ROOT/server.log" 2>&1 &
SERVER_PID=$!

for _ in {1..40}; do
    if funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15997 list \
        >"$TEST_ROOT/client.log" 2>&1; then
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        printf 'Fake App Server exited:\n' >&2
        sed -n '1,120p' "$TEST_ROOT/server.log" >&2
        exit 1
    fi
    sleep 0.05
done

grep -F 'agent-manager:page-two' "$TEST_ROOT/client.log" >/dev/null || {
    printf 'Pagination test did not find the managed second-page thread:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/client.log" >&2
    exit 1
}
grep -F 'declining unsupported detached server request' "$TEST_ROOT/client.log" >/dev/null || {
    printf 'Server request was not handled explicitly:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/client.log" >&2
    exit 1
}
for _ in {1..20}; do
    grep -F '"decision":"decline"' "$TEST_ROOT/server.log" >/dev/null && break
    sleep 0.05
done
grep -F '"decision":"decline"' "$TEST_ROOT/server.log" >/dev/null || {
    printf 'Direct fallback sent an invalid decline response:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/server.log" >&2
    exit 1
}

mkdir -p "$TEST_ROOT/source" "$TEST_ROOT/workspace"
if FAKE_WORKSPACE="$TEST_ROOT/workspace" ROLLBACK_MARKER="$TEST_ROOT/workspace-removed" \
    funxy "$PROJECT_DIR/manager.lang" \
        --server ws://127.0.0.1:15997 \
        --cwd "$TEST_ROOT/source" \
        --workspace-helper "$PROJECT_DIR/tests/fake_workspace.sh" \
        start rollback >"$TEST_ROOT/rollback-client.log" 2>&1; then
    printf 'Injected thread/name/set failure unexpectedly succeeded\n' >&2
    exit 1
fi

for _ in {1..20}; do
    if [[ -e "$TEST_ROOT/workspace-removed" ]] && \
        grep -F 'ROLLED_BACK_THREAD' "$TEST_ROOT/server.log" >/dev/null; then
        break
    fi
    sleep 0.05
done

[[ -e "$TEST_ROOT/workspace-removed" ]] || {
    printf 'Failed start did not release its workspace:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/rollback-client.log" >&2
    exit 1
}
grep -F 'ROLLED_BACK_THREAD' "$TEST_ROOT/server.log" >/dev/null || {
    printf 'Failed start did not delete its partially-created thread:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/rollback-client.log" >&2
    exit 1
}

printf 'App Server protocol tests passed\n'
