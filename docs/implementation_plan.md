# Quran Tafseer MCP (Free Pascal) — Implementation Plan

> Scope: **Quran only (for now)**. No interpretation/tafseer. Local corpora. Side‑by‑side comparison across many English translations plus Arabic base text.

## 1) Project goals and non‑goals

### Goals
- Provide a **neutral reference engine** over MCP for:
  - Arabic base text (verbatim).
  - Many English translations (verbatim).
  - Side‑by‑side display and search.
- Run as a **stdio MCP server** compatible with any MCP client; primary targets: **Claude Code** and **Codex**.
- Keep **original texts immutable**:
  - Never rewrite, normalize, reflow, strip diacritics, or “fix” punctuation in the source files.
  - All derived artifacts (indexes, caches) live elsewhere and are regenerable.
- Support a **private/local corpus library**:
  - Users can import legally obtained translations locally.
  - Repo can remain clean (no copyrighted corpora committed).
- Provide a **guided first-run experience** with bundled public-domain translations and Arabic base text, with interactive selection of additional translations from a static catalog.

### Non‑goals (explicit)
- No interpretation, meaning extraction, doctrinal claims, ranking “best” translation, or commentary generation.
- No hadith support in this phase.
- No online REST lookups during **runtime tool execution** (setup phase may download from allowlisted domains: `cdn.jsdelivr.net` (quran-api), `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`).

---

## 2) High‑level architecture

### Components
1. **MCP server binary** (Free Pascal, stdio transport)
   - JSON‑RPC message loop over stdin/stdout
   - Logs to stderr
2. **Corpus store** (on disk, immutable)
   - Arabic base text corpus
   - Multiple English translation corpora
3. **Index store** (derived, regenerable)
   - SQLite + FTS (recommended) or custom inverted indexes
4. **CLI utilities** (same binary with subcommands, or a companion tool)
   - Initialize folders
   - Register/import corpora
   - Build/rebuild indexes
   - Validate corpus integrity
5. **Setup system** (same binary, `init`/`setup` subcommands + auto-trigger on MCP start)
   - First-run detection (empty or missing data root)
   - Bundled corpus installation (copy from `bundled/` to data root)
   - Arabic base text download from quran-api (or Tanzil as fallback)
   - Interactive translation selection from static catalog
   - `quran.setup` MCP tool for conversational setup via Claude/Codex

### Folder layout (recommended)
```
repo/
  src/
  build/
  docs/
  bundled/
    quran/
      en.palmer.1880/original.tsv + manifest.json
      en.rodwell.1861/original.tsv + manifest.json
      en.sale.1734/original.tsv + manifest.json
      en.yusufali.1934/original.tsv + manifest.json
      en.pickthall.1930/original.tsv + manifest.json
      en.shakir/original.tsv + manifest.json
  catalog/
    translations.json
  data/                (optional sample; usually empty in repo)
  .gitignore

user_data_root/
  corpora/
    quran/
      ar.<id>/
        original.<ext>
        manifest.json
      en.<id>/
        original.<ext>
        manifest.json
  indexes/
    quran/
      <corpus-id>.sqlite
  config/
    server.json
```

---

## 3) Data model

### Corpus manifest schema (`manifest.json`)
Minimal fields:
- `id` (string, stable): e.g., `ar.uthmani`, `en.palmer.1880`, `en.user.yusufali`
- `kind`: `quran_arabic` | `quran_translation`
- `language`: `ar` | `en`
- `title`: human readable
- `author` / `translator`
- `source`: URL or provenance string (user-provided if local)
- `license_note`: freeform text (“personal use only”, “PD”, etc.)
- `format`: `tsv_surah_ayah_text` | `jsonl_surah_ayah_text` | `sqlite`
- `checksum`: SHA‑256 of `original.*` (for integrity checks)
- `created_at` / `imported_at`
- `origin`: `"bundled"` | `"downloaded"` | `"manual_import"` — how this corpus was installed
- `download_source` (optional): URL the corpus was fetched from (for `origin: "downloaded"`)
- `download_date` (optional): ISO 8601 timestamp of download (for `origin: "downloaded"`)

### Translation catalog schema (`catalog/translations.json`)
A static file shipped with the server, containing a deduplicated list of all known English translations available for download.

Entry fields:
- `id` (string, stable): e.g., `en.sahih`, `en.hilali`
- `title`: human readable
- `translator`
- `year` (optional)
- `sources` (array): one or more download sources
  - `provider`: `"quran-api"` | `"tanzil"` | `"tarteel"` | `"quranenc"`
  - `url`: download URL
  - `format`: `"json_chapter_verse_text"` | `"tsv_surah_ayah_text"` | `"tsv_pipe_surah_ayah_text"` | `"jsonl_surah_ayah_text"` | `"sqlite"`
  - `checksum`: SHA-256 of the expected downloaded file from this source (null if not yet verified)
- `canonical_source`: preferred provider for download (typically `"quran-api"`)
- `license_note`: freeform text
- `bundled` (bool): whether this translation is also shipped in `bundled/quran/`

> **Note:** The checksum lives inside each `source` entry (not at the catalog entry level) because different providers may serve different file formats/encodings of the same translation. The checksum in the installed corpus manifest (`corpora/quran/<id>/manifest.json`) applies to the `original.*` file regardless of which source it came from.

### Canonical verse key
- `(surah:int, ayah:int)`; stored as `surah*1000 + ayah` or `(surah,ayah)` columns.
- All translations must map to this key. If a corpus can’t provide a clean mapping, mark it `has_mapping:false` and allow **search-only** mode.

---

## 4) MCP tool surface (neutral, materials-only)

### Required tools (v1)
1. `quran.list_translations`
   - Input: `{ "lang": "en" }` (optional filters)
   - Output: list of translation manifests (subset)

2. `quran.get_ayah`
   - Input: `{ "surah": 2, "ayah": 255, "translations": ["en.xxx", "..."] | "all", "include_arabic": true }`
   - Output (structured):
     - `ref`, `arabic{ text, corpus_id }`, `translations[{ corpus_id, text }]`, `citations[]`

3. `quran.get_range`
   - Input: `{ "surah": 18, "start_ayah": 1, "end_ayah": 10, "translations": "...", "include_arabic": true }`
   - Output: array of ayah blocks (same shape as `get_ayah`)
   - Default max: 20 verses per call (structured), 15 verses (terminal). Dynamic scaling based on translation count (see section 13).
   - When truncated, response includes `truncated: true`, `total_requested`, `total_returned`, and a `continuation` hint.
   - **Limitation (v1):** Ranges are within a single surah only. The `surah` parameter is a single integer. To read across surah boundaries, make multiple `get_range` calls. Cross-surah ranges may be added in a future version.

4. `quran.search`
   - Input: `{ "query": "mercy", "lang": "en"|"ar", "translations": ["..."] | "all", "limit": 20 }`
   - Output: hits with `ref` and **snippets** (not full dumps)

5. `quran.resolve_ref`
   - Input: `{ "ref": "2:255" | "Q 2:255" | "Al-Baqarah 255" }`
   - Output: `{ "surah": 2, "ayah": 255, "normalized_ref": "Q 2:255" }`

6. `quran.setup`
   - Input: `{ "action": "status"|"list_available"|"install_bundled"|"download_arabic"|"download", ... }`
   - Actions:
     - `status`: returns setup state (what's installed, is setup complete)
     - `list_available`: full deduplicated catalog with install status per entry
     - `install_bundled`: copy bundled PD texts to data root (idempotent)
     - `download_arabic`: download Arabic base text from quran-api with checksum verification
     - `download`: download specific corpus IDs from catalog with checksum verification
   - Only tool permitted to make network calls (allowlisted domains only)

### `quran.diff` (implemented in M5)
- `quran.diff`
  - Input: `{ "surah": X, "ayah": Y, "translations": ["id1", "id2", ...] }`
  - Output: word-level LCS diff ops (equal/delete/insert) with similarity statistics.
  - First translation is the base; each subsequent one is compared against it.

### Output formatting modes
Provide `format` argument for display convenience:
- `structured` (default): JSON objects
- `terminal`: preformatted text blocks (Arabic on its own lines to reduce BiDi headaches)

---

## 5) Corpus ingestion and immutability

### Supported import formats (v1)
- `tsv_surah_ayah_text`: `surah<TAB>ayah<TAB>text`
- `json_chapter_verse_text`: quran-api format: `{"quran": [{"chapter":1, "verse":1, "text":"..."}]}`
- `jsonl_surah_ayah_text`: one JSON per line: `{"surah":2,"ayah":255,"text":"..."}`
- `sqlite`: if corpus ships as a DB, read it directly (still treat as immutable)

**Deferred:** `line_114` format (114 files/sections per corpus) is not supported in v1. No known corpus sources use this format. It may be added in M3+ if a concrete use case arises.

### Import rules
- Copy the original file into `corpora/quran/<id>/original.<ext>` unchanged.
- Generate `manifest.json` with checksum and metadata.
- Do **not** transform the text; if you need normalization for search, do it in the index only.

### Integrity checks
- `corpus.status` (CLI, not MCP): verify checksum matches original.
- Report missing verses, duplicates, or mapping gaps.

### Bundled corpus installation
The 6 public-domain translations in `bundled/quran/` are copied to the user's data root on first run. Each bundled corpus contains a pre-parsed `original.tsv` and `manifest.json` (with `origin: "bundled"`). The copy is idempotent: if a corpus already exists in the data root, it is skipped.

### Download-based corpus installation
For translations from the catalog:
1. HTTP fetch from the canonical source URL (HTTPS only, allowlisted domains: `cdn.jsdelivr.net`, `tanzil.net`, `quranenc.com`)
2. SHA-256 checksum verification against the source's `checksum` field in the catalog (null = skip with warning)
3. Parse/convert to `original.tsv` if needed:
   - quran-api JSON (`json_chapter_verse_text`): parse `{"quran": [{"chapter", "verse", "text"}]}`, write as TSV
   - Tanzil `txt-2` (`tsv_pipe_surah_ayah_text`): convert pipe delimiter (`|`) to tab (`\t`), strip comment lines (`#`) and blank lines
   - QuranEnc CSV: parse CSV, drop `id` and `footnotes` columns, write as TSV
   - QuranEnc SQLite: read `translations` table directly (store as `original.sqlite`, format `sqlite`)
4. Generate `manifest.json` with `origin: "downloaded"`, `download_source`, `download_date`
5. Build SQLite + FTS5 index for the new corpus

---

## 6) Indexing strategy (fast search, no source edits)

### Recommended: SQLite + FTS5
For each corpus that is searchable:
- Table `verses(surah INT, ayah INT, text TEXT)`
- Virtual FTS table `verses_fts(text, content='verses', content_rowid='rowid')`
- Index `(surah, ayah)` for fast lookup.

Normalization policy (index-only):
- English: lowercase folding; optional punctuation stripping **only inside the FTS index**
- Arabic: optionally store a separate `text_norm` column/index for search while returning raw `text` to users

### Search output constraints
- Return only:
  - `ref`
  - short snippet(s) from matching text
  - corpus_id used for snippet
- User/client calls `quran.get_ayah` to see the full side-by-side display.

---

## 7) CLI commands (developer & user workflow)

### Build/run commands (proposed)
- `quran-tafseer-mcp build` (optional wrapper) or external scripts.

### First-run setup
All commands use a platform-default data root when `--data` is omitted (Windows: `%LOCALAPPDATA%\quran-tafseer-mcp`, Linux/macOS: `$XDG_DATA_HOME/quran-tafseer-mcp`).
- `quran-tafseer-mcp init [--data <path>]`
  - Creates folder structure and starter config
  - Installs bundled PD translations (copies from `bundled/` to data root)
  - Downloads Arabic base text from quran-api (or Tanzil as fallback)
  - Enters interactive translation selection (lists catalog, user picks additional translations to download)
- `quran-tafseer-mcp init [--data <path>] --bundled-only`
  - Installs bundled corpora only, skips downloads (offline-friendly)
- `quran-tafseer-mcp init [--data <path>] --all`
  - Installs bundled + downloads all catalog translations (non-interactive)
- `quran-tafseer-mcp setup`
  - Re-run setup on an existing data root (e.g., to download additional translations)

### Catalog browsing
- `quran-tafseer-mcp catalog list`
  - Lists all available translations from the static catalog with install status
- `quran-tafseer-mcp catalog refresh`
  - Regenerates the catalog file (development use)

### Corpus management
- `quran-tafseer-mcp corpus add [--data <path>] --id <id> --kind translation --lang en --file <path> --format tsv_surah_ayah_text --title "..." --translator "..."`
- `quran-tafseer-mcp corpus list [--data <path>]`
- `quran-tafseer-mcp corpus validate [--data <path>] [--id <id>]`
- `quran-tafseer-mcp index build [--data <path>] [--id <id>|--all]`
- `quran-tafseer-mcp index status`

### MCP run
- `quran-tafseer-mcp mcp [--data <path>] [--log-level info|debug]`
  - When `--data` is omitted, uses the platform-default data root.
  - The MCP server always completes the `initialize` handshake first. After handshake, if the data root is empty or missing, the server:
    1. Auto-installs bundled corpora (silent, no network).
    2. Returns `quran.setup` in `tools/list` with a description indicating setup is recommended.
    3. If a non-setup tool is called before Arabic text is installed, returns a structured error with `code: -32001` and `message: "Setup incomplete. Call quran.setup with action 'status' for details."`.

---

## 8) Free Pascal implementation details

### Libraries/modules
- JSON: `fpjson`, `jsonparser`
- SQLite: `sqlite3` unit (or a small wrapper)
- Hashing: SHA-256 — self-contained implementation in `u_downloader.pas` (FPC 3.2.2 lacks `fpsha256`)
- HTTP: Platform-conditional — **WinINet** (native Windows API, no external deps) on Windows via `{$IFDEF MSWINDOWS}`, **fphttpclient + opensslsockets** on Linux/macOS (setup phase downloads only)

### Qur'an metadata unit
- `u_quran_metadata.pas` — Static Qur'an structural data:
  - Surah count (114)
  - Ayah count per surah (array of 114 integers)
  - Surah names: Arabic name, transliterated name(s), common English aliases
  - Used by `quran.resolve_ref` for name-to-number mapping and by all tools for bounds validation
  - This data is compiled into the binary (const arrays), not loaded from external files
  - Source: well-known canonical data, e.g., Tanzil's surah list or any standard Qur'an metadata

### Setup-related units
- `u_catalog.pas`: static translation catalog loading and querying (translations + Arabic editions)
- `u_downloader.pas`: HTTP download with domain allowlist, SHA-256 checksum verification, platform-conditional backend (WinINet on Windows, fphttpclient elsewhere)
- `u_tools_setup.pas`: tool handler for `quran.setup` (status, list_available, install_bundled, download_arabic, download)
- `u_corpus_installer.pas`: corpus installation logic (bundled copy + downloaded import + format conversion + manifest generation)

### Corpus loading strategy

At startup, load all installed corpora into memory as arrays indexed by `(surah, ayah)`.
A single 6236-verse corpus in TSV format is ~1–3 MB; even with 30+ translations loaded,
total memory is well under 100 MB. This gives O(1) lookup for `get_ayah` without requiring
SQLite for basic reads.

Structure: a 2D array `verses[surah][ayah]` per corpus (114 surahs, variable ayah counts).
Alternatively, a flat array indexed by `(surah * 1000 + ayah)` with bounds checking.

SQLite indexes (introduced in M2) are used **only for FTS search**, not for verse lookup.

### Bundled directory discovery

The server locates `bundled/quran/` relative to the executable's directory:
`ExtractFilePath(ParamStr(0)) + 'bundled' + PathDelim + 'quran'`.

This works for both development (exe in project root or `build/`) and installed deployments.
An optional `--bundled-path <dir>` CLI flag overrides the default for non-standard layouts.

### Error codes
All application-specific error codes are defined in a shared constants unit and used by all tool handlers. See the **Error code table** in `docs/design_document.md` section 8 for the complete mapping of codes (-32001 through -32010) to constants and meanings.

### Stdio JSON-RPC loop
- Read requests from stdin
- Parse JSON
- Dispatch method → handler
- Write responses to stdout
- **Never** write logs to stdout (stderr only)

### Framing
- **Implemented:** Newline-delimited JSON (per MCP spec 2024-11-05). Each JSON-RPC message is one line terminated by LF.
- Content-Length framing may be added behind a flag later if a client requires it.

---

## 9) Claude Code and Codex integration

### Claude Code (stdio server)
Document a sample config and CLI add command in README, including:
- Server command: `quran-tafseer-mcp mcp` (uses platform-default data root; no `--data` needed)
- Override with `--data <path>` for custom locations.
- Example: `claude mcp add quran-tafseer-mcp -- /path/to/quran-tafseer-mcp mcp`

### Codex (stdio server)
Document:
- How to add server in `~/.codex/config.toml` or via `codex mcp add ...`
- Same command line as above.

(Exact commands may vary with client versions; keep README examples updated.)

---

## 10) Repository, licensing, and safety posture

### Repo licensing
- Code: GPL-v3
- Corpora: **do not include** copyrighted translations in the public repo.
- `bundled/` directory: contains **only** public-domain and Gutenberg-licensed texts. These are tracked in git.
  - Wikisource PD: Palmer, Rodwell, Sale
  - Project Gutenberg: Yusuf Ali, Pickthall, Shakir (Gutenberg license terms preserved in each corpus directory)
- `catalog/` directory: static translation catalog file, tracked in git.

### Git hygiene
- `.gitignore`:
  - `bin/`
  - `indexes/`
  - `data/corpora_private/`
  - any user-imported corpora folders
- `bundled/quran/` and `catalog/` are tracked in git (PD/Gutenberg content only).

### User responsibility (README)
- Users must import only texts they are entitled to use.
- The tool stores originals unchanged and does not redistribute.
- Downloaded translations are fetched from their original source sites; the server does not host or mirror them.

---

## 11) Testing plan

### Unit tests
- JSON-RPC parsing/serialization
- Reference parsing (`resolve_ref`)
- Corpus format parsing (TSV/JSONL)
- Index lookup correctness for random verses
- Search returns deterministic refs/snippets

### Integration tests
- Launch server subprocess
- Call `initialize`, `tools/list`, `tools/call` for:
  - `list_translations`
  - `get_ayah`
  - `search`

### Golden tests (optional)
- For a small sample corpus, verify exact output strings match expected (ensures no accidental normalization).

### Test framework
FPCUnit (ships with Free Pascal). Test runner is a separate console program (`quran-tafseer-mcp_tests.lpr`) that runs all test suites.

### Test corpus fixtures
A minimal test corpus (`tests/fixtures/`) with:
- A 3-surah Arabic stub (surahs 1, 2, 114 — first and last 2 ayat only)
- A matching 3-surah English stub
- Pre-built manifests for both

#### Fixture directory layout
```
tests/fixtures/
  ar.test/
    original.tsv          # Arabic stub (placeholder transliteration)
    manifest.json
  en.test/
    original.tsv          # English stub (synthetic phrases)
    manifest.json
```

#### Exact ayah coverage (18 verses per corpus)
| Surah | Name | Ayat included | Count | Rationale |
|-------|------|--------------|-------|-----------|
| 1 | Al-Fatihah | 1–7 (all) | 7 | Too short to truncate |
| 2 | Al-Baqarah | 1–3, 255–256 | 5 | Covers surah start + Ayat al-Kursi (well-known test case) |
| 114 | An-Nas | 1–6 (all) | 6 | Too short to truncate; exercises last-surah boundary |

**Total:** 18 test verses per corpus.

#### Content conventions
- **Arabic (`ar.test`):** Uses placeholder ASCII transliteration (not real Arabic) to avoid encoding issues in test output. Example: `1\t1\t[ar.test] Q 1:1 bismillah placeholder`.
- **English (`en.test`):** Uses synthetic phrases with embedded refs for easy assertion matching. Example: `2\t255\t[en.test] Q 2:255 test text`.
- **Manifests:** Both use `"origin": "test_fixture"`, `"format": "tsv_surah_ayah_text"`, and a precomputed `"checksum"` matching their respective `original.tsv` files.

### Integration test approach
Launch the server binary as a subprocess, send JSON-RPC messages over stdin, read responses from stdout. Use the test fixtures as the data root. A helper unit `u_test_harness.pas` wraps subprocess I/O and JSON-RPC assertion helpers.

---

## 12) Milestones (suggested)

> **Maintenance rule:** When a milestone is completed, mark it with "✅ COMPLETED" in its heading and update the bullet points to reflect what was actually delivered (including any deviations from the original plan). This keeps the plan accurate as a living document.

### Pre-milestone — Corpus preparation and catalog seeding ✅ COMPLETED

This pre-milestone covers all scripted data preparation that must happen before M1.5a can start. The deliverables are committed to the repo and used by later milestones.

**Key discovery:** The [fawazahmed0/quran-api](https://github.com/fawazahmed0/quran-api) project provides 440+ translations in 90+ languages — including all 6 bundled PD translations and Arabic base text — in a uniform JSON format via CDN. Licensed under **The Unlicense** (public domain dedication). This replaces the original plan of scraping Wikisource + parsing Gutenberg + downloading from Tanzil/QuranEnc. **quran-api is now the single primary source** for both bundled corpora and the downloadable catalog.

#### Bundled corpus preparation

All 6 public-domain translations were downloaded from quran-api CDN (`json_chapter_verse_text` format), converted to `tsv_surah_ayah_text`, verified (6236 lines each, correct surah/ayah sequence), and stored with SHA-256 checksums.

- **Source:** quran-api CDN (format: `{"quran": [{"chapter": N, "verse": N, "text": "..."}]}`)
- **Conversion:** `scripts/prepare_bundled.py` downloads, converts JSON → TSV, verifies, computes SHA-256, generates manifests
- **Bundled translations:** Palmer, Rodwell, Sale (Wikisource PD), Yusuf Ali, Pickthall, Shakir (Gutenberg)
- Each `bundled/quran/<id>/` contains `original.tsv` (6236 lines) + `manifest.json`

#### Catalog seeding

`catalog/translations.json` was built by `scripts/seed_catalog.py` with:
- 50 English translations from quran-api (6 bundled, 44 downloadable)
- 3 Arabic editions (Uthmani Hafs, Simple, Uthmani minimal diacritics)
- Bundled entries include `bundled_checksum` (SHA-256 of installed TSV)
- Download source checksums are `null` (populated on-demand during M1.5b seeding)
- Tanzil added as secondary source for 13 translations that exist on both providers

#### Scripts (developer tools, not shipped)

| Script | Purpose |
|--------|---------|
| `scripts/prepare_bundled.py` | Downloads 6 PD translations from quran-api CDN, converts to TSV, verifies, generates manifests |
| `scripts/seed_catalog.py` | Builds `catalog/translations.json` from hardcoded edition list + bundled checksums |

These scripts live in `scripts/` and are gitignored from releases.

#### Deliverables
- `bundled/quran/` with 6 subdirectories, each containing `original.tsv` + `manifest.json`
- `catalog/translations.json` with 50 English translations + 3 Arabic editions
- Developer scripts in `scripts/`

#### Dependencies
- **Prerequisite for M1:** Needs at least one English corpus to test `get_ayah`. ✅ Available.
- **Prerequisite for M1.5a:** Needs all 6 bundled corpora. ✅ Available.
- **Catalog seeding prerequisite for M1.5b:** Needs download source checksums populated (currently `null`, will be filled by a seeding pass).

### Milestone 0 — Skeleton ✅ COMPLETED
- Repo scaffolding
- Stdio JSON-RPC loop (newline-delimited JSON per MCP spec, not Content-Length)
- `tools/list` returns empty set
- Basic logging to stderr with level filtering
- `u_quran_metadata.pas`: static surah data (names, ayah counts, aliases) compiled into the binary
- MCP dispatch: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`
- CLI: `quran-tafseer-mcp mcp [--data <path>] [--log-level]`, `--help`, `--version`
- Parse error handling: malformed JSON returns `-32700` and server continues
- Integration test script: `tests/test_m0.sh` (6 tests, all passing)

### Milestone 1 — Corpus + lookup ✅ COMPLETED
- `u_corpus_manifest.pas`: Manifest parsing from `manifest.json` with validation (id, kind, language, title, format, author/translator, checksum, origin)
- `u_corpus_reader.pas`: TSV reader loading verses into flat array indexed by `surah*1000+ayah` for O(1) lookup
- `u_corpus_store.pas`: Corpus store scanning `<data_root>/corpora/quran/` for subdirectories, loading manifests + verse data, providing `FindCorpus()`, `LookupVerse()`, `GetCorpusByIndex()`
- `u_tools_quran.pas`: Tool handlers for all three M1 tools
- `quran.list_translations`: Lists installed translation and Arabic corpora with metadata, supports `lang` filter
- `quran.get_ayah`: Fetches Arabic + N translations for a single verse with citations; supports `translations` (array or `"all"`), `include_arabic`, `arabic_id` params; proper error handling for out-of-range and missing corpora
- `quran.resolve_ref`: Normalizes references in multiple formats (`2:255`, `Q 2:255`, `Al-Baqarah 255`, surah name only); returns canonical `(surah, ayah)` with surah metadata
- Tool schemas registered in `tools/list` with full JSON Schema `inputSchema` definitions
- Test fixtures: `ar.test` and `en.test` corpora (18 verses each covering surahs 1, 2, 114)
- Integration test: `tests/test_m1.sh` (31 tests, all passing)

### Milestone 1.5a — Bundled corpora + catalog (no network) ✅ COMPLETED
- `u_catalog.pas`: Catalog loading from `catalog/translations.json` (53 entries: 50 English + 3 Arabic), querying by ID/index, language filtering, install-status cross-referencing with corpus store
- `u_corpus_installer.pas`: Bundled corpus installation with idempotency (skips if `manifest.json` exists at destination), stream-based file copy, install report (installed/skipped/errors)
- `u_tools_setup.pas`: `quran.setup` MCP tool handler with action-based dispatch — `status`, `list_available`, `install_bundled` fully implemented; `download_arabic` and `download` return "not available" stubs (deferred to M1.5b)
- `u_corpus_store.pas`: Added `SetBundledPath`/`GetBundledPath` for bundled path storage
- `u_tools_quran.pas`: Exported `BuildToolResult`, `BuildToolError`, `MakeTextContent` to interface (shared with `u_tools_setup`)
- `u_mcp.pas`: Exported `MakeStringProp`, `MakeIntProp`, `MakeBoolProp` to interface; registered `quran.setup` in `tools/list` (4 tools total); added setup-incomplete guard (`ERR_SETUP_INCOMPLETE` / `-32001` when `GetCorpusCount = 0` and tool is not `quran.setup`)
- `quran-tafseer-mcp.lpr`: Auto-trigger on MCP start (installs bundled corpora if data root is empty after `initialize` handshake); `--bundled-path` CLI override; catalog loading from `catalog/translations.json`; CLI `init --bundled-only` command
- Bundled corpus directory: 6 PD translations in `bundled/quran/` (en.palmer.1880, en.rodwell.1861, en.sale.1734, en.yusufali.1934, en.pickthall.1930, en.shakir)
- Static translation catalog: `catalog/translations.json` with 53 entries
- Integration test: `tests/test_m1_5a.sh` (32 tests across 8 sections, all passing)
- Backward compatible: M0 tests (6/6) and M1 tests (31/31) still pass

### Milestone 1.5b — Downloader + setup tool (network access) ✅ COMPLETED
- `u_downloader.pas`: HTTP download with domain allowlist (HTTPS only, 4 allowed domains), self-contained SHA-256 implementation (~130 lines, no external dependency), platform-conditional HTTP backend: **WinINet** on Windows (native TLS, no OpenSSL required), **fphttpclient + opensslsockets** on Linux/macOS
- `u_catalog.pas`: Extended to parse `"arabic"` array from catalog JSON (3 Arabic editions: ar.uthmani, ar.simple, ar.uthmani.min); added `FindArabicEntry()`, `GetArabicCatalogCount()`, `FindPreferredSource()` for source selection
- `u_corpus_installer.pas`: Format converters for quran-api JSON (`json_chapter_verse_text` → TSV) and Tanzil pipe format (`tsv_pipe_surah_ayah_text` → TSV); `DownloadAndInstallCatalogEntry()` orchestrates lookup → download → verify → convert → install with idempotency (skips if manifest exists); generated manifests include `origin: "downloaded"`, `download_source`, `download_date`
- `u_tools_setup.pas`: Replaced download stubs with working `HandleSetupDownloadArabic` (downloads ar.uthmani or custom `arabic_id`, re-scans store) and `HandleSetupDownload` (iterates `ids` array, collects per-ID results with installed/skipped/error status); updated tool schema with `ids` (array) and `arabic_id` (string) params
- `quran-tafseer-mcp.lpr`: Full `init` flow — Step 1 (bundled install, includes ar.uthmani) → Step 2 (load catalog) → Step 3 (if `--all`, download all catalog entries + non-bundled Arabic variants); continues on individual failures, exits 1 if any failed; added `u_downloader` to uses
- `quran-tafseer-mcp.lpi`: Added `u_downloader.pas` to project units
- `tests/test_m1_5a.sh`: Updated section E tests (download handlers no longer stubs)
- `tests/test_m1_5b.sh`: 21 tests across Tier 1 (offline, 11 tests: unknown ID error, no stub messages, empty/missing ids params, schema updated, init --all recognized) and Tier 2 (network, gated by `QURANREF_NETWORK_TESTS=1`, 10 tests: download ar.uthmani with 6236-line TSV + manifest verification, download en.sahih, re-download idempotency)
- **Deviation from plan:** No `u_setup.pas` created — download orchestration lives in `u_corpus_installer.pas` (`DownloadAndInstallCatalogEntry`) and `u_tools_setup.pas` (MCP handlers), keeping the architecture simpler
- **Platform fix:** Originally used `fphttpclient + opensslsockets` everywhere, but FPC 3.2.2 on Windows requires OpenSSL 1.1 DLLs which are no longer commonly available. Switched to WinINet on Windows (native TLS via `{$IFDEF MSWINDOWS}` conditional compilation) for zero-dependency HTTPS support
- Backward compatible: M0 (6/6), M1 (31/31), M1.5a (32/32) tests still pass

### Milestone 2 — Range + search ✅ COMPLETED
- `u_index_sqlite.pas`: SQLite FTS5 per-corpus indexing — `BuildIndex`, `BuildAllIndexes`, `SearchIndex`, `IndexExists` with `unicode61` tokenizer; schema: `verses(rowid, surah, ayah, text)` + `verses_fts` FTS5 virtual table; snippet extraction via `snippet()` function; rank conversion from FTS5 negative rank to positive score
- `u_tools_quran.pas`: `HandleGetRange` — single-surah verse range retrieval with dynamic verse limits based on translation count (1-2: 25, 3-6: 15, 7+: 10 verses max), truncation with `continuation` hint, per-corpus citation deduplication; `HandleSearch` — full-text search across selected translation corpora with cross-corpus result merging by (surah, ayah) key, per-corpus snippet collection, score-ranked output
- `u_mcp.pas`: `BuildToolSchema_GetRange` and `BuildToolSchema_Search` with full JSON Schema `inputSchema` definitions; dispatch entries in `HandleToolsCall`; tools/list now returns 6 tools; server version bumped to `0.3.0`
- `quran-tafseer-mcp.lpr`: Auto-build missing indexes at MCP startup after corpus store initialization; `index build` CLI subcommand (`quran-tafseer-mcp index build [--data <path>] [--id <corpus-id> | --all]`); updated usage text
- `quran-tafseer-mcp.lpi`: Added `u_index_sqlite.pas` to project units
- **Runtime dependency:** `sqlite3.dll` required on Windows (not shipped, user must provide); FPC `sqlite3` unit provides Pascal bindings with dynamic linking
- **Deviation from plan:** FTS5 `SQLITE_TRANSIENT` constant handled via inline type cast `sqlite3_destructor_type(Pointer(-1))` due to FPC 3.2.2 type system constraints
- Integration test: `tests/test_m2.sh` (35 tests across 6 sections: tools/list, get_range happy path, get_range errors, search happy path, search errors, index auto-build — all passing)
- Backward compatible: M0 (6/6), M1 (31/31), M1.5a (32/32) tests still pass

### Milestone 3 — Robust imports ✅ COMPLETED
- `u_corpus_reader.pas`: Added `LoadJsonlFile()` for JSONL format (`jsonl_surah_ayah_text`) — parses one JSON object per line (`{"surah":N,"ayah":N,"text":"..."}`), skips empty/comment lines, validates surah (1–114) and ayah (1–999) ranges, reports line numbers in warnings; wired into `LoadCorpus()` case statement; exported both `LoadTsvFile()` and `LoadJsonlFile()` in the interface for reuse by installer
- `u_corpus_manifest.pas`: Exported `ParseFormat()`, `FormatToStr()`, `KindToStr()`, `OriginToStr()` helper functions for format/kind/origin enum ↔ string conversion
- `u_corpus_installer.pas`: Added `ComputeFileChecksum()` (wraps `ComputeSha256Hex` from `u_downloader.pas` to hash a file, returns `sha256:<hex>`); added `InstallLocalCorpus()` — validates format, trial-loads file to verify it parses, copies to `<DataRoot>/corpora/quran/<id>/original.<ext>`, computes checksum, generates `manifest.json` with `origin: "manual_import"`
- `quran-tafseer-mcp.lpr`: Three new CLI subcommands under `corpus`:
  - `corpus list [--data <path>]`: scans `<DataRoot>/corpora/quran/` for manifests, prints id/title/author/language/kind/format/origin/checksum for each
  - `corpus validate [--data <path>] [--id <id>]`: validates single or all corpora — checks manifest fields, finds data file, recomputes SHA-256 and compares against `manifest.checksum`, loads and counts verses vs TOTAL_AYAH_COUNT (6236); reports VALID/INCOMPLETE/CHECKSUM MISMATCH/INVALID
  - `corpus add [--data <path>] --id <id> --file <path> --format <fmt> --title "..." [--translator "..."] [--kind translation] [--lang en]`: validates required params, trial-loads file, installs via `InstallLocalCorpus`, builds FTS5 index
- `u_mcp.pas`: Server version bumped to `0.4.0`
- Test fixtures: `tests/fixtures/en.testjsonl/` with `manifest.json` (format: `jsonl_surah_ayah_text`) and `original.jsonl` (18 verses matching en.test content)
- Integration test: `tests/test_m3.sh` (30 tests across 7 sections: JSONL loading via MCP, corpus list, corpus validate, corpus add TSV, corpus add JSONL, corpus add errors, version check — all passing)
- Backward compatible: M0 (6/6), M1 (31/31), M1.5a (32/32), M2 (35/35) tests still pass

### Milestone 4 — Client polish ✅ COMPLETED
- `u_format_terminal.pas`: Terminal rendering mode — converts structured JSON tool responses to preformatted text for terminal display. Arabic text on its own lines to avoid BiDi issues. Functions: `FormatGetAyahAsTerminal`, `FormatGetRangeAsTerminal`, `FormatSearchAsTerminal`, `FormatListTranslationsAsTerminal`, `FormatResolveRefAsTerminal`
- `format` parameter added to all tool schemas (`structured` default, `terminal` option) with JSON Schema enum validation
- `u_tools_quran.pas`: All 5 tool handlers (`list_translations`, `get_ayah`, `get_range`, `resolve_ref`, `search`) check `format` parameter and dispatch to terminal formatter or JSON serialization
- Dynamic verse limits for terminal mode in `get_range`: 1-2 translations → 15 verses, 3-6 → 10, 7+ → 7 (lower than structured mode's 25/15/10)
- `u_mcp.pas`: Server version bumped to `0.5.0`; `MakeFormatProp` helper builds the format property schema
- `README.md`: Complete project documentation — features, building, quick start, client setup (Claude Code CLI + config, Codex CLI + config, Windows path handling), CLI commands, output format examples, data layout, supported formats, license
- `.github/workflows/ci.yml`: GitHub Actions CI for Windows/Linux/macOS — builds with `lazbuild`, runs all test suites (M0–M4), uploads binary artifacts
- Integration test: `tests/test_m4.sh` (39 tests across 9 sections: version, schema format property, get_ayah terminal, get_range terminal, list_translations terminal, resolve_ref terminal, search terminal, default format, backward compatibility — all passing)
- Backward compatible: M0 (6/6), M1 (31/31), M1.5a (32/32), M2 (35/35), M3 (30/30) tests still pass

### Milestone 5 — diff ✅ COMPLETED
- `quran.diff` tool: Word-level diff between translations for a single verse. First translation in the array is the base; subsequent ones are compared against it using LCS (Longest Common Subsequence) algorithm.
- `u_tools_quran.pas`: Added `TDiffOpKind` (dokEqual/dokDelete/dokInsert), `TDiffOp` record, `TDiffOpArray`/`TWordArray` types, `Tokenize()` (whitespace splitter), `ComputeWordDiff()` (LCS-based word diff with merged consecutive ops), `HandleDiff()` (full tool handler with validation, diff computation, stats, terminal support)
- `u_format_terminal.pas`: Added `FormatDiffAsTerminal` — renders diff as `= equal`, `- delete`, `+ insert` markers with stats summary
- `u_mcp.pas`: Added `BuildToolSchema_Diff` (surah, ayah, translations array with minItems:2, format), registered in `HandleToolsList` and `HandleToolsCall` dispatch; server version bumped to `0.6.0`
- Output includes: ref, base corpus ID, diffs array (each with corpus_id, ops [{op, text}], stats {equal, deleted, inserted, similarity})
- Integration test: `tests/test_m5.sh` (27 tests across 6 sections: schema, basic diff, identical texts, error cases, terminal format, version — all passing)
- Backward compatible: M0 (6/6), M1 (31/31), M1.5a (32/32), M2 (35/35), M3 (30/30), M4 (39/39) tests still pass

---

## 13) Open questions to resolve early

### Resolved
- **Message framing:** Newline-delimited JSON (per MCP spec 2024-11-05). Content-Length was originally planned but the MCP spec requires newline-delimited for stdio transport.
- **Preferred on-disk corpus format:** TSV (`tsv_surah_ayah_text`) is the primary format. JSONL is supported. `line_114` format is deferred (see section 5).
- **MCP auto-trigger blocking:** The MCP server always completes the `initialize` handshake first. After handshake, if the data root is empty/missing, bundled corpora are installed silently, and `quran.setup` is advertised in `tools/list`. Non-setup tools return a structured error (`code: -32001`) until Arabic text is installed.
- **Gutenberg pre-parsing:** One-time script produces 3 separate TSV files (one per translation). See `docs/quran_translations_resource_list.md` section 3.

### Resolved (output size limits)
- **Maximum safe output for `get_range`:**
  - Claude Code default hard limit: 25,000 tokens (warning at 10K). Configurable via `MAX_MCP_OUTPUT_TOKENS`.
  - Codex CLI hard limit: ~10 KB (head+tail truncation at 128 lines each).
  - Estimated output per verse (Arabic + 6 translations): ~1,200 chars ≈ 300–350 tokens.
  - 50 verses × 6 translations ≈ 60 KB ≈ 17K tokens → exceeds Codex limit, borderline for Claude Code.
  - **Resolution:** Lower default `max_range_verses` from 50 to **20** (structured mode) and **15** (terminal mode). Consider dynamic scaling based on translation count:
    - 1–2 translations: up to 25 verses
    - 3–6 translations: up to 15 verses
    - 7+ translations: up to 10 verses
  - When the requested range exceeds the effective limit, return the first N verses plus pagination hints (`truncated: true`, `continuation` message, `total_requested` vs `total_returned`).
  - Optionally detect the client name from `initialize` → `clientInfo` and auto-lower limits for Codex (~8 verses).

### Resolved (Arabic variants)
- **Multiple Arabic variants:** Yes, support as separate corpora with IDs `ar.<variant>`.
  - quran-api and Tanzil both offer multiple Arabic script variants across two script families:
    - **Uthmani** (Rasm Uthmani — historical Quranic orthography): `uthmani` (full diacritics), `uthmani.min` (minimal diacritics)
    - **Simple/Imlaei** (Rasm Imla'i — modern Arabic orthography): `simple` (full), and others
  - **v1 default:** `ar.uthmani` (Hafs reading, matches the Medina Mushaf, used by Quran.com, most widely recognized).
  - **v1 scope:** Download and install only Uthmani. The catalog lists 3 Arabic editions for optional install via `quran.setup` (from quran-api).
  - **FTS indexing (M2):** Optionally use a simplified Arabic text (consonantal skeleton only) as the normalization source for Arabic FTS. The index uses clean text for matching; the server always returns the user's selected variant (typically Uthmani) in results.
  - Catalog Arabic IDs: `ar.uthmani`, `ar.simple`, `ar.uthmani.min`.

### Resolved (download URLs)
- **Exact download URL formats per provider:**

  **quran-api (primary — no auth, JSON via CDN):**
  - Editions list: `GET https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions.json`
  - Per-edition: `GET https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions/{key}.json`
    - Response: `{"quran": [{"chapter": 1, "verse": 1, "text": "..."}]}`. UTF-8. 6236 entries.
    - The downloader converts JSON to TSV when writing `original.tsv`.
  - 52 English translations + multiple Arabic editions available.
  - License: The Unlicense (public domain dedication). Individual translation copyrights may still apply.

  **Tanzil (secondary — no auth, pipe-delimited text):**
  - Translations: `GET https://tanzil.net/trans/?transID={lang.id}&type=txt-2`
    - Response: pipe-delimited (`surah|ayah|text`), one verse per line, comments (`#`) at end of file. UTF-8. 6236 data lines.
    - The downloader converts `|` delimiter to `\t` when writing `original.tsv`.
  - Arabic text: `POST https://tanzil.net/download/` with form body `quranType={variant}&outType=txt-2&agree=true`
    - Optional flags: `marks` (pause marks), `sajdah`, `rub` (rub-el-hizb), `alef` (superscript alif)
    - Same pipe-delimited response format.
  - Available English translation IDs: `en.ahmedali`, `en.ahmedraza`, `en.arberry`, `en.daryabadi`, `en.hilali`, `en.itani`, `en.maududi`, `en.mubarakpuri`, `en.pickthall`, `en.qarai`, `en.qaribullah`, `en.sahih`, `en.sarwar`, `en.shakir`, `en.transliteration`, `en.wahiduddin`, `en.yusufali`
  - Terms: Arabic text is CC BY 3.0 (attribution to Tanzil Project required). Translation redistribution terms vary per translator.

  **QUL/Tarteel (secondary — API only, no auth for API; bulk download requires login):**
  - List translations: `GET https://qul.tarteel.ai/api/v1/resources/translations` → JSON with `translations` array (~193 entries, all languages).
  - Per-surah fetch: `GET https://qul.tarteel.ai/api/v1/translations/{resource_id}/by_range?from={s}:{a}&to={s}:{a}` → JSON.
  - Full-Quran download requires 114 API calls (one per surah). Text may contain HTML `<sup>` footnote tags that need stripping.
  - Bulk file downloads (JSON/SQLite) require authentication — not usable for unattended downloads.

  **QuranEnc (secondary — no auth, CSV or SQLite):**
  - Bulk download: `GET https://quranenc.com/en/home/download/{format}/{translation_key}`
    - Formats: `csv`, `xml`, `sqlite`, `excel` (not `json`).
    - CSV: header row `id,sura,aya,translation,footnotes` after a comment block. UTF-8. Standard CSV quoting.
    - SQLite: table `translations(id, sura, aya, translation, footnotes)`. 6236 rows.
    - Filenames are versioned (e.g., `english_saheeh_v1.1.2-csv.1.csv`).
  - Per-surah API: `GET https://quranenc.com/api/v1/translation/sura/{translation_key}/{sura_number}` → JSON with `result` array (includes `arabic_text` alongside `translation`).
  - Available English keys: `english_saheeh`, `english_hilali_khan`, `english_rwwad`, `english_waleed` (4 English translations; 151 total across all languages).
  - Terms: Redistributable with attribution. Modification of translated text not allowed.

### Still open
(None — all open questions from the original plan have been resolved.)
