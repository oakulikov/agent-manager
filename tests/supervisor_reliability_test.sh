#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-manager-supervisor-reliability.XXXXXX")
FAKE_PID=""
SUPERVISOR_PID=""
CONTROL_URL=""
FAKE_LOG=""
PAIR_STATE=""

stop_pair() {
    for process_id in "$SUPERVISOR_PID" "$FAKE_PID"; do
        if [[ "$process_id" =~ ^[0-9]+$ ]]; then
            kill "$process_id" 2>/dev/null || true
            wait "$process_id" 2>/dev/null || true
        fi
    done
    SUPERVISOR_PID=""
    FAKE_PID=""
}

cleanup() {
    stop_pair
    case "$TEST_ROOT" in
        "${TMPDIR:-/tmp}"/agent-manager-supervisor-reliability.*) rm -rf -- "$TEST_ROOT" ;;
        *) printf 'Refusing to clean unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
    esac
}
trap cleanup EXIT

start_pair() {
    local name=$1
    local kind=$2
    local upstream_port=$3
    local control_port=$4
    local state_dir=$5
    local ttl=${6:-86400}
    local kind_file="$TEST_ROOT/$name.kind"
    printf '%s\n' "$kind" >"$kind_file"
    FAKE_LOG="$TEST_ROOT/$name.fake.log"
    funxy "$PROJECT_DIR/tests/fake_app_server.lang" \
        --request-kind-file "$kind_file" --port "$upstream_port" >"$FAKE_LOG" 2>&1 &
    FAKE_PID=$!
    sleep 0.2
    funxy "$PROJECT_DIR/supervisor.lang" \
        --upstream "ws://127.0.0.1:$upstream_port" --port "$control_port" \
        --state "$state_dir" --token test-capability --pending-ttl "$ttl" --notify false \
        >"$TEST_ROOT/$name.supervisor.log" 2>&1 &
    SUPERVISOR_PID=$!
    CONTROL_URL="ws://127.0.0.1:$control_port"
    PAIR_STATE=$state_dir
    for _ in {1..80}; do
        funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
            --supervisor-token test-capability doctor >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    printf 'Pair %s did not become ready\n' "$name" >&2
    return 1
}

seed_request() {
    local ticket=$1
    local request_json=$2
    local expires_at=$3
    local epoch
    local now
    epoch=$(tr -d '\n' <"$PAIR_STATE/upstream-epoch")
    now=$(date +%s)
    printf '{"ticket":"%s","state":"active","upstreamEpoch":"%s","createdAt":%s,"expiresAt":%s,"request":%s}\n' \
        "$ticket" "$epoch" "$now" "$expires_at" "$request_json" >"$PAIR_STATE/pending/$ticket.payload"
    : >"$PAIR_STATE/pending/$ticket.ready"
}

start_pair user none 16001 16002 "$TEST_ROOT/user-state"
seed_request userticket01 \
    '{"id":"user-input-1","method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"environment"},{"id":"confirm"}]}}' 0
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/user.pending"
USER_TICKET=$(awk '$3 == "item/tool/requestUserInput" { print $1; exit }' "$TEST_ROOT/user.pending")
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability answer "$USER_TICKET" \
    '{"environment":"staging","confirm":["yes"]}' >/dev/null
for _ in {1..40}; do
    grep -F 'USER_INPUT_RESPONSE' "$FAKE_LOG" >/dev/null && break
    sleep 0.05
done
grep -F '"environment":{"answers":["staging"]}' "$FAKE_LOG" >/dev/null || {
    printf 'Multi-question response payload was invalid\n' >&2
    exit 1
}
stop_pair

start_pair mcp none 16003 16004 "$TEST_ROOT/mcp-state"
seed_request mcpticket0001 \
    '{"id":"mcp-form-1","method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","serverName":"fake","mode":"form","message":"settings","requestedSchema":{"type":"object"}}}' 0
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/mcp.pending"
MCP_TICKET=$(awk '$3 == "mcpServer/elicitation/request" { print $1; exit }' "$TEST_ROOT/mcp.pending")
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability answer "$MCP_TICKET" \
    '{"environment":"staging","replicas":2}' >/dev/null
for _ in {1..40}; do
    grep -F 'MCP_FORM_RESPONSE' "$FAKE_LOG" >/dev/null && break
    sleep 0.05
done
grep -F '"action":"accept","content":{"environment":"staging","replicas":2}' "$FAKE_LOG" >/dev/null || {
    printf 'MCP form response payload was invalid\n' >&2
    exit 1
}
stop_pair

start_pair race approval 16005 16006 "$TEST_ROOT/race-state"
seed_request raceticket001 \
    '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}' 0
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/race.pending"
RACE_TICKET=$(awk '$3 == "item/commandExecution/requestApproval" { print $1; exit }' "$TEST_ROOT/race.pending")
set +e
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability approve "$RACE_TICKET" >/dev/null 2>&1 &
RACE_A_PID=$!
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability decline "$RACE_TICKET" >/dev/null 2>&1 &
RACE_B_PID=$!
wait "$RACE_A_PID"; RACE_A=$?
wait "$RACE_B_PID"; RACE_B=$?
set -e
if [[ $RACE_A -eq 0 && $RACE_B -eq 0 ]] || [[ $RACE_A -ne 0 && $RACE_B -ne 0 ]]; then
    printf 'Pending ticket race did not have exactly one winner\n' >&2
    exit 1
fi
stop_pair

start_pair stale-old approval 16007 16008 "$TEST_ROOT/stale-state"
seed_request staleticket01 \
    '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}' 0
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/stale-old.pending"
STALE_TICKET=$(awk '$2 == "active" { print $1; exit }' "$TEST_ROOT/stale-old.pending")
stop_pair
start_pair stale-new none 16009 16010 "$TEST_ROOT/stale-state"
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/stale-new.pending"
grep -E "^${STALE_TICKET}[[:space:]]+stale" "$TEST_ROOT/stale-new.pending" >/dev/null || {
    printf 'Old upstream ticket was not marked stale\n' >&2
    exit 1
}
if funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability approve "$STALE_TICKET" >/dev/null 2>&1; then
    printf 'Stale upstream ticket accepted a response\n' >&2
    exit 1
fi
stop_pair

start_pair ttl approval 16011 16012 "$TEST_ROOT/ttl-state" 1
TTL_EXPIRES=$(($(date +%s) + 1))
seed_request ttlticket001 \
    '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1"}}' "$TTL_EXPIRES"
sleep 1.2
funxy "$PROJECT_DIR/manager.lang" --server "$CONTROL_URL" \
    --supervisor-token test-capability pending >"$TEST_ROOT/ttl.pending"
grep -F 'No pending requests' "$TEST_ROOT/ttl.pending" >/dev/null || {
    printf 'Expired request remained pending\n' >&2
    exit 1
}

printf 'supervisor reliability tests passed\n'
