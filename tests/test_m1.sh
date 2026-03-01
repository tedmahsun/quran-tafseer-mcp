#!/usr/bin/env bash
# M1 integration test for quran-tafseer-mcp MCP server
# Tests: corpus loading, list_translations, get_ayah, resolve_ref
#
# Usage: bash tests/test_m1.sh [path-to-binary]

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
        echo "    Got: $(echo "$response" | head -c 300)"
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
        echo "    Got: $(echo "$response" | head -c 300)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    fi
}

echo "=== M1 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# Build the input
INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list"}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{}}}
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{"lang":"en"}}}
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1}}}
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255}}}
{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":114,"ayah":6}}}
{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255,"translations":["en.test"]}}}
{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255,"include_arabic":false}}}
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":115,"ayah":1}}}
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":300}}}
{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.nonexistent"]}}}
{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"2:255"}}}
{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Q 2:255"}}}
{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Al-Baqarah 255"}}}
{"jsonrpc":"2.0","id":53,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Al-Fatihah"}}}
{"jsonrpc":"2.0","id":54,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"An-Nas 3"}}}
{"jsonrpc":"2.0","id":55,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Nonexistent 1"}}}
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{}}}'

# Run the server
RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)

# Extract individual responses by id using grep
get_by_id() {
    echo "$RESPONSES" | grep -o "{[^}]*\"id\" *: *$1[^}]*}" | head -1
    # More robust: just get the line that contains the id
    echo "$RESPONSES" | while IFS= read -r line; do
        if echo "$line" | grep -qE "\"id\" *: *$1[^0-9]"; then
            echo "$line"
            break
        fi
    done
}

# Simpler approach: number the lines (responses are in order, notifications produce no response)
# Expected order: id=1 (init), id=10 (tools/list), id=20-21 (list_trans), id=30-34 (get_ayah),
#                 id=40-42 (errors), id=50-55 (resolve_ref), id=60 (missing params)
# Total: 19 responses

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

echo "--- tools/list ---"
R=$(find_response 10)
check_response "tools/list contains quran.list_translations" 'quran\.list_translations' "$R"
check_response "tools/list contains quran.get_ayah" 'quran\.get_ayah' "$R"
check_response "tools/list contains quran.resolve_ref" 'quran\.resolve_ref' "$R"

echo ""
echo "--- quran.list_translations ---"
R=$(find_response 20)
check_response "list_translations returns ar.test" 'ar\.test' "$R"
check_response "list_translations returns en.test" 'en\.test' "$R"

R=$(find_response 21)
check_response "list_translations lang=en excludes Arabic" 'en\.test' "$R"
check_not_present "list_translations lang=en has no Arabic in translations array" '"translations.*ar\.test' "$R"

echo ""
echo "--- quran.get_ayah ---"
R=$(find_response 30)
check_response "get_ayah Q1:1 has Arabic text" 'bismi allahi' "$R"
check_response "get_ayah Q1:1 has English text" 'name of God' "$R"
check_response "get_ayah Q1:1 ref is Q 1:1" 'Q 1:1' "$R"

R=$(find_response 31)
check_response "get_ayah Q2:255 has Arabic" 'allahu la ilaha' "$R"
check_response "get_ayah Q2:255 has English" 'Living.*Self-subsisting' "$R"

R=$(find_response 32)
check_response "get_ayah Q114:6 has correct text" 'Jinn.*Mankind' "$R"

R=$(find_response 33)
check_response "get_ayah with specific translation has en.test" 'en\.test' "$R"

R=$(find_response 34)
check_not_present "get_ayah include_arabic=false has no Arabic section" '"arabic" *: *\{' "$R"

echo ""
echo "--- quran.get_ayah error cases ---"
R=$(find_response 40)
check_response "get_ayah surah 115 returns out-of-range" 'out of range' "$R"
check_response "get_ayah surah 115 isError" 'isError.*true' "$R"

R=$(find_response 41)
check_response "get_ayah ayah 300 returns out-of-range" 'out of range.*286' "$R"

R=$(find_response 42)
check_response "get_ayah nonexistent corpus returns not found info" 'en\.nonexistent' "$R"

echo ""
echo "--- quran.resolve_ref ---"
# Note: inner JSON is escaped in the text field, so quotes appear as \"
R=$(find_response 50)
check_response "resolve_ref '2:255' gives surah 2" 'surah.*: *2' "$R"
check_response "resolve_ref '2:255' gives ayah 255" 'ayah.*: *255' "$R"
check_response "resolve_ref '2:255' normalized" 'Q 2:255' "$R"

R=$(find_response 51)
check_response "resolve_ref 'Q 2:255' works" 'Q 2:255' "$R"

R=$(find_response 52)
check_response "resolve_ref 'Al-Baqarah 255' gives surah 2" 'surah.*: *2' "$R"
check_response "resolve_ref 'Al-Baqarah 255' gives ayah 255" 'ayah.*: *255' "$R"

R=$(find_response 53)
check_response "resolve_ref 'Al-Fatihah' returns surah 1" 'surah.*: *1' "$R"
check_response "resolve_ref 'Al-Fatihah' returns ayah_count 7" 'ayah_count.*: *7' "$R"

R=$(find_response 54)
check_response "resolve_ref 'An-Nas 3' gives surah 114" 'surah.*: *114' "$R"
check_response "resolve_ref 'An-Nas 3' gives ayah 3" 'ayah.*: *3' "$R"

R=$(find_response 55)
check_response "resolve_ref 'Nonexistent 1' returns error" 'Cannot resolve' "$R"

echo ""
echo "--- missing params ---"
R=$(find_response 60)
check_response "get_ayah with no surah/ayah returns error" 'Missing required' "$R"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
