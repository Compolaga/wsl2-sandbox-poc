#!/usr/bin/env python3
"""Schrijft een bewijsmatrix. Eén groene run telt nooit als vrijgave."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from proof_ledger import CATALOG_PATH, load_catalog, load_manifest


def load_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def parse_samenvatting(pad: Path) -> dict:
    if not pad.is_file():
        return {}
    tekst = pad.read_text()
    out = {"tekst": tekst, "mode": "", "exit": "", "filter": False}
    for regel in tekst.splitlines():
        if regel.startswith("mode:"):
            out["mode"] = regel.split(":", 1)[1].strip()
        elif regel.startswith("exitcode:"):
            out["exit"] = regel.split(":", 1)[1].strip()
        elif regel.startswith("filter:"):
            out["filter"] = True
    failed = []
    pak = False
    for regel in tekst.splitlines():
        if regel.startswith("-- niet in orde"):
            pak = True
            continue
        if pak and regel.startswith("  "):
            failed.append(regel.strip())
    out["failed"] = failed
    return out


def ac_status(evidence: Path, ac: str, sam: dict) -> str:
    bestand = evidence / f"{ac}.txt"
    if not bestand.is_file():
        return "niet gedraaid"
    if any(item.startswith(ac) for item in sam.get("failed") or []):
        return "fail"
    return "pass" if sam.get("exit") == "0" else "niet eenduidig"


def manifest_status(manifest: dict | None, ac: str) -> str | None:
    if not manifest:
        return None
    for result in manifest.get("results", []):
        if result.get("id") == ac:
            return {
                "handmatig": "handmatig nog open",
                "skip": "niet gedraaid",
            }.get(result.get("status"), result.get("status"))
    return None


def row(naam: str, bewijs: str, uitkomst: str, bron: str) -> str:
    return f"| {naam} | {bewijs} | {uitkomst} | {bron} |"


def build(root: Path, evidence: Path) -> str:
    consent = load_json(root / "local" / "consent.json")
    intake = load_json(root / "local" / "policy-input.json")
    generated = root / "local" / "managed-settings.windows.generated.json"
    sam = parse_samenvatting(evidence / "samenvatting.txt")
    notes = load_json(root / "local" / "proof-notes.json") or {}
    manifest = load_manifest(evidence)
    catalog_path = root / "specs" / "acceptance-catalog.json"
    catalog = load_catalog(catalog_path if catalog_path.is_file() else CATALOG_PATH)

    consent_ok = "pass" if consent and consent.get("askedVia") else "fail"
    intake_ok = "pass" if intake and intake.get("confirmed") is True else "fail"
    payload_ok = "pass" if generated.is_file() else "niet gedraaid"
    red_ok = "pass" if "nulmeting" in sam.get("mode", "") and sam.get("exit") == "0" else (
        "niet deze run" if "nulmeting" not in sam.get("mode", "") else "fail"
    )
    green_ok = "niet deze run"
    if sam.get("mode") == "normaal":
        green_ok = "ongeldig" if sam.get("filter") else ("pass" if sam.get("exit") == "0" else "fail")

    bring = notes.get("windowsToWsl", "niet gedraaid")
    aannames = notes.get("aannames", "niet gedraaid")
    check_configs = notes.get("checkConfigs", "pass" if generated.is_file() else "niet gedraaid")
    selftest = notes.get("selftest", "niet gedraaid")
    verificatie = notes.get("verificatie", "niet gedraaid")

    regels = [
        "# Bewijsmatrix — automatisch uit deze run",
        "",
        "Claim nooit dat de sandbox houdt als een vrijgavepoort hieronder open is.",
        "Eén groene `run.sh` is een proef op één machine, geen uitrolklaar bewijs.",
        "",
        f"Evidence: `{evidence}`",
        f"Mode: {sam.get('mode') or 'onbekend'}   Exit: {sam.get('exit') or '?'}",
        "",
        "| AC / controle | Wat het bewijst | Uitkomst | Bewijs |",
        "|---|---|---|---|",
        row("A1–A11", "Aannames van deze laptop", aannames, "HANDOFF.md"),
        row("Installatie-toestemming", "Gebruiker heeft ja gezegd vóór apt/npm/WSL", consent_ok, "`local/consent.json`"),
        row("Workspace-intake", "Gekozen roots + blacklist bevestigd", intake_ok, "`local/policy-input.json`"),
        row("Windows → WSL", "Windows-mappen gekopieerd, geen symlink naar `/mnt`", bring, "`bring-workspace.sh`"),
        row("`check-configs.sh` payload", "Locks en `_beschermd` overleefden de merge", check_configs, str(generated.name)),
        row("`selftest.sh`", "Het harnas kan falen", selftest, "*geen* sandbox-bewijs"),
        row("`run.sh --red`", "Containmentproeven lekken zonder policy", red_ok, "samenvatting.txt"),
        row("`run.sh` groen", "Canary komt niet terug; toegestane paden wel", green_ok, "samenvatting.txt"),
    ]
    for meta in (item for item in catalog["acceptanceCriteria"] if item.get("matrix")):
        ac, uitleg = meta["id"], meta["description"]
        standaard = "handmatig nog open"
        if meta["kind"] != "manual":
            standaard = manifest_status(manifest, ac) or ac_status(evidence, ac, sam)
        uitkomst = notes.get(ac, standaard)
        bewijs = meta["evidence"] if (evidence / meta["evidence"]).is_file() else (
            "handmatig" if meta["kind"] == "manual" else meta["evidence"]
        )
        regels.append(row(ac, uitleg, uitkomst, bewijs))
    regels.append(row("VERIFICATIE.md", "Twaalf interactieve controles in een gewone sessie", verificatie, "VERIFICATIE.md"))
    regels += ["", "## Nog niet vrijgegeven — dit blijft open", ""]
    gates = manifest.get("releaseGates", []) if manifest else catalog["releaseGates"]
    for gate in gates:
        mark = "x" if gate.get("status") == "closed" else " "
        regels.append(f"- [{mark}] {gate['description']}")
    regels += [
        "",
        "Zonder de tweede developer-laptop is dit een proef op één machine, geen uitrolklaar bewijs.",
        "",
    ]
    return "\n".join(regels)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Schrijf de bewijsmatrix van deze run.")
    p.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    p.add_argument("--evidence", required=True)
    args = p.parse_args(argv)
    root = Path(args.root)
    evidence = Path(args.evidence)
    if not evidence.is_dir():
        print(f"FOUT: evidence-map ontbreekt: {evidence}")
        return 2
    tekst = build(root, evidence)
    doel = evidence / "proof-matrix.md"
    doel.write_text(tekst)
    print(tekst)
    print(f"geschreven: {doel}")
    if not re.search(r"Tweede developer-laptop", tekst):
        print("FOUT: bewijsmatrix mist de tweede-laptop-poort")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
