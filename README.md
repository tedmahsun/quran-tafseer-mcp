# Quran Tafseer MCP Server

**v1.0.0**

A neutral Quran reference MCP server written in Free Pascal. Provides side-by-side comparison of Arabic base text and English translations over the MCP stdio protocol. The server provides **materials only** — no interpretation, commentary, or tafseer.

## Features

- **6 bundled public-domain translations** (Palmer, Rodwell, Sale, Yusuf Ali, Pickthall, Shakir)
- **Arabic base text** (Uthmani script, Hafs reading) bundled and installed automatically
- **50+ downloadable translations** from quran-api catalog
- **Full-text search** across all installed translations (SQLite FTS5)
- **Reference resolution** — accepts `2:255`, `Q 2:255`, `Al-Baqarah 255`
- **Two output modes** — structured JSON or terminal-friendly preformatted text
- **Zero network calls at runtime** — all data is local; downloads only during setup

## MCP Tools

| Tool | Description |
|------|-------------|
| `quran.list_translations` | List installed translation and Arabic corpora |
| `quran.get_ayah` | Fetch Arabic + translations for a single verse |
| `quran.get_range` | Fetch a passage (dynamically limited by translation count) |
| `quran.search` | Full-text search with snippets and relevance scores |
| `quran.resolve_ref` | Normalize references to canonical `(surah, ayah)` form |
| `quran.setup` | First-run setup: install bundled, download Arabic/translations |

All tools accept `format: "terminal"` for preformatted text output (default: `"structured"` JSON).

## Building

This project is written in [Free Pascal](https://www.freepascal.org/) and uses the [Lazarus](https://www.lazarus-ide.org/) build tool `lazbuild`. If you don't have these installed, here's how to set up for each platform.

### Building from source

No binaries are provided so you will need to build from source.

#### Windows

Install Free Pascal and Lazarus using the combined installer from [SourceForge](https://sourceforge.net/projects/lazarus/files/). Choose the latest Lazarus release (3.6+), which bundles Free Pascal 3.2.2. After install, ensure `lazbuild` is on your PATH (typically `C:\Lazarus\lazbuild.exe`).

```bash
lazbuild quran-tafseer-mcp.lpi
```

#### Linux (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y fpc lazarus libsqlite3-0
lazbuild quran-tafseer-mcp.lpi
```

#### macOS

```bash
brew install fpc lazarus sqlite
lazbuild quran-tafseer-mcp.lpi
```

### Runtime dependency

**sqlite3** — required for full-text search. On Windows, place `sqlite3.dll` alongside the executable (download from [sqlite.org](https://www.sqlite.org/download.html)). On Linux/macOS it's typically already installed; if not, use `apt install libsqlite3-0` or `brew install sqlite`.

## Quick Start

```bash
# First-run setup: install bundled translations only (no network)
quran-tafseer-mcp init --bundled-only

# First-run setup: install bundled + download all catalog translations
quran-tafseer-mcp init --all

# Run as MCP server
quran-tafseer-mcp mcp
```

All commands use a **platform-default data root** when `--data` is omitted:
- **Windows:** `%LOCALAPPDATA%\quran-tafseer-mcp`
- **Linux/macOS:** `$XDG_DATA_HOME/quran-tafseer-mcp` (or `~/.local/share/quran-tafseer-mcp`)

Override with `--data <path>` if you want a custom location.

## Client Setup

Since `--data` is optional (the server uses a platform-default data root), client configuration is simple — no need to hardcode a data path.

### Claude Code

**Option 1: CLI (recommended)**

```bash
claude mcp add quran-tafseer-mcp -- /path/to/quran-tafseer-mcp mcp
```

**Option 2: Settings file** (project `.mcp.json`)

```json
{
  "mcpServers": {
    "quran-tafseer-mcp": {
      "command": "/path/to/quran-tafseer-mcp",
      "args": ["mcp"]
    }
  }
}
```

**Windows example:**

```json
{
  "mcpServers": {
    "quran-tafseer-mcp": {
      "command": "C:/path/to/quran-tafseer-mcp.exe",
      "args": ["mcp"]
    }
  }
}
```

To use a custom data root, add `"--data", "/path/to/data"` to the `args` array.

### Codex

```bash
codex mcp add quran-tafseer-mcp -- /path/to/quran-tafseer-mcp mcp
```

Or in `~/.codex/config.toml`:

```toml
[mcp_servers.quran-tafseer-mcp]
command = "/path/to/quran-tafseer-mcp"
args = ["mcp"]
```

### First run via MCP

On first MCP connection with an empty data root, the server automatically installs the 7 bundled corpora (6 English translations + Arabic base text). To download additional translations, ask your AI assistant to call `quran.setup`.

## CLI Commands

All commands use the platform-default data root when `--data` is omitted.

```bash
# MCP server
quran-tafseer-mcp mcp [--data <path>] [--log-level error|warn|info|debug]

# First-run setup
quran-tafseer-mcp init [--data <path>]                 # interactive setup
quran-tafseer-mcp init [--data <path>] --bundled-only  # bundled corpora only (no network)
quran-tafseer-mcp init [--data <path>] --all           # bundled + download all catalog translations

# Corpus management
quran-tafseer-mcp corpus list [--data <path>]
quran-tafseer-mcp corpus validate [--data <path>] [--id <id>]
quran-tafseer-mcp corpus add [--data <path>] --id <id> --file <path> --format <fmt> --title "..."

# Search index management
quran-tafseer-mcp index build [--data <path>] [--id <id> | --all]

# Other
quran-tafseer-mcp --version
quran-tafseer-mcp --help
```

## Output Format

All tools accept a `format` parameter:

- **`structured`** (default) — JSON objects with full data and citations
- **`terminal`** — preformatted text blocks optimized for terminal display. Arabic text is placed on its own lines to avoid BiDi rendering issues.

Example terminal output for `quran.get_ayah`:

```
-- Q 1:1 --

[Arabic · ar.uthmani]
بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ

[en.yusufali.1934]
In the name of Allah, Most Gracious, Most Merciful.

[en.pickthall.1930]
In the name of Allah, the Beneficent, the Merciful.
```

## Data Layout

```
quran-tafseer-mcp-data/
  corpora/quran/
    ar.uthmani/original.tsv + manifest.json
    en.palmer.1880/original.tsv + manifest.json
    ...
  indexes/quran/
    ar.uthmani.sqlite
    en.palmer.1880.sqlite
    ...
```

## Supported Corpus Formats

| Format | Description |
|--------|-------------|
| `tsv_surah_ayah_text` | Tab-separated: `surah\tayah\ttext` |
| `jsonl_surah_ayah_text` | One JSON per line: `{"surah":N,"ayah":N,"text":"..."}` |
| `json_chapter_verse_text` | quran-api format (download only) |

## Credits

- [Quran API](https://github.com/fawazahmed0/quran-api)
- [Tanzil](https://tanzil.net/)
- [Quranic Universal Library](https://qul.tarteel.ai/)
- [QuranEnc.com](https://quranenc.com/en/home)
- [Nurul Zaman](https://github.com/hanisahkz)

## License

Code: GPL-3.0

Bundled corpora: Public domain (Wikisource) and Project Gutenberg license. See individual corpus directories for details.

Users are responsible for ensuring they have the right to use any additional translations they import.
