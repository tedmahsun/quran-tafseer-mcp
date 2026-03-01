#!/usr/bin/env bash
# M1.5a integration test for quran-tafseer-mcp MCP server
# Tests: auto-trigger, quran.setup tool, bundled install, catalog, CLI init
#
# Usage: bash tests/test_m1_5a.sh [path-to-binary]

set -euo pipefail

BINARY="${1:-./quran-tafseer-mcp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPDIR_TEST="$(mktemp -d)"
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

# Find a JSON-RPC response by id. Uses here-string to avoid subshell issues.
find_response() {
    local target_id="$1"
    local all_lines="$2"
    while IFS= read -r line; do
        if echo "$line" | grep -qE "\"id\" *: *${target_id}[,} ]"; then
            echo "$line"
            return
        fi
    done <<< "$all_lines"
}

echo "=== M1.5a Integration Test ==="
echo "Binary: $BINARY"
echo ""

# ============================================================================
# A. Auto-trigger on empty data root
# ============================================================================
echo "--- A. Auto-trigger on empty data root ---"

DATA_A="$TMPDIR_TEST/data_auto"
mkdir -p "$DATA_A"

INPUT_A='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list"}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{}}}
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1}}}'

RESPONSES_A=$(echo "$INPUT_A" | "$BINARY" mcp --data "$DATA_A" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_A")
check_response "tools/list includes quran.setup" 'quran\.setup' "$R"
check_response "tools/list has 7 tools" '"name".*"name".*"name".*"name".*"name".*"name".*"name"' "$R"

R=$(find_response 20 "$RESPONSES_A")
check_response "list_translations returns en.palmer.1880" 'en\.palmer\.1880' "$R"
check_response "list_translations returns en.shakir" 'en\.shakir' "$R"

# Count translations (6 bundled)
TRANS_COUNT=$(echo "$R" | grep -oE 'en\.[a-z]' | wc -l)
if [ "$TRANS_COUNT" -ge 6 ]; then
    echo "  PASS: At least 6 translations returned after auto-install"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Expected at least 6 translations, got $TRANS_COUNT"
    FAIL=$((FAIL + 1))
fi

R=$(find_response 30 "$RESPONSES_A")
check_response "get_ayah Q1:1 returns text after auto-install" '(merciful|Merciful|name of)' "$R"

echo ""

# ============================================================================
# B. quran.setup status
# ============================================================================
echo "--- B. quran.setup status ---"

DATA_B="$TMPDIR_TEST/data_status"
mkdir -p "$DATA_B"

INPUT_B='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"status"}}}'

RESPONSES_B=$(echo "$INPUT_B" | "$BINARY" mcp --data "$DATA_B" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_B")
check_response "setup status: setup_completed true" 'setup_completed.*true' "$R"
check_response "setup status: arabic_installed true" 'arabic_installed.*true' "$R"
check_response "setup status: bundled_installed true" 'bundled_installed.*true' "$R"
check_response "setup status: installed_count 7" 'installed_count.*7' "$R"

echo ""

# ============================================================================
# C. quran.setup list_available
# ============================================================================
echo "--- C. quran.setup list_available ---"

DATA_C="$TMPDIR_TEST/data_catalog"
mkdir -p "$DATA_C"

INPUT_C='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"list_available"}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"list_available","lang":"en"}}}'

RESPONSES_C=$(echo "$INPUT_C" | "$BINARY" mcp --data "$DATA_C" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_C")
check_response "list_available returns entries" 'translations' "$R"
check_response "list_available has count field" 'count' "$R"

R=$(find_response 11 "$RESPONSES_C")
check_response "list_available with lang=en returns entries" 'translations' "$R"
# Bundled entries should show installed: true
check_response "list_available shows installed status" 'installed' "$R"

echo ""

# ============================================================================
# D. quran.setup install_bundled (idempotent)
# ============================================================================
echo "--- D. quran.setup install_bundled (idempotent) ---"

DATA_D="$TMPDIR_TEST/data_reinstall"
mkdir -p "$DATA_D"

# Auto-trigger will install bundled on first run. Then install_bundled should skip all.
INPUT_D='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"install_bundled"}}}'

RESPONSES_D=$(echo "$INPUT_D" | "$BINARY" mcp --data "$DATA_D" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_D")
check_response "install_bundled: installed_count 0" 'installed_count.*0' "$R"
check_response "install_bundled: skipped_count 7" 'skipped_count.*7' "$R"
check_response "install_bundled: error_count 0" 'error_count.*0' "$R"

echo ""

# ============================================================================
# E. Download handlers (no longer stubs — may fail gracefully without network)
# ============================================================================
echo "--- E. Download handlers ---"

DATA_E="$TMPDIR_TEST/data_stubs"
mkdir -p "$DATA_E"

INPUT_E='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download_arabic"}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download"}}}'

RESPONSES_E=$(echo "$INPUT_E" | "$BINARY" mcp --data "$DATA_E" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_E")
check_not_present "download_arabic no longer a stub" 'not available.*M1\.5b' "$R"

R=$(find_response 11 "$RESPONSES_E")
# download without ids param should give a parameter error, not a stub message
check_response "download without ids gives param error" '(ids|Missing required)' "$R"

echo ""

# ============================================================================
# F. Setup-incomplete guard
# ============================================================================
echo "--- F. Setup-incomplete guard ---"

DATA_F="$TMPDIR_TEST/data_guard"
mkdir -p "$DATA_F"

# Use a non-existent bundled path so auto-trigger doesn't fire
INPUT_F='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{}}}
{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"status"}}}'

RESPONSES_F=$(echo "$INPUT_F" | "$BINARY" mcp --data "$DATA_F" --bundled-path /nonexistent/path --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_F")
check_response "get_ayah blocked by setup guard" '(No corpora installed|isError)' "$R"

R=$(find_response 11 "$RESPONSES_F")
check_response "list_translations blocked by setup guard" '(No corpora installed|isError)' "$R"

# quran.setup itself should NOT be blocked
R=$(find_response 12 "$RESPONSES_F")
check_response "quran.setup not blocked by guard" 'setup_completed' "$R"
check_response "quran.setup status shows 0 installed" 'installed_count.*0' "$R"

echo ""

# ============================================================================
# G. Existing tools still work after auto-install
# ============================================================================
echo "--- G. Existing tools work after auto-install ---"

DATA_G="$TMPDIR_TEST/data_existing"
mkdir -p "$DATA_G"

INPUT_G='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1}}}
{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"quran.resolve_ref","arguments":{"ref":"Al-Baqarah 255"}}}'

RESPONSES_G=$(echo "$INPUT_G" | "$BINARY" mcp --data "$DATA_G" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_G")
check_response "get_ayah works after auto-install" 'Q 1:1' "$R"
check_response "get_ayah returns translation text" '(merciful|Merciful|name of)' "$R"
# Arabic should be present (ar.uthmani is bundled)
check_response "get_ayah includes Arabic text" 'ar\.uthmani' "$R"

R=$(find_response 11 "$RESPONSES_G")
check_response "resolve_ref works after auto-install" 'Q 2:255' "$R"
check_response "resolve_ref gives surah 2" 'surah.*2' "$R"

echo ""

# ============================================================================
# H. CLI init --bundled-only
# ============================================================================
echo "--- H. CLI init --bundled-only ---"

DATA_H="$TMPDIR_TEST/data_cli_init"

# First run
"$BINARY" init --data "$DATA_H" --bundled-only 2>&1 | head -20
INIT_EXIT=$?

if [ "$INIT_EXIT" -eq 0 ]; then
    echo "  PASS: CLI init --bundled-only exits 0"
    PASS=$((PASS + 1))
else
    echo "  FAIL: CLI init --bundled-only exited with code $INIT_EXIT"
    FAIL=$((FAIL + 1))
fi

# Check that 7 corpus directories were created (6 EN + 1 AR)
DIR_COUNT=$(ls -d "$DATA_H/corpora/quran/"*/ 2>/dev/null | wc -l)
if [ "$DIR_COUNT" -eq 7 ]; then
    echo "  PASS: 7 corpus directories created (6 EN + 1 AR)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Expected 7 corpus directories, found $DIR_COUNT"
    echo "    Contents: $(ls "$DATA_H/corpora/quran/" 2>/dev/null)"
    FAIL=$((FAIL + 1))
fi

# Check each corpus has manifest.json and original.tsv
ALL_VALID=true
for dir in "$DATA_H/corpora/quran/"*/; do
    if [ ! -f "$dir/manifest.json" ] || [ ! -f "$dir/original.tsv" ]; then
        ALL_VALID=false
        echo "    Missing files in: $dir"
    fi
done
if [ "$ALL_VALID" = true ]; then
    echo "  PASS: All corpus directories have manifest.json and original.tsv"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Some corpus directories missing required files"
    FAIL=$((FAIL + 1))
fi

# Idempotent: second run should skip all
SECOND_OUTPUT=$("$BINARY" init --data "$DATA_H" --bundled-only 2>&1)
if echo "$SECOND_OUTPUT" | grep -qE '(Skipped:.*7|Installed:[ ]*0)'; then
    echo "  PASS: Second init run is idempotent (all skipped)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Second init run should skip all"
    echo "    Output: $SECOND_OUTPUT"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
