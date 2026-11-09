#!/usr/bin/env python3
"""Render migration outcomes from runner artifacts and native Oracle CSV."""
from __future__ import annotations

import argparse
import csv
import html
import os
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

PHASES = ("capture", "convert", "generate", "datamove", "offload", "deploy", "load", "postdeploy")
DIAGNOSTICS_HEADER = ("owner", "object_name", "object_type", "status", "error_line", "error_position", "error_message")
RECONCILIATION_HEADER = ("source_object", "target_object", "data_file", "exported_rows", "loaded_rows", "rejected_rows", "discarded_rows", "target_rows", "status", "reason")
COUNT_FIELDS = ("exported_rows", "loaded_rows", "rejected_rows", "discarded_rows", "target_rows")
SCOPE = "Scope: row counts and execution/object diagnostics only; no value-by-value, business-function, or missing-object comparison."


def read_records(path, header, delimiter="\t"):
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter, strict=True)
        if tuple(reader.fieldnames or ()) != header:
            raise ValueError(f"Invalid header: {path.name}")
        rows = list(reader)
        if any(None in row or any(value is None for value in row.values()) for row in rows):
            raise ValueError(f"Incomplete or extra fields: {path.name}")
        return rows


def read_phases(path):
    rows = read_records(path, ("timestamp", "phase", "state", "exit_code", "attempt", "note"))
    latest = {}
    for row in rows:
        if not row["phase"] or row["state"] not in {"started", "succeeded", "failed"}:
            raise ValueError("Invalid phase status record")
        latest[row["phase"]] = row["state"]
    return latest


def read_scripts(path):
    latest = {}
    for row in read_records(path, ("phase", "path", "status", "note")):
        if row["phase"] == "plan" or row["path"] == "__phase_complete__":
            continue
        if (
            row["phase"] not in {"deploy", "postdeploy", "cleanup"}
            or not row["path"]
            or row["status"] not in {"executed", "failed", "not_run", "pending", "planned"}
        ):
            raise ValueError("Invalid deployment outcome record")
        latest[row["phase"], row["path"]] = row
    if not latest:
        raise ValueError("No actual deployment script outcomes")
    return list(latest.values())


def read_reconciliation(path):
    rows = read_records(path, RECONCILIATION_HEADER)
    if not rows:
        raise ValueError("Table row reconciliation has no records")
    for row in rows:
        if not row["source_object"] or row["status"] not in {"PASS", "FAIL"}:
            raise ValueError("Invalid table reconciliation record")
        if any(row[key] and not row[key].isdigit() for key in COUNT_FIELDS):
            raise ValueError("Invalid table row count")
        if row["status"] == "PASS":
            if (
                any(not row[key] for key in COUNT_FIELDS)
                or not (int(row["exported_rows"]) == int(row["loaded_rows"]) == int(row["target_rows"]))
                or int(row["rejected_rows"])
                or int(row["discarded_rows"])
            ):
                raise ValueError("Inconsistent PASS row reconciliation")
    return rows


def read_diagnostics(path):
    rows = read_records(path, DIAGNOSTICS_HEADER, ",")
    for row in rows:
        if not all(row[key] for key in ("owner", "object_name", "object_type", "status")):
            raise ValueError("Incomplete Oracle object diagnostic")
        if any(row[key] and not row[key].isdigit() for key in ("error_line", "error_position")):
            raise ValueError("Invalid Oracle diagnostic line/position")
        if row["status"] != "INVALID" and not row["error_message"]:
            raise ValueError("Unexpected non-diagnostic Oracle record")
    return rows


@dataclass
class Report:
    migration: str
    run_id: str
    generated_at: str
    status: str
    phases: dict
    scripts: list
    reconciliation: list
    mapping: list
    diagnostics: list | None
    incomplete: list

    @property
    def failed_scripts(self):
        return sum(row["status"] == "failed" for row in self.scripts)

    @property
    def invalid_objects(self):
        return len({
            (row["owner"], row["object_name"], row["object_type"])
            for row in self.diagnostics or [] if row["status"] == "INVALID"
        })

    @property
    def compiler_errors(self):
        return sum(bool(row["error_message"]) for row in self.diagnostics or [])


def build_report(directory, migration, run_id):
    directory = Path(directory)
    unavailable = []

    def collect(label, operation, default):
        try:
            return operation()
        except (OSError, ValueError, UnicodeError, csv.Error) as exc:
            unavailable.append(f"{label}: {exc}")
            return default

    phases = collect("Phase outcomes", lambda: read_phases(directory / "phase_status.tsv"), {})
    scripts = collect("Deployment script outcomes", lambda: read_scripts(directory / "deploy_manifest.tsv"), [])
    reconciliation = collect("Table row reconciliation", lambda: read_reconciliation(directory / "reconciliation.tsv"), [])
    diagnostics = collect("Unable to retrieve Oracle object diagnostics", lambda: read_diagnostics(directory / "target_object_diagnostics.csv"), None)
    mapping_file = directory / "idmap/schema_mapping.tsv"
    mapping = collect("Schema mapping", lambda: read_records(mapping_file, ("source_schema", "target_schema")), []) if mapping_file.exists() else []
    for phase in PHASES:
        if phases and phases.get(phase) not in {"succeeded", "failed"}:
            unavailable.append(f"{phase}: phase not completed")
    for row in scripts:
        if row["status"] not in {"executed", "failed"}:
            unavailable.append(f"{row['phase']}: script not completed: {row['path']}")
    data = Report(
        migration=migration, run_id=run_id,
        generated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        status="", phases=phases, scripts=scripts, reconciliation=reconciliation,
        mapping=mapping, diagnostics=diagnostics,
        incomplete=list(dict.fromkeys(unavailable)),
    )
    failed = (
        any(phases.get(phase) == "failed" for phase in (*PHASES, "cleanup"))
        or data.failed_scripts
        or any(row["status"] == "FAIL" for row in reconciliation)
        or data.invalid_objects or data.compiler_errors
    )
    data.status = "FAIL" if failed else "INCOMPLETE" if data.incomplete or not phases else "PASS"
    if not phases and not data.incomplete:
        data.incomplete.append("Phase outcomes: no recorded phases")
    return data


def totals(data):
    return {key: sum(int(row[key]) for row in data.reconciliation if row[key]) for key in COUNT_FIELDS}


def text_report(data):
    lines = ["Migration Validation Report", "===========================", f"Migration: {data.migration}", f"Run: {data.run_id}", f"Generated: {data.generated_at}", f"Status: {data.status}", "", "Migration Summary", "-----------------"]
    lines.extend(f"  {phase:<12} {data.phases.get(phase, 'not recorded')}" for phase in PHASES)
    if data.scripts:
        lines.append(f"  Scripts: {sum(row['status'] == 'executed' for row in data.scripts)} completed, {data.failed_scripts} failed")
    else:
        lines.append("  Script outcomes: unavailable")
    if data.diagnostics is not None:
        lines.append(f"  Oracle objects: {data.invalid_objects} invalid, {data.compiler_errors} compiler errors")
    if data.mapping:
        lines += ["", "Schema Mapping", "--------------"]
        lines.extend(f"  {row['source_schema']} -> {row['target_schema']}" for row in data.mapping)
    lines += ["", "Table Data Transfer", "-------------------"]
    lines.append(f"  Tables: {len(data.reconciliation)}; rows: {totals(data)['target_rows']}" if data.reconciliation else "  Row reconciliation unavailable; see Checks Not Completed.")
    for row in data.reconciliation:
        lines.append(f"{row['status']}: {row['source_object']} -> {row['target_object']}")
        lines.append("  " + "  ".join(f"{key.removesuffix('_rows')}={row[key] or 'unavailable'}" for key in COUNT_FIELDS))
        if row["reason"]:
            lines.append(f"  {row['reason']}")
    lines += ["", "Scripts Requiring Attention", "---------------------------"]
    attention = [row for row in data.scripts if row["status"] != "executed"]
    lines.extend(f"  {row['phase']}: {row['path']} — {row['status']}\n    {row['note']}" for row in attention)
    if not attention:
        lines.append("  No failed or incomplete script records." if data.scripts else "  Script outcomes unavailable; see Checks Not Completed.")
    lines += ["", "Objects Requiring Repair", "------------------------"]
    if data.diagnostics is None:
        lines.append("  Unable to retrieve Oracle object diagnostics; see Checks Not Completed.")
    elif not data.diagnostics:
        lines.append("  No invalid objects or compiler errors.")
    for row in data.diagnostics or []:
        lines.append(f"  {row['owner']}.{row['object_name']} — {row['object_type']} ({row['status']})")
        if row["error_message"]:
            lines.append(f"    Line {row['error_line'] or '?'}:{row['error_position'] or '?'}")
            lines.extend(f"      {line}" for line in row["error_message"].splitlines())
    if data.incomplete:
        lines += ["", "Checks Not Completed", "--------------------", *(f"  {message}" for message in data.incomplete)]
    lines += ["", "Details: migrate.log and native SQL Developer/loader logs.", SCOPE, ""]
    return "\n".join(lines)


def html_report(data):
    # One readable content model keeps HTML, terminal output, and status aligned.
    body = html.escape(text_report(data))
    for title in ("Migration Summary", "Schema Mapping", "Table Data Transfer", "Scripts Requiring Attention", "Objects Requiring Repair", "Checks Not Completed"):
        body = body.replace(html.escape(title) + "\n" + "-" * len(title), f"</pre><h2>{title}</h2><pre>")
    return f'''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Migration Validation Report — {html.escape(data.migration)}</title>
<style>body{{max-width:1100px;margin:2rem auto;padding:0 1rem;font:15px/1.5 system-ui;color:#172033}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.6 ui-monospace,monospace}}h2{{border-bottom:1px solid #ddd;padding-bottom:.4rem}}</style>
<pre>{body}</pre></html>'''


def _atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--migration", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args(argv)
    try:
        data = build_report(args.evidence_dir, args.migration, args.run_id)
        _atomic_write(args.output, html_report(data))
        _atomic_write(args.output.with_suffix(".txt"), text_report(data))
        summary = {"status": data.status, "tables": len(data.reconciliation), **totals(data), "failed_scripts": data.failed_scripts, "invalid_objects": data.invalid_objects if data.diagnostics is not None else "unavailable", "compiler_errors": data.compiler_errors if data.diagnostics is not None else "unavailable", "incomplete_checks": len(data.incomplete)}
        _atomic_write(args.evidence_dir / "validation_summary.txt", "".join(f"{key}={value}\n" for key, value in summary.items()))
        print(f"REPORT_RESULT status={data.status} report={args.output} text_report={args.output.with_suffix('.txt')}")
        return 0 if data.status == "PASS" else 2
    except (OSError, ValueError, UnicodeError, csv.Error) as exc:
        print(f"Report generation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
