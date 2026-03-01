#!/usr/bin/env bash
# M4 integration test for quran-tafseer-mcp MCP server
# Tests: terminal format output, version bump, format parameter in schemas
#
# Usage: bash tests/test_m4.sh [path-to-binary]

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

echo "=== M4 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# NOTE: In the JSON-RPC wire format, the inner JSON (tool result text) has
# escaped quotes: \"ref\" not "ref". Structured format checks use \\" to
# match the escaped form. Terminal format text does not use JSON escaping.

# ============================================================================
# SECTION 1: Version check
# ============================================================================
echo "--- Section 1: Version check ---"

VERSION_OUT=$("$BINARY" --version 2>&1 || true)
check_response "version is 1.0.0" "1\\.0\\.0" "$VERSION_OUT"

echo ""

# ============================================================================
# SECTION 2: Format parameter in tool schemas
# ============================================================================
echo "--- Section 2: Format parameter in schemas ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list"}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R10=$(find_response 10 "${LINES[@]}")
check_response "tools/list includes format property" '"format"' "$R10"
check_response "format enum includes structured" '"structured"' "$R10"
check_response "format enum includes terminal" '"terminal"' "$R10"

echo ""

# ============================================================================
# SECTION 3: get_ayah terminal format
# ============================================================================
echo "--- Section 3: get_ayah terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.test"],"format":"terminal"}}}
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255,"translations":["en.test"],"format":"terminal"}}}
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.test"],"format":"structured"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R20=$(find_response 20 "${LINES[@]}")
R21=$(find_response 21 "${LINES[@]}")
R22=$(find_response 22 "${LINES[@]}")

# Terminal format: ref header, Arabic label, corpus ID, no JSON keys
check_response "terminal get_ayah has ref header" "Q 1:1" "$R20"
check_response "terminal get_ayah has Arabic label" "Arabic" "$R20"
check_response "terminal get_ayah has translation label" "en\\.test" "$R20"
check_response "terminal get_ayah has verse text" "Compassionate" "$R20"
# In terminal mode, the text field should NOT contain escaped JSON key \"translations\"
check_not_present "terminal get_ayah is not JSON" 'translations.*:.*\[' "$R20"
# Terminal format for 2:255
check_response "terminal get_ayah 2:255 has ref" "Q 2:255" "$R21"
# Structured format: escaped JSON keys present
check_response "structured format has ref" 'ref.*Q 1:1' "$R22"
check_response "structured format has citations" 'citations' "$R22"

echo ""

# ============================================================================
# SECTION 4: get_range terminal format
# ============================================================================
echo "--- Section 4: get_range terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":3,"translations":["en.test"],"format":"terminal"}}}
{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":3,"translations":["en.test"],"format":"structured"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R30=$(find_response 30 "${LINES[@]}")
R31=$(find_response 31 "${LINES[@]}")

# Terminal range: multiple verse refs, no JSON structure
check_response "terminal get_range has Q 1:1" "Q 1:1" "$R30"
check_response "terminal get_range has Q 1:2" "Q 1:2" "$R30"
check_response "terminal get_range has Q 1:3" "Q 1:3" "$R30"
check_response "terminal get_range has verse text" "Lord of the Worlds" "$R30"
# Structured: contains verse ref keys
check_response "structured get_range has verses" 'verses' "$R31"
check_response "structured get_range has truncated" 'truncated' "$R31"

echo ""

# ============================================================================
# SECTION 5: list_translations terminal format
# ============================================================================
echo "--- Section 5: list_translations terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{"format":"terminal"}}}
{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{"format":"structured"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R40=$(find_response 40 "${LINES[@]}")
R41=$(find_response 41 "${LINES[@]}")

# Terminal list: section headers and corpus IDs
check_response "terminal list has Translations header" "Translations" "$R40"
check_response "terminal list has corpus IDs" "en\\.test" "$R40"
check_response "terminal list has Arabic section" "Arabic" "$R40"
check_response "terminal list has title" "English Test Fixture" "$R40"
# Structured: has JSON keys
check_response "structured list has has_mapping" 'has_mapping' "$R41"

echo ""

# ============================================================================
# SECTION 6: resolve_ref terminal format
# ============================================================================
echo "--- Section 6: resolve_ref terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"2:255","format":"terminal"}}}
{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Al-Baqarah","format":"terminal"}}}
{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"2:255","format":"structured"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R50=$(find_response 50 "${LINES[@]}")
R51=$(find_response 51 "${LINES[@]}")
R52=$(find_response 52 "${LINES[@]}")

check_response "terminal resolve_ref has normalized ref" "Q 2:255" "$R50"
check_response "terminal resolve_ref has surah name" "Al-Baqarah" "$R50"
# Surah-only resolve
check_response "terminal resolve_ref surah-only" "Q 2" "$R51"
check_response "terminal resolve_ref surah-only has name" "Al-Baqarah" "$R51"
check_response "terminal resolve_ref surah-only has ayat count" "286" "$R51"
# Structured: has specific JSON key
check_response "structured resolve_ref has normalized_ref" 'normalized_ref' "$R52"

echo ""

# ============================================================================
# SECTION 7: search terminal format
# ============================================================================
echo "--- Section 7: search terminal format ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"test","translations":["en.test"],"format":"terminal"}}}
{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"quran.search","arguments":{"query":"test","translations":["en.test"],"format":"structured"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R60=$(find_response 60 "${LINES[@]}")
R61=$(find_response 61 "${LINES[@]}")

check_response "terminal search has Search header" "Search.*test" "$R60"
check_response "terminal search has results" "result" "$R60"
check_response "terminal search has score" "score" "$R60"
# Structured: has JSON key
check_response "structured search has query" 'query' "$R61"

echo ""

# ============================================================================
# SECTION 8: Default format is structured
# ============================================================================
echo "--- Section 8: Default format is structured ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.test"]}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R70=$(find_response 70 "${LINES[@]}")
# Default (no format param) should return JSON — check for JSON structural marker
check_response "default format has ref key" 'ref.*Q 1:1' "$R70"
check_response "default format has citations" 'citations' "$R70"
# Make sure it's NOT terminal format (no "-- Q 1:1 --" header)
check_not_present "default format is not terminal" '-- Q 1:1 --' "$R70"

echo ""

# ============================================================================
# SECTION 9: Backward compatibility
# ============================================================================
echo "--- Section 9: Backward compatibility ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":80,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":"all"}}}
{"jsonrpc":"2.0","id":81,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":7}}}
{"jsonrpc":"2.0","id":82,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Al-Baqarah 255"}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R80=$(find_response 80 "${LINES[@]}")
R81=$(find_response 81 "${LINES[@]}")
R82=$(find_response 82 "${LINES[@]}")

check_response "get_ayah default returns JSON with ref" 'ref.*Q 1:1' "$R80"
check_response "get_range default returns JSON with verses" 'verses' "$R81"
check_response "resolve_ref default returns JSON" 'normalized_ref' "$R82"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================"
echo "M4 Tests: $PASS passed, $FAIL failed"
echo "========================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
