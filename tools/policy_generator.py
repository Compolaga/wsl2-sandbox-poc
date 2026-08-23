#!/usr/bin/env python3
"""CLI-adapter voor constructie van een Windows managed-policyartefact."""
from __future__ import annotations

import argparse
from pathlib import Path
from policy_artifact import (  # herexport voor bestaande gebruikers en tests
    PolicyError as IntakeError,
    generate,
    load_json,
    summarize,
    write_atomic,
)


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
