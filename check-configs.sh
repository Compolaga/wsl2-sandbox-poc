#!/usr/bin/env bash
# Bewaakt dat de drie uitrolconfigs elkaar niet kwijtraken.
#
# Ze dragen dezelfde padlijsten en dezelfde lock-keys. Wordt een pad in één bestand
# toegevoegd en in de Windows-variant vergeten, dan gaat dat als gat naar Willem en merkt
# geen enkele testrun het - die toetst alleen de slice die op dat moment actief is.
#
# Het vergelijkt de bestanden ONDERLING, niet tegen een lijst in dit script: een lijst hier
# zou een zevende pad dat overal nieuw is nooit opmerken.
#
# Draai dit na elke wijziging aan config/.

set -uo pipefail
cd "$(dirname "$0")"

# --selftest voert bekend-slechte payloads in en eist dat elk geval rood gaat. Zonder zoiets
# kan een fout in deze bewaker morgen opnieuw ontstaan zonder dat iets het merkt - precies
# wat er gebeurde toen de padmodus per ongeluk elke payload goedkeurde.
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
    ./check-configs.sh "$T/x.json" >/dev/null 2>&1; local rc=$?
    if [ "$rc" = "$2" ]; then GOED=$((GOED+1)); printf '  OK    %-52s -> exit %s\n' "$1" "$rc"
    else FOUT=$((FOUT+1)); printf '  FOUT  %-52s -> exit %s (verwacht %s)\n' "$1" "$rc" "$2"; fi
  }
  echo "== zelftest van de configbewaker =="
  keur "ongewijzigde payload"                        0 "pass"
  keur "wslInheritsWindowsSettings weg"              1 "del d['wslInheritsWindowsSettings']"
  keur "allowUnsandboxedCommands op true"            1 "d['sandbox']['allowUnsandboxedCommands']=True"
  keur "failIfUnavailable op false"                  1 "d['sandbox']['failIfUnavailable']=False"
  keur "allowManagedReadPathsOnly weg"               1 "del d['sandbox']['filesystem']['allowManagedReadPathsOnly']"
  keur "beschermd pad niet in permissions.deny"      1 "d['permissions']['deny']=[r for r in d['permissions']['deny'] if 'aws' not in r]"
  # Een pad BUITEN elke wortel: ~/map-c zou terecht gedekt zijn door denyRead "~/".
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

# Met een padargument toetst hij één willekeurig bestand op de lock-keys en de
# _beschermd-consistentie. Dat is de check voor Willems samengevoegde Intune-payload.
python3 - "${1:-}" <<'PY'
import json, sys

LOSSE = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None
UITROL = [LOSSE] if LOSSE else [
    "config/settings.slice1.json",
    "config/managed-settings.linux.json",
    "config/managed-settings.windows.json",
]
# Lock-keys met de waarde die ze moeten hebben. Deze kunnen sneuvelen bij een merge in
# Willems bestand, en AC-11 t/m AC-14 leunen er volledig op.
LOCKS = {
    "sandbox.enabled": True,
    "sandbox.failIfUnavailable": True,
    "sandbox.allowUnsandboxedCommands": False,
}
MANAGED_LOCKS = {
    "sandbox.filesystem.allowManagedReadPathsOnly": True,
    "sandbox.network.allowManagedDomainsOnly": True,
}
# Zonder deze key raakt de policy de WSL2-distro niet en is er nul bescherming. De handoff
# noemt hem "de kern"; hij hoort dus in de poort vóór Intune.
WINDOWS_LOCKS = {"wslInheritsWindowsSettings": True}

# Eén definitie van "dit is een wortel die alles eronder dekt". Liep eerder uiteen tussen
# check-configs.sh, de preflight in run.sh en dekt_pad, waardoor "~/**" hier wel en daar niet
# als brede deny gold.
WORTELS_HOME  = {"~/", "~", "~/**", "$HOME", "$HOME/", "$HOME/**"}
WORTELS_OVERIG = {"/mnt/", "/mnt", "/mnt/**", "/", "/**"}

def haal(d, pad):
    for k in pad.split("."):
        if not isinstance(d, dict) or k not in d: return None
        d = d[k]
    return d

def lijsten(d):
    fs  = haal(d, "sandbox.filesystem") or {}
    net = haal(d, "sandbox.network") or {}
    return {
        "permissions.deny":  set(haal(d, "permissions.deny") or []),
        "denyRead":          set(fs.get("denyRead", [])),
        "allowRead":         set(fs.get("allowRead", [])),
        "allowWrite":        set(fs.get("allowWrite", [])),
        "allowedDomains":    set(net.get("allowedDomains", [])),
    }

fouten = []
docs = {}
for p in UITROL:
    try: docs[p] = json.load(open(p))
    except FileNotFoundError: fouten.append(f"{p} ontbreekt"); continue
    except Exception as e:   fouten.append(f"{p} is geen geldige JSON: {e}"); continue

if len(docs) == len(UITROL):
    if not LOSSE:
        # Alleen de ONDERLINGE vergelijking hoort onder deze voorwaarde. De twee blokken
        # daarna golden per ongeluk ook alleen hier, waardoor de padmodus - de poort vóór
        # Intune - letterlijk elke payload goedkeurde.
        basis_naam = UITROL[0]
        basis = lijsten(docs[basis_naam])
        for p in UITROL[1:]:
            hier = lijsten(docs[p])
            for veld in basis:
                mist  = basis[veld] - hier[veld]
                extra = hier[veld] - basis[veld]
                if mist:  fouten.append(f"{p}: {veld} mist {sorted(mist)} (staat wel in {basis_naam})")
                if extra: fouten.append(f"{p}: {veld} heeft extra {sorted(extra)} (staat niet in {basis_naam})")

    # De twee lagen zijn niet symmetrisch. denyRead kent voorouders: "~/" dekt alles eronder.
    # permissions.deny kent die inversie niet - deny wint altijd van allow. Elk beschermd pad
    # moet daar dus letterlijk staan. De eis komt uit _beschermd in de config zelf: één plek
    # waar een pad wordt toegevoegd, en ontbreken op een van beide lagen is een fout.
    if LOSSE:
        # Anders is de poort circulair: de eis komt uit het _beschermd-blok in datzelfde
        # bestand, dus wie de bescherming wegmerget krijgt "consistent" te horen.
        try:
            ref = json.load(open("config/managed-settings.windows.json")).get("_beschermd", {})
        except Exception:
            ref = {}
        hier = haal(docs[LOSSE], "_beschermd") or {}
        for pad, regel in ref.items():
            if pad not in hier:
                fouten.append(f"{LOSSE}: _beschermd mist {pad!r} - dat staat wel in de referentie "
                              "config/managed-settings.windows.json; is de bescherming weggemerged?")

    for p, d in docs.items():
        beschermd = haal(d, "_beschermd") or {}
        if not beschermd:
            fouten.append(f"{p}: _beschermd ontbreekt. Merge dat blok mee uit "
                          "config/managed-settings.windows.json - het is de enige plek waar "
                          "een beschermd pad staat, en zonder is er niets om de twee lagen aan te toetsen")
            continue
        deny  = haal(d, "permissions.deny") or []
        dread = [str(x) for x in (haal(d, "sandbox.filesystem.denyRead") or [])]
        for pad, regel in beschermd.items():
            if regel not in deny:
                fouten.append(f"{p}: _beschermd noemt {pad!r} maar permissions.deny mist {regel!r}")
            if not (pad in dread or any(w in dread for w in WORTELS_HOME if pad.startswith("~/"))
                    or any(w in dread for w in WORTELS_OVERIG if pad.startswith(w.rstrip("*")))):
                fouten.append(f"{p}: _beschermd noemt {pad!r} maar denyRead dekt het niet, ook niet via een wortel")
        if not LOSSE:
            for regel in deny:
                if regel.startswith("Read(") and regel not in beschermd.values():
                    fouten.append(f"{p}: permissions.deny heeft {regel!r} maar _beschermd noemt het niet")

    for p, d in docs.items():
        if "/tmp" not in (haal(d, "sandbox.filesystem.allowWrite") or []):
            fouten.append(f"{p}: allowWrite mist \"/tmp\" - zonder dat kan geen enkele probe schrijven (AC-00p)")
        for sleutel, waarde in LOCKS.items():
            if haal(d, sleutel) != waarde:
                fouten.append(f"{p}: {sleutel} is {haal(d, sleutel)!r}, moet {waarde!r} zijn")
        if "managed" in p or LOSSE:
            for sleutel, waarde in MANAGED_LOCKS.items():
                if haal(d, sleutel) != waarde:
                    fouten.append(f"{p}: {sleutel} is {haal(d, sleutel)!r}, moet {waarde!r} zijn in een managed config")
        if "windows" in p or LOSSE:
            # Aparte controle: dit is een lijst, geen scalaire waarde. Zonder "wsl" erin is de
            # config in de distro net zo inert als zonder wslInheritsWindowsSettings.
            plat = haal(d, "sandbox.enabledPlatforms")
            if plat is not None and "wsl" not in plat:
                fouten.append(f"{p}: sandbox.enabledPlatforms is {plat!r} zonder \"wsl\" - de config is dan inert in de distro")
            for sleutel, waarde in WINDOWS_LOCKS.items():
                if haal(d, sleutel) != waarde:
                    fouten.append(f"{p}: {sleutel} is {haal(d, sleutel)!r}, moet {waarde!r} zijn - zonder deze key raakt de policy WSL2 niet")

# De macOS-testconfig hoort niet bij de uitrol en moet juist smal zijn.

BREED = WORTELS_HOME | {"/", "/**"}
mac = "config/managed-settings.macos-test.json"
try:
    if LOSSE: raise FileNotFoundError
    d = json.load(open(mac))
    paden = haal(d, "sandbox.filesystem.denyRead") or []
    breed = [p for p in paden if str(p).strip() in BREED]
    if breed:
        fouten.append(f"{mac}: denyRead bevat {breed} - die config hoort juist smal te zijn")
    # De onderlinge vergelijking slaat hij terecht over (hij heeft bewust andere paden), maar
    # de twee-lagen-controle niet: dit bestand is bij de vorige hernoeming juist achtergebleven.
    besch = haal(d, "_beschermd") or {}
    if not besch:
        fouten.append(f"{mac}: _beschermd ontbreekt - dan merkt niets het als de paden gaan drijven")
    else:
        dny = haal(d, "permissions.deny") or []
        dre = [str(x) for x in (haal(d, "sandbox.filesystem.denyRead") or [])]
        for pad, regel in besch.items():
            if regel not in dny:  fouten.append(f"{mac}: _beschermd noemt {pad!r} maar permissions.deny mist {regel!r}")
            if pad not in dre:    fouten.append(f"{mac}: _beschermd noemt {pad!r} maar denyRead mist het")
    if "/tmp" not in (haal(d, "sandbox.filesystem.allowWrite") or []):
        fouten.append(f"{mac}: allowWrite mist \"/tmp\" - zonder dat kan geen enkele probe schrijven (AC-00p)")
    if not fouten:
        print(f"OK    {mac} (smal, zoals bedoeld)")
except FileNotFoundError:
    pass

if fouten:
    print("Configs lopen uiteen:")
    for f in fouten: print(f"  {f}")
    sys.exit(1)

for p in UITROL: print(f"OK    {p}")
print("\nConfigs zijn consistent.")
PY
