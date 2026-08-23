#!/usr/bin/env bash
# Legt de beginstaat vast vóór er iets verandert. Zonder dit is teardown archeologie.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/repo-root.sh"
REPO_ROOT="$(sandbox_repo_root "$SCRIPT_DIR")" || exit $?
cd "$REPO_ROOT"

DOEL="${1:-local/beginstaat}"
KOPIE="$HOME/sandbox-beginstaat-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DOEL" "$KOPIE"

{
  echo "host:    $(uname -a)"
  echo "user:    $(id)"
  echo "wsl:     ${WSL_DISTRO_NAME:-<geen>}"
  echo "when:    $(date -Iseconds)"
} > "$DOEL/omgeving.txt"

dpkg -l > "$DOEL/dpkg.txt" 2>&1 || echo "dpkg ontbreekt" > "$DOEL/dpkg.txt"
{ command -v npm >/dev/null && npm ls -g --depth=0; } > "$DOEL/npm-globals.txt" 2>&1 || true
{
  node --version 2>&1 || true
  npm --version 2>&1 || true
  claude --version 2>&1 || true
} > "$DOEL/versies.txt"
{ command -v claude >/dev/null && claude auth status; } > "$DOEL/auth.txt" 2>&1 || true
ls -la ~ > "$DOEL/home.txt" 2>&1 || true
{ [ -d ~/.claude ] && ls -la ~/.claude; } > "$DOEL/dot-claude.txt" 2>&1 || true
ls -la /etc/apt/sources.list.d /etc/apt/preferences.d > "$DOEL/apt-config.txt" 2>&1 || true
[ -d ~/.claude ] && cp -a ~/.claude "$DOEL/dot-claude-backup" || true
[ -e ~/.claude.json ] && cp -p ~/.claude.json "$DOEL/claude.json" || true

cp -a "$DOEL"/. "$KOPIE"/
printf '%s\n' "$KOPIE" > "$DOEL/kopie-pad.txt"
if command -v python3 >/dev/null && [ "$DOEL" = "local/beginstaat" ]; then
  python3 tools/trial_lifecycle.py record beginstate-recorded --root "$PWD" \
    --evidence local/beginstaat/omgeving.txt --if-absent || exit 2
else
  echo "lifecycle: beginstaat wordt bij de installatiepoort uit de bestanden afgeleid"
fi
echo "beginstaat: $DOEL"
echo "kopie buiten de clone: $KOPIE"
echo "Zonder deze map is later niet meer te zien wat er al stond."
