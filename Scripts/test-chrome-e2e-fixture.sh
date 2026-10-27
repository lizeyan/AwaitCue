#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-chrome-fixture-test.XXXXXX")"
readonly request_log="${temporary_root}/requests.jsonl"
server_pid=""

cleanup() {
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
    rm -rf "${temporary_root}"
}
trap cleanup EXIT

port="$(/usr/bin/python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"

/usr/bin/python3 "${repository_root}/Tests/Fixtures/ChromeE2E/server.py" \
    --port "${port}" \
    --directory "${repository_root}/Tests/Fixtures/ChromeE2E" \
    --request-log "${request_log}" \
    > "${temporary_root}/server.log" 2>&1 &
server_pid="$!"

for _ in {1..50}; do
    if curl --fail --silent "http://127.0.0.1:${port}/health" >/dev/null; then
        break
    fi
    sleep 0.1
done
curl --fail --silent "http://127.0.0.1:${port}/health" | jq -e '.ok == true' >/dev/null
curl --fail --silent "http://127.0.0.1:${port}/index.html" \
    | grep -q 'AWAITCUE_E2E_STATUS_PENDING'

request_decision() {
    local marker="$1"
    local payload
    payload="$(jq -nc --arg marker "${marker}" '{text:{format:{name:"condition_evaluation"}},input:[{content:[{type:"input_text",text:$marker}]}]}')"
    curl --fail --silent \
        -X POST "http://127.0.0.1:${port}/v1/responses" \
        -H 'Content-Type: application/json' \
        --data "${payload}" \
        | jq -r '.output[0].content[0].text | fromjson | .decision'
}

test "$(request_decision 'data-status="running"')" = "notMatched"
test "$(request_decision 'data-status="success"')" = "matched"
test "$(jq -s 'map(select(.name == "condition_evaluation")) | length' "${request_log}")" = "2"

echo "Chrome E2E fixture and loopback Responses behavior passed."
