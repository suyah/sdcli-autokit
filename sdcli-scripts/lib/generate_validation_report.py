#!/usr/bin/env python3
"""Build normalized migration-validation evidence and reports.

The module deliberately has no database or YAML dependency. Bash collects live
metadata; this file performs deterministic evidence parsing and comparison.
"""

from __future__ import annotations

import argparse
import csv
import html
import os
import re
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence


INVENTORY_HEADER = (
    "schema",
    "category",
    "object_name",
    "parent_schema",
    "parent_name",
    "subtype",
    "ordinal",
    "attribute_name",
    "attribute_value",
    "status",
    "detail",
    "origin",
)


class EvidenceError(ValueError):
    """Raised when migration evidence is present but cannot be trusted."""


@dataclass(frozen=True, order=True)
class InventoryAttribute:
    ordinal: int
    name: str
    value: str


@dataclass(frozen=True)
class ObjectRecord:
    schema: str
    category: str
    name: str
    parent_schema: str = ""
    parent_name: str = ""
    subtype: str = ""
    attributes: tuple[InventoryAttribute, ...] = ()
    status: str = ""
    detail: str = ""
    origin: str = ""


@dataclass(frozen=True, order=True)
class SchemaMapping:
    source_schema: str
    target_schema: str
    method: str
    evidence_count: int
    status: str
    reason: str


@dataclass(frozen=True)
class ComparisonRecord:
    source_schema: str = ""
    source_category: str = ""
    source_name: str = ""
    generated_schema: str = ""
    generated_category: str = ""
    generated_name: str = ""
    target_schema: str = ""
    target_category: str = ""
    target_name: str = ""
    status: str = ""
    reason: str = ""
    origin: str = ""


@dataclass(frozen=True)
class ReportData:
    migration: str
    run_id: str
    generated_at: str
    status: str
    mappings: tuple[SchemaMapping, ...]
    reconciliation: tuple[dict[str, str], ...]
    source_inventory: tuple[ObjectRecord, ...]
    generated_inventory: tuple[ObjectRecord, ...]
    target_inventory: tuple[ObjectRecord, ...]
    comparisons: tuple[ComparisonRecord, ...]
    evidence_issues: tuple[str, ...]
    validation_findings: tuple[tuple[str, str], ...] = ()


def _clean_identifier(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1].replace('""', '"')
    if len(value) >= 2 and value[0] == "[" and value[-1] == "]":
        return value[1:-1].replace("]]", "]")
    return value


def _qualified_parts(value: str) -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    quoted = False
    bracketed = False
    index = 0
    while index < len(value):
        char = value[index]
        if quoted:
            current.append(char)
            if char == '"':
                if index + 1 < len(value) and value[index + 1] == '"':
                    current.append(value[index + 1])
                    index += 1
                else:
                    quoted = False
        elif bracketed:
            current.append(char)
            if char == "]":
                bracketed = False
        elif char == '"':
            quoted = True
            current.append(char)
        elif char == "[":
            bracketed = True
            current.append(char)
        elif char == ".":
            parts.append(_clean_identifier("".join(current)))
            current = []
        else:
            current.append(char)
        index += 1
    parts.append(_clean_identifier("".join(current)))
    return [part for part in parts if part]


def _object_schema_and_name(value: str) -> tuple[str, str]:
    parts = _qualified_parts(value)
    if len(parts) < 2:
        raise EvidenceError(f"qualified object name is required: {value!r}")
    return parts[-2], parts[-1]


def _record_key(record: ObjectRecord) -> tuple[str, ...]:
    return (
        record.schema,
        record.category,
        record.name,
        record.parent_schema,
        record.parent_name,
        record.subtype,
        record.status,
        record.detail,
        record.origin,
    )


def load_inventory(path: Path) -> list[ObjectRecord]:
    """Read attribute-row TSV evidence into one record per logical object."""

    grouped: dict[tuple[str, ...], list[InventoryAttribute]] = defaultdict(list)
    with Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != INVENTORY_HEADER:
            raise EvidenceError(f"invalid inventory header: {path}")
        for line_number, row in enumerate(reader, start=2):
            if not row["schema"] or not row["category"] or not row["object_name"]:
                raise EvidenceError(f"incomplete inventory row: {path}:{line_number}")
            record = ObjectRecord(
                schema=row["schema"],
                category=row["category"].upper(),
                name=row["object_name"],
                parent_schema=row["parent_schema"],
                parent_name=row["parent_name"],
                subtype=row["subtype"].upper(),
                status=row["status"].upper(),
                detail=row["detail"],
                origin=row["origin"],
            )
            if row["attribute_name"] or row["attribute_value"] or row["ordinal"]:
                try:
                    ordinal = int(row["ordinal"] or 0)
                except ValueError as exc:
                    raise EvidenceError(
                        f"invalid inventory ordinal: {path}:{line_number}"
                    ) from exc
                grouped[_record_key(record)].append(
                    InventoryAttribute(ordinal, row["attribute_name"], row["attribute_value"])
                )
            else:
                grouped.setdefault(_record_key(record), [])

    records = []
    for key, attributes in grouped.items():
        records.append(
            ObjectRecord(
                schema=key[0],
                category=key[1],
                name=key[2],
                parent_schema=key[3],
                parent_name=key[4],
                subtype=key[5],
                attributes=tuple(sorted(attributes)),
                status=key[6],
                detail=key[7],
                origin=key[8],
            )
        )
    return sorted(records, key=_object_sort_key)


def _object_sort_key(record: ObjectRecord) -> tuple:
    return (
        record.schema.casefold(),
        record.category,
        record.name.casefold(),
        record.parent_schema.casefold(),
        record.parent_name.casefold(),
        record.subtype,
        record.attributes,
    )


def _normalized_data_path(evidence_dir: Path, value: str) -> str:
    path = Path(value)
    if not path.is_absolute():
        path = Path(evidence_dir) / path
    return os.path.normcase(os.path.normpath(str(path.absolute())))


def _read_status(path: Path, minimum_fields: int) -> list[list[str]]:
    if not path.is_file():
        raise EvidenceError(f"status evidence is missing: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle, delimiter="\t"))
    if not rows:
        raise EvidenceError(f"status evidence is empty: {path}")
    for line_number, row in enumerate(rows, start=1):
        if len(row) < minimum_fields:
            raise EvidenceError(f"incomplete status row: {path}:{line_number}")
    return rows


def build_table_mappings(evidence_dir: Path) -> list[SchemaMapping]:
    evidence_dir = Path(evidence_dir)
    bcp_rows = _read_status(evidence_dir / "bcp_status.tsv", 4)
    loader_rows = _read_status(evidence_dir / "sqlldr_status.tsv", 8)

    source_by_path: dict[str, list[tuple[str, str]]] = defaultdict(list)
    target_by_path: dict[str, list[tuple[str, str]]] = defaultdict(list)
    issues: list[SchemaMapping] = []

    for row in bcp_rows:
        source_schema = ""
        try:
            source_schema, source_name = _object_schema_and_name(row[1])
        except EvidenceError:
            source_name = row[1]
        if row[0] != "0":
            issues.append(
                SchemaMapping(
                    source_schema,
                    "",
                    "DATA_FILE",
                    0,
                    "UNRESOLVED",
                    f"failed BCP status for {source_name}",
                )
            )
            continue
        if not row[2]:
            issues.append(
                SchemaMapping(
                    source_schema,
                    "",
                    "DATA_FILE",
                    0,
                    "UNRESOLVED",
                    f"missing BCP data path for {source_name}",
                )
            )
            continue
        source_by_path[_normalized_data_path(evidence_dir, row[2])].append(
            (source_schema, source_name)
        )

    for row in loader_rows:
        target_schema = ""
        try:
            target_schema, target_name = _object_schema_and_name(row[1])
        except EvidenceError:
            target_name = row[1]
        if row[0] != "0":
            issues.append(
                SchemaMapping(
                    "",
                    target_schema,
                    "DATA_FILE",
                    0,
                    "UNRESOLVED",
                    f"failed SQL*Loader status for {target_name}",
                )
            )
            continue
        if not row[3]:
            issues.append(
                SchemaMapping(
                    "",
                    target_schema,
                    "DATA_FILE",
                    0,
                    "UNRESOLVED",
                    f"missing SQL*Loader data path for {target_name}",
                )
            )
            continue
        target_by_path[_normalized_data_path(evidence_dir, row[3])].append(
            (target_schema, target_name)
        )

    pair_counts: Counter[tuple[str, str]] = Counter()
    for data_path in sorted(set(source_by_path) | set(target_by_path)):
        sources = source_by_path.get(data_path, [])
        targets = target_by_path.get(data_path, [])
        if len(sources) != 1 or len(targets) != 1:
            source_schema = sources[0][0] if len(sources) == 1 else ""
            target_schema = targets[0][0] if len(targets) == 1 else ""
            if len(sources) > 1:
                reason = f"duplicate BCP status for data path {data_path}"
            elif len(targets) > 1:
                reason = f"duplicate SQL*Loader status for data path {data_path}"
            else:
                reason = f"unpaired data path {data_path}"
            issues.append(
                SchemaMapping(
                    source_schema,
                    target_schema,
                    "DATA_FILE",
                    0,
                    "UNRESOLVED",
                    reason,
                )
            )
            continue
        pair_counts[(sources[0][0], targets[0][0])] += 1

    targets_by_source: dict[str, set[str]] = defaultdict(set)
    sources_by_target: dict[str, set[str]] = defaultdict(set)
    for source_schema, target_schema in pair_counts:
        targets_by_source[source_schema.casefold()].add(target_schema.casefold())
        sources_by_target[target_schema.casefold()].add(source_schema.casefold())

    mappings: list[SchemaMapping] = []
    for (source_schema, target_schema), count in pair_counts.items():
        reasons = []
        if len(targets_by_source[source_schema.casefold()]) > 1:
            reasons.append("source schema maps to multiple target schemas")
        if len(sources_by_target[target_schema.casefold()]) > 1:
            reasons.append("target schema maps from multiple source schemas")
        mappings.append(
            SchemaMapping(
                source_schema,
                target_schema,
                "DATA_FILE",
                count,
                "UNRESOLVED" if reasons else "MAPPED",
                "; ".join(reasons),
            )
        )

    return sorted(mappings + issues, key=_mapping_sort_key)


def _mapping_sort_key(mapping: SchemaMapping) -> tuple:
    return (
        mapping.source_schema.casefold(),
        mapping.target_schema.casefold(),
        mapping.status,
        mapping.reason,
    )


_QUALIFIED_IDENTIFIER = (
    r'(?:(?:"(?:[^"]|"")+"|\[[^\]]+\]|[A-Za-z0-9_$#]+)\.)?'
    r'(?:"(?:[^"]|"")+"|\[[^\]]+\]|[A-Za-z0-9_$#]+)'
)


def _attributes_from_columns(columns: str) -> tuple[InventoryAttribute, ...]:
    values = []
    for index, value in enumerate(columns.split(","), start=1):
        name = re.sub(r"\s+(ASC|DESC)\s*$", "", value.strip(), flags=re.IGNORECASE)
        values.append(InventoryAttribute(index, "column", _clean_identifier(name)))
    return tuple(values)


def _ddl_record(
    identifier: str,
    category: str,
    subtype: str,
    origin: str,
    *,
    parent: str = "",
    attributes: tuple[InventoryAttribute, ...] = (),
) -> ObjectRecord:
    schema, name = _object_schema_and_name(identifier)
    parent_schema = ""
    parent_name = ""
    if parent:
        parent_schema, parent_name = _object_schema_and_name(parent)
    return ObjectRecord(
        schema=schema,
        category=category,
        name=name,
        parent_schema=parent_schema,
        parent_name=parent_name,
        subtype=subtype,
        attributes=attributes,
        status="EXPECTED",
        detail="",
        origin=origin,
    )


def _schema_owner_for_generated_file(path: Path, root: Path) -> str:
    """Return a generated schema directory owner when SQL omits it.

    SQL Developer may emit object DDL without an owner inside a directory that
    is itself named for the generated schema.  Infer an owner only when that
    directory also has its generated ``user.sql``; root-level support scripts
    and arbitrary directories therefore remain evidence errors rather than
    being guessed.
    """

    relative_path = path.relative_to(root)
    if len(relative_path.parts) < 2:
        return ""
    candidate = relative_path.parts[0]
    if (root / candidate / "user.sql").is_file():
        return candidate
    return ""


def _qualify_generated_identifier(identifier: str, schema_owner: str) -> str:
    """Add the schema directory owner only to an unqualified identifier."""

    if schema_owner and len(_qualified_parts(identifier)) < 2:
        return f"{schema_owner}.{identifier}"
    return identifier


def _included_sql_files(sdcli_dir: Path) -> list[Path]:
    roots = sorted(
        set(Path(sdcli_dir).glob("master.sql"))
        | set(Path(sdcli_dir).glob("*/master.sql"))
    )
    if not roots:
        raise EvidenceError(f"generated master.sql not found under {sdcli_dir}")

    visited: set[Path] = set()
    ordered: list[Path] = []
    cleanup_names = {
        "dropallschemas.sql",
        "dropobjects.sql",
        "dropallobjects.sql",
        "cleanup.sql",
    }

    def visit(path: Path) -> None:
        path = path.resolve()
        if path in visited:
            return
        visited.add(path)
        if path.name.casefold() in cleanup_names:
            return
        if not path.is_file():
            raise EvidenceError(f"generated include is missing: {path}")
        ordered.append(path)
        for line in path.read_text(encoding="utf-8", errors="strict").splitlines():
            match = re.match(r'^\s*@@?\s*(?:"([^"]+)"|([^\s;]+))', line)
            if not match:
                continue
            include_value = match.group(1) or match.group(2)
            root_relative_path = (Path(sdcli_dir) / include_value).resolve()
            include_path = (
                root_relative_path
                if root_relative_path.is_file()
                else (path.parent / include_value).resolve()
            )
            visit(include_path)

    for root in roots:
        visit(root)
    return ordered


def _strip_sql_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", "", text)


def _split_sql_list(value: str) -> list[str]:
    """Split a SQL comma list without splitting nested expressions or strings."""

    parts: list[str] = []
    current: list[str] = []
    depth = 0
    single_quoted = False
    double_quoted = False
    index = 0
    while index < len(value):
        char = value[index]
        if single_quoted:
            current.append(char)
            if char == "'":
                if index + 1 < len(value) and value[index + 1] == "'":
                    current.append(value[index + 1])
                    index += 1
                else:
                    single_quoted = False
        elif double_quoted:
            current.append(char)
            if char == '"':
                if index + 1 < len(value) and value[index + 1] == '"':
                    current.append(value[index + 1])
                    index += 1
                else:
                    double_quoted = False
        elif char == "'":
            single_quoted = True
            current.append(char)
        elif char == '"':
            double_quoted = True
            current.append(char)
        elif char == "(":
            depth += 1
            current.append(char)
        elif char == ")":
            depth = max(0, depth - 1)
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        index += 1
    if current:
        parts.append("".join(current).strip())
    return [part for part in parts if part]


def _parse_generated_file(path: Path, root: Path) -> list[ObjectRecord]:
    if path.name.casefold() == "master.sql":
        return []
    text = _strip_sql_comments(path.read_text(encoding="utf-8", errors="strict"))
    origin = f"{path.relative_to(root)}"
    schema_owner = _schema_owner_for_generated_file(path, root)
    records: list[ObjectRecord] = []
    recognized_lines: set[int] = set()

    def line_number(offset: int) -> int:
        return text.count("\n", 0, offset) + 1

    def matched_line_number(match: re.Match[str]) -> int:
        first_token = re.search(r"\S", match.group(0))
        token_offset = first_token.start() if first_token else 0
        return line_number(match.start() + token_offset)

    def matches(pattern: str, flags: int = re.IGNORECASE | re.MULTILINE):
        return re.finditer(pattern, text, flags)

    simple_patterns = [
        (rf"^\s*CREATE\s+USER\s+({_QUALIFIED_IDENTIFIER})", "SCHEMAS", "USER"),
        (rf"^\s*CREATE\s+(?:GLOBAL\s+TEMPORARY\s+)?TABLE\s+({_QUALIFIED_IDENTIFIER})", "TABLES", "TABLE"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+({_QUALIFIED_IDENTIFIER})", "VIEWS", "VIEW"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE\s+({_QUALIFIED_IDENTIFIER})", "ROUTINES", "PROCEDURE"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+({_QUALIFIED_IDENTIFIER})", "ROUTINES", "FUNCTION"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?PACKAGE\s+BODY\s+({_QUALIFIED_IDENTIFIER})", "PACKAGE_BODIES", "PACKAGE BODY"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?PACKAGE(?!\s+BODY\b)\s+({_QUALIFIED_IDENTIFIER})", "PACKAGES", "PACKAGE"),
        (rf"^\s*CREATE\s+SEQUENCE\s+({_QUALIFIED_IDENTIFIER})", "SEQUENCES", "SEQUENCE"),
        (rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?SYNONYM\s+({_QUALIFIED_IDENTIFIER})", "SYNONYMS", "SYNONYM"),
        (rf"^\s*CREATE\s+ROLE\s+({_QUALIFIED_IDENTIFIER})", "ROLES", "ROLE"),
    ]
    for pattern, category, subtype in simple_patterns:
        for match in matches(pattern):
            identifier = match.group(1)
            if category in {"SCHEMAS", "ROLES"} and len(_qualified_parts(identifier)) < 2:
                identifier = f"{identifier}.{identifier}"
            else:
                identifier = _qualify_generated_identifier(identifier, schema_owner)
            records.append(_ddl_record(identifier, category, subtype, origin))
            recognized_lines.add(matched_line_number(match))

    trigger_pattern = rf"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER\s+({_QUALIFIED_IDENTIFIER}).*?\bON\s+({_QUALIFIED_IDENTIFIER})"
    for match in matches(trigger_pattern, re.IGNORECASE | re.MULTILINE | re.DOTALL):
        records.append(
            _ddl_record(
                _qualify_generated_identifier(match.group(1), schema_owner),
                "TRIGGERS",
                "TRIGGER",
                origin,
                parent=_qualify_generated_identifier(match.group(2), schema_owner),
            )
        )
        recognized_lines.add(matched_line_number(match))

    index_pattern = rf"^\s*CREATE\s+(UNIQUE\s+)?INDEX\s+({_QUALIFIED_IDENTIFIER})\s+ON\s+({_QUALIFIED_IDENTIFIER})\s*\(([^)]*)\)"
    for match in matches(index_pattern):
        attributes = list(_attributes_from_columns(match.group(4)))
        attributes.append(
            InventoryAttribute(0, "unique", "true" if match.group(1) else "false")
        )
        records.append(
            _ddl_record(
                _qualify_generated_identifier(match.group(2), schema_owner),
                "INDEXES",
                "UNIQUE" if match.group(1) else "INDEX",
                origin,
                parent=_qualify_generated_identifier(match.group(3), schema_owner),
                attributes=tuple(sorted(attributes)),
            )
        )
        recognized_lines.add(matched_line_number(match))

    constraint_pattern = rf"^\s*ALTER\s+TABLE\s+({_QUALIFIED_IDENTIFIER})\s+ADD\s+(?:CONSTRAINT\s+({_QUALIFIED_IDENTIFIER})\s+)?(PRIMARY\s+KEY|UNIQUE|FOREIGN\s+KEY|CHECK)\s*(?:\(([^)]*)\))?"
    for match in matches(constraint_pattern):
        parent = _qualify_generated_identifier(match.group(1), schema_owner)
        parent_schema, parent_name = _object_schema_and_name(parent)
        kind = re.sub(r"\s+", "_", match.group(3).upper())
        category = {
            "PRIMARY_KEY": "PRIMARY_KEYS",
            "UNIQUE": "UNIQUE_CONSTRAINTS",
            "FOREIGN_KEY": "FOREIGN_KEYS",
            "CHECK": "CHECK_CONSTRAINTS",
        }[kind]
        constraint_name = match.group(2) or f"{parent_name}_{kind}"
        if len(_qualified_parts(constraint_name)) < 2:
            constraint_name = f"{parent_schema}.{constraint_name}"
        if kind == "CHECK":
            attributes = (
                InventoryAttribute(0, "expression", (match.group(4) or "").strip()),
            )
        else:
            attributes = _attributes_from_columns(match.group(4) or "")
        records.append(
            _ddl_record(
                constraint_name,
                category,
                kind,
                origin,
                parent=parent,
                attributes=attributes,
            )
        )
        recognized_lines.add(matched_line_number(match))

    table_block_pattern = rf"^\s*CREATE\s+(?:GLOBAL\s+TEMPORARY\s+)?TABLE\s+({_QUALIFIED_IDENTIFIER})\s*\((.*?)\)\s*;"
    for match in matches(table_block_pattern, re.IGNORECASE | re.MULTILINE | re.DOTALL):
        table = _qualify_generated_identifier(match.group(1), schema_owner)
        table_schema, table_name = _object_schema_and_name(table)
        column_ordinal = 0
        for definition in _split_sql_list(match.group(2)):
            column_match = re.match(
                r'^\s*("(?:[^"]|"")+"|\[[^\]]+\]|[A-Za-z0-9_$#]+)\s+',
                definition,
            )
            if not column_match:
                continue
            column_name = _clean_identifier(column_match.group(1))
            if column_name.upper() in {
                "CONSTRAINT",
                "PRIMARY",
                "UNIQUE",
                "FOREIGN",
                "CHECK",
            }:
                continue
            column_ordinal += 1
            default_match = re.search(r"\bDEFAULT\b\s+(.+)$", definition, re.IGNORECASE | re.DOTALL)
            if default_match:
                default_detail = re.split(
                    r"\s+(?:NOT\s+NULL|NULL|CONSTRAINT|PRIMARY\s+KEY|UNIQUE|REFERENCES|CHECK)\b",
                    default_match.group(1).strip(),
                    maxsplit=1,
                    flags=re.IGNORECASE,
                )[0].strip()
                records.append(
                    ObjectRecord(
                        schema=table_schema,
                        category="DEFAULT_CONSTRAINTS",
                        name=f"{table_name}_{column_name}_DEFAULT",
                        parent_schema=table_schema,
                        parent_name=table_name,
                        subtype="DEFAULT",
                        attributes=(
                            InventoryAttribute(column_ordinal, "column", column_name),
                        ),
                        status="EXPECTED",
                        detail=default_detail,
                        origin=origin,
                    )
                )
        for column_match in re.finditer(
            r'^\s*("(?:[^"]|"")+"|\[[^\]]+\]|[A-Za-z0-9_$#]+).*?\bGENERATED\b.*?\bAS\s+IDENTITY\b',
            match.group(2),
            re.IGNORECASE | re.MULTILINE,
        ):
            records.append(
                ObjectRecord(
                    schema=table_schema,
                    category="IDENTITY_COLUMNS",
                    name=_clean_identifier(column_match.group(1)),
                    parent_schema=table_schema,
                    parent_name=table_name,
                    subtype="IDENTITY",
                    status="EXPECTED",
                    origin=origin,
                )
            )

    allowed_control = re.compile(
        r"^\s*(ALTER\s+SESSION|ALTER\s+USER|ALTER\s+INDEX|GRANT|COMMENT\s+ON)\b",
        re.IGNORECASE,
    )
    for number, line in enumerate(text.splitlines(), start=1):
        if not re.match(r"^\s*(CREATE|ALTER)\b", line, re.IGNORECASE):
            continue
        if number in recognized_lines or allowed_control.match(line):
            continue
        raise EvidenceError(f"unrecognized generated DDL: {origin}:{number}: {line.strip()}")
    return records


def parse_generated_inventory(sdcli_dir: Path) -> list[ObjectRecord]:
    sdcli_dir = Path(sdcli_dir).resolve()
    records: list[ObjectRecord] = []
    for path in _included_sql_files(sdcli_dir):
        records.extend(_parse_generated_file(path, sdcli_dir))
    unique = {_object_key_with_attributes(record): record for record in records}
    return sorted(unique.values(), key=_object_sort_key)


def _logical_category(category: str) -> str:
    category = category.upper()
    if category in {"PROCEDURES", "FUNCTIONS", "ROUTINES"}:
        return "ROUTINES"
    return category


def _identity(record: ObjectRecord) -> tuple[str, str]:
    return _logical_category(record.category), record.name.casefold()


def resolve_schema_mappings(
    source: Sequence[ObjectRecord],
    generated: Sequence[ObjectRecord],
    table_mappings: Sequence[SchemaMapping],
) -> list[SchemaMapping]:
    results = list(table_mappings)
    mapped_sources = {
        row.source_schema.casefold()
        for row in table_mappings
        if row.status == "MAPPED" and row.source_schema
    }
    mapped_targets = {
        row.target_schema.casefold()
        for row in table_mappings
        if row.status == "MAPPED" and row.target_schema
    }

    source_objects: dict[str, set[tuple[str, str]]] = defaultdict(set)
    source_names: dict[str, str] = {}
    for record in source:
        if _logical_category(record.category) == "SCHEMAS":
            continue
        key = record.schema.casefold()
        if key in mapped_sources:
            continue
        source_names.setdefault(key, record.schema)
        source_objects[key].add(_identity(record))

    target_objects: dict[str, set[tuple[str, str]]] = defaultdict(set)
    target_names: dict[str, str] = {}
    for record in generated:
        key = record.schema.casefold()
        target_names.setdefault(key, record.schema)
        if key == "emulation":
            continue
        if key in mapped_targets:
            continue
        if record.category in {"SCHEMAS", "ROLES", "PACKAGES", "PACKAGE_BODIES"}:
            continue
        target_objects[key].add(_identity(record))

    if "emulation" in target_names and "emulation" not in mapped_targets:
        results.append(
            SchemaMapping("", target_names["emulation"], "CONVERSION_ONLY", 1, "CONTEXT", "SQL Developer conversion owner")
        )

    scores: dict[tuple[str, str], int] = {}
    for source_key, identities in source_objects.items():
        for target_key, target_identities in target_objects.items():
            scores[(source_key, target_key)] = len(identities & target_identities)

    accepted_sources: set[str] = set()
    accepted_targets: set[str] = set()
    unresolved_targets: set[str] = set()
    for target_key in sorted(target_objects):
        target_scores = [(score, source_key) for (source_key, candidate), score in scores.items() if candidate == target_key]
        best_score = max((score for score, _ in target_scores), default=0)
        best_sources = [source_key for score, source_key in target_scores if score == best_score and score > 0]
        if len(best_sources) != 1:
            unresolved_targets.add(target_key)
            continue
        source_key = best_sources[0]
        source_scores = [
            (score, candidate_target)
            for (candidate_source, candidate_target), score in scores.items()
            if candidate_source == source_key
        ]
        source_best = max((score for score, _ in source_scores), default=0)
        best_targets = [target for score, target in source_scores if score == source_best and score > 0]
        if len(best_targets) != 1 or best_targets[0] != target_key:
            unresolved_targets.add(target_key)
            continue
        results.append(
            SchemaMapping(
                source_names[source_key],
                target_names[target_key],
                "OBJECT_IDENTITY",
                best_score,
                "MAPPED",
                "",
            )
        )
        accepted_sources.add(source_key)
        accepted_targets.add(target_key)

    for target_key in sorted(set(target_objects) - accepted_targets):
        reason = "object identity match is tied or empty"
        results.append(
            SchemaMapping("", target_names[target_key], "OBJECT_IDENTITY", 0, "UNRESOLVED", reason)
        )
    for source_key in sorted(set(source_objects) - accepted_sources):
        results.append(
            SchemaMapping(source_names[source_key], "", "OBJECT_IDENTITY", 0, "UNRESOLVED", "no unique generated owner")
        )
    return sorted(results, key=_mapping_sort_key)


def _object_key_with_attributes(record: ObjectRecord) -> tuple:
    return (
        record.schema.casefold(),
        _logical_category(record.category),
        record.name.casefold(),
        record.parent_schema.casefold(),
        record.parent_name.casefold(),
        record.subtype,
        record.attributes,
    )


_STRUCTURAL_CATEGORIES = {
    "PRIMARY_KEYS",
    "UNIQUE_CONSTRAINTS",
    "FOREIGN_KEYS",
    "CHECK_CONSTRAINTS",
    "DEFAULT_CONSTRAINTS",
    "INDEXES",
}


def _attribute_key(record: ObjectRecord) -> tuple[tuple[int, str, str], ...]:
    return tuple(
        (attribute.ordinal, attribute.name.casefold(), attribute.value.casefold())
        for attribute in sorted(record.attributes)
    )


def _comparison_key(
    record: ObjectRecord,
    schema_map: dict[str, str] | None = None,
    *,
    include_attributes: bool = True,
) -> tuple:
    schema_map = schema_map or {}
    schema = schema_map.get(record.schema.casefold(), record.schema).casefold()
    parent_schema = schema_map.get(
        record.parent_schema.casefold(), record.parent_schema
    ).casefold()
    category = _logical_category(record.category)
    if category in _STRUCTURAL_CATEGORIES:
        key = (schema, category, parent_schema, record.parent_name.casefold())
        if include_attributes:
            key += (_attribute_key(record),)
        return key
    if category in {"TRIGGERS", "IDENTITY_COLUMNS"}:
        key = (
            schema,
            category,
            record.name.casefold(),
            parent_schema,
            record.parent_name.casefold(),
        )
        if include_attributes:
            key += (_attribute_key(record),)
        return key
    key = (schema, category, record.name.casefold())
    if include_attributes:
        key += (_attribute_key(record),)
    return key


def _is_context_record(record: ObjectRecord, side: str) -> tuple[bool, str]:
    if record.schema.casefold() == "emulation":
        return True, "SQL Developer conversion owner"
    category = _logical_category(record.category)
    if category in {"SCHEMAS", "ROLES", "PACKAGES", "PACKAGE_BODIES"}:
        return True, "generated Oracle or SQL Developer support object"
    if (
        side == "target"
        and category == "SEQUENCES"
        and re.fullmatch(r"ISEQ\$\$_[0-9]+", record.name, re.IGNORECASE)
    ):
        return True, "Oracle-generated identity sequence"
    if side == "source" and any(
        attribute.name.casefold() == "is_ms_shipped"
        and attribute.value.casefold() in {"1", "true", "yes"}
        for attribute in record.attributes
    ):
        return True, "SQL Server shipped object"
    return False, ""


def _comparison_row(
    *,
    source: ObjectRecord | None = None,
    generated: ObjectRecord | None = None,
    target: ObjectRecord | None = None,
    status: str,
    reason: str,
) -> ComparisonRecord:
    return ComparisonRecord(
        source_schema=source.schema if source else "",
        source_category=source.category if source else "",
        source_name=source.name if source else "",
        generated_schema=generated.schema if generated else "",
        generated_category=generated.category if generated else "",
        generated_name=generated.name if generated else "",
        target_schema=target.schema if target else "",
        target_category=target.category if target else "",
        target_name=target.name if target else "",
        status=status,
        reason=reason,
        origin=(target or generated or source).origin if (target or generated or source) else "",
    )


def compare_objects(
    source: Sequence[ObjectRecord],
    generated: Sequence[ObjectRecord],
    target: Sequence[ObjectRecord],
    mappings: Sequence[SchemaMapping],
) -> list[ComparisonRecord]:
    """Compare source -> generated plan -> live target using logical keys."""

    schema_map = {
        row.source_schema.casefold(): row.target_schema
        for row in mappings
        if row.status == "MAPPED" and row.source_schema and row.target_schema
    }
    unresolved_sources = {
        row.source_schema.casefold()
        for row in mappings
        if row.status == "UNRESOLVED" and row.source_schema
    }

    generated_exact: dict[tuple, list[int]] = defaultdict(list)
    generated_coarse: dict[tuple, list[int]] = defaultdict(list)
    for index, record in enumerate(generated):
        generated_exact[_comparison_key(record)].append(index)
        generated_coarse[_comparison_key(record, include_attributes=False)].append(index)

    target_exact: dict[tuple, list[int]] = defaultdict(list)
    target_coarse: dict[tuple, list[int]] = defaultdict(list)
    for index, record in enumerate(target):
        target_exact[_comparison_key(record)].append(index)
        target_coarse[_comparison_key(record, include_attributes=False)].append(index)

    used_generated: set[int] = set()
    used_target: set[int] = set()
    rows: list[ComparisonRecord] = []

    def first_unused(indices: Sequence[int], used: set[int]) -> int | None:
        return next((index for index in indices if index not in used), None)

    for source_record in sorted(source, key=_object_sort_key):
        context, context_reason = _is_context_record(source_record, "source")
        if context:
            rows.append(
                _comparison_row(source=source_record, status="CONTEXT", reason=context_reason)
            )
            continue
        source_key = source_record.schema.casefold()
        if source_key in unresolved_sources or source_key not in schema_map:
            rows.append(
                _comparison_row(
                    source=source_record,
                    status="UNRESOLVED_MAPPING",
                    reason="source schema has no resolved target owner",
                )
            )
            continue

        exact_key = _comparison_key(source_record, schema_map)
        coarse_key = _comparison_key(source_record, schema_map, include_attributes=False)
        generated_index = first_unused(generated_exact.get(exact_key, ()), used_generated)
        if generated_index is None:
            differing_index = first_unused(
                generated_coarse.get(coarse_key, ()), used_generated
            )
            if differing_index is not None:
                used_generated.add(differing_index)
                rows.append(
                    _comparison_row(
                        source=source_record,
                        generated=generated[differing_index],
                        status="DIFFERENT",
                        reason="generated object structure differs from source",
                    )
                )
            else:
                rows.append(
                    _comparison_row(
                        source=source_record,
                        status="MISSING_IN_CONVERSION",
                        reason="source object has no generated target counterpart",
                    )
                )
            continue

        used_generated.add(generated_index)
        generated_record = generated[generated_index]
        target_key = _comparison_key(generated_record)
        target_coarse_key = _comparison_key(generated_record, include_attributes=False)
        target_index = first_unused(target_exact.get(target_key, ()), used_target)
        if target_index is None:
            differing_index = first_unused(
                target_coarse.get(target_coarse_key, ()), used_target
            )
            if differing_index is not None:
                used_target.add(differing_index)
                rows.append(
                    _comparison_row(
                        source=source_record,
                        generated=generated_record,
                        target=target[differing_index],
                        status="DIFFERENT",
                        reason="deployed target structure differs from generated plan",
                    )
                )
            else:
                rows.append(
                    _comparison_row(
                        source=source_record,
                        generated=generated_record,
                        status="MISSING_IN_TARGET",
                        reason="generated object is absent from the target",
                    )
                )
            continue

        used_target.add(target_index)
        target_record = target[target_index]
        if target_record.status.upper() == "INVALID":
            rows.append(
                _comparison_row(
                    source=source_record,
                    generated=generated_record,
                    target=target_record,
                    status="INVALID_IN_TARGET",
                    reason=target_record.detail or "target object is invalid",
                )
            )
        else:
            rows.append(
                _comparison_row(
                    source=source_record,
                    generated=generated_record,
                    target=target_record,
                    status="MATCH",
                    reason="",
                )
            )

    for generated_index, generated_record in enumerate(generated):
        if generated_index in used_generated:
            continue
        context, context_reason = _is_context_record(generated_record, "generated")
        target_index = first_unused(
            target_exact.get(_comparison_key(generated_record), ()), used_target
        )
        target_record = target[target_index] if target_index is not None else None
        if target_index is not None:
            used_target.add(target_index)
        if context:
            rows.append(
                _comparison_row(
                    generated=generated_record,
                    target=target_record,
                    status="CONTEXT",
                    reason=context_reason,
                )
            )
        elif target_record is None:
            rows.append(
                _comparison_row(
                    generated=generated_record,
                    status="MISSING_IN_TARGET",
                    reason="generated object is absent from the target",
                )
            )
        elif target_record.status.upper() == "INVALID":
            rows.append(
                _comparison_row(
                    generated=generated_record,
                    target=target_record,
                    status="INVALID_IN_TARGET",
                    reason=target_record.detail or "target object is invalid",
                )
            )
        else:
            rows.append(
                _comparison_row(
                    generated=generated_record,
                    target=target_record,
                    status="DIFFERENT",
                    reason="generated object has no source counterpart",
                )
            )

    for target_index, target_record in enumerate(target):
        if target_index in used_target:
            continue
        context, context_reason = _is_context_record(target_record, "target")
        rows.append(
            _comparison_row(
                target=target_record,
                status="CONTEXT" if context else "EXTRA_IN_TARGET",
                reason=context_reason or "target object is not present in the generated plan",
            )
        )

    return sorted(
        rows,
        key=lambda row: (
            (row.source_schema or row.generated_schema or row.target_schema).casefold(),
            row.source_category or row.generated_category or row.target_category,
            (row.source_name or row.generated_name or row.target_name).casefold(),
            row.status,
        ),
    )


def write_tsv_atomic(path: Path, header: Iterable[str], rows: Iterable[Iterable[object]]) -> None:
    """Write deterministic UTF-8 TSV evidence without exposing partial files."""

    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
            writer.writerow(tuple(header))
            for row in rows:
                writer.writerow(tuple(row))
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _inventory_rows(records: Sequence[ObjectRecord]) -> Iterable[tuple[object, ...]]:
    for record in sorted(records, key=_object_sort_key):
        attributes = record.attributes or (InventoryAttribute(0, "", ""),)
        for attribute in attributes:
            yield (
                record.schema,
                record.category,
                record.name,
                record.parent_schema,
                record.parent_name,
                record.subtype,
                attribute.ordinal or "",
                attribute.name,
                attribute.value,
                record.status,
                record.detail,
                record.origin,
            )


def write_evidence_outputs(
    evidence_dir: Path,
    mappings: Sequence[SchemaMapping],
    generated: Sequence[ObjectRecord],
    comparisons: Sequence[ComparisonRecord],
) -> None:
    """Write the normalized snapshot artifacts consumed by shell and HTML."""

    evidence_dir = Path(evidence_dir)
    write_tsv_atomic(
        evidence_dir / "schema_mapping.tsv",
        ("source_schema", "target_schema", "method", "evidence_count", "status", "reason"),
        (
            (
                row.source_schema,
                row.target_schema,
                row.method,
                row.evidence_count,
                row.status,
                row.reason,
            )
            for row in sorted(mappings, key=_mapping_sort_key)
        ),
    )
    write_tsv_atomic(
        evidence_dir / "generated_target_inventory.tsv",
        INVENTORY_HEADER,
        _inventory_rows(generated),
    )
    comparison_header = (
        "source_schema",
        "source_category",
        "source_name",
        "generated_schema",
        "generated_category",
        "generated_name",
        "target_schema",
        "target_category",
        "target_name",
        "status",
        "reason",
        "origin",
    )
    comparison_rows = (
        (
            row.source_schema,
            row.source_category,
            row.source_name,
            row.generated_schema,
            row.generated_category,
            row.generated_name,
            row.target_schema,
            row.target_category,
            row.target_name,
            row.status,
            row.reason,
            row.origin,
        )
        for row in sorted(
            comparisons,
            key=lambda item: (
                (item.source_schema or item.generated_schema or item.target_schema).casefold(),
                item.source_category or item.generated_category or item.target_category,
                (item.source_name or item.generated_name or item.target_name).casefold(),
                item.status,
            ),
        )
    )
    write_tsv_atomic(
        evidence_dir / "object_comparison.tsv", comparison_header, comparison_rows
    )


def _read_reconciliation(path: Path) -> tuple[dict[str, str], ...]:
    with Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {
            "source_object",
            "target_object",
            "exported_rows",
            "loaded_rows",
            "rejected_rows",
            "discarded_rows",
            "target_rows",
            "status",
            "reason",
        }
        if not required.issubset(set(reader.fieldnames or ())):
            raise EvidenceError(f"invalid reconciliation header: {path}")
        rows = tuple(dict(row) for row in reader)
    if not rows:
        raise EvidenceError(f"reconciliation evidence is empty: {path}")
    return rows


def _read_validation_checks(path: Path) -> tuple[tuple[str, str, int, str], ...]:
    with Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != ("check", "status", "issues", "detail"):
            raise EvidenceError(f"invalid validation checks header: {path}")
        checks = []
        for line_number, row in enumerate(reader, start=2):
            status = row["status"].upper()
            if not row["check"] or status not in {"PASS", "FAIL", "INCOMPLETE"}:
                raise EvidenceError(f"invalid validation check: {path}:{line_number}")
            try:
                issues = int(row["issues"])
            except ValueError as exc:
                raise EvidenceError(
                    f"invalid validation check issue count: {path}:{line_number}"
                ) from exc
            if issues < 0 or (status == "PASS") != (issues == 0):
                raise EvidenceError(f"inconsistent validation check: {path}:{line_number}")
            checks.append((row["check"], status, issues, row["detail"]))
    if not checks:
        raise EvidenceError(f"validation checks evidence is empty: {path}")
    return tuple(checks)


def _escaped(value: object) -> str:
    return html.escape(str(value), quote=True)


def _html_table(table_id: str, headers: Sequence[str], rows: Iterable[Sequence[object]]) -> str:
    escaped_id = _escaped(table_id)
    header_html = "".join(
        f'<th scope="col">{_escaped(header)}</th>' for header in headers
    )
    body_rows = []
    for row in rows:
        body_rows.append(
            "<tr>" + "".join(f"<td>{_escaped(value)}</td>" for value in row) + "</tr>"
        )
    if not body_rows:
        body_rows.append(
            f'<tr><td colspan="{len(headers)}" class="empty">No records</td></tr>'
        )
    return (
        f'<label class="filter">Filter <input type="search" '
        f'oninput="filterTable(\'{escaped_id}\', this.value)" '
        f'aria-controls="{escaped_id}"></label>'
        f'<div class="table-wrap"><table id="{escaped_id}" data-sortable>'
        f"<thead><tr>{header_html}</tr></thead><tbody>{''.join(body_rows)}</tbody>"
        "</table></div>"
    )


def _comparison_rows(rows: Iterable[ComparisonRecord]) -> Iterable[tuple[str, ...]]:
    for row in rows:
        yield (
            row.source_schema,
            row.source_category,
            row.source_name,
            row.generated_schema,
            row.generated_category,
            row.generated_name,
            row.target_schema,
            row.target_category,
            row.target_name,
            row.status,
            row.reason,
        )


def render_report(report_data: ReportData, output_path: Path) -> None:
    """Render one offline HTML report and atomically replace the destination."""

    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    exception_rows = [
        row
        for row in report_data.comparisons
        if row.status not in {"MATCH", "CONTEXT"}
    ]
    routine_rows = [
        row
        for row in report_data.comparisons
        if "ROUTINE"
        in {
            _logical_category(row.source_category),
            _logical_category(row.generated_category),
            _logical_category(row.target_category),
        }
    ]
    context_rows = [row for row in report_data.comparisons if row.status == "CONTEXT"]
    inventory_counts: Counter[tuple[str, str, str]] = Counter()
    for side, records in (
        ("Source", report_data.source_inventory),
        ("Generated", report_data.generated_inventory),
        ("Target", report_data.target_inventory),
    ):
        for record in records:
            inventory_counts[(side, record.schema, _logical_category(record.category))] += 1

    mapping_table = _html_table(
        "schema-mapping",
        ("Source schema", "Target schema", "Method", "Evidence", "Status", "Reason"),
        (
            (
                row.source_schema,
                row.target_schema,
                row.method,
                row.evidence_count,
                row.status,
                row.reason,
            )
            for row in report_data.mappings
        ),
    )
    reconciliation_headers = (
        "Source object",
        "Target object",
        "Exported",
        "Loaded",
        "Rejected",
        "Discarded",
        "Target rows",
        "Status",
        "Reason",
    )
    reconciliation_table = _html_table(
        "data-reconciliation",
        reconciliation_headers,
        (
            tuple(
                row.get(key, "")
                for key in (
                    "source_object",
                    "target_object",
                    "exported_rows",
                    "loaded_rows",
                    "rejected_rows",
                    "discarded_rows",
                    "target_rows",
                    "status",
                    "reason",
                )
            )
            for row in report_data.reconciliation
        ),
    )
    inventory_table = _html_table(
        "object-inventory",
        ("Stage", "Schema", "Category", "Count"),
        (
            (side, schema, category, count)
            for (side, schema, category), count in sorted(
                inventory_counts.items(),
                key=lambda item: tuple(value.casefold() for value in item[0]),
            )
        ),
    )
    comparison_headers = (
        "Source schema",
        "Source category",
        "Source object",
        "Generated schema",
        "Generated category",
        "Generated object",
        "Target schema",
        "Target category",
        "Target object",
        "Status",
        "Reason",
    )
    exceptions_table = _html_table(
        "object-exceptions", comparison_headers, _comparison_rows(exception_rows)
    )
    routines_table = _html_table(
        "routine-validation", comparison_headers, _comparison_rows(routine_rows)
    )
    context_table = _html_table(
        "supporting-context", comparison_headers, _comparison_rows(context_rows)
    )
    evidence_rows = list(report_data.validation_findings)
    evidence_rows.extend(("INCOMPLETE", issue) for issue in report_data.evidence_issues)
    if not evidence_rows:
        evidence_rows = [("OK", "All required evidence was readable")]
    evidence_table = _html_table(
        "evidence-health", ("Status", "Diagnostic"), evidence_rows
    )

    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Migration validation report — {_escaped(report_data.migration)}</title>
<style>
:root {{ color-scheme: light; --ink:#172033; --muted:#5d6878; --line:#d9dee7; --panel:#f6f8fb; --accent:#2457c5; --pass:#176b3a; --fail:#a12622; }}
body {{ margin:0; font:14px/1.45 system-ui,sans-serif; color:var(--ink); background:#fff; }}
main {{ max-width:1400px; margin:auto; padding:28px; }}
h1 {{ margin:0 0 8px; font-size:28px; }} h2 {{ margin-top:32px; }}
.summary {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; margin:20px 0; }}
.card {{ border:1px solid var(--line); border-radius:8px; padding:14px; background:var(--panel); }}
.label {{ color:var(--muted); display:block; font-size:12px; text-transform:uppercase; }}
.status {{ font-weight:700; }} .status.PASS {{ color:var(--pass); }} .status.FAIL,.status.INCOMPLETE {{ color:var(--fail); }}
.table-wrap {{ overflow:auto; border:1px solid var(--line); border-radius:8px; }}
table {{ border-collapse:collapse; width:100%; min-width:760px; }}
th,td {{ border-bottom:1px solid var(--line); padding:8px 10px; text-align:left; vertical-align:top; }}
th {{ background:var(--panel); cursor:pointer; position:sticky; top:0; }}
.filter {{ display:block; margin:8px 0; }} .filter input {{ min-width:260px; padding:6px; }}
.empty {{ color:var(--muted); text-align:center; }} details {{ margin-top:20px; }} summary {{ cursor:pointer; font-weight:700; }}
code {{ white-space:pre-wrap; }}
</style>
</head>
<body><main>
<h1>Migration Validation Report</h1>
<section id="run-summary"><h2>Run Summary</h2>
<div class="summary">
<div class="card"><span class="label">Migration</span>{_escaped(report_data.migration)}</div>
<div class="card"><span class="label">Run</span>{_escaped(report_data.run_id)}</div>
<div class="card"><span class="label">Generated</span>{_escaped(report_data.generated_at)}</div>
<div class="card"><span class="label">Status</span><span class="status {_escaped(report_data.status)}">{_escaped(report_data.status)}</span></div>
</div></section>
<section id="schema-mapping-section"><h2>Schema Mapping</h2>{mapping_table}</section>
<section id="data-reconciliation-section"><h2>Data Reconciliation</h2>{reconciliation_table}</section>
<section id="object-inventory-section"><h2>Object Inventory</h2>{inventory_table}</section>
<section id="object-exceptions-section"><h2>Object Exceptions</h2>{exceptions_table}</section>
<details open><summary>Routine Validation</summary>{routines_table}</details>
<details><summary>Supporting Migration Context</summary>{context_table}</details>
<section id="evidence-health-section"><h2>Evidence Health</h2>{evidence_table}</section>
</main>
<script>
function filterTable(id, value) {{
  const term=value.toLocaleLowerCase();
  document.querySelectorAll('#'+id+' tbody tr').forEach(row => {{
    row.hidden=!row.textContent.toLocaleLowerCase().includes(term);
  }});
}}
document.querySelectorAll('table[data-sortable] th').forEach((header,index) => {{
  header.addEventListener('click', () => {{
    const body=header.closest('table').tBodies[0];
    const rows=Array.from(body.rows);
    const direction=header.dataset.direction==='asc' ? -1 : 1;
    rows.sort((a,b) => direction*a.cells[index].textContent.localeCompare(b.cells[index].textContent,undefined,{{numeric:true}}));
    rows.forEach(row => body.appendChild(row));
    header.dataset.direction=direction===1 ? 'asc' : 'desc';
  }});
}});
</script>
</body></html>
"""

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output_path.name}.", dir=output_path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(document)
        os.replace(temporary_name, output_path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def _build_report_data(
    sdcli_dir: Path,
    evidence_dir: Path,
    migration: str,
    run_id: str,
    generated_at: str,
) -> ReportData:
    issues: list[str] = []

    def collect(label: str, operation, default):
        try:
            return operation()
        except (EvidenceError, OSError, UnicodeError, csv.Error) as exc:
            issues.append(f"{label}: {exc}")
            return default

    source = collect(
        "source inventory",
        lambda: load_inventory(evidence_dir / "source_object_inventory.tsv"),
        [],
    )
    generated = collect(
        "generated target inventory",
        lambda: parse_generated_inventory(sdcli_dir),
        [],
    )
    target = collect(
        "target inventory",
        lambda: load_inventory(evidence_dir / "target_object_inventory.tsv"),
        [],
    )
    table_mappings = collect(
        "data-file mapping",
        lambda: build_table_mappings(evidence_dir),
        [],
    )
    mappings = collect(
        "schema mapping",
        lambda: resolve_schema_mappings(source, generated, table_mappings),
        list(table_mappings),
    )
    comparisons = collect(
        "object comparison",
        lambda: compare_objects(source, generated, target, mappings),
        [],
    )
    reconciliation = collect(
        "data reconciliation",
        lambda: _read_reconciliation(evidence_dir / "reconciliation.tsv"),
        (),
    )
    validation_checks = collect(
        "validation checks",
        lambda: _read_validation_checks(evidence_dir / "validation_checks.tsv"),
        (),
    )

    try:
        write_evidence_outputs(evidence_dir, mappings, generated, comparisons)
    except OSError as exc:
        issues.append(f"normalized evidence output: {exc}")

    mapping_issues = sum(row.status == "UNRESOLVED" for row in mappings)
    comparison_issues = sum(
        row.status not in {"MATCH", "CONTEXT"} for row in comparisons
    )
    reconciliation_issues = sum(row.get("status") != "PASS" for row in reconciliation)
    validation_findings = tuple(
        (
            status,
            f"{name}: {detail or f'{count} issue(s)'}",
        )
        for name, status, count, detail in validation_checks
        if status != "PASS"
    )
    has_incomplete_check = any(status == "INCOMPLETE" for status, _ in validation_findings)
    has_failed_check = any(status == "FAIL" for status, _ in validation_findings)
    if issues or has_incomplete_check:
        status = "INCOMPLETE"
    elif has_failed_check or mapping_issues or comparison_issues or reconciliation_issues:
        status = "FAIL"
    else:
        status = "PASS"
    return ReportData(
        migration=migration,
        run_id=run_id,
        generated_at=generated_at,
        status=status,
        mappings=tuple(mappings),
        reconciliation=tuple(reconciliation),
        source_inventory=tuple(source),
        generated_inventory=tuple(generated),
        target_inventory=tuple(target),
        comparisons=tuple(comparisons),
        evidence_issues=tuple(issues),
        validation_findings=validation_findings,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate an offline migration validation report")
    parser.add_argument("--sdcli-dir", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--migration", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args(argv)
    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    try:
        report_data = _build_report_data(
            args.sdcli_dir,
            args.evidence_dir,
            args.migration,
            args.run_id,
            generated_at,
        )
        render_report(report_data, args.output)
    except (OSError, UnicodeError, csv.Error) as exc:
        print(f"REPORT_ERROR unable to create validation report: {exc}", file=sys.stderr)
        return 1

    mapping_issues = sum(row.status == "UNRESOLVED" for row in report_data.mappings)
    comparison_issues = sum(
        row.status not in {"MATCH", "CONTEXT"} for row in report_data.comparisons
    )
    print(
        "REPORT_RESULT "
        f"status={report_data.status} "
        f"mapping_issues={mapping_issues} "
        f"comparison_issues={comparison_issues} "
        f"incomplete_sections={len(report_data.evidence_issues) + sum(status == 'INCOMPLETE' for status, _ in report_data.validation_findings)} "
        f"report={args.output}"
    )
    return 0 if report_data.status == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
