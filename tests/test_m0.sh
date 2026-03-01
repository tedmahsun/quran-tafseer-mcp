#!/usr/bin/env bash
# M0 integration test for quran-tafseer-mcp MCP server
# Pipes 6 JSON-RPC messages and shows responses.
#
# Usage: bash tests/test_m0.sh [path-to-binary]

set -euo pipefail

BINARY="${1:-./quran-tafseer-mcp}"
TMPDIR_TEST="$(mktemp -d)"
DATA_ROOT="$TMPDIR_TEST/data"
mkdir -p "$DATA_ROOT"

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

PASS=0
FAIL=0

check_response() {
    local label="$1"
    local pattern="$2"
    local response="$3"
    if echo "$response" | grep -qE "$pattern"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    Expected pattern: $pattern"
        echo "    Got: $response"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== M0 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# Build the input: 6 JSON-RPC messages, one per line
INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1}}}
{"jsonrpc":"2.0","id":4,"method":"ping"}
{"jsonrpc":"2.0","id":5,"method":"nonexistent/method"}'

# Run the server with the input piped in
RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)

echo "Responses received:"
echo "$RESPONSES"
echo ""

# Parse responses (one per line)
R1=$(echo "$RESPONSES" | sed -n '1p')
R2=$(echo "$RESPONSES" | sed -n '2p')
R3=$(echo "$RESPONSES" | sed -n '3p')
R4=$(echo "$RESPONSES" | sed -n '4p')
R5=$(echo "$RESPONSES" | sed -n '5p')

echo "Checking responses:"

# 1. initialize — expect serverInfo with name "quran-tafseer-mcp"
# FPC AsJSON formats with spaces around colons, so use regex
check_response "initialize returns serverInfo" '"name" *: *"quran-tafseer-mcp"' "$R1"
check_response "initialize returns protocolVersion" '"protocolVersion" *: *"2024-11-05"' "$R1"

# 2. notifications/initialized — no response, so R2 should be tools/list response

# 3. tools/list — expect tools array (populated since M1)
check_response "tools/list returns tools array" '"tools" *: *\[' "$R2"

# 4. tools/call — quran.get_ayah now handled (since M1), returns a result
check_response "tools/call for known tool returns result" '"result"' "$R3"

# 5. ping — expect empty result object (R4)
check_response "ping returns empty result" '"result" *: *\{\}' "$R4"

# 6. unknown method — expect method not found error (R5)
check_response "unknown method returns method-not-found" 'Method not found' "$R5"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
