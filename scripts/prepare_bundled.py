#!/usr/bin/env python3
"""
Download 6 public-domain English translations from quran-api CDN,
convert each to TSV (surah<TAB>ayah<TAB>text), verify verse counts,
compute SHA-256, and generate manifest.json files.

Developer-only script. Not shipped to end users.
"""

import hashlib
import json
import os
import sys
import urllib.request
from datetime import datetime, timezone

# Canonical ayah counts per surah (1-indexed: AYAH_COUNTS[0] is unused)
# Source: u_quran_metadata.pas (matches Tanzil/standard Quran structure)
AYAH_COUNTS = [
    0,  # placeholder for 0-index
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109,    # 1-10
    123, 111, 43, 52, 99, 128, 111, 110, 98, 135,     # 11-20
    112, 78, 118, 64, 77, 227, 93, 88, 69, 60,        # 21-30
    34, 30, 73, 54, 45, 83, 182, 88, 75, 85,          # 31-40
    54, 53, 89, 59, 37, 35, 38, 29, 18, 45,           # 41-50
    60, 49, 62, 55, 78, 96, 29, 22, 24, 13,           # 51-60
    14, 11, 11, 18, 12, 12, 30, 52, 52, 44,           # 61-70
    28, 28, 20, 56, 40, 31, 50, 40, 46, 42,           # 71-80
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20,           # 81-90
    15, 21, 11, 8, 8, 19, 5, 8, 8, 11,                # 91-100
    11, 8, 3, 9, 5, 4, 7, 3, 6, 3,                    # 101-110
    5, 4, 5, 6,                                         # 111-114
]

TOTAL_VERSES = 6236

# Bundled translation definitions
BUNDLED = [
    {
        "id": "en.palmer.1880",
        "api_key": "eng-edwardhenrypalm",
        "title": "The Qur'an (Palmer)",
        "translator": "E. H. Palmer",
        "year": 1880,
        "source": "https://en.wikisource.org/wiki/The_Qur%27an_(Palmer)",
        "license_note": "Public domain (author died 1882)",
    },
    {
        "id": "en.rodwell.1861",
        "api_key": "eng-johnmedowsrodwe",
        "title": "The Koran (Rodwell)",
        "translator": "J. M. Rodwell",
        "year": 1861,
        "source": "https://en.wikisource.org/wiki/The_Koran_(Rodwell)",
        "license_note": "Public domain (author died 1900)",
    },
    {
        "id": "en.sale.1734",
        "api_key": "eng-georgesale",
        "title": "The Koran (Sale)",
        "translator": "George Sale",
        "year": 1734,
        "source": "https://en.wikisource.org/wiki/The_Koran_(Sale)",
        "license_note": "Public domain (author died 1736)",
    },
    {
        "id": "en.yusufali.1934",
        "api_key": "eng-abdullahyusufal",
        "title": "The Holy Qur'an (Yusuf Ali)",
        "translator": "Abdullah Yusuf Ali",
        "year": 1934,
        "source": "https://www.gutenberg.org/ebooks/16955",
        "license_note": "Project Gutenberg License",
    },
    {
        "id": "en.pickthall.1930",
        "api_key": "eng-mohammedmarmadu",
        "title": "The Meaning of the Glorious Koran (Pickthall)",
        "translator": "Mohammed Marmaduke Pickthall",
        "year": 1930,
        "source": "https://www.gutenberg.org/ebooks/16955",
        "license_note": "Project Gutenberg License",
    },
    {
        "id": "en.shakir",
        "api_key": "eng-mohammadhabibsh",
        "title": "The Quran (Shakir)",
        "translator": "Mohammad Habib Shakir",
        "year": None,
        "source": "https://www.gutenberg.org/ebooks/16955",
        "license_note": "Project Gutenberg License",
    },
]

CDN_BASE = "https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions"
BUNDLED_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bundled", "quran")


def download_json(api_key: str) -> list[dict]:
    """Download a translation JSON from quran-api CDN and return the verse list."""
    url = f"{CDN_BASE}/{api_key}.json"
    print(f"  Downloading {url} ...")
    req = urllib.request.Request(url, headers={"User-Agent": "quran-tafseer-mcp/prepare_bundled"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data["quran"]


def verses_to_tsv(verses: list[dict]) -> str:
    """Convert quran-api verse list to TSV string (surah\\tayah\\ttext)."""
    lines = []
    for v in verses:
        text = v["text"].strip()
        # Ensure no embedded tabs or newlines in text
        text = text.replace("\t", " ").replace("\n", " ").replace("\r", "")
        lines.append(f"{v['chapter']}\t{v['verse']}\t{text}")
    return "\n".join(lines) + "\n"


def verify_tsv(tsv_content: str, corpus_id: str) -> bool:
    """Verify TSV has exactly 6236 lines with correct surah/ayah sequence."""
    lines = tsv_content.strip().split("\n")
    if len(lines) != TOTAL_VERSES:
        print(f"  ERROR: {corpus_id} has {len(lines)} lines, expected {TOTAL_VERSES}")
        return False

    expected_idx = 0
    for surah in range(1, 115):
        for ayah in range(1, AYAH_COUNTS[surah] + 1):
            parts = lines[expected_idx].split("\t", 2)
            if len(parts) != 3:
                print(f"  ERROR: {corpus_id} line {expected_idx + 1}: expected 3 tab-separated fields, got {len(parts)}")
                return False
            s, a = int(parts[0]), int(parts[1])
            if s != surah or a != ayah:
                print(f"  ERROR: {corpus_id} line {expected_idx + 1}: expected {surah}:{ayah}, got {s}:{a}")
                return False
            if not parts[2].strip():
                print(f"  WARNING: {corpus_id} line {expected_idx + 1}: empty text for {surah}:{ayah}")
            expected_idx += 1

    print(f"  OK: {corpus_id} — {TOTAL_VERSES} verses verified")
    return True


def sha256_of(content: str) -> str:
    """Compute SHA-256 hex digest of a string (UTF-8 encoded)."""
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def make_manifest(defn: dict, checksum: str) -> dict:
    """Build a manifest.json dict for a bundled corpus."""
    manifest = {
        "id": defn["id"],
        "kind": "quran_translation",
        "language": "en",
        "title": defn["title"],
        "translator": defn["translator"],
        "source": defn["source"],
        "license_note": defn["license_note"],
        "format": "tsv_surah_ayah_text",
        "checksum": f"sha256:{checksum}",
        "origin": "bundled",
    }
    if defn["year"] is not None:
        manifest["year"] = defn["year"]
    return manifest


def main():
    os.makedirs(BUNDLED_DIR, exist_ok=True)

    errors = []
    for defn in BUNDLED:
        corpus_id = defn["id"]
        corpus_dir = os.path.join(BUNDLED_DIR, corpus_id)
        os.makedirs(corpus_dir, exist_ok=True)

        print(f"\nProcessing {corpus_id}:")

        # Download
        try:
            verses = download_json(defn["api_key"])
        except Exception as e:
            print(f"  FAILED to download: {e}")
            errors.append(corpus_id)
            continue

        # Convert to TSV
        tsv_content = verses_to_tsv(verses)

        # Verify
        if not verify_tsv(tsv_content, corpus_id):
            errors.append(corpus_id)
            continue

        # Write TSV
        tsv_path = os.path.join(corpus_dir, "original.tsv")
        with open(tsv_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(tsv_content)
        print(f"  Written: {tsv_path}")

        # Compute checksum
        checksum = sha256_of(tsv_content)
        print(f"  SHA-256: {checksum}")

        # Write manifest
        manifest = make_manifest(defn, checksum)
        manifest_path = os.path.join(corpus_dir, "manifest.json")
        with open(manifest_path, "w", encoding="utf-8", newline="\n") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
            f.write("\n")
        print(f"  Written: {manifest_path}")

    # Summary
    print(f"\n{'='*60}")
    if errors:
        print(f"ERRORS: {len(errors)} corpora failed: {', '.join(errors)}")
        sys.exit(1)
    else:
        print(f"SUCCESS: All {len(BUNDLED)} bundled corpora prepared.")
        sys.exit(0)


if __name__ == "__main__":
    main()
