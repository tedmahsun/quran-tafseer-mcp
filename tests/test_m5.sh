#!/usr/bin/env bash
# M5 integration test for quran-tafseer-mcp MCP server
# Tests: quran.diff tool (word-level diff between translations)
#
# Usage: bash tests/test_m5.sh [path-to-binary]

set -euo pipefail

BINARY="${1:-./quran-tafseer-mcp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPDIR_TEST="$(mktemp -d)"
DATA_ROOT="$TMPDIR_TEST/data"

# Set up data root with test fixtures
mkdir -p "$DATA_ROOT/corpora/quran"
cp -r "$SCRIPT_DIR/fixtures/ar.test" "$DATA_ROOT/corpora/quran/ar.test"
cp -r "$SCRIPT_DIR/fixtures/en.test" "$DATA_ROOT/corpora/quran/en.test"
cp -r "$SCRIPT_DIR/fixtures/en.testjsonl" "$DATA_ROOT/corpora/quran/en.testjsonl"

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

PASS=0
FAIL=0

check_response() {
    local label="$1"
    local pattern="$2"
    local response="$3"
    if echo "$response" | grep -qE -- "$pattern"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label"
        echo "    Expected pattern: $pattern"
        echo "    Got: $(echo "$response" | head -c 400)"
        FAIL=$((FAIL + 1))
    fi
}

check_not_present() {
    local label="$1"
    local pattern="$2"
    local response="$3"
    if echo "$response" | grep -qE -- "$pattern"; then
        echo "  FAIL: $label"
        echo "    Pattern should NOT be present: $pattern"
        echo "    Got: $(echo "$response" | head -c 400)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

# Helper: find JSON-RPC response by id
find_response() {
    local target_id="$1"
    shift
    local lines=("$@")
    for line in "${lines[@]}"; do
        if echo "$line" | grep -qE "\"id\" *: *${target_id}[,} ]"; then
            echo "$line"
            return
        fi
    done
    echo ""
}

echo "=== M5 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# ============================================================================
# SECTION 1: Tool schema
# ============================================================================
echo "--- Section 1: Tool schema ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R10=$(find_response 10 "${LINES[@]}")

check_response "tools/list includes quran.diff" "quran\\.diff" "$R10"
check_response "diff schema has translations" "translations" "$R10"
check_response "diff schema has surah" "surah" "$R10"
check_response "diff schema has ayah" "ayah" "$R10"

echo ""

# ============================================================================
# SECTION 2: Basic diff (structured format)
# ============================================================================
echo "--- Section 2: Basic diff (structured) ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1,"translations":["en.test","en.testjsonl"]}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R20=$(find_response 20 "${LINES[@]}")

check_response "diff returns ref" "Q 1:1" "$R20"
check_response "diff returns base corpus" "en\\.test" "$R20"
check_response "diff returns diffs array" "diffs" "$R20"
check_response "diff returns ops" "ops" "$R20"
check_response "diff has equal op" "equal" "$R20"
check_response "diff has stats" "stats" "$R20"
check_response "diff has similarity" "similarity" "$R20"

echo ""

# ============================================================================
# SECTION 3: Diff with identical texts
# ============================================================================
echo "--- Section 3: Diff with same corpus (identical) ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1,"translations":["en.test","en.test"]}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R30=$(find_response 30 "${LINES[@]}")

check_response "identical texts show only equal ops" "equal" "$R30"
check_not_present "identical texts have no delete ops" "\"delete\"" "$R30"
check_not_present "identical texts have no insert ops" "\"insert\"" "$R30"
# Similarity should be 1 (or close to 1)
check_response "identical texts have similarity 1" "similarity.*: *1[.},]" "$R30"

echo ""

# ============================================================================
# SECTION 4: Error cases
# ============================================================================
echo "--- Section 4: Error cases ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1,"translations":["en.test"]}}}
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1}}}
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":999,"ayah":1,"translations":["en.test","en.testjsonl"]}}}
{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":999,"translations":["en.test","en.testjsonl"]}}}
{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1,"translations":["en.test","en.nonexistent"]}}}
{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{"name":"quran.diff","arguments":{}}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R40=$(find_response 40 "${LINES[@]}")
R41=$(find_response 41 "${LINES[@]}")
R42=$(find_response 42 "${LINES[@]}")
R43=$(find_response 43 "${LINES[@]}")
R44=$(find_response 44 "${LINES[@]}")
R45=$(find_response 45 "${LINES[@]}")

check_response "diff with only 1 translation errors" "at least 2" "$R40"
check_response "diff without translations errors" "at least 2" "$R41"
check_response "diff with invalid surah errors" "out of range" "$R42"
check_response "diff with invalid ayah errors" "out of range" "$R43"
check_response "diff with unknown corpus errors" "not found" "$R44"
check_response "diff without surah/ayah errors" "Missing required" "$R45"

echo ""

# ============================================================================
# SECTION 5: Terminal format
# ============================================================================
echo "--- Section 5: Terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"quran.diff","arguments":{"surah":1,"ayah":1,"translations":["en.test","en.testjsonl"],"format":"terminal"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R50=$(find_response 50 "${LINES[@]}")

check_response "terminal diff has header" "Diff Q 1:1" "$R50"
check_response "terminal diff has base label" "Base.*en\\.test" "$R50"
check_response "terminal diff has vs label" "vs en\\.testjsonl" "$R50"
check_response "terminal diff has equal marker" "= " "$R50"
check_response "terminal diff has stats" "sim=" "$R50"

echo ""

# ============================================================================
# SECTION 6: Version check
# ============================================================================
echo "--- Section 6: Version check ---"

VERSION_OUT=$("$BINARY" --version 2>&1 || true)
check_response "version is 1.0.0" "1\\.0\\.0" "$VERSION_OUT"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================"
echo "M5 Tests: $PASS passed, $FAIL failed"
echo "========================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
