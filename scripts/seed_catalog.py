#!/usr/bin/env python3
"""
Build catalog/translations.json from quran-api editions list.

Reads bundled corpus manifests for checksums, builds catalog entries for all
English translations available from quran-api, and includes Arabic base text.

Developer-only script. Not shipped to end users.
"""

import hashlib
import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLED_DIR = os.path.join(REPO_ROOT, "bundled", "quran")
CATALOG_DIR = os.path.join(REPO_ROOT, "catalog")
CDN_BASE = "https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions"

# ============================================================================
# ENGLISH TRANSLATIONS from quran-api
# ============================================================================
# Each entry: (corpus_id, api_key, title, translator, year, license_note, bundled)
# Year is None if unknown. license_note is brief provenance info.

ENGLISH_TRANSLATIONS = [
    # --- Bundled (public domain / Gutenberg) ---
    ("en.palmer.1880", "eng-edwardhenrypalm", "The Qur'an (Palmer)",
     "E. H. Palmer", 1880,
     "Public domain (author died 1882)", True),

    ("en.rodwell.1861", "eng-johnmedowsrodwe", "The Koran (Rodwell)",
     "J. M. Rodwell", 1861,
     "Public domain (author died 1900)", True),

    ("en.sale.1734", "eng-georgesale", "The Koran (Sale)",
     "George Sale", 1734,
     "Public domain (author died 1736)", True),

    ("en.yusufali.1934", "eng-abdullahyusufal", "The Holy Qur'an (Yusuf Ali)",
     "Abdullah Yusuf Ali", 1934,
     "Project Gutenberg License", True),

    ("en.pickthall.1930", "eng-mohammedmarmadu",
     "The Meaning of the Glorious Koran (Pickthall)",
     "Mohammed Marmaduke Pickthall", 1930,
     "Project Gutenberg License", True),

    ("en.shakir", "eng-mohammadhabibsh", "The Quran (Shakir)",
     "Mohammad Habib Shakir", None,
     "Project Gutenberg License", True),

    # --- Non-bundled (available for download) ---
    ("en.abdelhaleem", "eng-abdelhaleem", "The Qur'an (Abdel Haleem)",
     "Abdel Haleem", 2004,
     "Oxford University Press", False),

    ("en.abdulhye", "eng-abdulhye", "The Quran (Abdul Hye)",
     "Abdul Hye", None,
     "quran-api (The Unlicense)", False),

    ("en.daryabadi", "eng-abdulmajiddarya", "Tafsir-ul-Qur'an (Daryabadi)",
     "Abdul Majid Daryabadi", None,
     "quran-api (The Unlicense)", False),

    ("en.maududi", "eng-abulalamaududi", "Tafhim al-Qur'an (Maududi)",
     "Abul A'la Maududi", None,
     "quran-api (The Unlicense)", False),

    ("en.ahmedali", "eng-ahmedali", "Al-Qur'an (Ahmed Ali)",
     "Ahmed Ali", 1984,
     "quran-api (The Unlicense)", False),

    ("en.bewley", "eng-aishabewley", "The Noble Qur'an (Bewley)",
     "Aisha Bewley", None,
     "quran-api (The Unlicense)", False),

    ("en.arberry", "eng-ajarberry", "The Koran Interpreted (Arberry)",
     "A. J. Arberry", 1955,
     "quran-api (The Unlicense)", False),

    ("en.bilalmuhammad", "eng-albilalmuhammad",
     "The Quran (Al-Bilal Muhammad et al.)",
     "Al-Bilal Muhammad et al.", None,
     "quran-api (The Unlicense)", False),

    ("en.bakhtiari", "eng-alibakhtiarinej", "The Quran (Bakhtiari Nejad)",
     "Ali Bakhtiari Nejad", None,
     "quran-api (The Unlicense)", False),

    ("en.qarai", "eng-aliquliqarai", "The Qur'an (Qarai)",
     "Ali Quli Qarai", None,
     "quran-api (The Unlicense)", False),

    ("en.unal", "eng-aliunal", "The Qur'an (Ali Unal)",
     "Ali Unal", None,
     "quran-api (The Unlicense)", False),

    ("en.almuntakhab", "eng-almuntakhabfita",
     "Al-Muntakhab fi Tafsir al-Qur'an al-Karim",
     "Egyptian Ministry of Awqaf", None,
     "quran-api (The Unlicense)", False),

    ("en.kamalomar", "eng-drkamalomar", "The Quran (Dr. Kamal Omar)",
     "Dr. Kamal Omar", None,
     "quran-api (The Unlicense)", False),

    ("en.bakhtiar", "eng-drlalehbakhtiar", "The Sublime Quran (Bakhtiar)",
     "Dr. Laleh Bakhtiar", 2007,
     "quran-api (The Unlicense)", False),

    ("en.munshey", "eng-drmunirmunshey", "The Quran (Dr. Munir Munshey)",
     "Dr. Munir Munshey", None,
     "quran-api (The Unlicense)", False),

    ("en.farookmalik", "eng-farookmalik",
     "English Translation of the Meaning of Al-Qur'an (Farook Malik)",
     "Farook Malik", None,
     "quran-api (The Unlicense)", False),

    ("en.aziz", "eng-hamidsaziz", "The Quran (Hamid S. Aziz)",
     "Hamid S. Aziz", None,
     "quran-api (The Unlicense)", False),

    ("en.literal", "eng-literal", "Literal Translation",
     "Literal", None,
     "quran-api (The Unlicense)", False),

    ("en.maududi.2", "eng-maududi", "Tafhim al-Qur'an (Maududi, alt.)",
     "Abul A'la Maududi", None,
     "quran-api (The Unlicense)", False),

    ("en.miranees.orig", "eng-miraneesorigina",
     "The Quran (Mir Anees, Original)",
     "Mir Anees", None,
     "quran-api (The Unlicense)", False),

    ("en.miraneesuddin", "eng-miraneesuddin", "The Quran (Mir Aneesuddin)",
     "Mir Aneesuddin", None,
     "quran-api (The Unlicense)", False),

    ("en.mohammadshafi", "eng-mohammadshafi",
     "Ma'ariful Qur'an (Muhammad Shafi)",
     "Muhammad Shafi", None,
     "quran-api (The Unlicense)", False),

    ("en.taqiusmani", "eng-muftitaqiusmani",
     "The Meanings of the Noble Qur'an (Mufti Taqi Usmani)",
     "Mufti Taqi Usmani", None,
     "quran-api (The Unlicense)", False),

    ("en.asad", "eng-muhammadasad", "The Message of the Qur'an (Asad)",
     "Muhammad Asad", 1980,
     "quran-api (The Unlicense)", False),

    ("en.ghali", "eng-muhammadmahmoud",
     "Towards Understanding the Ever-Glorious Qur'an (Ghali)",
     "Muhammad Mahmoud Ghali", None,
     "quran-api (The Unlicense)", False),

    ("en.sarwar", "eng-muhammadsarwar", "The Quran (Sarwar)",
     "Muhammad Sarwar", None,
     "quran-api (The Unlicense)", False),

    ("en.hilali", "eng-muhammadtaqiudd",
     "The Noble Qur'an (Hilali & Khan)",
     "Muhammad Taqi-ud-Din al-Hilali & Muhammad Muhsin Khan", None,
     "quran-api (The Unlicense)", False),

    ("en.taqiusmani.2", "eng-muhammadtaqiusm",
     "The Meanings of the Noble Qur'an (M. Taqi Usmani, alt.)",
     "Muhammad Taqi Usmani", None,
     "quran-api (The Unlicense)", False),

    ("en.clearquran", "eng-mustafakhattaba",
     "The Clear Quran (Khattab, Allah edition)",
     "Mustafa Khattab", 2015,
     "quran-api (The Unlicense)", False),

    ("en.clearquran.god", "eng-mustafakhattabg",
     "The Clear Quran (Khattab, God edition)",
     "Mustafa Khattab", 2015,
     "quran-api (The Unlicense)", False),

    ("en.dawood", "eng-njdawood", "The Koran (Dawood)",
     "N. J. Dawood", 1956,
     "quran-api (The Unlicense)", False),

    ("en.rwwad", "eng-rowwadtranslati",
     "Translation by Rowwad Translation Center",
     "Rowwad Translation Center", None,
     "quran-api (The Unlicense)", False),

    ("en.kaskas", "eng-safikaskas", "The Qur'an (Safi Kaskas)",
     "Safi Kaskas", None,
     "quran-api (The Unlicense)", False),

    ("en.mubarakpuri", "eng-safiurrahmanalm",
     "Tafsir Ibn Kathir (Mubarakpuri)",
     "Safi-ur-Rahman al-Mubarakpuri", None,
     "quran-api (The Unlicense)", False),

    ("en.shabbirahmed", "eng-shabbirahmed", "QXP - The Quran (Shabbir Ahmed)",
     "Shabbir Ahmed", None,
     "quran-api (The Unlicense)", False),

    ("en.vickarahamed", "eng-syedvickarahame",
     "The Quran (Syed Vickar Ahamed)",
     "Syed Vickar Ahamed", None,
     "quran-api (The Unlicense)", False),

    ("en.itani", "eng-talalitani", "Quran in English (Itani)",
     "Talal Itani", 2012,
     "Creative Commons Attribution", False),

    ("en.itani.new", "eng-talalaitaninewt",
     "Quran in English (Itani, New Translation)",
     "Talal A. Itani", None,
     "quran-api (The Unlicense)", False),

    ("en.irving", "eng-tbirving", "The Qur'an (T.B. Irving)",
     "T. B. Irving", 1985,
     "quran-api (The Unlicense)", False),

    ("en.monotheist", "eng-themonotheistgr",
     "The Quran: A Monotheist Translation",
     "The Monotheist Group", 2011,
     "quran-api (The Unlicense)", False),

    ("en.studyquran", "eng-thestudyquran",
     "The Study Quran",
     "Seyyed Hossein Nasr et al.", 2015,
     "quran-api (The Unlicense)", False),

    ("en.sahih", "eng-ummmuhammad",
     "Saheeh International",
     "Umm Muhammad (Saheeh International)", None,
     "quran-api (The Unlicense)", False),

    ("en.wahiduddin", "eng-wahiduddinkhan",
     "The Quran (Wahiduddin Khan)",
     "Wahiduddin Khan", None,
     "quran-api (The Unlicense)", False),

    ("en.yusufali.orig", "eng-yusufaliorig",
     "The Holy Qur'an (Yusuf Ali, Original)",
     "Abdullah Yusuf Ali", 1934,
     "quran-api (The Unlicense)", False),
]

# ============================================================================
# ARABIC EDITIONS
# ============================================================================
# (id, api_key, title, description, license_note)

ARABIC_EDITIONS = [
    ("ar.uthmani", "ara-quranuthmanihaf",
     "Uthmani Script (Hafs)",
     "Standard Uthmani script with full diacritics, Hafs reading",
     "Quran text"),

    ("ar.simple", "ara-quransimple",
     "Simple Script",
     "Modern Arabic orthography (Imla'i) with diacritics",
     "Quran text"),

    ("ar.uthmani.min", "ara-quranuthmanihaf1",
     "Uthmani Script (Hafs, minimal diacritics)",
     "Uthmani script with minimal diacritical marks",
     "Quran text"),
]

# ============================================================================
# TANZIL CROSS-REFERENCE (for secondary source entries)
# ============================================================================
# Maps our corpus IDs to Tanzil translation IDs where available
TANZIL_MAP = {
    "en.yusufali.1934": "en.yusufali",
    "en.pickthall.1930": "en.pickthall",
    "en.shakir": "en.shakir",
    "en.ahmedali": "en.ahmedali",
    "en.daryabadi": "en.daryabadi",
    "en.hilali": "en.hilali",
    "en.arberry": "en.arberry",
    "en.maududi": "en.maududi",
    "en.qarai": "en.qarai",
    "en.sahih": "en.sahih",
    "en.sarwar": "en.sarwar",
    "en.wahiduddin": "en.wahiduddin",
    "en.mubarakpuri": "en.mubarakpuri",
}


def read_bundled_checksum(corpus_id: str) -> str | None:
    """Read the checksum from a bundled corpus manifest."""
    manifest_path = os.path.join(BUNDLED_DIR, corpus_id, "manifest.json")
    if not os.path.exists(manifest_path):
        return None
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    return manifest.get("checksum")


def build_translation_entry(corpus_id, api_key, title, translator, year,
                            license_note, bundled):
    """Build a single catalog translation entry."""
    entry = {
        "id": corpus_id,
        "title": title,
        "translator": translator,
    }
    if year is not None:
        entry["year"] = year

    # Primary source: quran-api
    sources = [{
        "provider": "quran-api",
        "url": f"{CDN_BASE}/{api_key}.json",
        "format": "json_chapter_verse_text",
        "checksum": None,
    }]

    # Secondary source: Tanzil (if available)
    tanzil_id = TANZIL_MAP.get(corpus_id)
    if tanzil_id:
        sources.append({
            "provider": "tanzil",
            "url": f"https://tanzil.net/trans/?transID={tanzil_id}&type=txt-2",
            "format": "tsv_pipe_surah_ayah_text",
            "checksum": None,
        })

    entry["sources"] = sources
    entry["canonical_source"] = "quran-api"
    entry["license_note"] = license_note
    entry["bundled"] = bundled

    # For bundled translations, include the TSV checksum
    if bundled:
        checksum = read_bundled_checksum(corpus_id)
        if checksum:
            entry["bundled_checksum"] = checksum

    return entry


def build_arabic_entry(ar_id, api_key, title, description, license_note):
    """Build a single catalog Arabic entry."""
    return {
        "id": ar_id,
        "title": title,
        "description": description,
        "sources": [{
            "provider": "quran-api",
            "url": f"{CDN_BASE}/{api_key}.json",
            "format": "json_chapter_verse_text",
            "checksum": None,
        }],
        "canonical_source": "quran-api",
        "license_note": license_note,
    }


def main():
    os.makedirs(CATALOG_DIR, exist_ok=True)

    # Build translation entries
    translations = []
    bundled_count = 0
    for args in ENGLISH_TRANSLATIONS:
        entry = build_translation_entry(*args)
        translations.append(entry)
        if entry["bundled"]:
            bundled_count += 1

    # Build Arabic entries
    arabic = []
    for args in ARABIC_EDITIONS:
        arabic.append(build_arabic_entry(*args))

    # Build catalog
    catalog = {
        "version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "translations": translations,
        "arabic": arabic,
    }

    # Write catalog
    catalog_path = os.path.join(CATALOG_DIR, "translations.json")
    with open(catalog_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"Catalog written: {catalog_path}")
    print(f"  Translations: {len(translations)} ({bundled_count} bundled)")
    print(f"  Arabic editions: {len(arabic)}")

    # Verify bundled checksums are present
    missing_checksums = []
    for entry in translations:
        if entry["bundled"] and not entry.get("bundled_checksum"):
            missing_checksums.append(entry["id"])

    if missing_checksums:
        print(f"\n  WARNING: Missing bundled checksums for: {', '.join(missing_checksums)}")
        print("  Run scripts/prepare_bundled.py first!")
        sys.exit(1)
    else:
        print(f"  All {bundled_count} bundled checksums verified present.")


if __name__ == "__main__":
    main()
