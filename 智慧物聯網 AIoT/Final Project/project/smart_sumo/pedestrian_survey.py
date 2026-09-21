from __future__ import annotations

import json
import sys
from pathlib import Path

from .config import ensure_dir, resolve_path


def _load_pypdf():
    vendor_dir = Path(__file__).resolve().parent.parent / ".vendor"
    if vendor_dir.exists():
        sys.path.insert(0, str(vendor_dir))
    from pypdf import PdfReader  # type: ignore

    return PdfReader


def _normalize_text(text: str) -> str:
    return "".join(text.replace("\u3000", " ").split())


def build_pedestrian_survey_status(settings: dict, raw_files: dict[str, Path]) -> Path:
    pdf_path = raw_files["pedestrian_survey_pdf"]
    PdfReader = _load_pypdf()
    reader = PdfReader(str(pdf_path))
    text = "\n".join(page.extract_text() or "" for page in reader.pages)
    normalized_text = _normalize_text(text)

    exact_name = _normalize_text(settings["target_tls"]["official_name"])
    aliases = [_normalize_text(alias) for alias in settings["target_tls"].get("official_name_aliases", [])]

    exact_hit = exact_name in normalized_text
    alias_hits = [alias for alias in aliases if alias in normalized_text]

    payload = {
        "source_pdf": str(pdf_path),
        "latest_survey_year": settings["pedestrian_generation"]["latest_survey_year"],
        "page_count": len(reader.pages),
        "official_intersection_name": settings["target_tls"]["official_name"],
        "exact_name_found": exact_hit,
        "alias_hits": alias_hits,
        "target_intersection_covered": exact_hit,
        "notes": [
            "The status is based on searchable text extraction from the latest published pedestrian survey PDF.",
            "If target_intersection_covered is false, this project cannot honestly claim an official pedestrian count for IJHM7 without a separate field count."
        ],
    }

    generated_dir = ensure_dir(resolve_path(settings, settings["paths"]["generated_dir"]))
    output = generated_dir / "pedestrian_survey_status.json"
    output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return output
