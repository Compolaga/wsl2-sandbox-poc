#!/usr/bin/env python3
"""Constructie en validatie van het managed-policyartefact.

Dit is de enige plek waar padnormalisatie, veilige merges, verplichte locks,
beschermde paden en workspace-dekking worden gedefinieerd. Shellscripts zijn
alleen adapters naar deze regels.
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Iterable

RUNTIME_READ = (
    "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt", "/tmp",
    "/proc", "/dev", "~/.nvm", "~/.npm", "~/.gitconfig",
)
FIXTURE_READ = ("~/repos",)
FIXTURE_WRITE = ("~/repos",)
SYSTEM_ROOTS = {
    "/", "/home", "/root", "/usr", "/bin", "/sbin", "/lib", "/lib64",
    "/etc", "/opt", "/proc", "/dev",
}
LOCKS = {
    ("sandbox", "enabled"): True,
    ("sandbox", "failIfUnavailable"): True,
    ("sandbox", "allowUnsandboxedCommands"): False,
}
MANAGED_LOCKS = {
    ("sandbox", "filesystem", "allowManagedReadPathsOnly"): True,
    ("sandbox", "network", "allowManagedDomainsOnly"): True,
    ("allowManagedMcpServersOnly",): True,
}
WINDOWS_LOCKS = {("wslInheritsWindowsSettings",): True}
ALL_GENERATED_LOCKS = {**LOCKS, **MANAGED_LOCKS, **WINDOWS_LOCKS}
HOME_DENY_ROOTS = {"~", "~/", "~/**", "$HOME", "$HOME/", "$HOME/**"}
OTHER_DENY_ROOTS = {"/mnt", "/mnt/", "/mnt/**", "/", "/**"}


class PolicyError(ValueError):
    pass


def normalize_linux_path(raw: str) -> str:
    path = str(raw or "").strip().replace("\\", "/")
    if not path:
        raise PolicyError("leeg pad")
    if path != "~" and not path.startswith("~/") and not path.startswith("/"):
        raise PolicyError(f"{raw!r} is geen absoluut Linux-pad of ~/...")
    if path != "/":
        path = path.rstrip("/")
    return path


def read_rule(path: str) -> str:
    if path.endswith((".txt", ".env")) or "." in Path(path).name:
        return f"Read({path})"
    anchor = "/" + path if path.startswith("/") and not path.startswith("//") else path
    return f"Read({anchor}/**)"


def assert_workspace(path: str, allow_mnt: bool) -> None:
    if path in {"~", "/", "/home"} or path in SYSTEM_ROOTS:
        raise PolicyError(f"{path} is te breed als workspace")
    if (path == "/mnt" or path.startswith("/mnt/")) and not allow_mnt:
        raise PolicyError(
            f"{path} ligt onder /mnt; dat opent de Windows-schijf. Kies een Linux-pad "
            "en haal de Windows-map daarheen met ./bring-workspace.sh, of zet "
            "allowWindowsMounts alleen als je dat risico bewust accepteert."
        )


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError as exc:
        raise PolicyError(f"{path} ontbreekt") from exc
    except json.JSONDecodeError as exc:
        raise PolicyError(f"{path} is geen geldige JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise PolicyError(f"{path} bevat geen JSON-object")
    return data


def nested(data: dict, keys: tuple[str, ...]):
    current = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def nested_if_present(data: dict, keys: tuple[str, ...]) -> tuple[bool, object]:
    """Onderscheid een ontbrekende lock van een expliciete, conflicterende waarde."""
    current = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return False, None
        current = current[key]
    return True, current


def lists(data: dict) -> dict[str, set]:
    return {
        "permissions.deny": set(nested(data, ("permissions", "deny")) or []),
        "denyRead": set(nested(data, ("sandbox", "filesystem", "denyRead")) or []),
        "allowRead": set(nested(data, ("sandbox", "filesystem", "allowRead")) or []),
        "allowWrite": set(nested(data, ("sandbox", "filesystem", "allowWrite")) or []),
        "allowedDomains": set(nested(data, ("sandbox", "network", "allowedDomains")) or []),
    }


def path_is_covered(path: str, deny_read: Iterable[str]) -> bool:
    entries = {str(entry).strip() for entry in deny_read}
    if path in entries:
        return True
    if path.startswith("~/") and entries & HOME_DENY_ROOTS:
        return True
    if path == "/mnt" or path.startswith("/mnt/"):
        return bool(entries & OTHER_DENY_ROOTS)
    return bool(entries & {"/", "/**"}) if path.startswith("/") else False


def validate_policy(
    data: dict,
    *,
    label: str = "payload",
    managed: bool = True,
    windows: bool = False,
    macos_test: bool = False,
    enforce_locks: bool = True,
    reference_protected: dict | None = None,
    intake: dict | None = None,
) -> list[str]:
    errors: list[str] = []
    protected = nested(data, ("_beschermd",)) or {}
    if not isinstance(protected, dict) or not protected:
        errors.append(
            f"{label}: _beschermd ontbreekt. Merge dat blok mee uit "
            "config/managed-settings.windows.json"
        )
        protected = {}
    if reference_protected:
        for path in reference_protected:
            if path not in protected:
                errors.append(
                    f"{label}: _beschermd mist {path!r} - dat staat wel in de referentie; "
                    "is de bescherming weggemerged?"
                )

    deny = nested(data, ("permissions", "deny")) or []
    deny_read = nested(data, ("sandbox", "filesystem", "denyRead")) or []
    for path, rule in protected.items():
        if rule not in deny:
            errors.append(f"{label}: _beschermd noemt {path!r} maar permissions.deny mist {rule!r}")
        if not path_is_covered(path, deny_read):
            errors.append(f"{label}: _beschermd noemt {path!r} maar denyRead dekt het niet")

    allow_write = nested(data, ("sandbox", "filesystem", "allowWrite")) or []
    if "/tmp" not in allow_write:
        errors.append(f'{label}: allowWrite mist "/tmp" - zonder dat kan geen probe schrijven')

    required = dict(LOCKS) if enforce_locks else {}
    if enforce_locks and managed:
        required.update(MANAGED_LOCKS)
    if enforce_locks and windows:
        required.update(WINDOWS_LOCKS)
    for keys, expected in required.items():
        actual = nested(data, keys)
        if actual != expected:
            errors.append(f"{label}: {'.'.join(keys)} is {actual!r}, moet {expected!r} zijn")

    if windows:
        platforms = nested(data, ("sandbox", "enabledPlatforms"))
        if platforms is not None and "wsl" not in platforms:
            errors.append(f'{label}: sandbox.enabledPlatforms is {platforms!r} zonder "wsl"')

    if macos_test:
        broad = sorted(set(map(str, deny_read)) & (HOME_DENY_ROOTS | {"/", "/**"}))
        if broad:
            errors.append(f"{label}: denyRead bevat {broad} - die config hoort juist smal te zijn")
        for path in protected:
            if path not in deny_read:
                errors.append(f"{label}: _beschermd noemt {path!r} maar denyRead mist het letterlijk")

    if intake is not None:
        allow_read = nested(data, ("sandbox", "filesystem", "allowRead")) or []
        normalized_allow = set()
        for item in allow_read:
            try:
                normalized_allow.add(normalize_linux_path(str(item)))
            except PolicyError:
                normalized_allow.add(str(item))
        missing = []
        for workspace in intake.get("workspaces") or []:
            try:
                path = normalize_linux_path(workspace.get("path", ""))
            except PolicyError as exc:
                errors.append(f"intake: {exc}")
                continue
            if path not in normalized_allow:
                missing.append(path)
        if missing:
            errors.append(f"{label}: mist workspaces uit de intake: {', '.join(missing)}")
    return errors


def validate_config_set(documents: dict[str, dict], *, single: bool = False,
                        reference_protected: dict | None = None) -> list[str]:
    errors: list[str] = []
    names = list(documents)
    if not single and names:
        base_name = names[0]
        base = lists(documents[base_name])
        for name in names[1:]:
            current = lists(documents[name])
            for field in base:
                missing = base[field] - current[field]
                extra = current[field] - base[field]
                if missing:
                    errors.append(f"{name}: {field} mist {sorted(missing)} (staat wel in {base_name})")
                if extra:
                    errors.append(f"{name}: {field} heeft extra {sorted(extra)} (staat niet in {base_name})")
    for name, data in documents.items():
        errors.extend(validate_policy(
            data,
            label=name,
            managed=single or "managed" in name,
            windows=single or "windows" in name,
            reference_protected=reference_protected if single else None,
        ))
        if not single:
            protected_rules = set((data.get("_beschermd") or {}).values())
            for rule in nested(data, ("permissions", "deny")) or []:
                if str(rule).startswith("Read(") and rule not in protected_rules:
                    errors.append(f"{name}: permissions.deny heeft {rule!r} maar _beschermd noemt het niet")
    return errors


def merge_existing(base: dict, existing: dict) -> dict:
    for keys, expected in ALL_GENERATED_LOCKS.items():
        present, actual = nested_if_present(existing, keys)
        if present and actual != expected:
            name = ".".join(keys)
            raise PolicyError(
                f"bestaande settings conflicteren met verplichte lock {name}: "
                f"{actual!r}, verwacht {expected!r}"
            )
    out = deepcopy(existing)
    out["wslInheritsWindowsSettings"] = True
    out["sandbox"] = deepcopy(base["sandbox"])
    if "sandbox" in existing:
        protected_keys = {"filesystem", "network", "enabled", "failIfUnavailable", "allowUnsandboxedCommands"}
        for key, value in existing["sandbox"].items():
            if key not in protected_keys:
                out["sandbox"].setdefault(key, value)
    deny = list(existing.get("permissions", {}).get("deny") or [])
    for rule in base["permissions"]["deny"]:
        if rule not in deny:
            deny.append(rule)
    out.setdefault("permissions", {})["deny"] = deny
    out["_beschermd"] = deepcopy(base["_beschermd"])
    out["allowManagedMcpServersOnly"] = existing.get(
        "allowManagedMcpServersOnly", base.get("allowManagedMcpServersOnly")
    )
    if "allowedMcpServers" in existing:
        out["allowedMcpServers"] = existing["allowedMcpServers"]
    elif "allowedMcpServers" in base:
        out["allowedMcpServers"] = base["allowedMcpServers"]
    return out


def generate(intake: dict, template: dict) -> dict:
    if intake.get("confirmed") is not True:
        raise PolicyError("intake is niet bevestigd; zet confirmed: true pas na de AskUserQuestion-samenvatting")
    if not intake.get("askedVia"):
        raise PolicyError("askedVia ontbreekt; vastleggen via AskUserQuestion")
    allow_mnt = bool(intake.get("allowWindowsMounts"))
    if allow_mnt and intake.get("allowWindowsMountsConfirmed") is not True:
        raise PolicyError("allowWindowsMounts vraagt een tweede ja: allowWindowsMountsConfirmed: true")
    workspaces = intake.get("workspaces") or []
    if not workspaces:
        raise PolicyError("minstens één workspace is verplicht")

    roots: list[tuple[str, str]] = []
    seen = set()
    for workspace in workspaces:
        path = normalize_linux_path(workspace.get("path", ""))
        assert_workspace(path, allow_mnt)
        if path in seen:
            raise PolicyError(f"dubbele workspace {path}")
        seen.add(path)
        access = workspace.get("access", "read-write")
        if access not in {"read-only", "read-write"}:
            raise PolicyError(f"onbekende access {access!r} voor {path}")
        roots.append((path, access))

    protected_paths = []
    for item in intake.get("protectedPaths") or []:
        path = normalize_linux_path(item.get("path", ""))
        if (path == "/mnt" or path.startswith("/mnt/")) and not allow_mnt:
            raise PolicyError(f"beschermd pad {path} ligt onder /mnt")
        under_workspace = any(path == root or path.startswith(root + "/") for root, _ in roots)
        under_home = path.startswith("~/") or path.startswith("/home/")
        if not (under_workspace or under_home):
            raise PolicyError(f"beschermd pad {path} ligt niet onder een workspace of de Linux-home")
        protected_paths.append(path)

    out = deepcopy(template)
    fs = out["sandbox"]["filesystem"]
    allow_read = [p for p in fs.get("allowRead", []) if p in RUNTIME_READ or p in FIXTURE_READ]
    allow_write = [p for p in fs.get("allowWrite", []) if p == "/tmp" or p in FIXTURE_WRITE]
    if "/tmp" not in allow_write:
        allow_write.append("/tmp")
    for path, access in roots:
        if path not in allow_read:
            allow_read.append(path)
        if access == "read-write" and path not in allow_write:
            allow_write.append(path)
    fs["allowRead"], fs["allowWrite"] = allow_read, allow_write

    deny_read = list(fs.get("denyRead") or [])
    protected = dict(out.get("_beschermd") or {})
    deny = list(out.get("permissions", {}).get("deny") or [])
    for path in protected_paths:
        if path not in deny_read:
            deny_read.append(path)
        rule = read_rule(path)
        protected[path] = rule
        if rule not in deny:
            deny.append(rule)
    fs["denyRead"] = deny_read
    out["_beschermd"] = protected
    out.setdefault("permissions", {})["deny"] = deny

    domains = out["sandbox"]["network"].setdefault("allowedDomains", [])
    for domain in intake.get("allowedDomains") or []:
        if domain and domain not in domains:
            domains.append(domain)
    proxy = intake.get("proxy") or {}
    env = {key: proxy[key] for key in ("HTTPS_PROXY", "NO_PROXY", "HTTP_PROXY") if proxy.get(key)}
    if env:
        out.setdefault("env", {}).update(env)
    if intake.get("existingManagedSettings"):
        out = merge_existing(out, load_json(Path(intake["existingManagedSettings"])))

    for keys, expected in ALL_GENERATED_LOCKS.items():
        current = out
        for key in keys[:-1]:
            current = current.setdefault(key, {})
        current[keys[-1]] = expected
    platforms = nested(out, ("sandbox", "enabledPlatforms"))
    if platforms is not None and "wsl" not in platforms:
        raise PolicyError("enabledPlatforms mist wsl")
    errors = validate_policy(out, windows=True, intake=intake)
    if errors:
        raise PolicyError("gegenereerde policy is ongeldig: " + "; ".join(errors))
    return out


def write_atomic(path: Path, data: dict, force: bool) -> None:
    if path.exists() and not force:
        raise PolicyError(f"{path} bestaat al; gebruik --force om te overschrijven")
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


def summarize(data: dict, allow_mnt: bool = False) -> str:
    fs = data["sandbox"]["filesystem"]
    lines = [
        "workspaces (allowRead): " + ", ".join(p for p in fs["allowRead"] if p not in RUNTIME_READ),
        "schrijfbaar: " + ", ".join(p for p in fs["allowWrite"] if p != "/tmp"),
        "beschermd: " + ", ".join(data["_beschermd"].keys()),
        "domeinen: " + ", ".join(data["sandbox"]["network"].get("allowedDomains") or []),
    ]
    if allow_mnt:
        lines.append("WAARSCHUWING: allowWindowsMounts staat aan; paden onder /mnt openen de Windows-schijf.")
    return "\n".join(lines)


def check_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Valideer managed-policyartefacten.")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--single", action="store_true")
    parser.add_argument("--reference", default="config/managed-settings.windows.json")
    parser.add_argument("--macos", default="config/managed-settings.macos-test.json")
    args = parser.parse_args(argv)
    paths = args.paths or [
        "config/settings.slice1.json", "config/managed-settings.linux.json",
        "config/managed-settings.windows.json",
    ]
    try:
        documents = {path: load_json(Path(path)) for path in paths}
        reference = load_json(Path(args.reference)).get("_beschermd", {}) if args.single else None
        errors = validate_config_set(documents, single=args.single, reference_protected=reference)
        if not args.single:
            mac_path = Path(args.macos)
            mac = load_json(mac_path)
            errors.extend(validate_policy(
                mac,
                label=str(mac_path),
                managed=False,
                macos_test=True,
                enforce_locks=False,
            ))
    except PolicyError as exc:
        errors = [str(exc)]
    if errors:
        print("Configs lopen uiteen:")
        for error in errors:
            print(f"  {error}")
        return 1
    if not args.single:
        print(f"OK    {args.macos} (smal, zoals bedoeld)")
    for path in paths:
        print(f"OK    {path}")
    print("\nConfigs zijn consistent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(check_main())
