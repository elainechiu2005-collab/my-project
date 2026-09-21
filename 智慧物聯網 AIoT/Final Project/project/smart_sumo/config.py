from __future__ import annotations

import json
from pathlib import Path


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def load_settings(config_path: str | None = None) -> dict:
    path = project_root() / (config_path or "project_settings.json")
    with path.open("r", encoding="utf-8") as fh:
        settings = json.load(fh)
    settings["_project_root"] = str(project_root())
    return settings


def resolve_path(settings: dict, relative_path: str) -> Path:
    return Path(settings["_project_root"]) / relative_path


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path
