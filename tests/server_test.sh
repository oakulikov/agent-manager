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

printf '%s\n' '#!/usr/bin/env bash' >"$FAKE_BIN/ps"
printf '%s\n' 'case "$*" in' >>"$FAKE_BIN/ps"
printf '%s\n' '  *command=*) printf "codex app-server --listen %s\\n" "${AGENT_MANAGER_SERVER:-}" ;;' >>"$FAKE_BIN/ps"
printf '%s\n' '  *) printf "Fri Aug  1 12:00:00 2026\\n" ;;' >>"$FAKE_BIN/ps"
printf '%s\n' 'esac' >>"$FAKE_BIN/ps"
chmod +x "$FAKE_BIN/funxy" "$FAKE_BIN/codex" "$FAKE_BIN/ps"

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
    "$PROJECT_DIR/agent-manager" server-start >"$TEST_ROOT/managed-start.log" &
FIRST_START_PID=$!
FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-start >"$TEST_ROOT/concurrent-start.log" &
SECOND_START_PID=$!
wait "$FIRST_START_PID"
wait "$SECOND_START_PID"
assert_contains "$TEST_ROOT/managed-start.log" "managed-process"
assert_contains "$TEST_ROOT/concurrent-start.log" "managed-process"
[[ $(find "$STATE_HOME/agent-manager" -name '*.pid' | wc -l | tr -d ' ') -eq 1 ]] || \
    fail "concurrent starts created multiple PID files"

FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-status >"$TEST_ROOT/managed-status.log"
assert_contains "$TEST_ROOT/managed-status.log" "managed-process"

FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-stop >"$TEST_ROOT/managed-stop.log" 2>&1
assert_contains "$TEST_ROOT/managed-stop.log" "Stopped managed"
if find "$STATE_HOME/agent-manager" -name '*.pid' -print | grep . >/dev/null; then
    fail "stale App Server PID file remains"
fi

rm -f -- "$READY_FILE"
SERVER_KEY=$(printf '%s' ws://127.0.0.1:15999 | cksum | awk '{ print $1 }')
STALE_PID_FILE="$STATE_HOME/agent-manager/app-server-$SERVER_KEY.pid"
printf '%s\n%s\n' "$$" "Thu Jan  1 00:00:00 1970" >"$STALE_PID_FILE"
if FAKE_SERVER_MODE=managed FAKE_SERVER_READY="$READY_FILE" PATH="$TEST_PATH" \
    XDG_STATE_HOME="$STATE_HOME" AGENT_MANAGER_SERVER=ws://127.0.0.1:15999 \
    "$PROJECT_DIR/agent-manager" server-status >"$TEST_ROOT/stale-status.log"; then
    fail "reused PID was accepted as an owned App Server"
fi
assert_contains "$TEST_ROOT/stale-status.log" "stopped"
[[ ! -f "$STALE_PID_FILE" ]] || fail "stale reused PID file was not removed"

printf 'server lifecycle tests passed\n'
