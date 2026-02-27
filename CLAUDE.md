# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A **neutral Quran Tafseer MCP server** written in **Free Pascal** (Lazarus IDE). Provides side-by-side comparison of Arabic base text and many English translations over the MCP stdio protocol. The server provides **materials only** — no interpretation, commentary, or tafsir.

Primary MCP clients: **Claude Code** and **Codex**.

## Core Design Constraints

- **Immutability:** Original corpus texts are stored and returned verbatim. No edits, normalization, reflow, or diacritics stripping in source files. Derived artifacts (indexes, caches) live separately and are regenerable.
- **Local-only at runtime:** All corpora are read from disk. No network calls during runtime tool execution. The only exception is the **setup phase** (first-run init, `quran.setup` tool), which may download corpora from allowlisted domains (`tanzil.net`, `qul.tarteel.ai`, `quranenc.com`).
- **Bundled corpora:** Six public-domain English translations ship in `bundled/quran/` and are installed automatically on first run.
- **Neutrality:** Outputs are primary-source text + provenance only.

## Architecture

### Transport
- **stdio** JSON-RPC (Content-Length framing, LSP-style)
- All logs to stderr; never write non-protocol output to stdout

### MCP Tools (v1)
| Tool | Purpose |
|------|---------|
| `quran.list_translations` | List installed translation/Arabic corpora |
| `quran.get_ayah` | Fetch Arabic + N translations for a single verse |
| `quran.get_range` | Fetch a passage (max 50 verses per call) |
| `quran.search` | FTS across selected corpora, returns refs + snippets |
| `quran.resolve_ref` | Normalize references ("Al-Baqarah 255" → Q 2:255) |
| `quran.setup` | First-run setup: browse catalog, install bundled corpora, download translations |

### Planned Source Units
| Unit | Responsibility |
|------|---------------|
| `u_jsonrpc.pas` | Content-Length framing + JSON-RPC parsing/serialization |
| `u_mcp.pas` | MCP method dispatch (initialize, tools/list, tools/call) |
| `u_corpus_manifest.pas` | Manifest parsing + validation |
| `u_corpus_reader_*.pas` | Readers for TSV/JSONL/SQLite corpus formats |
| `u_index_sqlite.pas` | SQLite + FTS5 index build, lookup, search |
| `u_quran_metadata.pas` | Static Qur'an structural data (surah names, ayah counts, aliases) |
| `u_tools_quran.pas` | Tool handlers for all quran.* tools |
| `u_format_terminal.pas` | Terminal-friendly rendering mode |
| `u_setup.pas` | First-run detection, bundled install, download orchestration |
| `u_catalog.pas` | Static translation catalog loading and querying |
| `u_downloader.pas` | HTTP download + checksum verification |
| `u_tools_setup.pas` | Tool handler for `quran.setup` |
| `u_corpus_installer.pas` | Corpus installation (bundled copy + downloaded import) |

### Data Layout

**In-repo (shipped with server):**
```
repo/
  bundled/quran/
    en.palmer.1880/original.tsv + manifest.json
    en.rodwell.1861/original.tsv + manifest.json
    en.sale.1734/original.tsv + manifest.json
    en.yusufali.1934/original.tsv + manifest.json
    en.pickthall.1930/original.tsv + manifest.json
    en.shakir/original.tsv + manifest.json
  catalog/translations.json
```

**User data root (outside repo):**
```
user_data_root/
  corpora/quran/
    ar.<id>/original.<ext> + manifest.json
    en.<id>/original.<ext> + manifest.json
  indexes/quran/<corpus-id>.sqlite
  config/server.json
```

Corpus formats: `tsv_surah_ayah_text`, `jsonl_surah_ayah_text`, `sqlite` (read-only). (`line_114` deferred to M3+.)

### Indexing
SQLite + FTS5 per corpus. Normalization is index-only (lowercase, NFKC); raw text is always returned to users.

## Build and Run

Free Pascal / Lazarus project. Compiler-generated files (*.o, *.ppu, *.exe, etc.) are gitignored.

```bash
# Build (when source exists)
lazbuild quranref.lpi        # or: fpc <main_unit>.pas

# Run as MCP server
quranref mcp --data <DATA_ROOT> [--log-level info|debug]

# First-run setup (interactive: installs bundled, downloads Arabic, selects translations)
quranref init --data <path>
quranref init --data <path> --bundled-only   # install bundled corpora only, no downloads
quranref init --data <path> --all            # install bundled + download all catalog translations

# Setup on existing data root
quranref setup                               # re-run setup on existing data root

# Catalog browsing
quranref catalog list                        # list available translations from catalog
quranref catalog refresh                     # regenerate catalog (development use)

# CLI corpus management
quranref corpus add --id <id> --kind translation --lang en --file <path> --format tsv_surah_ayah_text --title "..." --translator "..."
quranref corpus list
quranref corpus validate [--id <id>]
quranref index build [--id <id>|--all]
```

## Free Pascal Libraries
- JSON: `fpjson`, `jsonparser`
- SQLite: `sqlite3` unit
- Hashing: SHA-256 (FPC built-in or vendored)
- HTTP: `fphttpclient` from `fcl-web` (setup phase downloads only)

## Implementation Milestones
- **M0:** Repo scaffolding, stdio JSON-RPC loop, `tools/list` returns empty set, basic logging, `u_quran_metadata.pas`
- **M1:** Corpus manifests, `list_translations`, `get_ayah` (one Arabic + one English corpus), `resolve_ref`
- **M1.5a:** Bundled corpora + catalog (no network) — bundled corpus install, `catalog/translations.json`, `quranref init --bundled-only`, MCP auto-trigger
- **M1.5b:** Downloader + setup tool (network access) — HTTP downloader, `quran.setup` MCP tool, `quranref init` full flow
- **M2:** `get_range`, SQLite indexing, `search` (English)
- **M3:** Robust imports (TSV + JSONL), `corpus add/validate`, integrity reporting
- **M4:** Terminal output mode, client setup docs, CI builds

## Key Documents
- `docs/design_document.md` — Full design spec (tool schemas, corpus model, error model, security)
- `docs/implementation_plan.md` — Detailed implementation plan with milestones
- `docs/quran_translations_resource_list.md` — Where to obtain translation corpora
