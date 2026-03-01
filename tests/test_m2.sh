#!/usr/bin/env bash
# M2 integration test for quran-tafseer-mcp MCP server
# Tests: quran.get_range, quran.search, index auto-build
#
# Usage: bash tests/test_m2.sh [path-to-binary]

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
        echo "    Got: $(echo "$response" | head -c 400)"
        FAIL=$((FAIL + 1))
    fi
}

check_not_present() {
    local label="$1"
    local pattern="$2"
    local response="$3"
    if echo "$response" | grep -qE "$pattern"; then
        echo "  FAIL: $label"
        echo "    Pattern should NOT be present: $pattern"
        echo "    Got: $(echo "$response" | head -c 400)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

echo "=== M2 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# ============================================================================
# Build the MCP input
# ============================================================================
INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list"}
{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":7}}}
{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":2,"start_ayah":1,"end_ayah":3}}}
{"jsonrpc":"2.0","id":102,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":114,"start_ayah":1,"end_ayah":6}}}
{"jsonrpc":"2.0","id":103,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":7,"translations":["en.test"]}}}
{"jsonrpc":"2.0","id":104,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":7,"include_arabic":false}}}
{"jsonrpc":"2.0","id":110,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":115,"start_ayah":1,"end_ayah":3}}}
{"jsonrpc":"2.0","id":111,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":2,"start_ayah":1,"end_ayah":300}}}
{"jsonrpc":"2.0","id":112,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":2,"start_ayah":5,"end_ayah":3}}}
{"jsonrpc":"2.0","id":113,"method":"tools/call","params":{"name":"quran.get_range","arguments":{}}}
{"jsonrpc":"2.0","id":200,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"Merciful"}}}
{"jsonrpc":"2.0","id":201,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"Merciful","translations":["en.test"]}}}
{"jsonrpc":"2.0","id":202,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"compulsion","limit":5}}}
{"jsonrpc":"2.0","id":210,"method":"tools/call","params":{"name":"quran.search","arguments":{}}}
{"jsonrpc":"2.0","id":211,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"Merciful","translations":["en.nonexistent"]}}}'

# Run the server
RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)

# Parse response lines
mapfile -t LINES <<< "$RESPONSES"

# Helper: find response by id
find_response() {
    local target_id="$1"
    for line in "${LINES[@]}"; do
        if echo "$line" | grep -qE "\"id\" *: *${target_id}[,} ]"; then
            echo "$line"
            return
        fi
    done
    echo ""
}

# ============================================================================
# A. tools/list includes new tools
# ============================================================================
echo "--- A. tools/list ---"
R=$(find_response 10)
check_response "tools/list contains quran.get_range" 'quran\.get_range' "$R"
check_response "tools/list contains quran.search" 'quran\.search' "$R"
check_response "tools/list has 7 tools" '"name".*"name".*"name".*"name".*"name".*"name".*"name"' "$R"

# ============================================================================
# B. quran.get_range — happy path
# Note: inner JSON is serialized inside the "text" field, so quotes appear
# as \" in the response. Patterns use unquoted field names for matching.
# ============================================================================
echo ""
echo "--- B. quran.get_range (happy path) ---"

R=$(find_response 100)
check_response "get_range Q1:1-7 has verses array" 'verses' "$R"
check_response "get_range Q1:1-7 has Q 1:1" 'Q 1:1' "$R"
check_response "get_range Q1:1-7 has Q 1:7" 'Q 1:7' "$R"
check_response "get_range Q1:1-7 total_returned 7" 'total_returned.*7' "$R"
check_response "get_range Q1:1-7 not truncated" 'truncated.*false' "$R"
check_response "get_range Q1:1-7 has Arabic text" 'bismi allahi' "$R"
check_response "get_range Q1:1-7 has English text" 'name of God' "$R"

R=$(find_response 101)
check_response "get_range Q2:1-3 has 3 verses" 'total_returned.*3' "$R"
check_response "get_range Q2:1-3 has Q 2:1" 'Q 2:1' "$R"
check_response "get_range Q2:1-3 has Q 2:3" 'Q 2:3' "$R"

R=$(find_response 102)
check_response "get_range Q114:1-6 has 6 verses" 'total_returned.*6' "$R"
check_response "get_range Q114:1-6 has correct text" 'Lord of Mankind' "$R"

R=$(find_response 103)
check_response "get_range with specific translation has en.test" 'en\.test' "$R"

R=$(find_response 104)
check_not_present "get_range include_arabic=false omits Arabic" 'corpus_id.*ar\.test' "$R"

# ============================================================================
# C. quran.get_range — error cases
# ============================================================================
echo ""
echo "--- C. quran.get_range (error cases) ---"

R=$(find_response 110)
check_response "get_range surah 115 returns out-of-range" 'out of range' "$R"
check_response "get_range surah 115 isError" 'isError.*true' "$R"

R=$(find_response 111)
check_response "get_range end_ayah 300 returns out-of-range" 'out of range' "$R"
check_response "get_range end_ayah 300 has cross-surah hint" 'single surah|multiple calls' "$R"

R=$(find_response 112)
check_response "get_range start > end returns error" 'end_ayah.*must be|Missing required' "$R"

R=$(find_response 113)
check_response "get_range missing params returns error" 'Missing required' "$R"

# ============================================================================
# D. quran.search — happy path
# ============================================================================
echo ""
echo "--- D. quran.search (happy path) ---"

R=$(find_response 200)
check_response "search 'Merciful' has hits" 'hits' "$R"
check_response "search 'Merciful' query echoed" 'query.*Merciful' "$R"
check_response "search 'Merciful' finds Q 1:1" 'Q 1:1' "$R"
check_response "search 'Merciful' finds Q 1:3" 'Q 1:3' "$R"
check_response "search 'Merciful' has snippets" 'snippet' "$R"

R=$(find_response 201)
check_response "search with specific translations has en.test" 'en\.test' "$R"
check_response "search with specific translations has hits" 'hits' "$R"

R=$(find_response 202)
check_response "search 'compulsion' finds Q 2:256" 'Q 2:256' "$R"

# ============================================================================
# E. quran.search — error cases
# ============================================================================
echo ""
echo "--- E. quran.search (error cases) ---"

R=$(find_response 210)
check_response "search empty query returns error" 'Missing required.*query' "$R"

R=$(find_response 211)
check_response "search nonexistent corpus returns error" 'not found|INDEX_MISSING|No search index' "$R"

# ============================================================================
# F. Index auto-build
# ============================================================================
echo ""
echo "--- F. Index auto-build ---"
check_response "Index file created for ar.test" "true" "$(test -f "$DATA_ROOT/indexes/quran/ar.test.sqlite" && echo true || echo false)"
check_response "Index file created for en.test" "true" "$(test -f "$DATA_ROOT/indexes/quran/en.test.sqlite" && echo true || echo false)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
