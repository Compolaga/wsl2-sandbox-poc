#!/usr/bin/env python3
"""Maak en verifieer de attestatie voor één exact policy-artefact.

Alle plaatsingsadapters gaan door deze interface. Het manifest bindt de
bevestigde intake en elk veiligheidsbewijs met SHA-256 aan de payload die naar
Program Files gaat.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from agent_gate import (
    GateError,
    consent_path,
    generated_path,
    intake_path,
    latest_red_ok,
    require_place,
)

SCHEMA_VERSION = 1
MANIFEST_NAME = "placement-manifest.json"
REQUIRED_IDS = {
    "consent",
    "intake",
    "policy",
    "template",
    "beginstaat",
    "snapshot",
    "rollback-roundtrip",
    "red-baseline",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _relative(root: Path, path: Path) -> str:
    try:
        return str(path.resolve(strict=True).relative_to(root.resolve(strict=True)))
    except ValueError as exc:
        raise GateError(f"{path} ligt buiten de repository") from exc


def _entry(root: Path, identifier: str, path: Path) -> dict[str, str]:
    return {"id": identifier, "path": _relative(root, path), "sha256": sha256(path)}


def _beginstaat(root: Path) -> Path:
    directory = root / "local" / "beginstaat"
    for name in ("dpkg.txt", "omgeving.txt"):
        candidate = directory / name
        if candidate.is_file():
            return candidate
    raise GateError("local/beginstaat bevat geen dpkg.txt of omgeving.txt")


def _write_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def create_manifest(root: Path, manifest_path: Path | None = None) -> Path:
    root = root.resolve(strict=True)
    require_place(root)
    manifest_path = manifest_path or root / "local" / MANIFEST_NAME
    reference = root / "config" / "managed-settings.windows.json"
    entries = [
        _entry(root, "consent", consent_path(root)),
        _entry(root, "intake", intake_path(root)),
        _entry(root, "policy", generated_path(root)),
        _entry(root, "template", reference),
        _entry(root, "beginstaat", _beginstaat(root)),
        _entry(root, "snapshot", root / "local" / "snapshot.json"),
        _entry(root, "rollback-roundtrip", root / "local" / "rollback-roundtrip.ok"),
        _entry(root, "red-baseline", latest_red_ok(root)),
    ]
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "files": entries,
    }
    _write_atomic(manifest_path, manifest)
    verify_manifest(manifest_path, root)
    return manifest_path


def _safe_path(root: Path, relative: str) -> Path:
    if not relative or Path(relative).is_absolute():
        raise GateError(f"ongeldig absoluut of leeg manifestpad: {relative!r}")
    candidate = (root / relative).resolve(strict=True)
    try:
        candidate.relative_to(root.resolve(strict=True))
    except ValueError as exc:
        raise GateError(f"manifestpad ontsnapt uit de repository: {relative}") from exc
    if not candidate.is_file():
        raise GateError(f"manifestbestand is geen regulier bestand: {relative}")
    return candidate


def verify_manifest(manifest_path: Path, root: Path | None = None) -> Path:
    manifest_path = manifest_path.resolve(strict=True)
    root = (root or manifest_path.parent.parent).resolve(strict=True)
    try:
        data = json.loads(manifest_path.read_text())
    except json.JSONDecodeError as exc:
        raise GateError(f"{manifest_path} is geen geldige JSON: {exc}") from exc
    if data.get("schemaVersion") != SCHEMA_VERSION:
        raise GateError(f"onbekende placement-manifestversie: {data.get('schemaVersion')!r}")
    raw_entries = data.get("files")
    if not isinstance(raw_entries, list):
        raise GateError("placement-manifest mist files")
    entries: dict[str, tuple[dict, Path]] = {}
    for entry in raw_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise GateError("ongeldige file-entry in placement-manifest")
        identifier = entry["id"]
        if identifier in entries:
            raise GateError(f"dubbele manifest-entry: {identifier}")
        path = _safe_path(root, entry.get("path", ""))
        expected = entry.get("sha256")
        actual = sha256(path)
        if not isinstance(expected, str) or actual != expected:
            raise GateError(f"SHA-256 mismatch voor {identifier}: {entry.get('path')}")
        entries[identifier] = (entry, path)
    if set(entries) != REQUIRED_IDS:
        missing = sorted(REQUIRED_IDS - set(entries))
        extra = sorted(set(entries) - REQUIRED_IDS)
        raise GateError(f"manifestbewijzen wijken af; ontbreekt={missing}, extra={extra}")

    expected_paths = {
        "consent": consent_path(root),
        "intake": intake_path(root),
        "policy": generated_path(root),
        "template": root / "config" / "managed-settings.windows.json",
        "snapshot": root / "local" / "snapshot.json",
        "rollback-roundtrip": root / "local" / "rollback-roundtrip.ok",
        "red-baseline": latest_red_ok(root),
    }
    for identifier, expected in expected_paths.items():
        if entries[identifier][1] != expected.resolve(strict=True):
            raise GateError(f"manifest wijst voor {identifier} niet naar {expected}")
    if entries["beginstaat"][1] != _beginstaat(root).resolve(strict=True):
        raise GateError("manifest wijst niet naar de actuele beginstaat")

    # Herhaal de semantische poort na de hashcontrole. Een zelfgeschreven
    # manifest kan daardoor geen consent, intake of policy-locks fabriceren.
    require_place(root)
    return entries["policy"][1]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Attesteer of verifieer een policyplaatsing.")
    parser.add_argument("command", choices=("create", "verify"))
    parser.add_argument("--root")
    parser.add_argument("--manifest")
    parser.add_argument("--json", action="store_true", help="geef het geverifieerde artefact als JSON")
    args = parser.parse_args(argv)
    root = Path(args.root) if args.root else None
    manifest = Path(args.manifest) if args.manifest else (
        (root or Path(__file__).resolve().parents[1]) / "local" / MANIFEST_NAME
    )
    try:
        if args.command == "create":
            result = create_manifest(root or Path(__file__).resolve().parents[1], manifest)
        else:
            result = verify_manifest(manifest, root)
    except (GateError, FileNotFoundError) as exc:
        print(f"FOUT: {exc}")
        return 2
    if args.json and args.command == "verify":
        print(json.dumps({"artifact": str(result), "sha256": sha256(result)}))
    else:
        print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
