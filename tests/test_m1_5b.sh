#!/usr/bin/env bash
# M1.5b integration test for quran-tafseer-mcp MCP server
# Tests: download handlers, format conversion, CLI init full flow
#
# Tier 1: Offline tests (always run)
# Tier 2: Network tests (gated by QURANREF_NETWORK_TESTS=1)
#
# Usage: bash tests/test_m1_5b.sh [path-to-binary]

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

echo "=== M1.5b Integration Test ==="
echo "Binary: $BINARY"
echo ""

# ============================================================================
# TIER 1: OFFLINE TESTS
# ============================================================================

echo "=== Tier 1: Offline Tests ==="
echo ""

# --- A. download with unknown ID returns error ---
echo "--- A. download with unknown ID ---"

DATA_A="$TMPDIR_TEST/data_unknown"
mkdir -p "$DATA_A"

INPUT_A='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download","ids":["en.nonexistent_12345"]}}}'

RESPONSES_A=$(echo "$INPUT_A" | "$BINARY" mcp --data "$DATA_A" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_A")
check_response "download unknown ID → error/not found" '(not found|Not found|isError)' "$R"

echo ""

# --- B. download_arabic is no longer "not available" ---
echo "--- B. download_arabic no longer stub ---"

DATA_B="$TMPDIR_TEST/data_no_stub"
mkdir -p "$DATA_B"

INPUT_B='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download_arabic"}}}'

RESPONSES_B=$(echo "$INPUT_B" | "$BINARY" mcp --data "$DATA_B" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_B")
check_not_present "download_arabic not 'not available'" 'not available' "$R"
check_not_present "download_arabic not 'M1.5b'" 'M1\.5b' "$R"

echo ""

# --- C. download with empty ids array → success with 0 installed ---
echo "--- C. download with empty ids ---"

DATA_C="$TMPDIR_TEST/data_empty"
mkdir -p "$DATA_C"

INPUT_C='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download","ids":[]}}}'

RESPONSES_C=$(echo "$INPUT_C" | "$BINARY" mcp --data "$DATA_C" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_C")
check_response "download empty ids → installed_count 0" 'installed_count.*0' "$R"
check_response "download empty ids → error_count 0" 'error_count.*0' "$R"

echo ""

# --- D. download with missing ids param → invalid params ---
echo "--- D. download missing ids param ---"

DATA_D="$TMPDIR_TEST/data_no_ids"
mkdir -p "$DATA_D"

INPUT_D='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download"}}}'

RESPONSES_D=$(echo "$INPUT_D" | "$BINARY" mcp --data "$DATA_D" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_D")
check_response "download no ids → error about ids" '(ids|Missing required)' "$R"

echo ""

# --- E. tools/list schema no longer says "not yet available" ---
echo "--- E. tools/list schema updated ---"

DATA_E="$TMPDIR_TEST/data_schema"
mkdir -p "$DATA_E"

INPUT_E='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/list"}'

RESPONSES_E=$(echo "$INPUT_E" | "$BINARY" mcp --data "$DATA_E" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_E")
check_not_present "tools/list no 'not yet available'" 'not yet available' "$R"
check_response "tools/list has quran.setup" 'quran\.setup' "$R"
check_response "tools/list schema mentions ids" 'ids' "$R"

echo ""

# --- F. init --all flag recognized ---
echo "--- F. init --all flag recognized ---"

DATA_F="$TMPDIR_TEST/data_init_all"

# init --all should start (bundled portion works, downloads may fail without network)
# We just check it doesn't crash with "not yet implemented" or "unknown flag"
INIT_OUTPUT=$("$BINARY" init --data "$DATA_F" --all --log-level error 2>&1 || true)

check_not_present "init --all not 'not yet implemented'" 'not yet implemented' "$INIT_OUTPUT"
check_response "init --all mentions Step" 'Step' "$INIT_OUTPUT"

echo ""

echo "=== Tier 1 Results: $PASS passed, $FAIL failed ==="

# ============================================================================
# TIER 2: NETWORK TESTS (gated)
# ============================================================================

if [ "${QURANREF_NETWORK_TESTS:-0}" != "1" ]; then
    echo ""
    echo "Skipping Tier 2 (network tests). Set QURANREF_NETWORK_TESTS=1 to enable."
    echo ""
    echo "=== Final Results: $PASS passed, $FAIL failed ==="
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
    exit 0
fi

echo ""
echo "=== Tier 2: Network Tests ==="
echo ""

# --- G. download_arabic finds ar.uthmani already installed from bundled ---
echo "--- G. download_arabic (ar.uthmani is bundled) ---"

DATA_G="$TMPDIR_TEST/data_arabic"
mkdir -p "$DATA_G"

# Auto-trigger will install bundled (including ar.uthmani). download_arabic should say already_installed.
INPUT_G='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download_arabic"}}}'

RESPONSES_G=$(echo "$INPUT_G" | "$BINARY" mcp --data "$DATA_G" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_G")
check_response "download_arabic → already_installed" 'already_installed' "$R"
check_response "download_arabic → ar.uthmani" 'ar\.uthmani' "$R"

# Verify files on disk (from bundled install)
if [ -f "$DATA_G/corpora/quran/ar.uthmani/original.tsv" ]; then
    echo "  PASS: ar.uthmani/original.tsv exists"
    PASS=$((PASS + 1))
else
    echo "  FAIL: ar.uthmani/original.tsv not found"
    FAIL=$((FAIL + 1))
fi

if [ -f "$DATA_G/corpora/quran/ar.uthmani/manifest.json" ]; then
    echo "  PASS: ar.uthmani/manifest.json exists"
    PASS=$((PASS + 1))
else
    echo "  FAIL: ar.uthmani/manifest.json not found"
    FAIL=$((FAIL + 1))
fi

# Check manifest has origin: bundled (not downloaded)
if grep -q '"origin".*"bundled"' "$DATA_G/corpora/quran/ar.uthmani/manifest.json" 2>/dev/null; then
    echo "  PASS: manifest has origin=bundled"
    PASS=$((PASS + 1))
else
    echo "  FAIL: manifest missing origin=bundled"
    FAIL=$((FAIL + 1))
fi

# Check TSV line count (should be 6236 for full Quran)
TSV_LINES=$(wc -l < "$DATA_G/corpora/quran/ar.uthmani/original.tsv" 2>/dev/null || echo 0)
# Trim whitespace
TSV_LINES=$(echo "$TSV_LINES" | tr -d ' ')
if [ "$TSV_LINES" -ge 6200 ]; then
    echo "  PASS: TSV has $TSV_LINES lines (>=6200)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: TSV has $TSV_LINES lines (expected >=6200)"
    FAIL=$((FAIL + 1))
fi

echo ""

# --- H. download en.sahih ---
echo "--- H. download en.sahih ---"

DATA_H="$TMPDIR_TEST/data_sahih"
mkdir -p "$DATA_H"

INPUT_H='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download","ids":["en.sahih"]}}}'

RESPONSES_H=$(echo "$INPUT_H" | "$BINARY" mcp --data "$DATA_H" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_H")
check_response "download en.sahih → installed_count 1" 'installed_count.*1' "$R"

if [ -f "$DATA_H/corpora/quran/en.sahih/original.tsv" ]; then
    echo "  PASS: en.sahih/original.tsv exists"
    PASS=$((PASS + 1))
else
    echo "  FAIL: en.sahih/original.tsv not found"
    FAIL=$((FAIL + 1))
fi

echo ""

# --- I. Re-download is idempotent ---
echo "--- I. Re-download idempotent ---"

INPUT_I='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.setup","arguments":{"action":"download","ids":["en.sahih"]}}}'

RESPONSES_I=$(echo "$INPUT_I" | "$BINARY" mcp --data "$DATA_H" --log-level error 2>/dev/null)

R=$(find_response 10 "$RESPONSES_I")
check_response "re-download → already_installed" 'already_installed' "$R"
check_response "re-download → installed_count 0" 'installed_count.*0' "$R"

echo ""
echo "=== Final Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
