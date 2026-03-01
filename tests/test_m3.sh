#!/usr/bin/env bash
# M3 integration test for quran-tafseer-mcp MCP server
# Tests: JSONL loading, corpus list, corpus validate, corpus add
#
# Usage: bash tests/test_m3.sh [path-to-binary]

set -euo pipefail

BINARY="${1:-./quran-tafseer-mcp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

TMPDIR_TEST="$(mktemp -d)"
DATA_ROOT="$TMPDIR_TEST/data"

# Set up data root with test fixtures (TSV + JSONL)
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

# Helper: find JSON-RPC response by id (handles "id" : N with spaces)
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

echo "=== M3 Integration Test ==="
echo "Binary: $BINARY"
echo "Data root: $DATA_ROOT"
echo ""

# ============================================================================
# SECTION 1: JSONL LOADING (via MCP server)
# ============================================================================
echo "--- Section 1: JSONL Corpus Loading ---"

INPUT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"quran.list_translations","arguments":{}}}
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.testjsonl"]}}}
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255,"translations":["en.testjsonl"]}}}
{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":114,"ayah":6,"translations":["en.testjsonl"]}}}
{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"quran.get_range","arguments":{"surah":1,"start_ayah":1,"end_ayah":3,"translations":["en.testjsonl"]}}}
{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.test","en.testjsonl"]}}}'

RESPONSES=$(echo "$INPUT" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES <<< "$RESPONSES"

R10=$(find_response 10 "${LINES[@]}")
R20=$(find_response 20 "${LINES[@]}")
R21=$(find_response 21 "${LINES[@]}")
R22=$(find_response 22 "${LINES[@]}")
R30=$(find_response 30 "${LINES[@]}")
R40=$(find_response 40 "${LINES[@]}")

check_response "list_translations includes en.testjsonl" "en\\.testjsonl" "$R10"
check_response "JSONL corpus: 1:1 text" "en\\.testjsonl.*Compassionate.*Merciful" "$R20"
check_response "JSONL corpus: 2:255 Ayat al-Kursi" "en\\.testjsonl.*Living.*Self-subsisting" "$R21"
check_response "JSONL corpus: 114:6" "en\\.testjsonl.*Jinn.*Mankind" "$R22"
check_response "JSONL range: 1:1-3" "en\\.testjsonl.*Lord of the Worlds" "$R30"
check_response "Both TSV and JSONL in same response" "en\\.test.*Compassionate" "$R40"
check_response "Both TSV and JSONL in same response (jsonl)" "en\\.testjsonl.*Compassionate" "$R40"

echo ""

# ============================================================================
# SECTION 2: corpus list
# ============================================================================
echo "--- Section 2: corpus list ---"

LIST_OUT=$("$BINARY" corpus list --data "$DATA_ROOT" --log-level error 2>/dev/null || true)

check_response "corpus list shows ar.test" "ar\\.test" "$LIST_OUT"
check_response "corpus list shows en.test" "en\\.test" "$LIST_OUT"
check_response "corpus list shows en.testjsonl" "en\\.testjsonl" "$LIST_OUT"
check_response "corpus list shows title" "English Test Fixture" "$LIST_OUT"
check_response "corpus list shows JSONL title" "English JSONL Test Fixture" "$LIST_OUT"
check_response "corpus list shows format" "tsv_surah_ayah_text" "$LIST_OUT"
check_response "corpus list shows JSONL format" "jsonl_surah_ayah_text" "$LIST_OUT"

echo ""

# ============================================================================
# SECTION 3: corpus validate
# ============================================================================
echo "--- Section 3: corpus validate ---"

# Validate all — test fixtures are incomplete (18 verses, not 6236)
VALIDATE_ALL=$("$BINARY" corpus validate --data "$DATA_ROOT" --log-level error 2>/dev/null || true)

check_response "validate shows INCOMPLETE for en.test" "INCOMPLETE.*en\\.test" "$VALIDATE_ALL"
check_response "validate shows INCOMPLETE for en.testjsonl" "INCOMPLETE.*en\\.testjsonl" "$VALIDATE_ALL"
check_response "validate shows verse count" "18/6236" "$VALIDATE_ALL"

# Validate single corpus
VALIDATE_ONE=$("$BINARY" corpus validate --data "$DATA_ROOT" --id en.test --log-level error 2>/dev/null || true)
check_response "validate single shows en.test" "en\\.test" "$VALIDATE_ONE"

# Tamper with a corpus and validate — should show CHECKSUM MISMATCH
cp -r "$DATA_ROOT/corpora/quran/en.test" "$DATA_ROOT/corpora/quran/en.tampered"
# Modify the data file
echo "999	999	TAMPERED LINE" >> "$DATA_ROOT/corpora/quran/en.tampered/original.tsv"
# Update manifest id
sed -i 's/"en.test"/"en.tampered"/' "$DATA_ROOT/corpora/quran/en.tampered/manifest.json"

VALIDATE_TAMPERED=$("$BINARY" corpus validate --data "$DATA_ROOT" --id en.tampered --log-level error 2>/dev/null || true)
check_response "tampered corpus shows CHECKSUM MISMATCH" "CHECKSUM MISMATCH.*en\\.tampered" "$VALIDATE_TAMPERED"

echo ""

# ============================================================================
# SECTION 4: corpus add (TSV)
# ============================================================================
echo "--- Section 4: corpus add (TSV) ---"

# Create a TSV file to add
ADD_TSV="$TMPDIR_TEST/add_test.tsv"
cat > "$ADD_TSV" <<'TSVEOF'
1	1	[en.added] In the name of God.
1	2	[en.added] Praise be to God.
2	255	[en.added] Ayat al-Kursi.
TSVEOF

ADD_OUT=$("$BINARY" corpus add --data "$DATA_ROOT" --id en.added --file "$ADD_TSV" \
  --format tsv_surah_ayah_text --title "Added Test Translation" \
  --translator "Tester" --log-level error 2>&1 || true)

check_response "corpus add TSV reports success" "installed successfully" "$ADD_OUT"

# Verify via MCP server
INPUT2='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":1,"ayah":1,"translations":["en.added"]}}}'

RESPONSES2=$(echo "$INPUT2" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES2 <<< "$RESPONSES2"
R50=$(find_response 50 "${LINES2[@]}")
check_response "added TSV corpus accessible via MCP" "en\\.added.*name of God" "$R50"

# Verify manifest was created
check_response "added TSV corpus has manifest" "true" \
  "$([ -f "$DATA_ROOT/corpora/quran/en.added/manifest.json" ] && echo 'true' || echo 'false')"

# Verify manifest has correct origin
MANIFEST_CONTENT=$(cat "$DATA_ROOT/corpora/quran/en.added/manifest.json")
check_response "added corpus has manual_import origin" "manual_import" "$MANIFEST_CONTENT"

echo ""

# ============================================================================
# SECTION 5: corpus add (JSONL)
# ============================================================================
echo "--- Section 5: corpus add (JSONL) ---"

ADD_JSONL="$TMPDIR_TEST/add_jsonl_test.jsonl"
cat > "$ADD_JSONL" <<'JSONLEOF'
{"surah":1,"ayah":1,"text":"[en.addedjsonl] In the name of God."}
{"surah":1,"ayah":2,"text":"[en.addedjsonl] Praise be to God."}
{"surah":2,"ayah":255,"text":"[en.addedjsonl] Ayat al-Kursi."}
JSONLEOF

ADD_JSONL_OUT=$("$BINARY" corpus add --data "$DATA_ROOT" --id en.addedjsonl \
  --file "$ADD_JSONL" --format jsonl_surah_ayah_text \
  --title "Added JSONL Translation" --log-level error 2>&1 || true)

check_response "corpus add JSONL reports success" "installed successfully" "$ADD_JSONL_OUT"

# Verify via MCP server
INPUT3='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"quran.get_ayah","arguments":{"surah":2,"ayah":255,"translations":["en.addedjsonl"]}}}'

RESPONSES3=$(echo "$INPUT3" | "$BINARY" mcp --data "$DATA_ROOT" --log-level error 2>/dev/null)
mapfile -t LINES3 <<< "$RESPONSES3"
R60=$(find_response 60 "${LINES3[@]}")
check_response "added JSONL corpus accessible via MCP" "en\\.addedjsonl.*Ayat al-Kursi" "$R60"

echo ""

# ============================================================================
# SECTION 6: corpus add errors
# ============================================================================
echo "--- Section 6: corpus add errors ---"

# Missing --id
ADD_ERR=$("$BINARY" corpus add --data "$DATA_ROOT" --file "$ADD_TSV" \
  --format tsv_surah_ayah_text --title "X" --log-level error 2>&1 || true)
check_response "corpus add without --id errors" "id.*required" "$ADD_ERR"

# Missing --file
ADD_ERR2=$("$BINARY" corpus add --data "$DATA_ROOT" --id en.x \
  --format tsv_surah_ayah_text --title "X" --log-level error 2>&1 || true)
check_response "corpus add without --file errors" "file.*required" "$ADD_ERR2"

# Missing --format
ADD_ERR3=$("$BINARY" corpus add --data "$DATA_ROOT" --id en.x \
  --file "$ADD_TSV" --title "X" --log-level error 2>&1 || true)
check_response "corpus add without --format errors" "format.*required" "$ADD_ERR3"

# File not found
ADD_ERR4=$("$BINARY" corpus add --data "$DATA_ROOT" --id en.x \
  --file "/nonexistent/file.tsv" --format tsv_surah_ayah_text \
  --title "X" --log-level error 2>&1 || true)
check_response "corpus add with missing file errors" "not found" "$ADD_ERR4"

echo ""

# ============================================================================
# SECTION 7: Version check
# ============================================================================
echo "--- Section 7: Version check ---"

VERSION_OUT=$("$BINARY" --version 2>&1 || true)
check_response "version is 1.0.0" "1\\.0\\.0" "$VERSION_OUT"

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================"
echo "M3 Tests: $PASS passed, $FAIL failed"
echo "========================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
