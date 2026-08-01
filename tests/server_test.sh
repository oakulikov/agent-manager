#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-manager-server-test.XXXXXX")
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p -- "$FAKE_BIN"

cleanup() {
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/agent-manager-server-test.*) rm -rf -- "$TEST_ROOT" ;;
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

printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_BIN/funxy"
printf '%s\n' 'if [[ ${FAKE_SERVER_MODE:-} == external ]]; then exit 0; fi' >>"$FAKE_BIN/funxy"
printf '%s\n' '[[ -f ${FAKE_SERVER_READY:?} ]]' >>"$FAKE_BIN/funxy"

printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_BIN/codex"
printf '%s\n' 'touch "${FAKE_SERVER_READY:?}"' >>"$FAKE_BIN/codex"
printf '%s\n' 'exec sleep 60' >>"$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/funxy" "$FAKE_BIN/codex"

TEST_PATH="$FAKE_BIN:/usr/bin:/bin"
STATE_HOME="$TEST_ROOT/state"
READY_FILE="$TEST_ROOT/ready"

FAKE_SERVER_MODE=external FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15998 \
    "$PROJECT_DIR/agent-manager" server-status >"$TEST_ROOT/external-status.log"
assert_contains "$TEST_ROOT/external-status.log" "external"
if FAKE_SERVER_MODE=external FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15998 \
    "$PROJECT_DIR/agent-manager" server-stop 2>"$TEST_ROOT/external-stop.log"; then
    fail "launcher stopped an external endpoint"
fi
assert_contains "$TEST_ROOT/external-stop.log" "externally managed"

FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-start >"$TEST_ROOT/managed-start.log"
assert_contains "$TEST_ROOT/managed-start.log" "managed-process"

FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-status >"$TEST_ROOT/managed-status.log"
assert_contains "$TEST_ROOT/managed-status.log" "managed-process"

FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-stop >"$TEST_ROOT/managed-stop.log"
assert_contains "$TEST_ROOT/managed-stop.log" "Stopped managed"
if find "$STATE_HOME/agent-manager" -name '*.pid' -print | grep . >/dev/null; then
    fail "stale App Server PID file remains"
fi

printf 'server lifecycle tests passed\n'
