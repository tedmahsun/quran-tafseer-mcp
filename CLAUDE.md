# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A **neutral Quran Tafseer MCP server** written in **Free Pascal** (Lazarus IDE). Provides side-by-side comparison of Arabic base text and many English translations over the MCP stdio protocol. The server provides **materials only** — no interpretation, commentary, or tafseer.

Primary MCP clients: **Claude Code** and **Codex**.

## Core Design Constraints

- **Immutability:** Original corpus texts are stored and returned verbatim. No edits, normalization, reflow, or diacritics stripping in source files. Derived artifacts (indexes, caches) live separately and are regenerable.
- **Local-only at runtime:** All corpora are read from disk. No network calls during runtime tool execution. The only exception is the **setup phase** (first-run init, `quran.setup` tool), which may download corpora from allowlisted domains (`cdn.jsdelivr.net` for quran-api, `tanzil.net`, `qul.tarteel.ai`, `quranenc.com`).
- **Bundled corpora:** Six public-domain English translations and the Arabic base text (`ar.uthmani`, Uthmani script, Hafs reading) ship in `bundled/quran/` and are installed automatically on first run.
- **Neutrality:** Outputs are primary-source text + provenance only.

## Architecture

### Transport
- **stdio** JSON-RPC (newline-delimited JSON per MCP spec 2024-11-05)
- All logs to stderr; never write non-protocol output to stdout

### MCP Tools (v1.0.0, 7 tools)
| Tool | Purpose |
|------|---------|
| `quran.list_translations` | List installed translation/Arabic corpora |
| `quran.get_ayah` | Fetch Arabic + N translations for a single verse |
| `quran.get_range` | Fetch a passage (dynamic limit based on translation count) |
| `quran.search` | FTS across selected corpora, returns refs + snippets |
| `quran.resolve_ref` | Normalize references ("Al-Baqarah 255" → Q 2:255) |
| `quran.diff` | Word-level diff between translations (LCS-based) |
| `quran.setup` | First-run setup: browse catalog, install bundled corpora, download translations |

### Source Units
| Unit | Responsibility |
|------|---------------|
| `u_jsonrpc.pas` | Newline-delimited JSON-RPC parsing/serialization |
| `u_mcp.pas` | MCP method dispatch (initialize, tools/list, tools/call) |
| `u_log.pas` | Logging to stderr with level filtering |
| `u_quran_metadata.pas` | Static Qur'an structural data (surah names, ayah counts, aliases) |
| `u_corpus_manifest.pas` | Manifest parsing + validation, format/kind/origin string helpers |
| `u_corpus_reader.pas` | TSV + JSONL corpus readers |
| `u_corpus_store.pas` | Corpus store: scan, load, lookup by ID or index |
| `u_catalog.pas` | Static translation catalog loading and querying (50 EN + 3 AR) |
| `u_corpus_installer.pas` | Bundled copy + downloaded import + local install + format conversion |
| `u_downloader.pas` | HTTP download + SHA-256 checksum verification |
| `u_index_sqlite.pas` | SQLite FTS5 index build, lookup, search |
| `u_tools_quran.pas` | Tool handlers for quran.* tools (list, get_ayah, get_range, resolve_ref, search, diff) |
| `u_tools_setup.pas` | Tool handler for `quran.setup` |
| `u_format_terminal.pas` | Terminal rendering mode (JSON → preformatted text) |

### Data Layout

**In-repo (shipped with server):**
```
repo/
  bundled/quran/
    ar.uthmani/original.tsv + manifest.json
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

Corpus formats: `tsv_surah_ayah_text`, `json_chapter_verse_text` (quran-api), `jsonl_surah_ayah_text`.

### Indexing
SQLite + FTS5 per corpus. Normalization is index-only (lowercase, NFKC); raw text is always returned to users.

## Build and Run

Free Pascal / Lazarus project. Compiler-generated files (*.o, *.ppu, *.exe, etc.) are gitignored.

```bash
# Build
lazbuild quran-tafseer-mcp.lpi

# Run as MCP server (--data is optional; defaults to platform data dir)
quran-tafseer-mcp mcp [--data <path>] [--log-level info|debug]

# First-run setup
quran-tafseer-mcp init [--data <path>]                  # install bundled + download Arabic + interactive
quran-tafseer-mcp init [--data <path>] --bundled-only   # install bundled corpora only, no downloads
quran-tafseer-mcp init [--data <path>] --all            # install bundled + download all catalog translations

# CLI corpus management
quran-tafseer-mcp corpus add [--data <path>] --id <id> --file <path> --format tsv_surah_ayah_text --title "..." [--translator "..."] [--kind translation] [--lang en]
quran-tafseer-mcp corpus list [--data <path>]
quran-tafseer-mcp corpus validate [--data <path>] [--id <id>]
quran-tafseer-mcp index build [--data <path>] [--id <id>|--all]
```

**Default data root** (when `--data` is omitted):
- Windows: `%LOCALAPPDATA%\quran-tafseer-mcp`
- Linux/macOS: `$XDG_DATA_HOME/quran-tafseer-mcp` (or `~/.local/share/quran-tafseer-mcp`)

## Free Pascal Libraries
- JSON: `fpjson`, `jsonparser`
- SQLite: `sqlite3` unit (dynamic linking; `sqlite3.dll` required on Windows)
- Hashing: Self-contained SHA-256 in `u_downloader.pas` (FPC 3.2.2 lacks `fpsha256`)
- HTTP: **WinINet** on Windows (native TLS, no external deps), **fphttpclient + opensslsockets** on Linux/macOS (setup phase downloads only)

## Implementation Milestones (all complete)
- **M0:** Repo scaffolding, stdio JSON-RPC loop, `tools/list`, basic logging, `u_quran_metadata.pas`
- **M1:** Corpus manifests, `list_translations`, `get_ayah`, `resolve_ref`
- **M1.5a:** Bundled corpora + catalog (no network) — bundled install, `catalog/translations.json`, MCP auto-trigger
- **M1.5b:** Downloader + setup tool (network) — HTTP downloader, `quran.setup` MCP tool, `quran-tafseer-mcp init`
- **M2:** `get_range`, SQLite FTS5 indexing, `search`
- **M3:** JSONL reader, `corpus add/validate/list`, integrity reporting
- **M4:** Terminal output mode (`format: "terminal"`), README, CI builds
- **M5:** `quran.diff` — word-level LCS diff between translations

## Key Documents
- `docs/design_document.md` — Full design spec (tool schemas, corpus model, error model, security)
- `docs/implementation_plan.md` — Detailed implementation plan with milestones
- `docs/quran_translations_resource_list.md` — Where to obtain translation corpora
