import argparse
import json

from smart_sumo.config import load_settings
from smart_sumo.open_data import fetch_open_data
from smart_sumo.pedestrian_survey import build_pedestrian_survey_status
from smart_sumo.signal_calibration import build_signal_calibration
from smart_sumo.traffic_generation import build_all_routes


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch official Taipei data and build SUMO inputs.")
    parser.add_argument("--config", default="project_settings.json")
    parser.add_argument("--force-download", action="store_true")
    args = parser.parse_args()

    settings = load_settings(args.config)
    raw_files = fetch_open_data(settings, force=args.force_download)
    calibration_path = build_signal_calibration(settings, raw_files)
    pedestrian_status_path = build_pedestrian_survey_status(settings, raw_files)
    route_paths = build_all_routes(settings, raw_files)

    summary = {
        "raw_files": {key: str(path) for key, path in raw_files.items()},
        "calibration": str(calibration_path),
        "pedestrian_survey_status": str(pedestrian_status_path),
        "generated": {key: str(path) for key, path in route_paths.items()},
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
