#!/usr/bin/env python3
"""Vertaal een bevestigde workspace-intake naar een Windows managed-settings payload."""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from copy import deepcopy
from pathlib import Path

RUNTIME_READ = (
    "/usr",
    "/bin",
    "/sbin",
    "/lib",
    "/lib64",
    "/etc",
    "/opt",
    "/tmp",
    "/proc",
    "/dev",
    "~/.nvm",
    "~/.npm",
    "~/.gitconfig",
)
# Fixtures van de testsuite blijven leesbaar naast de gekozen workspaces.
FIXTURE_READ = ("~/repos",)
FIXTURE_WRITE = ("~/repos",)
SYSTEM_ROOTS = {"/", "/home", "/root", "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt", "/proc", "/dev"}
LOCKS = {
    ("sandbox", "enabled"): True,
    ("sandbox", "failIfUnavailable"): True,
    ("sandbox", "allowUnsandboxedCommands"): False,
    ("sandbox", "filesystem", "allowManagedReadPathsOnly"): True,
    ("sandbox", "network", "allowManagedDomainsOnly"): True,
}


class IntakeError(ValueError):
    pass


def normalize_linux_path(raw: str) -> str:
    pad = str(raw or "").strip().replace("\\", "/")
    if not pad:
        raise IntakeError("leeg pad")
    if pad == "~":
        return "~"
    if pad.startswith("~/"):
        pass
    elif not pad.startswith("/"):
        raise IntakeError(f"{raw!r} is geen absoluut Linux-pad of ~/...")
    if pad != "/":
        pad = pad.rstrip("/")
    return pad


def read_rule(pad: str) -> str:
    if pad.endswith(".txt") or pad.endswith(".env") or "." in Path(pad).name:
        return f"Read({pad})"
    anker = pad if pad.startswith("/") else pad
    if anker.startswith("/") and not anker.startswith("//"):
        anker = "/" + anker
    return f"Read({anker}/**)"


def deny_entry(pad: str) -> str:
    return pad if pad.endswith(".txt") or pad.endswith(".env") else pad


def assert_workspace(pad: str, allow_mnt: bool) -> None:
    if pad in {"~", "/", "/home"} or pad in SYSTEM_ROOTS:
        raise IntakeError(f"{pad} is te breed als workspace")
    if pad.startswith("/mnt") and not allow_mnt:
        raise IntakeError(
            f"{pad} ligt onder /mnt; dat opent de Windows-schijf. "
            "Kies een Linux-pad en haal de Windows-map daarheen met ./bring-workspace.sh, "
            "of zet allowWindowsMounts alleen als je dat risico bewust accepteert."
        )


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as e:
        raise IntakeError(f"{path} ontbreekt") from e
    except json.JSONDecodeError as e:
        raise IntakeError(f"{path} is geen geldige JSON: {e}") from e


def merge_existing(base: dict, existing: dict) -> dict:
    out = deepcopy(existing)
    out["wslInheritsWindowsSettings"] = True
    out["sandbox"] = deepcopy(base["sandbox"])
    if "sandbox" in existing:
        for k, v in existing["sandbox"].items():
            if k in {"filesystem", "network", "enabled", "failIfUnavailable", "allowUnsandboxedCommands"}:
                continue
            out["sandbox"].setdefault(k, v)
    deny = list(existing.get("permissions", {}).get("deny") or [])
    for regel in base["permissions"]["deny"]:
        if regel not in deny:
            deny.append(regel)
    out.setdefault("permissions", {})["deny"] = deny
    out["_beschermd"] = deepcopy(base["_beschermd"])
    for key, waarde in (
        ("allowManagedMcpServersOnly", True),
    ):
        if key in existing and existing[key] is False:
            raise IntakeError(f"bestaande settings verzwakken {key}")
        out[key] = existing.get(key, base.get(key))
    if "allowedMcpServers" in existing:
        out["allowedMcpServers"] = existing["allowedMcpServers"]
    elif "allowedMcpServers" in base:
        out["allowedMcpServers"] = base["allowedMcpServers"]
    for k, v in existing.items():
        if k not in out:
            out[k] = v
    return out


def generate(intake: dict, template: dict) -> dict:
    if intake.get("confirmed") is not True:
        raise IntakeError(
            "intake is niet bevestigd; zet confirmed: true pas na de AskUserQuestion-samenvatting"
        )
    if not intake.get("askedVia"):
        raise IntakeError("askedVia ontbreekt; vastleggen via AskUserQuestion")
    allow_mnt = bool(intake.get("allowWindowsMounts"))
    if allow_mnt and intake.get("allowWindowsMountsConfirmed") is not True:
        raise IntakeError(
            "allowWindowsMounts vraagt een tweede ja: allowWindowsMountsConfirmed: true"
        )
    workspaces = intake.get("workspaces") or []
    if not workspaces:
        raise IntakeError("minstens één workspace is verplicht")

    seen = set()
    roots = []
    for ws in workspaces:
        pad = normalize_linux_path(ws.get("path", ""))
        assert_workspace(pad, allow_mnt)
        if pad in seen:
            raise IntakeError(f"dubbele workspace {pad}")
        seen.add(pad)
        access = ws.get("access", "read-write")
        if access not in {"read-only", "read-write"}:
            raise IntakeError(f"onbekende access {access!r} voor {pad}")
        roots.append((pad, access))

    protected = []
    for item in intake.get("protectedPaths") or []:
        pad = normalize_linux_path(item.get("path", ""))
        if pad.startswith("/mnt") and not allow_mnt:
            raise IntakeError(f"beschermd pad {pad} ligt onder /mnt")
        onder_ws = any(pad == r or pad.startswith(r + "/") for r, _ in roots)
        onder_home = pad.startswith("~/") or pad.startswith("/home/")
        if not (onder_ws or onder_home):
            raise IntakeError(f"beschermd pad {pad} ligt niet onder een workspace of de Linux-home")
        protected.append(pad)

    out = deepcopy(template)
    fs = out["sandbox"]["filesystem"]
    allow_read = [p for p in fs.get("allowRead", []) if p in RUNTIME_READ or p in FIXTURE_READ]
    allow_write = [p for p in fs.get("allowWrite", []) if p == "/tmp" or p in FIXTURE_WRITE]
    if "/tmp" not in allow_write:
        allow_write.append("/tmp")
    for pad, access in roots:
        if pad not in allow_read:
            allow_read.append(pad)
        if access == "read-write" and pad not in allow_write:
            allow_write.append(pad)
    fs["allowRead"] = allow_read
    fs["allowWrite"] = allow_write

    deny_read = list(fs.get("denyRead") or [])
    beschermd = dict(out.get("_beschermd") or {})
    deny = list(out.get("permissions", {}).get("deny") or [])
    for pad in protected:
        d = deny_entry(pad)
        if d not in deny_read:
            deny_read.append(d)
        regel = read_rule(pad)
        beschermd[pad] = regel
        if regel not in deny:
            deny.append(regel)
    fs["denyRead"] = deny_read
    out["_beschermd"] = beschermd
    out.setdefault("permissions", {})["deny"] = deny

    extra_domains = [d for d in (intake.get("allowedDomains") or []) if d]
    if extra_domains:
        domains = list(out["sandbox"]["network"].get("allowedDomains") or [])
        for d in extra_domains:
            if d not in domains:
                domains.append(d)
        out["sandbox"]["network"]["allowedDomains"] = domains

    proxy = intake.get("proxy") or {}
    env = {}
    for key in ("HTTPS_PROXY", "NO_PROXY", "HTTP_PROXY"):
        if proxy.get(key):
            env[key] = proxy[key]
    if env:
        out.setdefault("env", {}).update(env)

    existing_pad = intake.get("existingManagedSettings")
    if existing_pad:
        existing = load_json(Path(existing_pad))
        out = merge_existing(out, existing)

    for keys, waarde in LOCKS.items():
        hier = out
        for k in keys[:-1]:
            hier = hier.setdefault(k, {})
        if hier.get(keys[-1]) != waarde:
            hier[keys[-1]] = waarde
    out["wslInheritsWindowsSettings"] = True
    plats = out.get("sandbox", {}).get("enabledPlatforms")
    if plats is not None and "wsl" not in plats:
        raise IntakeError("enabledPlatforms mist wsl")
    return out


def write_atomic(path: Path, data: dict, force: bool) -> None:
    if path.exists() and not force:
        raise IntakeError(f"{path} bestaat al; gebruik --force om te overschrijven")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def summarize(data: dict, allow_mnt: bool = False) -> str:
    fs = data["sandbox"]["filesystem"]
    regels = [
        "workspaces (allowRead): " + ", ".join(p for p in fs["allowRead"] if p not in RUNTIME_READ),
        "schrijfbaar: " + ", ".join(p for p in fs["allowWrite"] if p != "/tmp"),
        "beschermd: " + ", ".join(data["_beschermd"].keys()),
        "domeinen: " + ", ".join(data["sandbox"]["network"].get("allowedDomains") or []),
    ]
    if allow_mnt:
        regels.append(
            "WAARSCHUWING: allowWindowsMounts staat aan; paden onder /mnt openen de Windows-schijf."
        )
    return "\n".join(regels)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Genereer een lokale Windows-testpayload uit intake.")
    p.add_argument("intake")
    p.add_argument("uitvoer")
    p.add_argument("--template", default="config/managed-settings.windows.json")
    p.add_argument("--force", action="store_true")
    args = p.parse_args(argv)
    try:
        intake = load_json(Path(args.intake))
        template = load_json(Path(args.template))
        data = generate(intake, template)
        write_atomic(Path(args.uitvoer), data, args.force)
    except IntakeError as e:
        print(f"FOUT: {e}")
        return 2
    print(summarize(data, bool(intake.get("allowWindowsMounts"))))
    print(f"geschreven: {args.uitvoer}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
