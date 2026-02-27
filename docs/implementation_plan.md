# Quran Tafseer MCP (Free Pascal) — Implementation Plan

> Scope: **Quran only (for now)**. No interpretation/tafsir. Local corpora. Side‑by‑side comparison across many English translations plus Arabic base text.

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
- Provide a **guided first-run experience** with bundled public-domain translations, automatic Arabic base text download, and interactive selection of additional translations from a static catalog.

### Non‑goals (explicit)
- No interpretation, meaning extraction, doctrinal claims, ranking “best” translation, or commentary generation.
- No hadith support in this phase.
- No online REST lookups during **runtime tool execution** (setup phase may download from allowlisted domains: `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`).

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
   - Arabic base text download from Tanzil
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
- `id` (string, stable): e.g., `ar.tanzil.uthmani`, `en.palmer.1880`, `en.user.yusufali`
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
  - `provider`: `"tanzil"` | `"tarteel"` | `"quranenc"`
  - `url`: download URL
  - `format`: `"tsv_surah_ayah_text"` | `"jsonl_surah_ayah_text"` | `"sqlite"`
  - `checksum`: SHA-256 of the expected downloaded file from this source
- `canonical_source`: preferred provider for download
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
     - `download_arabic`: download Arabic base text from Tanzil with checksum verification
     - `download`: download specific corpus IDs from catalog with checksum verification
   - Only tool permitted to make network calls (allowlisted domains only)

### Optional tool (v1.1+) — strictly descriptive
- `quran.diff`
  - Input: `{ "surah": X, "ayah": Y, "translations": ["..."] }`
  - Output: **machine-readable diffs only** (token spans/edits), no prose.

### Output formatting modes
Provide `format` argument for display convenience:
- `structured` (default): JSON objects
- `terminal`: preformatted text blocks (Arabic on its own lines to reduce BiDi headaches)

---

## 5) Corpus ingestion and immutability

### Supported import formats (v1)
- `tsv_surah_ayah_text`: `surah<TAB>ayah<TAB>text`
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
1. HTTP fetch from the canonical source URL (HTTPS only, allowlisted domains)
2. SHA-256 checksum verification against the source's `checksum` field in the catalog
3. Parse/convert to `original.tsv` if needed:
   - Tanzil `txt-2`: convert pipe delimiter (`|`) to tab (`\t`), strip comment lines (`#`) and blank lines
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
- `quranref build` (optional wrapper) or external scripts.

### First-run setup
- `quranref init --data <path>`
  - Creates folder structure and starter config
  - Installs bundled PD translations (copies from `bundled/` to data root)
  - Downloads Arabic base text from Tanzil
  - Enters interactive translation selection (lists catalog, user picks additional translations to download)
- `quranref init --data <path> --bundled-only`
  - Installs bundled corpora only, skips downloads (offline-friendly)
- `quranref init --data <path> --all`
  - Installs bundled + downloads all catalog translations (non-interactive)
- `quranref setup`
  - Re-run setup on an existing data root (e.g., to download additional translations)

### Catalog browsing
- `quranref catalog list`
  - Lists all available translations from the static catalog with install status
- `quranref catalog refresh`
  - Regenerates the catalog file (development use)

### Corpus management
- `quranref corpus add --id <id> --kind translation --lang en --file <path> --format tsv_surah_ayah_text --title "..." --translator "..."`
- `quranref corpus list`
- `quranref corpus validate [--id <id>]`
- `quranref index build [--id <id>|--all]`
- `quranref index status`

### MCP run
- `quranref mcp --data <path> [--log-level info|debug]`
  - The MCP server always completes the `initialize` handshake first. After handshake, if the data root is empty or missing, the server:
    1. Auto-installs bundled corpora (silent, no network).
    2. Returns `quran.setup` in `tools/list` with a description indicating setup is recommended.
    3. If a non-setup tool is called before Arabic text is installed, returns a structured error with `code: -32001` and `message: "Setup incomplete. Call quran.setup with action 'status' for details."`.

---

## 8) Free Pascal implementation details

### Libraries/modules
- JSON: `fpjson`, `jsonparser`
- SQLite: `sqlite3` unit (or a small wrapper)
- Hashing: SHA‑256 (use available FPC units or vendor a tiny implementation)
- HTTP: `fphttpclient` from `fcl-web` (setup phase downloads only)

### Qur'an metadata unit
- `u_quran_metadata.pas` — Static Qur'an structural data:
  - Surah count (114)
  - Ayah count per surah (array of 114 integers)
  - Surah names: Arabic name, transliterated name(s), common English aliases
  - Used by `quran.resolve_ref` for name-to-number mapping and by all tools for bounds validation
  - This data is compiled into the binary (const arrays), not loaded from external files
  - Source: well-known canonical data, e.g., Tanzil's surah list or any standard Qur'an metadata

### Setup-related units
- `u_setup.pas`: first-run detection, bundled corpus installation, download orchestration
- `u_catalog.pas`: static translation catalog loading and querying
- `u_downloader.pas`: HTTP download with checksum verification (allowlisted domains only)
- `u_tools_setup.pas`: tool handler for `quran.setup`
- `u_corpus_installer.pas`: corpus installation logic (bundled copy + downloaded import + manifest generation)

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
- Implement **Content-Length** style framing (LSP-like) if required by a client, otherwise newline-delimited JSON.
- Prefer implementing Content-Length framing to maximize compatibility.

---

## 9) Claude Code and Codex integration

### Claude Code (stdio server)
Document a sample config and CLI add command in README, including:
- Server command: `quranref mcp --data <user_data_root>`
- Ensure paths are absolute on Windows.

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
FPCUnit (ships with Free Pascal). Test runner is a separate console program (`quranref_tests.lpr`) that runs all test suites.

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

### Pre-milestone — Corpus preparation and catalog seeding

This pre-milestone covers all manual/scripted data preparation that must happen before M0 can start. The deliverables are committed to the repo and used by later milestones.

#### Bundled corpus preparation

The 6 public-domain translations in `bundled/quran/` do not yet exist. They must be parsed from their original sources into the `tsv_surah_ayah_text` format:

1. **Wikisource PD texts (Palmer, Rodwell, Sale):** Manual or scripted download from Wikisource. Parse HTML/wikitext into `surah<TAB>ayah<TAB>text` TSV. Store in `bundled/quran/en.<id>/original.tsv`.
2. **Gutenberg triple-pack (Yusuf Ali, Pickthall, Shakir):** Download from `gutenberg.org/ebooks/16955`. The plain-text file contains all three translations interleaved. A one-time parsing script splits them into 3 separate TSV files.
3. **Manifest generation:** For each bundled corpus, generate `manifest.json` with `origin: "bundled"`, computed SHA-256 checksum, and metadata (title, translator, year, license_note, format).
4. **Verification:** Each TSV must have exactly 6236 lines (one per verse). Surah/ayah pairs must match the canonical counts from `u_quran_metadata.pas`.

#### Catalog seeding (checksum population)

`catalog/translations.json` references SHA-256 checksums per download source. These checksums require actual file downloads to compute:

- **Bundled corpora:** Checksums are computed from the `original.tsv` files already in `bundled/quran/` — known at repo build time. These are filled in during bundled corpus preparation above.
- **Download sources (Tanzil, QuranEnc):** Checksums are computed once using a developer-only script (`scripts/seed_catalog.py`) that downloads each URL, computes SHA-256, and writes the checksums into `catalog/translations.json`.
- The seeding script runs once during initial catalog creation and again whenever a provider updates their files. It is **not** shipped to end users.
- Until the seeding script runs, catalog entries for downloadable sources use `"checksum": null` (meaning "not yet verified"). The downloader in M1.5b treats `null` checksum as "skip verification with a warning log."
- The seeding script is a **prerequisite for M1.5b** (not M1.5a, which is offline-only).

#### Scripts (developer tools, not shipped)

| Script | Purpose |
|--------|---------|
| `scripts/parse_wikisource.py` | One-time Wikisource HTML/wikitext → TSV parser for Palmer, Rodwell, Sale |
| `scripts/parse_gutenberg.py` | One-time Gutenberg plain-text splitter → 3 TSV files for Yusuf Ali, Pickthall, Shakir |
| `scripts/seed_catalog.py` | Downloads each catalog source URL, computes SHA-256, writes checksums into `catalog/translations.json` |

These scripts live in `scripts/` and are gitignored from releases.

#### Deliverables
- `bundled/quran/` with 6 subdirectories, each containing `original.tsv` + `manifest.json`
- `catalog/translations.json` with checksums for bundled sources filled in (download source checksums may be `null` initially)
- Developer scripts in `scripts/`

#### Dependencies
- **Prerequisite for M1:** Needs at least one English corpus to test `get_ayah`.
- **Prerequisite for M1.5a:** Needs all 6 bundled corpora.
- **Catalog seeding prerequisite for M1.5b:** Needs download source checksums populated.

### Milestone 0 — Skeleton
- Repo scaffolding
- Stdio JSON-RPC loop
- `tools/list` returns empty set
- Basic logging
- `u_quran_metadata.pas`: static surah data (names, ayah counts, aliases) compiled into the binary

### Milestone 1 — Corpus + lookup
- Corpus manifests
- `quran.list_translations`
- `quran.get_ayah` from one Arabic corpus + one English corpus
- `quran.resolve_ref` (depends only on `u_quran_metadata.pas` static data, not on corpora or indexes)

### Milestone 1.5a — Bundled corpora + catalog (no network)
- Bundled corpus directory with 6 PD translations (pre-parsed TSV + manifests) in `bundled/quran/`
- Static translation catalog (`catalog/translations.json`)
- `u_catalog.pas`: catalog loading, querying, install-status tracking
- `u_corpus_installer.pas`: corpus installation logic (bundled copy + manifest validation)
- `quranref init --bundled-only` CLI flow
- Auto-trigger on MCP start: complete `initialize` handshake first, then install bundled corpora if data root is empty

### Milestone 1.5b — Downloader + setup tool (network access)
- `u_downloader.pas`: HTTP client + SHA-256 checksum verification
- `u_setup.pas`: first-run detection, download orchestration
- `u_tools_setup.pas`: `quran.setup` MCP tool handler (all 5 sub-actions)
- `quranref init` full flow (bundled install + Arabic download + interactive selection)
- `quranref init --all` flag
- `quran.setup` MCP tool (all sub-actions: status, list_available, install_bundled, download_arabic, download)

### Milestone 2 — Range + search
- `quran.get_range`
- SQLite indexing
- `quran.search` (English)

### Milestone 3 — Robust imports
- `corpus add/validate`
- Support TSV + JSONL
- Better error messages & integrity reporting

### Milestone 4 — Client polish
- `format:"terminal"` output mode
- Documentation for Claude Code + Codex setup
- CI builds on Windows/Linux/macOS

### Milestone 5 (optional) — diff
- `quran.diff` with machine-readable diffs only

---

## 13) Open questions to resolve early

### Resolved
- **Message framing:** Content-Length (LSP-style) is the default. Newline-delimited JSON may be supported behind a flag.
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
- **Multiple Arabic variants:** Yes, support as separate corpora with IDs `ar.tanzil.<variant>`.
  - Tanzil offers 6 variants across two script families:
    - **Uthmani** (Rasm Uthmani — historical Quranic orthography): `uthmani` (full diacritics), `uthmani-min` (minimal diacritics)
    - **Simple/Imlaei** (Rasm Imla'i — modern Arabic orthography): `simple` (full), `simple-enhanced` (no tajweed markers), `simple-min` (minimal), `simple-clean` (no diacritics at all)
  - **v1 default:** `ar.tanzil.uthmani` (matches the Medina Mushaf, used by Quran.com, most widely recognized).
  - **v1 scope:** Download and install only Uthmani. The catalog lists all 6 for optional install via `quran.setup`.
  - **FTS indexing (M2):** Optionally use `ar.tanzil.simple-clean` (consonantal skeleton only) as the normalization source for Arabic FTS. The index uses clean text for matching; the server always returns the user's selected variant (typically Uthmani) in results.
  - Proposed corpus IDs: `ar.tanzil.uthmani`, `ar.tanzil.uthmani-min`, `ar.tanzil.simple`, `ar.tanzil.simple-enhanced`, `ar.tanzil.simple-min`, `ar.tanzil.simple-clean`.

### Resolved (download URLs)
- **Exact download URL formats per provider:**

  **Tanzil (primary — no auth, pipe-delimited text):**
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
