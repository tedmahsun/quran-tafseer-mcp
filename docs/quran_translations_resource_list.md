# Quran English Translations — Resource List

This list is for building a **local Quran Tafseer library** for **side-by-side comparison** (Arabic + many English translations).

Important sanity notes:
- "Freely accessible online" does **not** automatically mean "public domain" or "redistributable."
- For a public GitHub repo, only public-domain and explicitly licensed texts are shipped (in `bundled/`).
- For personal study, you can often download and store copies locally if the source permits it. Always read each site's terms.

---

## 1) Three tiers of translations

The server organizes translations into three tiers based on how they are acquired:

### Tier 1 — Bundled (shipped in repo, installed automatically)
Six public-domain English translations ship in `bundled/quran/` and are copied to the user's data root on first run. No network access required.

- E. H. Palmer (1880) — Wikisource, PD
- J. M. Rodwell (1861) — Wikisource, PD
- George Sale (1734) — Wikisource, PD
- Abdullah Yusuf Ali (1934) — Project Gutenberg
- Marmaduke Pickthall (1930) — Project Gutenberg
- M. H. Shakir — Project Gutenberg (date uncertain; year dropped from corpus ID)

### Tier 2 — Catalog-downloadable (user selects during setup)
All English translations available from Tanzil, Tarteel/QUL, and QuranEnc are listed in a static `catalog/translations.json` file shipped with the server. Users browse and select translations during first-run setup (via `quranref init` or `quran.setup` MCP tool). Downloads are from the original source sites, verified by SHA-256 checksum.

### Tier 3 — Manual import (user-acquired)
Any translation the user has obtained separately can be imported via `quranref corpus add`. This is the fallback for translations not in the catalog, copyrighted texts the user is licensed to use, or custom/personal translations.

---

## 2) Bundled public-domain translations (Wikisource)

These are historically distinct translations clearly marked public domain worldwide on Wikisource. They ship in `bundled/quran/` as pre-parsed TSV files with manifests.

| Corpus ID | Title | Translator | Source |
|-----------|-------|------------|--------|
| `en.palmer.1880` | The Qur'an (Palmer) | E. H. Palmer | https://en.wikisource.org/wiki/The_Qur%27an_(Palmer) |
| `en.rodwell.1861` | The Koran (Rodwell) | J. M. Rodwell | https://en.wikisource.org/wiki/The_Koran_(Rodwell) |
| `en.sale.1734` | The Koran (Sale) | George Sale | https://en.wikisource.org/wiki/Author:George_Sale |

**Import caution:** Older editions sometimes have odd formatting and may need careful parsing (without altering the text). Verse mapping is verified during the pre-parsing step.

---

## 3) Bundled Gutenberg translations

Three popular English translations from a single Project Gutenberg package, pre-parsed into 3 separate TSV corpora. Gutenberg license terms are preserved in each corpus directory.

| Corpus ID | Title | Translator | Source |
|-----------|-------|------------|--------|
| `en.yusufali.1934` | The Holy Qur'an | Abdullah Yusuf Ali | https://www.gutenberg.org/ebooks/16955 |
| `en.pickthall.1930` | The Meaning of the Glorious Koran | Marmaduke Pickthall | https://www.gutenberg.org/ebooks/16955 |
| `en.shakir` | The Quran (Shakir) | M. H. Shakir | https://www.gutenberg.org/ebooks/16955 |

**Note on Shakir dating:** The M.H. Shakir translation appeared in the Gutenberg package alongside Yusuf Ali and Pickthall. The exact standalone publication date is disputed (the 1866 date sometimes cited is incorrect — Shakir's work is 20th century). The year is dropped from the corpus ID to avoid encoding uncertain provenance.

**Note:** The Gutenberg package contains all three translations in one file. A pre-parsing step splits them into 3 separate TSV corpora. Gutenberg's distribution terms are specific to Gutenberg; individual translation copyrights can vary by jurisdiction/edition.

---

## 4) Catalog sources (providers the catalog draws from)

The static translation catalog (`catalog/translations.json`) aggregates translations from these three providers. Users do not need to visit these sites manually; the `quranref init` CLI and `quran.setup` MCP tool handle browsing, selection, and download.

### Tanzil
The primary source for a broad English-translation library. Provides downloadable text files in a consistent format.

- Translations page: https://tanzil.net/trans/
- Arabic text downloads (canonical base text): https://tanzil.net/download/
- Text license info (Arabic text): https://tanzil.net/docs/text_license
- FAQ (general policy notes): https://tanzil.net/docs/faq

### QUL (Tarteel)
Developer-friendly downloads (JSON / SQLite). Treats as an aggregator: provenance is recorded per translation.

- Resources overview: https://qul.tarteel.ai/resources
- Translations page: https://qul.tarteel.ai/resources/translation
- Example translation pack page: https://qul.tarteel.ai/resources/translation/92

### QuranEnc
Curated translations with a "no modification" posture that matches the project's immutability philosophy. Provides versioning.

- Home (includes terms block): https://www.quranenc.com/
- PDF downloads index: https://quranenc.com/en/pdf
- Example English browse page: https://quranenc.com/en/browse/english_saheeh

**Deduplication:** When the same translation appears on multiple providers, the catalog contains a single entry with multiple source URLs. The `canonical_source` field indicates the preferred download provider.

---

## 5) Quranist / Qur'an-only / reformist-adjacent translations (neutral inclusion)

These are included because the MCP aims to be **neutral and comprehensive**, not "mainstream-only."
**Reality check:** many of these are **copyrighted** even if they are downloadable. For a public repo, do not bundle them unless you have explicit permission. They may appear in the catalog if a provider hosts them, or can be manually imported.

### Sam Gerrans — "The Qur'an: A Complete Revelation" (Quranite)
- Online reader: https://reader.quranite.com/
- Download page (offers SQL/XML/JSON): https://reader.quranite.com/pages/download
- PDF edition (example): https://quranite.com/wp-content/uploads/The-Quran-A-Complete-Revelation-Ed-3.pdf

### Rashad Khalifa — "Quran: The Final Testament (Authorized English Version)"
- Official online reading (Masjid Tucson): https://www.masjidtucson.org/quran/noframes/
- Portal / versions info: https://www.masjidtucson.org/quran/

### Edip Yuksel / Layth Saleh al-Shaiban / Martha Schulte-Nafeh — "Quran: A Reformist Translation"
- Downloadable PDF (commonly referenced): https://www.studyquran.org/resources/Quran_Reformist_Translation.pdf

### The Monotheist Group — "The Great Quran" / "A Monotheist Translation"
- Internet Archive item: https://archive.org/details/the-great-quran

**Note:** Prefer sources that provide clear provenance and terms.

---

## 6) Acquisition workflow

The server supports three acquisition paths, in order of preference:

### Automatic first-run setup (recommended)
1. Run `quranref init --data <path>` (CLI) or let the MCP server auto-trigger on first start.
2. Bundled PD translations are copied from `bundled/quran/` to the data root automatically.
3. Arabic base text is downloaded from Tanzil (checksum-verified).
4. User is presented with the translation catalog and selects additional translations to download.
5. Selected translations are downloaded, verified, and indexed.

### MCP-guided setup (for Claude/Codex clients)
1. Client calls `quran.setup` with `action: "status"` to check setup state.
2. Client calls `action: "install_bundled"` and `action: "download_arabic"`.
3. Client calls `action: "list_available"` to show available translations.
4. User selects translations; client calls `action: "download"` with chosen IDs.

### Manual import (fallback)
1. User obtains translation files from any source.
2. `quranref corpus add --id <id> --file <path> --format tsv_surah_ayah_text ...`
3. `quranref index build --id <id>`

---

## 7) Translation catalog structure

The static `catalog/translations.json` ships with the server and contains a deduplicated list of all known English translations available for download.

**Entry schema:**
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

> **Note:** The checksum is per-source (not per-entry) because different providers may serve different file formats/encodings. The checksum in the installed manifest applies to the `original.*` file regardless of download source.

See `docs/implementation_plan.md` section 3 for the full schema specification.

---

## 8) What to record in each corpus manifest (minimum)

- `id` (stable): `en.<translator_or_project>.<edition_or_year>`
- `title`, `translator`, `year` (if known)
- `source_url`
- `download_date`
- `license_note` (short, factual)
- `format` (TSV / JSONL / SQLite / etc.)
- `checksum` (sha256 of the original file)
- `origin`: `"bundled"` | `"downloaded"` | `"manual_import"` — how this corpus was installed
- `download_source` (for downloaded corpora): URL the file was fetched from
- `download_date` (for downloaded corpora): ISO 8601 timestamp of download

This keeps your system auditable and keeps the server neutral: it returns **texts + provenance**, not opinions.
