import re
import urllib.request
from pathlib import Path

from .config import ensure_dir, resolve_path


def _fetch_bytes(url: str, timeout: int = 60) -> bytes:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read()


def download_binary(url: str, target: Path) -> Path:
    ensure_dir(target.parent)
    target.write_bytes(_fetch_bytes(url))
    return target


def scrape_dataset_download_url(dataset_detail_url: str) -> str:
    html = _fetch_bytes(dataset_detail_url).decode("utf-8", "ignore")
    matches = re.findall(r'"/api/dataset/[^"]+/resource/[^"]+/download"', html)
    if not matches:
        raise RuntimeError(f"Unable to find download URL on {dataset_detail_url}")
    return "https://data.taipei" + matches[0].strip('"')


def fetch_open_data(settings: dict, force: bool = False) -> dict[str, Path]:
    raw_dir = ensure_dir(resolve_path(settings, settings["paths"]["raw_dir"]))
    sources = settings["data_sources"]

    targets = {
        "timing_plan": raw_dir / "timing_plan.json",
        "timing_schedule": raw_dir / "timing_schedule.json",
        "vd_sections": raw_dir / "vd_sections.xml",
        "vd_live": raw_dir / "vd_live.xml",
        "signal_positions": raw_dir / "signal_positions.tsv",
        "pedestrian_survey_pdf": raw_dir / "pedestrian_survey_112.pdf"
    }

    url_map = {
        "timing_plan": sources["timing_plan_url"],
        "timing_schedule": sources["timing_schedule_url"],
        "vd_sections": sources["vd_section_url"],
        "vd_live": sources["vd_live_url"],
        "signal_positions": scrape_dataset_download_url(sources["signal_positions_dataset"]),
        "pedestrian_survey_pdf": sources["pedestrian_survey_pdf"]
    }

    for key, target in targets.items():
        if force or not target.exists():
            download_binary(url_map[key], target)

    return targets
