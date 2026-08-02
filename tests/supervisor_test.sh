#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-manager-supervisor-test.XXXXXX")
FAKE_PID=""
SUPERVISOR_PID=""

cleanup() {
    for process_id in "$SUPERVISOR_PID" "$FAKE_PID"; do
        if [[ "$process_id" =~ ^[0-9]+$ ]]; then
            kill "$process_id" 2>/dev/null || true
            wait "$process_id" 2>/dev/null || true
        fi
    done
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/agent-manager-supervisor-test.*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

printf 'approval\n' >"$TEST_ROOT/request-kind"
funxy "$PROJECT_DIR/tests/fake_app_server.lang" \
    --request-kind-file "$TEST_ROOT/request-kind" --port 15997 >"$TEST_ROOT/fake.log" 2>&1 &
FAKE_PID=$!
sleep 0.2
funxy "$PROJECT_DIR/supervisor.lang" \
    --upstream ws://127.0.0.1:15997 --port 15996 --state "$TEST_ROOT/state" \
    --token test-capability --notify false >"$TEST_ROOT/supervisor.log" 2>&1 &
SUPERVISOR_PID=$!

for _ in {1..80}; do
    if funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
        --supervisor-token test-capability list >"$TEST_ROOT/list.log" 2>&1; then
        break
    fi
    sleep 0.05
done
grep -F 'agent-manager:page-two' "$TEST_ROOT/list.log" >/dev/null || {
    printf 'Proxied pagination failed:\n' >&2
    sed -n '1,160p' "$TEST_ROOT/list.log" >&2
    exit 1
}

funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token test-capability events tail >"$TEST_ROOT/cursor.log"
CURSOR=$(awk '$1 == "CURSOR" { print $2 }' "$TEST_ROOT/cursor.log")
printf 'none\n' >"$TEST_ROOT/request-kind"
funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token test-capability list >/dev/null
funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token test-capability events "$CURSOR" >"$TEST_ROOT/events.log"
grep -F 'thread/status/changed' "$TEST_ROOT/events.log" >/dev/null || {
    printf 'Persisted event cursor did not return the new event\n' >&2
    exit 1
}

funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token test-capability pending >"$TEST_ROOT/pending.log"
TICKET=$(awk '$3 == "item/commandExecution/requestApproval" { print $1; exit }' "$TEST_ROOT/pending.log")
[[ "$TICKET" =~ ^[0-9a-f]{12}$ ]] || {
    printf 'Pending approval was not persisted\n' >&2
    exit 1
}
if funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token wrong-token pending >/dev/null 2>&1; then
    printf 'Supervisor accepted an invalid token\n' >&2
    exit 1
fi
funxy "$PROJECT_DIR/manager.lang" --server ws://127.0.0.1:15996 \
    --supervisor-token test-capability approve "$TICKET" >/dev/null
for _ in {1..40}; do
    grep -F '"decision":"accept"' "$TEST_ROOT/fake.log" >/dev/null && break
    sleep 0.05
done
grep -F '"decision":"accept"' "$TEST_ROOT/fake.log" >/dev/null || {
    printf 'Approval response did not reach upstream with the exact payload\n' >&2
    exit 1
}
for _ in {1..40}; do
    if ! find "$TEST_ROOT/state/pending" -name '*.ready' -print | grep . >/dev/null; then break; fi
    sleep 0.05
done
if find "$TEST_ROOT/state/pending" -name '*.ready' -print | grep . >/dev/null; then
    printf 'Resolved approval remained in the queue\n' >&2
    exit 1
fi

printf 'supervisor integration tests passed\n'
