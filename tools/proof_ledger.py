#!/usr/bin/env python3
"""Gestructureerde bewijsledger en de canonieke acceptatiecatalogus."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "specs" / "acceptance-catalog.json"


def load_catalog(path: Path = CATALOG_PATH) -> dict[str, Any]:
    catalog = json.loads(path.read_text())
    ids = [item["id"] for item in catalog["acceptanceCriteria"]]
    if len(ids) != len(set(ids)):
        raise ValueError("acceptatiecatalogus bevat dubbele ids")
    known = set(ids)
    for item in catalog["acceptanceCriteria"]:
        unknown = set(item.get("dependsOn", [])) - known
        if unknown:
            raise ValueError(f"{item['id']} heeft onbekende afhankelijkheden: {sorted(unknown)}")
    return catalog


def catalog_by_id(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in catalog["acceptanceCriteria"]}


def parse_summary(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    text = path.read_text()
    result: dict[str, Any] = {"text": text, "mode": "", "exitCode": None, "filter": ""}
    for line in text.splitlines():
        if line.startswith("run:"):
            result["runId"] = line.split(":", 1)[1].strip()
        elif line.startswith("mode:"):
            result["mode"] = line.split(":", 1)[1].strip()
        elif line.startswith("filter:"):
            result["filter"] = line.split(":", 1)[1].strip().split(" ", 1)[0]
        elif line.startswith("exitcode:"):
            raw = line.split(":", 1)[1].strip()
            result["exitCode"] = int(raw) if raw.isdigit() else None
    failures: dict[str, str] = {}
    capture = False
    for line in text.splitlines():
        if line.startswith("-- niet in orde"):
            capture = True
            continue
        if capture and line.startswith("  "):
            message = line.strip()
            match = re.match(r"(AC-[0-9]+[a-z]?):\s*(.*)", message)
            if match:
                failures[match.group(1)] = match.group(2)
    result["failures"] = failures
    return result


def parse_results(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    # bin/sandbox test schrijft statusovergangen append-only (bezig -> pass/fail en soms later
    # pass -> ongeldig door een afhankelijke poort). Net als status_van in Bash wint de
    # laatste status, maar de oorspronkelijke volgorde van ids blijft behouden.
    by_id: dict[str, dict[str, str]] = {}
    for line in path.read_text().splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[0]:
            by_id[parts[0]] = {"id": parts[0], "status": parts[1], "description": parts[2]}
    return list(by_id.values())


def expected_from_environment(path: Path) -> list[str]:
    if not path.is_file():
        return []
    match = re.search(r"^verwacht:\s+\d+ tests:\s*(.*)$", path.read_text(), re.MULTILINE)
    return match.group(1).split() if match else []


def build_manifest(root: Path, evidence: Path) -> dict[str, Any]:
    catalog = load_catalog(root / "specs" / "acceptance-catalog.json")
    known = catalog_by_id(catalog)
    summary = parse_summary(evidence / "samenvatting.txt")
    raw_results = parse_results(evidence / "results.tsv")
    unknown = [item["id"] for item in raw_results if item["id"] not in known]
    if unknown:
        raise ValueError(f"resultaten bevatten onbekende AC-ids: {unknown}")
    allowed = set(catalog["statuses"])
    failures = summary.get("failures", {})
    notes_path = root / "local" / "proof-notes.json"
    try:
        notes = json.loads(notes_path.read_text()) if notes_path.is_file() else {}
    except json.JSONDecodeError:
        notes = {}
    results = []
    for raw in raw_results:
        item = dict(raw)
        if item["id"] in failures:
            item["status"] = "ongeldig" if "ONGELDIG" in failures[item["id"]] else "fail"
            item["reason"] = failures[item["id"]]
        if item["status"] not in allowed:
            raise ValueError(f"ongeldige status voor {item['id']}: {item['status']}")
        noted_status = notes.get(item["id"])
        if noted_status in allowed:
            item["status"] = noted_status
            item["source"] = "local/proof-notes.json"
        meta = known[item["id"]]
        item["kind"] = meta["kind"]
        item["evidence"] = meta["evidence"]
        if meta.get("dependsOn"):
            item["dependsOn"] = meta["dependsOn"]
        results.append(item)
    counts = {status: 0 for status in catalog["statuses"]}
    for item in results:
        counts[item["status"]] += 1
    mode = summary.get("mode") or "onbekend"
    gate_notes = notes.get("releaseGates", {})
    gates = []
    for gate in catalog["releaseGates"]:
        status = gate_notes.get(gate["id"], "open")
        if status not in {"open", "closed"}:
            raise ValueError(f"ongeldige vrijgavepoortstatus voor {gate['id']}: {status}")
        gates.append(dict(gate, status=status))
    return {
        "schemaVersion": 1,
        "runId": summary.get("runId") or evidence.name,
        "mode": mode,
        "filter": summary.get("filter") or None,
        "partial": bool(summary.get("filter")) or mode == "onbekend",
        "exitCode": summary.get("exitCode"),
        "expected": expected_from_environment(evidence / "environment.txt"),
        "counts": counts,
        "results": results,
        "releaseGates": gates,
        "sources": {"summary": "samenvatting.txt", "environment": "environment.txt", "results": "results.tsv"},
    }


def write_manifest(root: Path, evidence: Path) -> Path:
    target = evidence / "run.json"
    target.write_text(json.dumps(build_manifest(root, evidence), indent=2, ensure_ascii=False) + "\n")
    return target


def load_manifest(evidence: Path) -> dict[str, Any] | None:
    path = evidence / "run.json"
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError:
        return None
    return value if value.get("schemaVersion") == 1 else None


def render_console(manifest: dict[str, Any]) -> str:
    """Render een compacte consoleweergave uit dezelfde ledger als de matrix."""
    counts = manifest.get("counts", {})
    failed = counts.get("fail", 0) + counts.get("ongeldig", 0)
    lines = [
        f"run:        {manifest.get('runId', 'onbekend')}",
        f"mode:       {manifest.get('mode', 'onbekend')}",
    ]
    if manifest.get("filter"):
        lines.append(f"filter:     {manifest['filter']} (DEELRUN - dit is geen volledige run)")
    lines.extend([
        "geslaagd {passed}   gefaald {failed}   overgeslagen {skipped}   "
        "handmatig {manual}   (verwacht {expected})".format(
            passed=counts.get("pass", 0), failed=failed, skipped=counts.get("skip", 0),
            manual=counts.get("handmatig", 0), expected=len(manifest.get("expected", [])),
        ),
        f"exitcode:   {manifest.get('exitCode', '?')}",
    ])
    problems = [item for item in manifest.get("results", []) if item.get("status") in {"fail", "ongeldig"}]
    if problems:
        lines.append("-- niet in orde --")
        lines.extend(f"  {item['id']}: {item.get('reason') or item.get('description', '')}" for item in problems)
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Schrijf run.json uit de ruwe runartefacten.")
    parser.add_argument("--root", default=str(ROOT))
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--print-summary", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--read-only", action="store_true", help="Render bestaand run.json zonder herschrijven.")
    args = parser.parse_args(argv)
    root, evidence = Path(args.root), Path(args.evidence)
    if not evidence.is_dir():
        print(f"FOUT: evidence-map ontbreekt: {evidence}")
        return 2
    try:
        target = evidence / "run.json"
        if args.read_only:
            if load_manifest(evidence) is None:
                raise ValueError("run.json ontbreekt of heeft een onbekend schema")
        else:
            target = write_manifest(root, evidence)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"FOUT: runmanifest kon niet worden geschreven: {error}")
        return 2
    if not args.quiet and not args.read_only:
        print(f"geschreven: {target}")
    if args.print_summary:
        print(render_console(load_manifest(evidence) or {}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
