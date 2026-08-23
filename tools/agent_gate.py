#!/usr/bin/env python3
"""Weigert installeren, genereren, plaatsen en groene runs zonder vastgelegde AskUserQuestion-antwoorden."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from policy_artifact import (
    PolicyError,
    assert_workspace,
    load_json as load_policy_json,
    normalize_linux_path,
    validate_policy,
)

ASKED_VIA = {"AskUserQuestion", "CursorAskQuestion", "human-cli"}
PLACE_NAME = "managed-settings.windows.generated.json"
TEMPLATE_NAME = "managed-settings.windows.json"


class GateError(ValueError):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as e:
        raise GateError(f"{path} ontbreekt") from e
    except json.JSONDecodeError as e:
        raise GateError(f"{path} is geen geldige JSON: {e}") from e


def consent_path(root: Path) -> Path:
    return root / "local" / "consent.json"


def intake_path(root: Path) -> Path:
    return root / "local" / "policy-input.json"


def generated_path(root: Path) -> Path:
    return root / "local" / PLACE_NAME


def require_asked_via(data: dict, welke: str) -> None:
    via = data.get("askedVia")
    if via not in ASKED_VIA:
        raise GateError(
            f"{welke} mist een geldige askedVia (AskUserQuestion, CursorAskQuestion of human-cli)"
        )
    if not data.get("confirmedAt"):
        raise GateError(f"{welke} mist confirmedAt")


def require_consent(root: Path, cluster: str | None = None) -> dict:
    data = load_json(consent_path(root))
    require_asked_via(data, "local/consent.json")
    for key in ("wsl", "apt", "nodeClaude"):
        if key not in data or not isinstance(data[key], bool):
            raise GateError(f"local/consent.json mist boolean {key}")
    if cluster:
        if data.get(cluster) is not True:
            raise GateError(
                f"{cluster} is niet goedgekeurd in local/consent.json. "
                "Installeer dit cluster niet."
            )
    return data


def require_intake(root: Path, path: Path | None = None) -> dict:
    path = path or intake_path(root)
    data = load_json(path)
    label = str(path)
    require_asked_via(data, label)
    if data.get("confirmed") is not True:
        raise GateError(
            f"{label} is niet bevestigd. "
            "Vat de AskUserQuestion-antwoorden samen en zet confirmed: true pas na ja."
        )
    workspaces = data.get("workspaces") or []
    if not workspaces:
        raise GateError(f"{label} heeft geen workspaces")
    allow_mnt = bool(data.get("allowWindowsMounts"))
    seen = set()
    for workspace in workspaces:
        try:
            path = normalize_linux_path(workspace.get("path", ""))
            assert_workspace(path, allow_mnt)
        except PolicyError as exc:
            raise GateError(f"ongeldige workspace in {label}: {exc}") from exc
        if path in seen:
            raise GateError(f"dubbele workspace {path} in {label}")
        seen.add(path)
        if workspace.get("access", "read-write") not in {"read-only", "read-write"}:
            raise GateError(f"ongeldige access voor workspace {path}")
    if data.get("allowWindowsMounts") is True and data.get("allowWindowsMountsConfirmed") is not True:
        raise GateError(
            "allowWindowsMounts staat aan zonder allowWindowsMountsConfirmed: true"
        )
    modus = data.get("bringMode", "copy")
    if modus not in {"copy", "bind"}:
        raise GateError(f"onbekende bringMode {modus!r}")
    if modus == "bind" and data.get("bindApproved") is not True:
        raise GateError(
            "bringMode is bind zonder bindApproved: true. "
            "Copy is de standaard; bind alleen na een tweede ja."
        )
    return data


def require_bind(root: Path) -> dict:
    data = require_intake(root)
    if data.get("bindApproved") is not True:
        raise GateError(
            "bind-mount is niet goedgekeurd. Zet bindApproved: true pas na een tweede AskUserQuestion."
        )
    return data


def payload_matches_intake(payload: dict, intake: dict, reference_protected: dict | None = None) -> None:
    errors = validate_policy(
        payload,
        windows=True,
        intake=intake,
        reference_protected=reference_protected,
    )
    if errors:
        raise GateError("gegenereerde payload is ongeldig: " + "; ".join(errors))


def require_generated(root: Path, intake: dict) -> Path:
    pad = generated_path(root)
    if not pad.is_file():
        raise GateError(
            f"{pad} ontbreekt. Genereer eerst: ./bin/sandbox policy generate local/policy-input.json"
        )
    if pad.name == TEMPLATE_NAME or pad.resolve() == (root / "config" / TEMPLATE_NAME).resolve():
        raise GateError("de statische template mag niet als payload dienen")
    try:
        payload = load_policy_json(pad)
    except PolicyError as exc:
        raise GateError(str(exc)) from exc
    reference_path = root / "config" / TEMPLATE_NAME
    if not reference_path.is_file():
        reference_path = repo_root() / "config" / TEMPLATE_NAME
    try:
        reference = load_policy_json(reference_path).get("_beschermd", {})
    except PolicyError as exc:
        raise GateError(str(exc)) from exc
    payload_matches_intake(payload, intake, reference)
    return pad


def latest_red_ok(root: Path) -> Path:
    hits = sorted((root / "evidence").glob("*-red/samenvatting.txt"), reverse=True)
    for sam in hits:
        tekst = sam.read_text()
        if "nulmeting" not in tekst:
            continue
        if "exitcode:   0" in tekst or "exitcode: 0" in tekst:
            return sam
    raise GateError(
        "geen geslaagde rode nulmeting gevonden in evidence/*-red/. "
        "Draai eerst ./bin/sandbox test --red vóór je een policy plaatst."
    )


def require_voorbereiding(root: Path) -> None:
    staat = root / "local" / "beginstaat"
    if not ((staat / "dpkg.txt").is_file() or (staat / "omgeving.txt").is_file()):
        raise GateError(
            "local/beginstaat ontbreekt. Draai eerst ./bin/sandbox baseline — "
            "zonder beginstaat is teardown archeologie."
        )
    if not (root / "local" / "snapshot.json").is_file():
        raise GateError(
            "local/snapshot.json ontbreekt. Geen WSL-snapshot betekent geen proef. "
            "Draai scripts/windows/create-snapshot.ps1 en kopieer de json hierheen."
        )


def require_place(root: Path) -> dict:
    require_consent(root)
    require_voorbereiding(root)
    if not (root / "local" / "rollback-roundtrip.ok").is_file():
        raise GateError(
            "local/rollback-roundtrip.ok ontbreekt. Test de rollback eerst "
            "met scripts/windows/test-rollback-roundtrip.ps1 in een admin-PowerShell."
        )
    intake = require_intake(root)
    require_generated(root, intake)
    latest_red_ok(root)
    return intake


def require_green(root: Path) -> dict:
    return require_intake(root)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Poort vóór installeren, genereren, plaatsen of groene run.")
    p.add_argument(
        "commando",
        choices=("consent", "intake", "install", "install-wsl", "install-apt", "install-node",
                 "generate", "bind", "place", "green", "voorbereiding"),
    )
    p.add_argument("--root", default=str(repo_root()))
    p.add_argument(
        "--intake",
        help="intakebestand voor de generate-poort; standaard local/policy-input.json",
    )
    args = p.parse_args(argv)
    root = Path(args.root)
    try:
        if args.commando == "consent":
            require_consent(root)
        elif args.commando == "intake":
            require_intake(root)
        elif args.commando == "install":
            require_consent(root)
        elif args.commando == "install-wsl":
            require_consent(root, "wsl")
        elif args.commando == "install-apt":
            require_consent(root, "apt")
        elif args.commando == "install-node":
            require_consent(root, "nodeClaude")
        elif args.commando == "generate":
            require_intake(root, Path(args.intake) if args.intake else None)
        elif args.commando == "bind":
            require_bind(root)
        elif args.commando == "place":
            require_place(root)
        elif args.commando == "green":
            require_green(root)
        elif args.commando == "voorbereiding":
            require_voorbereiding(root)
    except GateError as e:
        print(f"FOUT: {e}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
