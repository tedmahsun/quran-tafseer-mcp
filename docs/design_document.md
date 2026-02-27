# Quran Tafseer MCP (Free Pascal) — Design Document

## 0) Summary

This document describes the design of a **neutral Quran Tafseer MCP server** written in **Free Pascal**. The server provides **materials only**: Arabic base text and many English translations, enabling side‑by‑side comparison and text search. The server **does not interpret** and does not ship commentary/tafsir.

Primary clients: **Claude Code** and **Codex**. Transport: **stdio** (JSON‑RPC).

Key design constraints:
- **Immutability:** Original texts are stored and returned verbatim. No edits, normalization, reflow, or diacritics stripping in the source corpus files.
- **Local-only at runtime:** All corpora are read locally. No network calls during runtime tool execution. The only exception is the **setup phase** (first-run init, `quran.setup` tool), which may download corpora from allowlisted domains.
- **Bundled corpora:** Six public-domain English translations ship in the repo under `bundled/quran/` and are installed automatically on first run.
- **Neutrality:** Outputs are primary-source text + provenance only.

---

## 1) Users and use cases

### Users
- Users doing self‑study and translation comparison.
- Users compiling from source and importing their own corpora.

### Use cases
1. **Side-by-side comparison**
   - “Show Q 2:255 in Arabic plus 30 English translations.”
2. **Context reading**
   - “Show Q 18:1–10 in Arabic plus selected translations.”
3. **Search across translations**
   - “Find verses where any of these translations contain ‘mercy’.”
4. **Reference normalization**
   - Input “2:255” or “Al‑Baqarah 255” and get canonical `(surah, ayah)`.
5. **First-run setup**
   - Guided installation of bundled public-domain translations, Arabic base text download, and interactive selection of additional translations from a static catalog.

---

## 2) System boundaries

### In scope
- MCP stdio server
- Corpus storage layout + manifests
- Index building and search
- CLI utilities for corpus management
- Terminal-friendly rendering mode (optional)
- **First-run setup system** (CLI `init`/`setup` commands + auto-trigger on first MCP start + `quran.setup` MCP tool)
- **Static translation catalog** (`catalog/translations.json`) shipped with the server for browsing and downloading translations
- **Bundled public-domain corpora** (6 English translations in `bundled/quran/`)

### Out of scope
- Interpretation, meaning extraction, doctrinal analysis, ranking translations
- Hadith
- Online fetching during **runtime tool execution** (setup phase may download from allowlisted domains: `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`)

---

## 3) Transport and protocol

### Transport
- **stdio**: server reads from `stdin` and writes to `stdout`.
- All logs go to `stderr` to avoid corrupting the protocol stream.

### Message framing
Implement **Content-Length framing** (LSP-style) for maximum compatibility:

```
Content-Length: <bytes>\r\n
\r\n
<JSON payload>
```

If a client sends newline-delimited JSON (rare in MCP), you may optionally support it behind a flag, but Content-Length should be the default.

### Required MCP methods (minimum viable interoperability)
- `initialize`
- `initialized` (notification)
- `tools/list`
- `tools/call`

---

## 4) Tool design (materials-only)

### Tool: `quran.list_translations`
Returns all installed translation corpora (English only, for now) and Arabic corpora.

**Input**
```json
{ "lang": "en", "kind": "translation" }
```

**Output**
```json
{
  "translations": [
    {
      "id": "en.example.translation",
      "title": "Example Translation",
      "translator": "Name",
      "source": "Provenance string or URL",
      "license_note": "Personal use only",
      "format": "tsv_surah_ayah_text",
      "has_mapping": true
    }
  ],
  "arabic": [
    { "id": "ar.tanzil.uthmani", "title": "Tanzil Uthmani", "has_mapping": true }
  ]
}
```

---

### Tool: `quran.get_ayah`
Fetches Arabic and N translations for a single verse.

**Input**
```json
{
  "surah": 2,
  "ayah": 255,
  "translations": ["en.a", "en.b"] ,
  "include_arabic": true,
  "arabic_id": "ar.tanzil.uthmani",
  "format": "structured"
}
```

**Output (structured)**
```json
{
  "ref": "Q 2:255",
  "arabic": { "corpus_id": "ar.tanzil.uthmani", "text": "..." },
  "translations": [
    { "corpus_id": "en.a", "text": "..." },
    { "corpus_id": "en.b", "text": "..." }
  ],
  "citations": [
    { "corpus_id": "ar.tanzil.uthmani", "checksum": "sha256:..." },
    { "corpus_id": "en.a", "checksum": "sha256:..." }
  ]
}
```

**Output (terminal mode)**
- Designed for VS Code terminal and Windows Terminal stability:
  - Reference line
  - Arabic on its own line(s)
  - Each translation on its own line prefixed with an ID short name

---

### Tool: `quran.get_range`
Returns a passage for context reading; limits prevent runaway output.

**Input**
```json
{ "surah": 18, "start_ayah": 1, "end_ayah": 10, "translations": "all", "include_arabic": true }
```

**Output**
Array of blocks identical to `quran.get_ayah` shape.

**Limits**
- Default max: 20 verses per call in structured mode, 15 in terminal mode (configurable via `max_range_verses`).
- Dynamic scaling based on translation count: 1–2 translations → up to 25 verses; 3–6 → up to 15; 7+ → up to 10.
- When the requested range exceeds the effective limit, return the first N verses plus pagination hints:
  ```json
  { "verses": [...], "truncated": true, "total_requested": 30, "total_returned": 15, "continuation": "Use get_range with start_ayah=16 to continue" }
  ```
- Optionally detect client from `initialize` → `clientInfo` and auto-lower limits for Codex (~8 verses due to 10 KB output truncation).

**Limitation (v1):** Ranges are within a single surah only. The `surah` parameter is a single integer. To read across surah boundaries, make multiple `get_range` calls. Cross-surah ranges may be added in a future version.

**Error when `end_ayah` exceeds surah bounds:**
When `end_ayah` is greater than the surah's actual ayah count, the server returns `ERR_VERSE_OUT_OF_RANGE` (-32003) with an extended hint:
```json
{
  "code": -32003,
  "message": "Ayah 290 is out of range for surah 2 (max: 286).",
  "data": {
    "surah": 2,
    "requested_end_ayah": 290,
    "max_ayah": 286,
    "hint": "Cross-surah ranges are not supported in v1. To continue into the next surah, make a separate get_range call."
  }
}
```

---

### Tool: `quran.search`
Searches across selected corpora and returns refs and snippets.

**Input**
```json
{
  "query": "mercy",
  "lang": "en",
  "translations": ["en.a","en.b"],
  "limit": 20
}
```

**Output**
```json
{
  "query": "mercy",
  "hits": [
    {
      "ref": "Q 2:218",
      "score": 12.34,
      "snippets": [
        { "corpus_id": "en.a", "snippet": "...mercy..." }
      ]
    }
  ]
}
```

**Policy**
- Snippets only (e.g., 200–400 chars). Client calls `quran.get_ayah` for full texts.

---

### Tool: `quran.resolve_ref`
Normalizes messy references.

**Input**
```json
{ "ref": "Al-Baqarah 255" }
```

**Output**
```json
{ "surah": 2, "ayah": 255, "normalized_ref": "Q 2:255" }
```

---

### Tool: `quran.setup`
Guides first-run setup and corpus installation. Only this tool may make network calls (to allowlisted domains: `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`). All other `quran.*` tools operate purely on local data.

**Sub-actions**

#### `status`
Returns current setup state.

**Input**
```json
{ "action": "status" }
```

**Output**
```json
{
  "setup_completed": true,
  "arabic_installed": true,
  "bundled_installed": true,
  "installed_count": 8,
  "available_count": 45,
  "data_root": "/path/to/user_data_root"
}
```

#### `list_available`
Returns the full deduplicated translation catalog with install status per entry.

**Input**
```json
{ "action": "list_available", "lang": "en" }
```

**Output**
```json
{
  "translations": [
    {
      "id": "en.palmer.1880",
      "title": "The Qur'an (Palmer)",
      "translator": "E. H. Palmer",
      "year": 1880,
      "license_note": "Public domain",
      "sources": [
        { "provider": "bundled", "format": "tsv_surah_ayah_text" },
        { "provider": "tanzil", "url": "https://tanzil.net/trans/en.palmer", "format": "tsv_surah_ayah_text" }
      ],
      "canonical_source": "bundled",
      "installed": true,
      "bundled": true
    }
  ]
}
```

#### `install_bundled`
Copies the 6 bundled public-domain translations from `bundled/quran/` to the data root. Idempotent.

**Input**
```json
{ "action": "install_bundled" }
```

**Output**
```json
{
  "installed": ["en.palmer.1880", "en.rodwell.1861", "en.sale.1734", "en.yusufali.1934", "en.pickthall.1930", "en.shakir"],
  "skipped": [],
  "errors": []
}
```

#### `download_arabic`
Downloads the Arabic base text from Tanzil. Verifies checksum after download.

**Input**
```json
{ "action": "download_arabic", "arabic_id": "ar.tanzil.uthmani" }
```

**Output**
```json
{
  "corpus_id": "ar.tanzil.uthmani",
  "status": "installed",
  "checksum": "sha256:..."
}
```

#### `download`
Downloads specific translation corpus IDs from the catalog. Verifies checksums.

**Input**
```json
{ "action": "download", "ids": ["en.sahih", "en.hilali"] }
```

**Output**
```json
{
  "results": [
    { "id": "en.sahih", "status": "installed", "checksum": "sha256:..." },
    { "id": "en.hilali", "status": "installed", "checksum": "sha256:..." }
  ],
  "errors": []
}
```

**Error cases**
- Network failure (download timeout, DNS resolution failure)
- Checksum mismatch (downloaded file does not match expected hash)
- Partial setup (some corpora installed, others failed)
- Unknown corpus ID (not found in catalog)
- Data root not writable

---

## 5) Corpus model

### Corpus pack structure
Each corpus lives in its own directory and contains:
- `original.<ext>`: immutable source file
- `manifest.json`: metadata + checksum + format definition

Example:
```
corpora/quran/en.yusufali/
  original.txt
  manifest.json
```

### Immutability rules
- The server must never write into corpus directories.
- Indexes and caches are generated into `indexes/`.

### Supported formats (v1)
- `tsv_surah_ayah_text` (recommended for user imports)
- `jsonl_surah_ayah_text`
- `sqlite` (read-only, if corpus is already DB-shaped)

### Manifest `origin` field
Each manifest includes an `origin` field indicating how the corpus was installed:
- `"bundled"` — shipped with the server in `bundled/quran/`, copied to data root on first run
- `"downloaded"` — fetched from an online source during setup (via `quran.setup` or CLI)
- `"manual_import"` — added by the user via `quranref corpus add`

Downloaded corpora also include `download_source` (URL) and `download_date` (ISO 8601) fields.

### Bundled corpora
Six public-domain English translations ship in the repository under `bundled/quran/`. Each contains a pre-parsed `original.tsv` and `manifest.json`. These are copied to the user's data root on first run (via `quranref init` or auto-trigger on MCP start).

| Corpus ID | Title | Translator | Source |
|-----------|-------|------------|--------|
| `en.palmer.1880` | The Qur'an (Palmer) | E. H. Palmer | Wikisource (PD) |
| `en.rodwell.1861` | The Koran (Rodwell) | J. M. Rodwell | Wikisource (PD) |
| `en.sale.1734` | The Koran (Sale) | George Sale | Wikisource (PD) |
| `en.yusufali.1934` | The Holy Qur'an | Abdullah Yusuf Ali | Project Gutenberg |
| `en.pickthall.1930` | The Meaning of the Glorious Koran | Marmaduke Pickthall | Project Gutenberg |
| `en.shakir` | The Quran (Shakir) | M. H. Shakir | Project Gutenberg (date uncertain; year dropped from ID) |

### Translation catalog
A static `catalog/translations.json` ships with the server. It contains a deduplicated list of all known English translations available for download, drawn from Tanzil, Tarteel/QUL, and QuranEnc.

**Catalog entry schema:**
```json
{
  "id": "en.sahih",
  "title": "Saheeh International",
  "translator": "Saheeh International",
  "year": 1997,
  "sources": [
    {
      "provider": "tanzil",
      "url": "https://tanzil.net/trans/en.sahih",
      "format": "tsv_surah_ayah_text",
      "checksum": "sha256:abc123..."
    },
    {
      "provider": "quranenc",
      "url": "https://quranenc.com/en/browse/english_saheeh",
      "format": "jsonl_surah_ayah_text",
      "checksum": "sha256:def456..."
    }
  ],
  "canonical_source": "tanzil",
  "license_note": "Personal use only",
  "bundled": false
}
```

> **Note:** The checksum lives inside each `source` entry (not at the catalog entry level) because different providers may serve different file formats/encodings of the same translation. The checksum in the installed corpus manifest (`corpora/quran/<id>/manifest.json`) applies to the `original.*` file regardless of which source it came from.

**Deduplication strategy:** When the same translation appears on multiple providers, a single catalog entry lists all sources. The `canonical_source` field indicates the preferred download provider. The `id` is stable and provider-independent.

### Mapping requirement
For side-by-side comparison, corpora should be verse-addressable:
- If a corpus cannot provide exact `(surah,ayah)` mapping, mark `has_mapping=false` and allow:
  - search-only mode, OR
  - block it from normal comparison tools (configurable)

---

## 6) Indexing and storage

### Recommended approach: SQLite + FTS5 per corpus
For each corpus that is searchable:
- `verses(surah INT, ayah INT, text TEXT)`
- `verses_fts(text, content='verses', content_rowid='rowid')`

Index files:
```
indexes/quran/en.yusufali.sqlite
indexes/quran/ar.tanzil.uthmani.sqlite
```

### Index-only normalization
To preserve immutability:
- Store raw `text` in `verses.text` exactly as imported.
- Store optional `text_norm` for search (generated), but always return `text`.

Suggested normalization:
- English: lowercase, Unicode NFKC (optional), collapse whitespace
- Arabic: optionally build a *search* normalization (e.g., remove tatweel) but never return it

---

## 7) Configuration

### `config/server.json`
Key fields:
- `data_root`
- `max_range_verses`
- `default_arabic_id`
- `default_translation_ids` (optional)
- `search_snippet_chars`
- `log_level`
- `setup_completed` (bool): set to `true` after first-run setup finishes successfully. When `false` or absent, the MCP server auto-triggers setup on start.

---

## 8) Error model

Use JSON-RPC error objects consistently:
- `code`: stable numeric code (e.g., -32000 for server errors)
- `message`: human readable
- `data`: structured details (e.g., which corpus ID missing)

Examples:
- Unknown corpus ID
- Verse out of range
- Range too large
- Index missing (suggest running reindex)
- Download failed (network timeout, DNS resolution failure)
- Checksum mismatch (downloaded file does not match expected hash from catalog)
- Partial setup (some corpora installed successfully, others failed — report per-corpus status)
- Setup not completed (runtime tools called before setup; suggest running `quranref init` or `quran.setup`)

### Error code table

All tool errors use JSON-RPC error objects. Standard JSON-RPC codes (-327xx) are used for protocol errors; application-specific codes use the -320xx range.

| Code | Constant | Meaning |
|------|----------|---------|
| -32700 | *(JSON-RPC)* | Parse error — malformed JSON |
| -32600 | *(JSON-RPC)* | Invalid request — missing method or id |
| -32601 | *(JSON-RPC)* | Method not found |
| -32602 | *(JSON-RPC)* | Invalid params — wrong types or missing required fields |
| -32603 | *(JSON-RPC)* | Internal error — unhandled exception |
| -32001 | `ERR_SETUP_INCOMPLETE` | Setup not completed; call `quran.setup` with action `status` |
| -32002 | `ERR_CORPUS_NOT_FOUND` | Requested corpus ID is not installed |
| -32003 | `ERR_VERSE_OUT_OF_RANGE` | Surah or ayah number out of bounds |
| -32004 | `ERR_RANGE_TOO_LARGE` | Requested range exceeds max allowed verses |
| -32005 | `ERR_INDEX_MISSING` | FTS index not built for requested corpus; run `index build` |
| -32006 | `ERR_CROSS_SURAH_RANGE` | Range spans multiple surahs (reserved for future use) |
| -32007 | `ERR_DOWNLOAD_FAILED` | Network error during setup download |
| -32008 | `ERR_CHECKSUM_MISMATCH` | Downloaded file does not match expected checksum |
| -32009 | `ERR_CATALOG_ID_UNKNOWN` | Requested ID not found in translation catalog |
| -32010 | `ERR_DATA_ROOT_NOT_WRITABLE` | Cannot write to data root directory |

These constants are defined in `u_mcp.pas` (or a shared error constants unit) and used by all tool handlers. The `data` field of the error object carries structured details specific to each error (e.g., the out-of-range ayah number, the corpus ID that was not found, etc.).

---

## 9) Security and privacy

### Setup phase (network access permitted)
- Network access is restricted to **allowlisted domains only**: `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`.
- All downloads are verified against SHA-256 checksums from the static catalog before installation.
- Downloads use HTTPS only.
- No credentials or tokens are sent; all accessed resources are publicly available.
- See `docs/implementation_plan.md` section 13 ("Resolved — download URLs") for exact URL patterns, HTTP methods, and response formats per provider.

### Runtime phase (no network access)
- All processing is local. No network calls during runtime tool execution.
- Do not write corpora contents to logs.
- If users enable debug logging, redact verse texts by default (configurable) to avoid accidental leaks via log sharing.

---

## 10) Performance considerations

- `get_ayah` should be O(1) lookup using `(surah,ayah)` index (in-memory arrays, not SQLite — see implementation plan section 8).
- `get_range` builds the response array incrementally but respects the verse limit to keep the serialized JSON within MCP output budgets. Default limit 20 verses (structured) / 15 (terminal), dynamically scaled by translation count.
- `search` uses FTS indexes; restrict snippet length and hit count.
- **MCP output budget:** Claude Code truncates tool output at 25K tokens (default). Codex truncates at ~10 KB. The server respects these limits via `max_range_verses` and client-aware auto-scaling.

---

## 11) Implementation notes (Free Pascal)

### Key units/modules
- `u_jsonrpc.pas`: framing + JSON-RPC parsing/serialization
- `u_mcp.pas`: initialize/tools/list/tools/call dispatch
- `u_corpus_manifest.pas`: manifest parsing + validation
- `u_corpus_reader_*.pas`: readers for TSV/JSONL/SQLite
- `u_index_sqlite.pas`: index build + lookup + search
- `u_quran_metadata.pas`: static Qur'an structural data (114 surah names, ayah counts, aliases) — compiled into the binary
- `u_tools_quran.pas`: tool handlers for `quran.*` tools (except setup)
- `u_format_terminal.pas`: terminal rendering mode
- `u_setup.pas`: first-run detection, bundled corpus installation, download orchestration
- `u_catalog.pas`: static translation catalog loading and querying
- `u_downloader.pas`: HTTP download with checksum verification
- `u_tools_setup.pas`: tool handler for `quran.setup`
- `u_corpus_installer.pas`: corpus installation logic (bundled copy + downloaded import + manifest generation)

### Additional libraries
- `fphttpclient` (from `fcl-web`): HTTP client for downloading corpora during setup phase

### Logging
- Always stderr
- Log levels: error/warn/info/debug
- Provide `--log-level` CLI switch

---

## 12) Compatibility with Claude Code and Codex

- Stdio transport is the baseline for both.
- Provide a single run command for both clients:
  - `quranref mcp --data <DATA_ROOT>`

Document client configuration examples in README (paths, quoting rules on Windows, etc.).

---

## 13) Future extensions (still neutral)

- Add more import formats (XML, custom formats) via separate reader units.
- **Arabic variants (planned for catalog in v1, optional install):** Tanzil offers 6 variants — `uthmani`, `uthmani-min`, `simple`, `simple-enhanced`, `simple-min`, `simple-clean`. v1 ships only `ar.tanzil.uthmani` (default). The catalog lists all 6 as `ar.tanzil.<variant>` for optional install via `quran.setup`. `simple-clean` (no diacritics) may be used internally for Arabic FTS normalization in M2+.
- Add a purely mechanical `quran.diff` output (token spans only) if needed for UI highlighting.

---

## 14) Acceptance criteria (v1)

- Server starts and passes MCP handshake with Claude Code and Codex.
- At least one Arabic corpus + two English translation corpora can be imported and listed.
- `quran.get_ayah` returns correct side-by-side outputs with citations.
- `quran.search` returns deterministic refs + snippets and never emits full dumps by default.
- No corpus files are modified during import/index/use.
- First-run auto-detection works: MCP server detects empty/missing data root and triggers setup.
- Bundled corpora (6 PD translations) install correctly via `quranref init` and `quran.setup`.
- Arabic base text downloads successfully from Tanzil with checksum verification.
- `quran.setup` tool works end-to-end: status, list_available, install_bundled, download_arabic, download.
- Setup is idempotent: running init or `quran.setup` actions multiple times produces no errors or duplicates.

