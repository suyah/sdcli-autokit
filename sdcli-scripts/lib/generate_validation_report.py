#!/usr/bin/env python3
"""Render migration validation reports from direct, structured evidence.

Database queries and orchestration remain in migrate.sh.  This module reads
only autokit-owned TSV contracts; it never parses SQL Developer generated DDL.
"""

from __future__ import annotations

import argparse
import csv
import html
import os
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
VALID_CHECK_STATUSES = {"PASS", "FAIL", "INCOMPLETE", "NOT_EVALUATED"}
REQUIRED_VALIDATION_CHECKS = {
    "run_log",
    "sdcli_error_log",
    "sqlldr_logs",
    "missing_evidence",
    "reconciliation",
    "target_objects",
    "metadata_collection",
}
PLAN_DEPLOY_STATUSES = {"control", "covered", "excluded"}
OPERATIONAL_DEPLOY_STATUSES = {"executed", "failed", "not_run", "pending", "planned"}
INCOMPLETE_DEPLOY_STATUSES = {"not_run", "pending", "planned"}


class EvidenceError(ValueError):
    """Raised when an evidence artifact is missing, empty, or malformed."""


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


@dataclass(frozen=True)
class ValidationCheck:
    check: str
    status: str
    issues: int
    detail: str


@dataclass(frozen=True)
class DeploymentRecord:
    phase: str
    path: str
    status: str
    note: str


@dataclass(frozen=True)
class InvalidObjectFinding:
    owner: str
    name: str
    object_type: str
    status: str
    line: str
    position: str
    message: str


@dataclass(frozen=True)
class InventoryCount:
    stage: str
    schema: str
    category: str
    count: int


@dataclass(frozen=True)
class EvidenceHealth:
    status: str
    section: str
    detail: str


@dataclass(frozen=True)
class ReportData:
    migration: str
    run_id: str
    generated_at: str
    status: str
    summary: tuple[ValidationCheck, ...]
    reconciliation: tuple[dict[str, str], ...]
    deployment_records: tuple[DeploymentRecord, ...]
    invalid_objects: tuple[InvalidObjectFinding, ...]
    inventory_counts: tuple[InventoryCount, ...]
    evidence_health: tuple[EvidenceHealth, ...]


def _object_sort_key(record: ObjectRecord) -> tuple[object, ...]:
    return (
        record.schema.casefold(),
        record.category,
        record.name.casefold(),
        record.parent_schema.casefold(),
        record.parent_name.casefold(),
        record.subtype,
        record.attributes,
        record.detail,
    )


def _require_complete_tsv_row(
    path: Path,
    line_number: int,
    row: dict[str | None, str | None],
    fields: Sequence[str],
) -> None:
    if None in row or any(row.get(field) is None for field in fields):
        raise EvidenceError(f"malformed TSV row: {path}:{line_number}")


def load_inventory(path: Path) -> list[ObjectRecord]:
    """Load strict marker-derived inventory TSV into logical object records."""

    path = Path(path)
    grouped: dict[tuple[str, ...], list[InventoryAttribute]] = defaultdict(list)
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != INVENTORY_HEADER:
            raise EvidenceError(f"invalid inventory header: {path}")
        for line_number, row in enumerate(reader, start=2):
            _require_complete_tsv_row(path, line_number, row, INVENTORY_HEADER)
            if not row["schema"] or not row["category"] or not row["object_name"]:
                raise EvidenceError(f"incomplete inventory row: {path}:{line_number}")
            category = row["category"].upper()
            key = (
                row["schema"],
                category,
                row["object_name"],
                row["parent_schema"],
                row["parent_name"],
                row["subtype"].upper(),
                row["status"].upper(),
                row["detail"],
                row["origin"],
                row["ordinal"] if category == "COMPILER_ERRORS" else "",
            )
            if row["attribute_name"] or row["attribute_value"] or row["ordinal"]:
                try:
                    ordinal = int(row["ordinal"] or 0)
                except ValueError as exc:
                    raise EvidenceError(
                        f"invalid inventory ordinal: {path}:{line_number}"
                    ) from exc
                grouped[key].append(
                    InventoryAttribute(
                        ordinal, row["attribute_name"], row["attribute_value"]
                    )
                )
            else:
                grouped.setdefault(key, [])

    if not grouped:
        raise EvidenceError(f"inventory evidence is empty: {path}")

    records = [
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
        for key, attributes in grouped.items()
    ]
    return sorted(records, key=_object_sort_key)


def _read_reconciliation(path: Path) -> tuple[dict[str, str], ...]:
    path = Path(path)
    required = (
        "source_object",
        "target_object",
        "data_file",
        "exported_rows",
        "loaded_rows",
        "rejected_rows",
        "discarded_rows",
        "target_rows",
        "status",
        "reason",
    )
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != required:
            raise EvidenceError(f"invalid reconciliation header: {path}")
        rows = []
        for line_number, row in enumerate(reader, start=2):
            _require_complete_tsv_row(path, line_number, row, required)
            rows.append(dict(row))
    if not rows:
        raise EvidenceError(f"reconciliation evidence is empty: {path}")
    for line_number, row in enumerate(rows, start=2):
        if not row["source_object"] or not row["status"]:
            raise EvidenceError(f"incomplete reconciliation row: {path}:{line_number}")
        status = row["status"].upper()
        if status not in {"PASS", "FAIL"}:
            raise EvidenceError(f"invalid reconciliation status: {path}:{line_number}")
        count_fields = (
            "exported_rows",
            "loaded_rows",
            "rejected_rows",
            "discarded_rows",
            "target_rows",
        )
        if any(row[field] and not row[field].isdigit() for field in count_fields):
            raise EvidenceError(f"invalid reconciliation count: {path}:{line_number}")
        if status == "PASS":
            if any(not row[field] for field in count_fields):
                raise EvidenceError(f"incomplete PASS reconciliation: {path}:{line_number}")
            if (
                row["exported_rows"] != row["loaded_rows"]
                or row["loaded_rows"] != row["target_rows"]
                or row["rejected_rows"] != "0"
                or row["discarded_rows"] != "0"
            ):
                raise EvidenceError(f"inconsistent PASS reconciliation: {path}:{line_number}")
    return tuple(rows)


def _read_validation_checks(path: Path) -> tuple[ValidationCheck, ...]:
    path = Path(path)
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != ("check", "status", "issues", "detail"):
            raise EvidenceError(f"invalid validation checks header: {path}")
        checks = []
        seen_checks: set[str] = set()
        for line_number, row in enumerate(reader, start=2):
            _require_complete_tsv_row(
                path, line_number, row, ("check", "status", "issues", "detail")
            )
            status = row["status"].upper()
            if not row["check"] or status not in VALID_CHECK_STATUSES:
                raise EvidenceError(f"invalid validation check: {path}:{line_number}")
            if row["check"] in seen_checks:
                raise EvidenceError(f"duplicate validation check: {path}:{line_number}")
            try:
                issues = int(row["issues"])
            except ValueError as exc:
                raise EvidenceError(
                    f"invalid validation check issue count: {path}:{line_number}"
                ) from exc
            if issues < 0 or (status == "PASS" and issues != 0):
                raise EvidenceError(f"inconsistent validation check: {path}:{line_number}")
            checks.append(ValidationCheck(row["check"], status, issues, row["detail"]))
            seen_checks.add(row["check"])
    if not checks:
        raise EvidenceError(f"validation checks evidence is empty: {path}")
    missing = sorted(REQUIRED_VALIDATION_CHECKS - seen_checks)
    if missing:
        raise EvidenceError(
            f"validation checks evidence is incomplete: {path}: missing {', '.join(missing)}"
        )
    return tuple(checks)


def _read_deploy_manifest(path: Path) -> tuple[DeploymentRecord, ...]:
    """Return the latest outcome for each phase/path pair."""

    path = Path(path)
    latest: dict[tuple[str, str], DeploymentRecord] = {}
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != ("phase", "path", "status", "note"):
            raise EvidenceError(f"invalid deploy manifest header: {path}")
        for line_number, row in enumerate(reader, start=2):
            _require_complete_tsv_row(
                path, line_number, row, ("phase", "path", "status", "note")
            )
            if not row["phase"] or not row["path"] or not row["status"]:
                raise EvidenceError(f"incomplete deploy manifest row: {path}:{line_number}")
            phase = row["phase"].lower()
            status = row["status"].lower()
            if phase == "plan":
                allowed_statuses = PLAN_DEPLOY_STATUSES
            elif phase in {"deploy", "postdeploy", "cleanup"}:
                allowed_statuses = OPERATIONAL_DEPLOY_STATUSES
            else:
                allowed_statuses = set()
            if status not in allowed_statuses:
                raise EvidenceError(f"invalid deploy manifest state: {path}:{line_number}")
            record = DeploymentRecord(
                phase, row["path"], status, row["note"]
            )
            latest[(record.phase, record.path)] = record
    if not latest:
        raise EvidenceError(f"deploy manifest evidence is empty: {path}")
    return tuple(
        sorted(latest.values(), key=lambda row: (row.phase, row.path.casefold()))
    )


def _line_and_position(record: ObjectRecord) -> tuple[str, str]:
    for attribute in record.attributes:
        if attribute.name == "line_position":
            line, separator, position = attribute.value.partition(":")
            return line, position if separator else ""
    return "", ""


def _invalid_object_findings(
    target_inventory: Sequence[ObjectRecord],
) -> tuple[InvalidObjectFinding, ...]:
    invalid_records: dict[tuple[str, str, str], ObjectRecord] = {}
    compiler_records: list[ObjectRecord] = []
    for record in target_inventory:
        key = (record.schema, record.name, record.subtype)
        if record.category == "COMPILER_ERRORS":
            if record.status == "INVALID":
                compiler_records.append(record)
        elif record.status and record.status != "VALID":
            invalid_records[key] = record

    findings: list[InvalidObjectFinding] = []
    covered: set[tuple[str, str, str]] = set()
    for record in compiler_records:
        key = (record.schema, record.name, record.subtype)
        invalid = invalid_records.get(key)
        line, position = _line_and_position(record)
        findings.append(
            InvalidObjectFinding(
                owner=record.schema,
                name=record.name,
                object_type=record.subtype,
                status=invalid.status if invalid else record.status,
                line=line,
                position=position,
                message=record.detail,
            )
        )
        covered.add(key)

    for key, record in invalid_records.items():
        if key in covered:
            continue
        findings.append(
            InvalidObjectFinding(
                owner=record.schema,
                name=record.name,
                object_type=record.subtype or record.category,
                status=record.status,
                line="",
                position="",
                message=record.detail,
            )
        )
    return tuple(
        sorted(
            findings,
            key=lambda row: (
                row.owner.casefold(),
                row.name.casefold(),
                row.object_type,
                int(row.line) if row.line.isdigit() else 0,
                int(row.position) if row.position.isdigit() else 0,
                row.message,
            ),
        )
    )


def _inventory_counts(
    source: Sequence[ObjectRecord], target: Sequence[ObjectRecord]
) -> tuple[InventoryCount, ...]:
    counts: Counter[tuple[str, str, str]] = Counter()
    for stage, records in (("Source", source), ("Target", target)):
        for record in records:
            if record.category == "COMPILER_ERRORS":
                continue
            counts[(stage, record.schema, record.category)] += 1
    return tuple(
        InventoryCount(stage, schema, category, count)
        for (stage, schema, category), count in sorted(
            counts.items(),
            key=lambda item: (
                item[0][0],
                item[0][1].casefold(),
                item[0][2],
            ),
        )
    )


def _build_report_data(
    evidence_dir: Path,
    migration: str,
    run_id: str,
    generated_at: str,
) -> ReportData:
    evidence_dir = Path(evidence_dir)
    evidence_issues: list[EvidenceHealth] = []

    def collect(label: str, operation, default):
        try:
            return operation()
        except (EvidenceError, OSError, UnicodeError, csv.Error) as exc:
            evidence_issues.append(EvidenceHealth("INCOMPLETE", label, str(exc)))
            return default

    validation_checks = collect(
        "validation checks",
        lambda: _read_validation_checks(evidence_dir / "validation_checks.tsv"),
        (),
    )
    reconciliation = collect(
        "data reconciliation",
        lambda: _read_reconciliation(evidence_dir / "reconciliation.tsv"),
        (),
    )
    deployments = collect(
        "deployment manifest",
        lambda: _read_deploy_manifest(evidence_dir / "deploy_manifest.tsv"),
        (),
    )
    source = collect(
        "source inventory",
        lambda: load_inventory(evidence_dir / "source_object_inventory.tsv"),
        (),
    )
    target = collect(
        "target inventory",
        lambda: load_inventory(evidence_dir / "target_object_inventory.tsv"),
        (),
    )

    invalid_objects = _invalid_object_findings(target)
    inventory_counts = _inventory_counts(source, target)
    failed_deployments = sum(row.status == "failed" for row in deployments)
    incomplete_deployments = sum(
        row.status in INCOMPLETE_DEPLOY_STATUSES for row in deployments
    )
    deploy_record_count = sum(row.phase == "deploy" for row in deployments)
    invalid_keys = {
        (row.owner, row.name, row.object_type)
        for row in invalid_objects
    }
    compiler_error_count = sum(
        record.category == "COMPILER_ERRORS" and record.status == "INVALID"
        for record in target
    )
    if not deployments or not deploy_record_count or incomplete_deployments:
        deployment_status = "INCOMPLETE"
    elif failed_deployments:
        deployment_status = "FAIL"
    else:
        deployment_status = "PASS"
    invalid_status = (
        "INCOMPLETE"
        if not target
        else "FAIL"
        if invalid_keys or compiler_error_count
        else "PASS"
    )

    summary = list(validation_checks)
    summary.extend(
        (
            ValidationCheck(
                "deployment_scripts",
                deployment_status,
                1
                if not deployments or not deploy_record_count
                else failed_deployments + incomplete_deployments,
                (
                    f"records={len(deployments)} deploy_records={deploy_record_count} "
                    f"failed={failed_deployments} "
                    f"not_run={incomplete_deployments}"
                )
                if deployments
                else "deployment manifest is unavailable",
            ),
            ValidationCheck(
                "invalid_target_objects",
                invalid_status,
                1 if not target else len(invalid_keys),
                f"invalid_objects={len(invalid_keys)} compiler_errors={compiler_error_count}"
                if target
                else "target inventory is unavailable",
            ),
            ValidationCheck(
                "metadata_coverage",
                "NOT_EVALUATED",
                0,
                "structured source-to-converted object mapping is unavailable; generated SQL was not parsed",
            ),
            ValidationCheck(
                "source_inventory",
                "PASS" if source else "INCOMPLETE",
                0 if source else 1,
                f"objects={len(source)}" if source else "source inventory is unavailable",
            ),
            ValidationCheck(
                "target_inventory",
                "PASS" if target else "INCOMPLETE",
                0 if target else 1,
                f"objects={len(target) - compiler_error_count} compiler_errors={compiler_error_count}"
                if target
                else "target inventory is unavailable",
            ),
        )
    )

    reconciliation_failed = any(row.get("status", "").upper() != "PASS" for row in reconciliation)
    if evidence_issues or any(row.status == "INCOMPLETE" for row in summary):
        status = "INCOMPLETE"
    elif (
        any(row.status == "FAIL" for row in summary)
        or reconciliation_failed
        or failed_deployments
        or invalid_objects
    ):
        status = "FAIL"
    else:
        status = "PASS"

    if not evidence_issues:
        evidence_issues.append(
            EvidenceHealth("PASS", "required evidence", "all required evidence was readable")
        )

    return ReportData(
        migration=migration,
        run_id=run_id,
        generated_at=generated_at,
        status=status,
        summary=tuple(summary),
        reconciliation=tuple(reconciliation),
        deployment_records=tuple(deployments),
        invalid_objects=invalid_objects,
        inventory_counts=inventory_counts,
        evidence_health=tuple(evidence_issues),
    )


def _clean_text(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _text_table(headers: Sequence[str], rows: Iterable[Sequence[object]]) -> list[str]:
    clean_rows = [[_clean_text(value) for value in row] for row in rows]
    if not clean_rows:
        return ["No records."]
    clean_headers = [_clean_text(value) for value in headers]
    widths = [len(value) for value in clean_headers]
    for row in clean_rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    if sum(widths) + (3 * (len(widths) - 1)) <= 120:
        def aligned(row: Sequence[str]) -> str:
            return " | ".join(value.ljust(widths[index]) for index, value in enumerate(row)).rstrip()

        return [
            aligned(clean_headers),
            "-+-".join("-" * width for width in widths),
            *(aligned(row) for row in clean_rows),
        ]

    def pipe_row(row: Sequence[str]) -> str:
        return "| " + " | ".join(value.replace("|", "\\|") for value in row) + " |"

    return [pipe_row(clean_headers), *(pipe_row(row) for row in clean_rows)]


def _append_text_section(
    lines: list[str], heading: str, headers: Sequence[str], rows: Iterable[Sequence[object]]
) -> None:
    lines.extend(("", heading, "-" * len(heading)))
    lines.extend(_text_table(headers, rows))


def _atomic_write(path: Path, content: str) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def render_text_report(report_data: ReportData, output_path: Path) -> None:
    lines = [
        "Migration Validation Report",
        "===========================",
        f"Migration: {report_data.migration}",
        f"Run: {report_data.run_id}",
        f"Generated: {report_data.generated_at}",
        f"Status: {report_data.status}",
    ]
    _append_text_section(
        lines,
        "Validation Summary",
        ("Check", "Status", "Issues", "Detail"),
        ((row.check, row.status, row.issues, row.detail) for row in report_data.summary),
    )
    _append_text_section(
        lines,
        "Data Reconciliation",
        ("Source", "Target", "Exported", "Loaded", "Rejected", "Discarded", "Target rows", "Status", "Reason"),
        (
            (
                row.get("source_object", ""),
                row.get("target_object", ""),
                row.get("exported_rows", ""),
                row.get("loaded_rows", ""),
                row.get("rejected_rows", ""),
                row.get("discarded_rows", ""),
                row.get("target_rows", ""),
                row.get("status", ""),
                row.get("reason", ""),
            )
            for row in report_data.reconciliation
        ),
    )
    _append_text_section(
        lines,
        "Deployment Script Outcomes",
        ("Phase", "Path", "Status", "Note"),
        ((row.phase, row.path, row.status, row.note) for row in report_data.deployment_records),
    )
    _append_text_section(
        lines,
        "Invalid Oracle Objects and Compiler Diagnostics",
        ("Owner", "Object", "Type", "Status", "Line", "Position", "Message"),
        (
            (row.owner, row.name, row.object_type, row.status, row.line, row.position, row.message)
            for row in report_data.invalid_objects
        ),
    )
    _append_text_section(
        lines,
        "Metadata Coverage",
        ("Status", "Detail"),
        (
            (row.status, row.detail)
            for row in report_data.summary
            if row.check == "metadata_coverage"
        ),
    )
    _append_text_section(
        lines,
        "Inventory Counts",
        ("Stage", "Schema", "Category", "Count"),
        ((row.stage, row.schema, row.category, row.count) for row in report_data.inventory_counts),
    )
    _append_text_section(
        lines,
        "Evidence Health",
        ("Status", "Section", "Diagnostic"),
        ((row.status, row.section, row.detail) for row in report_data.evidence_health),
    )
    lines.append("")
    _atomic_write(Path(output_path), "\n".join(lines))


def _escaped(value: object) -> str:
    return html.escape(str(value), quote=True)


def _html_table(headers: Sequence[str], rows: Iterable[Sequence[object]]) -> str:
    row_values = list(rows)
    header = "".join(f'<th scope="col">{_escaped(value)}</th>' for value in headers)
    if row_values:
        body = "".join(
            "<tr>" + "".join(f"<td>{_escaped(value)}</td>" for value in row) + "</tr>"
            for row in row_values
        )
    else:
        body = f'<tr><td colspan="{len(headers)}" class="empty">No records</td></tr>'
    return (
        '<div class="table-wrap"><table><thead><tr>'
        + header
        + "</tr></thead><tbody>"
        + body
        + "</tbody></table></div>"
    )


def render_report(report_data: ReportData, output_path: Path) -> None:
    summary_table = _html_table(
        ("Check", "Status", "Issues", "Detail"),
        ((row.check, row.status, row.issues, row.detail) for row in report_data.summary),
    )
    reconciliation_table = _html_table(
        ("Source", "Target", "Exported", "Loaded", "Rejected", "Discarded", "Target rows", "Status", "Reason"),
        (
            (
                row.get("source_object", ""),
                row.get("target_object", ""),
                row.get("exported_rows", ""),
                row.get("loaded_rows", ""),
                row.get("rejected_rows", ""),
                row.get("discarded_rows", ""),
                row.get("target_rows", ""),
                row.get("status", ""),
                row.get("reason", ""),
            )
            for row in report_data.reconciliation
        ),
    )
    deployment_table = _html_table(
        ("Phase", "Path", "Status", "Note"),
        ((row.phase, row.path, row.status, row.note) for row in report_data.deployment_records),
    )
    invalid_table = _html_table(
        ("Owner", "Object", "Type", "Status", "Line", "Position", "Message"),
        (
            (row.owner, row.name, row.object_type, row.status, row.line, row.position, row.message)
            for row in report_data.invalid_objects
        ),
    )
    metadata_table = _html_table(
        ("Status", "Detail"),
        ((row.status, row.detail) for row in report_data.summary if row.check == "metadata_coverage"),
    )
    inventory_table = _html_table(
        ("Stage", "Schema", "Category", "Count"),
        ((row.stage, row.schema, row.category, row.count) for row in report_data.inventory_counts),
    )
    health_table = _html_table(
        ("Status", "Section", "Diagnostic"),
        ((row.status, row.section, row.detail) for row in report_data.evidence_health),
    )

    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Migration validation report — {_escaped(report_data.migration)}</title>
<style>
:root {{ color-scheme:light; --ink:#172033; --muted:#5d6878; --line:#d9dee7; --panel:#f6f8fb; --pass:#176b3a; --fail:#a12622; }}
body {{ margin:0; font:14px/1.45 system-ui,sans-serif; color:var(--ink); background:#fff; }}
main {{ max-width:1400px; margin:auto; padding:28px; }}
h1 {{ margin:0 0 8px; font-size:28px; }} h2 {{ margin-top:32px; }}
.summary {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; margin:20px 0; }}
.card {{ border:1px solid var(--line); border-radius:8px; padding:14px; background:var(--panel); }}
.label {{ color:var(--muted); display:block; font-size:12px; text-transform:uppercase; }}
.status {{ font-weight:700; }} .PASS {{ color:var(--pass); }} .FAIL,.INCOMPLETE {{ color:var(--fail); }}
.table-wrap {{ overflow:auto; border:1px solid var(--line); border-radius:8px; }}
table {{ border-collapse:collapse; width:100%; min-width:720px; }}
th,td {{ border-bottom:1px solid var(--line); padding:8px 10px; text-align:left; vertical-align:top; }}
th {{ background:var(--panel); }} .empty {{ color:var(--muted); text-align:center; }}
</style>
</head>
<body><main>
<h1>Migration Validation Report</h1>
<div class="summary">
<div class="card"><span class="label">Migration</span>{_escaped(report_data.migration)}</div>
<div class="card"><span class="label">Run</span>{_escaped(report_data.run_id)}</div>
<div class="card"><span class="label">Generated</span>{_escaped(report_data.generated_at)}</div>
<div class="card"><span class="label">Status</span><span class="status {_escaped(report_data.status)}">{_escaped(report_data.status)}</span></div>
</div>
<section><h2>Validation Summary</h2>{summary_table}</section>
<section><h2>Data Reconciliation</h2>{reconciliation_table}</section>
<section><h2>Deployment Script Outcomes</h2>{deployment_table}</section>
<section><h2>Invalid Oracle Objects and Compiler Diagnostics</h2>{invalid_table}</section>
<section><h2>Metadata Coverage</h2>{metadata_table}</section>
<section><h2>Inventory Counts</h2>{inventory_table}</section>
<section><h2>Evidence Health</h2>{health_table}</section>
</main></body></html>
"""
    _atomic_write(Path(output_path), document)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate an offline migration validation report from structured evidence"
    )
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
            args.evidence_dir, args.migration, args.run_id, generated_at
        )
        render_report(report_data, args.output)
        render_text_report(report_data, args.output.with_suffix(".txt"))
    except (OSError, UnicodeError, csv.Error) as exc:
        print(f"REPORT_ERROR unable to create validation report: {exc}", file=sys.stderr)
        return 1

    failed_checks = sum(row.status == "FAIL" for row in report_data.summary)
    failed_deployments = sum(
        row.status == "failed" for row in report_data.deployment_records
    )
    invalid_objects = len(
        {
            (row.owner, row.name, row.object_type)
            for row in report_data.invalid_objects
        }
    )
    incomplete_sections = sum(
        row.status == "INCOMPLETE" for row in report_data.evidence_health
    )
    not_evaluated_sections = sum(
        row.status == "NOT_EVALUATED" for row in report_data.summary
    )
    print(
        "REPORT_RESULT "
        f"status={report_data.status} "
        f"failed_checks={failed_checks} "
        f"failed_deployments={failed_deployments} "
        f"invalid_objects={invalid_objects} "
        f"incomplete_sections={incomplete_sections} "
        f"not_evaluated_sections={not_evaluated_sections} "
        f"report={args.output} "
        f"text_report={args.output.with_suffix('.txt')}"
    )
    return 0 if report_data.status == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
