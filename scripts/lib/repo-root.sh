#!/usr/bin/env bash
# Gedeelde, side-effectvrije repository-rootdetectie voor CLI en interne adapters.

sandbox_repo_root() {
  local current="${1:-${BASH_SOURCE[0]}}"

  if [ -f "$current" ]; then
    current="$(dirname "$current")"
  fi
  current="$(CDPATH= cd -- "$current" 2>/dev/null && pwd -P)" || return 1

  while [ "$current" != "/" ]; do
    if [ -f "$current/bin/sandbox" ] && [ -d "$current/scripts" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    current="$(dirname "$current")"
  done

  echo "FOUT: repository-root niet gevonden." >&2
  return 2
}
