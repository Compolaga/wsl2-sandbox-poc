#!/usr/bin/env bash
# Dunne adapter naar de centrale policy-artefactvalidatie.
set -uo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../lib/repo-root.sh"
REPO_ROOT="$(sandbox_repo_root "$SCRIPT_DIR")" || exit $?
cd "$REPO_ROOT"

# Voert bekend-slechte payloads in en eist dat elke mutatie rood gaat.
if [ "${1:-}" = "--selftest" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  GOED=0; FOUT=0
  keur() {  # keur <omschrijving> <verwachte exitcode> <python-mutatie>
    python3 - "$T/x.json" <<PYX
import json
d = json.load(open("config/managed-settings.windows.json"))
$3
json.dump(d, open("$T/x.json", "w"), indent=2)
PYX
    "$SCRIPT_DIR/check-configs.sh" "$T/x.json" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "$2" ]; then GOED=$((GOED+1)); printf '  OK    %-52s -> exit %s\n' "$1" "$rc"
    else FOUT=$((FOUT+1)); printf '  FOUT  %-52s -> exit %s (verwacht %s)\n' "$1" "$rc" "$2"; fi
  }
  echo "== zelftest van de configbewaker =="
  keur "ongewijzigde payload"                        0 "pass"
  keur "wslInheritsWindowsSettings weg"              1 "del d['wslInheritsWindowsSettings']"
  keur "allowUnsandboxedCommands op true"            1 "d['sandbox']['allowUnsandboxedCommands']=True"
  keur "failIfUnavailable op false"                  1 "d['sandbox']['failIfUnavailable']=False"
  keur "allowManagedReadPathsOnly weg"               1 "del d['sandbox']['filesystem']['allowManagedReadPathsOnly']"
  keur "allowManagedMcpServersOnly op false"         1 "d['allowManagedMcpServersOnly']=False"
  keur "beschermd pad niet in permissions.deny"      1 "d['permissions']['deny']=[r for r in d['permissions']['deny'] if 'aws' not in r]"
  keur "beschermd pad buiten elke wortel, niet in denyRead" 1 "d['_beschermd']['/opt/map-c']='Read(//opt/map-c/**)'; d['permissions']['deny'].append('Read(//opt/map-c/**)')"
  keur "_beschermd helemaal weg"                     1 "del d['_beschermd']"
  keur "/tmp niet in allowWrite"                     1 "d['sandbox']['filesystem']['allowWrite']=['~/repos']"
  keur "enabledPlatforms zonder wsl"                 1 "d['sandbox']['enabledPlatforms']=['linux']"
  keur "bescherming weggemerged uit _beschermd"      1 "d['_beschermd']={'~/probe-a':'Read(~/probe-a/**)'}; d['permissions']['deny']=['Read(~/probe-a/**)']; d['sandbox']['filesystem']['denyRead']=['~/','/mnt/']"
  echo
  printf 'goed %d   fout %d\n' "$GOED" "$FOUT"
  [ $FOUT -eq 0 ] && echo "De configbewaker gaat rood op elke bekend-slechte payload." \
                  || echo "De configbewaker laat iets door dat hij hoort te vangen."
  exit $([ $FOUT -eq 0 ] && echo 0 || echo 1)
fi

if [ -n "${1:-}" ]; then
  python3 tools/policy_artifact.py --single "$1"
else
  python3 tools/policy_artifact.py
fi
