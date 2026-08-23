#!/usr/bin/env python3
"""Observeer, plan en verifieer de lifecycle van één laptopproef.

Het hash-gekoppelde journal onder ``local/`` is bewijs van uitgevoerde
overgangen, niet de uitvoerder daarvan. Bash en PowerShell blijven de adapters
voor installatie, plaatsing en rollback. Deze module automatiseert bewust geen
destructieve cleanup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from agent_gate import GateError, require_voorbereiding
from placement_gate import verify_manifest

SCHEMA_VERSION = 1
JOURNAL_NAME = "trial-lifecycle.jsonl"
ZERO_HASH = "0" * 64
EVENTS = (
    "beginstate-recorded",
    "snapshot-recorded",
    "rollback-route-tested",
    "install-started",
    "install-completed",
    "placement-started",
    "policy-placed",
    "verification-recorded",
    "rollback-started",
    "policy-removed",
    "runtime-verified",
    "cleanup-reviewed",
)


class LifecycleError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical(entry: dict[str, Any]) -> bytes:
    value = {key: entry[key] for key in entry if key != "hash"}
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def _entry_hash(entry: dict[str, Any]) -> str:
    return hashlib.sha256(_canonical(entry)).hexdigest()


def journal_path(root: Path) -> Path:
    return root / "local" / JOURNAL_NAME


def _evidence_path(root: Path, raw: str) -> Path:
    if not raw or Path(raw).is_absolute():
        raise LifecycleError("bewijs moet een relatief pad binnen de repository zijn")
    try:
        candidate = (root / raw).resolve(strict=True)
    except FileNotFoundError as exc:
        raise LifecycleError(f"bewijs ontbreekt: {raw}") from exc
    try:
        candidate.relative_to(root.resolve(strict=True))
    except ValueError as exc:
        raise LifecycleError(f"bewijs ligt buiten de repository: {raw}") from exc
    if not candidate.is_file():
        raise LifecycleError(f"bewijs is geen regulier bestand: {raw}")
    return candidate


def load_journal(root: Path, verify_evidence: bool = True) -> list[dict[str, Any]]:
    path = journal_path(root)
    if not path.is_file():
        return []
    entries: list[dict[str, Any]] = []
    previous = ZERO_HASH
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as exc:
            raise LifecycleError(f"journalregel {line_number} is geen geldige JSON") from exc
        if not isinstance(entry, dict) or entry.get("schemaVersion") != SCHEMA_VERSION:
            raise LifecycleError(f"journalregel {line_number} heeft een onbekend schema")
        if entry.get("sequence") != line_number:
            raise LifecycleError(f"journalregel {line_number} heeft een ongeldige sequence")
        if entry.get("previousHash") != previous or entry.get("hash") != _entry_hash(entry):
            raise LifecycleError(f"hashketen van journalregel {line_number} klopt niet")
        if entry.get("event") not in EVENTS:
            raise LifecycleError(f"journalregel {line_number} heeft een onbekende gebeurtenis")
        evidence = _evidence_path(root, entry.get("evidence", ""))
        if verify_evidence and sha256(evidence) != entry.get("evidenceSha256"):
            raise LifecycleError(
                f"bewijs voor {entry['event']} is gewijzigd of verwisseld: {entry['evidence']}"
            )
        previous = entry["hash"]
        entries.append(entry)
    return entries


def _names(entries: list[dict[str, Any]]) -> list[str]:
    return [entry["event"] for entry in entries]


def _validate_transition(event: str, names: list[str]) -> None:
    if event in names:
        raise LifecycleError(f"{event} is al vastgelegd")
    present = set(names)
    required = {
        "install-completed": {"install-started"},
        "policy-placed": {"placement-started"},
        "verification-recorded": {"policy-placed"},
        "rollback-started": {"policy-placed"},
        "policy-removed": {"rollback-started"},
        "runtime-verified": {"policy-removed"},
        "cleanup-reviewed": {"runtime-verified"},
    }.get(event, set())
    missing = required - present
    if missing:
        raise LifecycleError(f"{event} kan niet vóór {', '.join(sorted(missing))}")
    if "placement-started" in present and "policy-placed" not in present and event != "policy-placed":
        raise LifecycleError("plaatsing is onvoltooid; inspecteer eerst de Windows-policy")
    if "rollback-started" in present and "policy-removed" not in present and event != "policy-removed":
        raise LifecycleError("rollback is onvoltooid; verwijder of herstel eerst de policy")
    if "policy-removed" in present and event in {
        "install-started", "install-completed", "placement-started", "policy-placed",
        "verification-recorded", "rollback-started",
    }:
        raise LifecycleError("deze proef is al teruggedraaid; begin met een nieuw lokaal journal")
    if event == "placement-started" and "policy-placed" in present:
        raise LifecycleError("de policy is al geplaatst")
    if event == "rollback-started" and "policy-removed" in present:
        raise LifecycleError("de policy is al verwijderd")


def _validate_event_evidence(root: Path, event: str, evidence: Path) -> None:
    relative = str(evidence.relative_to(root))
    if event in {"placement-started", "policy-placed", "rollback-started"}:
        expected = root / "local" / "placement-manifest.json"
        if evidence != expected.resolve(strict=True):
            raise LifecycleError(f"{event} vereist local/placement-manifest.json als bewijs")
        try:
            verify_manifest(evidence, root)
        except (GateError, FileNotFoundError, OSError) as exc:
            raise LifecycleError(f"placement-manifest is niet meer geldig: {exc}") from exc
    elif event == "verification-recorded":
        try:
            manifest = json.loads(evidence.read_text())
        except json.JSONDecodeError as exc:
            raise LifecycleError("verificatiebewijs is geen geldig run.json") from exc
        bad = [
            item.get("id", "?") for item in manifest.get("results", [])
            if item.get("status") in {"fail", "ongeldig"}
        ]
        if (
            evidence.name != "run.json"
            or manifest.get("schemaVersion") != 1
            or manifest.get("partial") is not False
            or manifest.get("exitCode") != 0
            or bad
        ):
            raise LifecycleError(
                f"verificatiebewijs is niet volledig groen (fouten={bad}, bron={relative})"
            )
    elif event == "policy-removed" and "rollback-selfcheck OK" not in evidence.read_text(errors="replace"):
        raise LifecycleError("rollbackbewijs mist 'rollback-selfcheck OK'")
    elif event == "runtime-verified":
        text = evidence.read_text(errors="replace")
        if "claude:" not in text or "policy: niet actief" not in text:
            raise LifecycleError("runtimebewijs mist Claude-versie of inactieve-policycontrole")


def record(
    root: Path,
    event: str,
    evidence: str,
    detail: str = "",
    if_absent: bool = False,
) -> dict[str, Any]:
    root = root.resolve(strict=True)
    entries = load_journal(root)
    evidence_path = _evidence_path(root, evidence)
    if if_absent and event in _names(entries):
        existing = next(entry for entry in entries if entry["event"] == event)
        if existing["evidence"] != str(evidence_path.relative_to(root)):
            raise LifecycleError(f"{event} is al met ander bewijs vastgelegd")
        return existing
    _validate_transition(event, _names(entries))
    _validate_event_evidence(root, event, evidence_path)
    entry: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "sequence": len(entries) + 1,
        "recordedAt": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "evidence": str(evidence_path.relative_to(root)),
        "evidenceSha256": sha256(evidence_path),
        "previousHash": entries[-1]["hash"] if entries else ZERO_HASH,
    }
    if detail:
        entry["detail"] = detail
    entry["hash"] = _entry_hash(entry)
    path = journal_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    # O_APPEND voorkomt dat een succesvolle oudere regel door deze schrijver
    # wordt herschreven. fsync maakt een terugkeer na een afgebroken adapter veilig.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, json.dumps(entry, ensure_ascii=False, sort_keys=True).encode() + b"\n")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    load_journal(root)
    return entry


def _preparation_ok(root: Path) -> tuple[bool, str | None]:
    try:
        require_voorbereiding(root)
    except GateError as exc:
        return False, str(exc)
    return True, None


def _placement_manifest_ok(root: Path) -> tuple[bool, str | None]:
    try:
        verify_manifest(root / "local" / "placement-manifest.json", root)
    except (GateError, FileNotFoundError, OSError) as exc:
        return False, str(exc)
    return True, None


def status(root: Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    entries = load_journal(root)
    names = _names(entries)
    present = set(names)
    preparation_ok, preparation_problem = _preparation_ok(root)
    manifest_ok, manifest_problem = _placement_manifest_ok(root)
    if "rollback-started" in present and "policy-removed" not in present:
        phase = "rollback-incomplete"
        next_step = "Voltooi rollback-policy.ps1; verwijder geen pakketten."
        blocked = True
    elif "placement-started" in present and "policy-placed" not in present:
        phase = "placement-incomplete"
        next_step = "Inspecteer de Windows-policy en voltooi plaatsing of begin rollback."
        blocked = True
    elif "policy-removed" in present and "runtime-verified" not in present:
        phase = "policy-removed"
        next_step = "Herstart WSL en bewijs dat Claude zonder de proefpolicy start."
        blocked = True
    elif "runtime-verified" in present and "cleanup-reviewed" not in present:
        phase = "cleanup-ready"
        next_step = "Vergelijk met de beginstaat; cleanup blijft handmatig."
        blocked = False
    elif "cleanup-reviewed" in present:
        phase = "cleanup-reviewed"
        next_step = "Laat een tweede paar ogen de machine met de beginstaat vergelijken."
        blocked = False
    elif "rollback-started" not in present and "policy-placed" in present:
        phase = "verified" if "verification-recorded" in present else "policy-placed"
        next_step = (
            "Start rollback voordat je pakketten verwijdert."
            if "verification-recorded" in present
            else "Draai volledige verificatie of start veilige rollback."
        )
        blocked = False
    elif manifest_ok:
        phase = "placement-ready"
        next_step = "Plaats uitsluitend via place-policy.sh of place-policy.ps1."
        blocked = False
    elif preparation_ok:
        phase = "prepared"
        next_step = "Rond consent/intake/nulmeting af en maak het placement-manifest."
        blocked = False
    else:
        phase = "initial"
        next_step = "Leg beginstaat en WSL-snapshot vast vóór installatie of plaatsing."
        blocked = True
    return {
        "schemaVersion": SCHEMA_VERSION,
        "phase": phase,
        "blocked": blocked,
        "nextStep": next_step,
        "events": names,
        "checks": {
            "preparation": {"ok": preparation_ok, "problem": preparation_problem},
            "placementManifest": {"ok": manifest_ok, "problem": manifest_problem},
        },
    }


def plan(root: Path, action: str) -> dict[str, Any]:
    result = status(root)
    present = set(result["events"])
    if result["phase"] in {"placement-incomplete", "rollback-incomplete"}:
        if not (action == "rollback" and result["phase"] == "rollback-incomplete"):
            raise LifecycleError(result["nextStep"])
    if action == "install":
        if not result["checks"]["preparation"]["ok"]:
            raise LifecycleError(result["checks"]["preparation"]["problem"] or "voorbereiding ontbreekt")
        if present & {"placement-started", "policy-placed", "rollback-started", "policy-removed"}:
            raise LifecycleError("installatie hoort vóór plaatsing en rollback")
        if "install-completed" in present:
            raise LifecycleError("installatie is al voltooid; wijzig pakketten niet stil binnen dezelfde proef")
    elif action == "place":
        if not result["checks"]["placementManifest"]["ok"]:
            raise LifecycleError(result["checks"]["placementManifest"]["problem"] or "manifest ongeldig")
        if present & {"placement-started", "policy-placed", "rollback-started", "policy-removed"}:
            raise LifecycleError("plaatsing is al gestart of de proef is al teruggedraaid")
    elif action == "verify":
        if "policy-placed" not in present or "rollback-started" in present:
            raise LifecycleError("verificatie vereist een geplaatste policy vóór rollback")
    elif action == "rollback":
        if "policy-placed" not in present or "policy-removed" in present:
            raise LifecycleError("rollback vereist een geplaatste, nog niet verwijderde policy")
    elif action == "cleanup":
        if not {"policy-removed", "runtime-verified"} <= present:
            raise LifecycleError("cleanup blijft geblokkeerd tot policy weg en runtime opnieuw geverifieerd is")
    return dict(result, action=action, allowed=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Observeer en bewaak de lifecycle van de laptopproef.")
    parser.add_argument("command", choices=("status", "verify", "plan", "record"))
    parser.add_argument("value", nargs="?", help="actie voor plan, gebeurtenis voor record")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--evidence", help="relatief bewijsbestand voor record")
    parser.add_argument("--detail", default="")
    parser.add_argument("--if-absent", action="store_true", help="accepteer dezelfde bestaande gebeurtenis")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    root = Path(args.root)
    try:
        if args.command == "record":
            if args.value not in EVENTS or not args.evidence:
                raise LifecycleError("record vereist een geldige gebeurtenis en --evidence")
            result: Any = record(root, args.value, args.evidence, args.detail, args.if_absent)
        elif args.command == "plan":
            if args.value not in {"install", "place", "verify", "rollback", "cleanup"}:
                raise LifecycleError("plan vereist install, place, verify, rollback of cleanup")
            result = plan(root, args.value)
        elif args.command == "verify":
            entries = load_journal(root)
            result = {"valid": True, "entries": len(entries), "status": status(root)}
        else:
            result = status(root)
    except (LifecycleError, GateError, FileNotFoundError, OSError) as exc:
        print(f"FOUT: {exc}")
        return 2
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == "status":
        print(f"fase:         {result['phase']}")
        print(f"volgende stap: {result['nextStep']}")
    elif args.command == "plan":
        print(f"OK: {args.value} is veilig volgens het lifecycle-journal")
    elif args.command == "verify":
        print(f"OK: lifecycle-journal geldig ({result['entries']} regels)")
    else:
        print(f"vastgelegd: {result['event']} (regel {result['sequence']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
