#!/usr/bin/env python3
"""Import a two-column category workbook into PhotoAI.sqlite.

Expected worksheet columns:
1. 大分類
2. 小分類

This tool updates ClusterSummary while preserving existing cluster_id values
for unchanged keywords. For newly imported keywords, it creates empty
SemanticDictionary rows; the iOS app will generate missing text embeddings on
the next sync.
"""

from __future__ import annotations

import argparse
import re
import sqlite3
import sys
import zipfile
from collections import OrderedDict
from pathlib import Path
from typing import Iterable
from xml.etree import ElementTree as ET


MAIN_HEADER = "大分類"
SUB_HEADER = "小分類"
XML_NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL_NS = {"r": "http://schemas.openxmlformats.org/package/2006/relationships"}


def col_to_index(cell_ref: str) -> int:
    match = re.match(r"([A-Z]+)", cell_ref)
    if not match:
        return 0

    value = 0
    for char in match.group(1):
        value = value * 26 + (ord(char) - ord("A") + 1)
    return value - 1


def parse_shared_strings(workbook_zip: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in workbook_zip.namelist():
        return []

    root = ET.fromstring(workbook_zip.read("xl/sharedStrings.xml"))
    shared_strings: list[str] = []
    for item in root.findall("x:si", XML_NS):
        text = "".join(node.text or "" for node in item.findall(".//x:t", XML_NS))
        shared_strings.append(text)
    return shared_strings


def first_sheet_path(workbook_zip: zipfile.ZipFile) -> str:
    workbook = ET.fromstring(workbook_zip.read("xl/workbook.xml"))
    rels = ET.fromstring(workbook_zip.read("xl/_rels/workbook.xml.rels"))
    relationship_map = {
        rel.attrib["Id"]: rel.attrib["Target"] for rel in rels.findall("r:Relationship", REL_NS)
    }

    first_sheet = workbook.find("x:sheets/x:sheet", XML_NS)
    if first_sheet is None:
        raise ValueError("The workbook does not contain any sheets.")

    relation_id = first_sheet.attrib.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id")
    target = relationship_map.get(relation_id or "")
    if not target:
        raise ValueError("Unable to resolve the first worksheet relationship.")

    return f"xl/{target}"


def cell_value(cell: ET.Element, shared_strings: list[str]) -> str:
    cell_type = cell.attrib.get("t")

    if cell_type == "inlineStr":
        return "".join(node.text or "" for node in cell.findall(".//x:t", XML_NS))

    value_node = cell.find("x:v", XML_NS)
    if value_node is None or value_node.text is None:
        return ""

    raw_value = value_node.text
    if cell_type == "s":
        return shared_strings[int(raw_value)]
    return raw_value


def make_unique_keyword(keyword: str, parent_category: str, existing_keywords: set[str]) -> str:
    if keyword not in existing_keywords:
        return keyword

    candidate = f"{keyword} ({parent_category})"
    if candidate not in existing_keywords:
        return candidate

    suffix = 2
    while True:
        candidate = f"{keyword} ({parent_category} {suffix})"
        if candidate not in existing_keywords:
            return candidate
        suffix += 1


def read_xlsx_rows(xlsx_path: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    with zipfile.ZipFile(xlsx_path) as workbook_zip:
        shared_strings = parse_shared_strings(workbook_zip)
        sheet_path = first_sheet_path(workbook_zip)
        sheet_root = ET.fromstring(workbook_zip.read(sheet_path))

    rows: list[list[str]] = []
    for row in sheet_root.findall("x:sheetData/x:row", XML_NS):
        values: dict[int, str] = {}
        max_index = -1
        for cell in row.findall("x:c", XML_NS):
            cell_ref = cell.attrib.get("r", "A1")
            index = col_to_index(cell_ref)
            values[index] = cell_value(cell, shared_strings).strip()
            max_index = max(max_index, index)

        if max_index < 0:
            continue

        normalized_row = [values.get(index, "").strip() for index in range(max_index + 1)]
        rows.append(normalized_row)

    if not rows:
        raise ValueError("The worksheet is empty.")

    header = rows[0]
    if len(header) < 2 or header[0] != MAIN_HEADER or header[1] != SUB_HEADER:
        raise ValueError(f"Expected headers [{MAIN_HEADER}, {SUB_HEADER}], got {header[:2]}.")

    categories: "OrderedDict[str, str]" = OrderedDict()
    renamed_keywords: list[tuple[str, str]] = []
    for row_index, row in enumerate(rows[1:], start=2):
        if len(row) < 2:
            continue

        parent_category = row[0].strip()
        keyword = row[1].strip()
        if not parent_category or not keyword:
            continue

        if keyword not in categories:
            categories[keyword] = parent_category
        elif categories[keyword] != parent_category:
            unique_keyword = make_unique_keyword(keyword, parent_category, set(categories))
            categories[unique_keyword] = parent_category
            renamed_keywords.append((keyword, unique_keyword))

    if not categories:
        raise ValueError("No valid category rows were found in the worksheet.")

    return [(parent, keyword) for keyword, parent in categories.items()], renamed_keywords


def ensure_tables(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS SemanticDictionary (
            keyword TEXT PRIMARY KEY,
            word_embedding BLOB
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS ClusterSummary (
            cluster_id INTEGER PRIMARY KEY AUTOINCREMENT,
            keyword TEXT NOT NULL,
            parent_category TEXT NOT NULL,
            random_vector BLOB,
            FOREIGN KEY (keyword) REFERENCES SemanticDictionary(keyword)
        )
        """
    )


def existing_keyword_map(connection: sqlite3.Connection) -> dict[str, int]:
    cursor = connection.execute("SELECT cluster_id, keyword FROM ClusterSummary")
    return {keyword: cluster_id for cluster_id, keyword in cursor.fetchall()}


def existing_photo_features(connection: sqlite3.Connection) -> bool:
    cursor = connection.execute(
        """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = 'PhotoFeatures'
        LIMIT 1
        """
    )
    return cursor.fetchone() is not None


def update_cluster_summary(
    connection: sqlite3.Connection,
    categories: list[tuple[str, str]],
) -> tuple[int, int, int]:
    keyword_to_cluster = existing_keyword_map(connection)
    imported_keywords = {keyword for _, keyword in categories}
    removed_keywords = set(keyword_to_cluster) - imported_keywords

    updated_count = 0
    inserted_count = 0

    for parent_category, keyword in categories:
        connection.execute(
            """
            INSERT OR IGNORE INTO SemanticDictionary (keyword, word_embedding)
            VALUES (?, NULL)
            """,
            (keyword,),
        )

        if keyword in keyword_to_cluster:
            connection.execute(
                """
                UPDATE ClusterSummary
                SET parent_category = ?
                WHERE keyword = ?
                """,
                (parent_category, keyword),
            )
            updated_count += 1
        else:
            connection.execute(
                """
                INSERT INTO ClusterSummary (keyword, parent_category, random_vector)
                VALUES (?, ?, NULL)
                """,
                (keyword, parent_category),
            )
            inserted_count += 1

    if removed_keywords:
        removed_cluster_ids = [keyword_to_cluster[keyword] for keyword in removed_keywords]
        if existing_photo_features(connection):
            connection.executemany(
                "UPDATE PhotoFeatures SET cluster_id = -1 WHERE cluster_id = ?",
                ((cluster_id,) for cluster_id in removed_cluster_ids),
            )

        connection.executemany(
            "DELETE FROM ClusterSummary WHERE keyword = ?",
            ((keyword,) for keyword in removed_keywords),
        )

    return inserted_count, updated_count, len(removed_keywords)


def import_workbook(xlsx_path: Path, sqlite_path: Path) -> None:
    categories, renamed_keywords = read_xlsx_rows(xlsx_path)
    sqlite_path.parent.mkdir(parents=True, exist_ok=True)

    with sqlite3.connect(sqlite_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        ensure_tables(connection)
        inserted_count, updated_count, removed_count = update_cluster_summary(connection, categories)
        connection.commit()

    parent_names = sorted({parent for parent, _ in categories})
    print(f"Imported {len(categories)} subcategories from {xlsx_path}.")
    print(f"Parent categories: {len(parent_names)}")
    print(f"Inserted: {inserted_count}, Updated: {updated_count}, Removed: {removed_count}")
    if renamed_keywords:
        print(f"Renamed {len(renamed_keywords)} duplicate keywords to keep them unique:")
        for original, renamed in renamed_keywords[:10]:
            print(f"  - {original} -> {renamed}")
        if len(renamed_keywords) > 10:
            print(f"  ... and {len(renamed_keywords) - 10} more")
    print("Next step: run Classification/rebuild_taxonomy_db.sh or the Swift embedding tool to precompute text embeddings on Mac.")


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--xlsx",
        default="Classification/分類表.xlsx",
        help="Path to the source workbook.",
    )
    parser.add_argument(
        "--sqlite",
        default="MobileCLIPExplore/SQLite/PhotoAI.sqlite",
        help="Path to the target SQLite database.",
    )
    return parser.parse_args(list(argv))


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    xlsx_path = Path(args.xlsx).expanduser().resolve()
    sqlite_path = Path(args.sqlite).expanduser().resolve()

    if not xlsx_path.exists():
        print(f"Workbook not found: {xlsx_path}", file=sys.stderr)
        return 1

    try:
        import_workbook(xlsx_path, sqlite_path)
    except Exception as error:  # noqa: BLE001
        print(f"Import failed: {error}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
