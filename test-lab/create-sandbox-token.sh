#!/usr/bin/env bash
# Maakt een verse Claude-OAuth-token voor de WSL2-meting.
# Jij doet alleen de browserlogin; dit script vangt de token af en zet hem
# in ~/.sandbox-token. De token zelf wordt niet geprint.
#
# setup-token wrapt de ~108-teken-token op een 80-koloms tty tot 79+rest.
# Daarom draait dit in een pty van 400 kolommen, en plakt de parser een
# harde wrap alsnog aan elkaar.
#
# Draai dit in Terminal.app, niet vanuit een agent:
#   ~/Desktop/wsl2-claude-code-sandbox/test-lab/create-sandbox-token.sh

set -euo pipefail

DOEL="${SANDBOX_TOKEN_PAD:-$HOME/.sandbox-token}"

if ! command -v claude >/dev/null; then
  printf '\033[31mFOUT: claude staat niet in PATH.\033[0m\n' >&2
  exit 2
fi

# Een eerder gekopieerde setup-token kan door de TUI over twee regels zijn
# verdeeld en voorloopspaties bevatten. Als na het verwijderen van whitespace
# één volledige token overblijft, normaliseer die dan zonder opnieuw inloggen.
if [ -f "$DOEL" ]; then
  if python3 - "$DOEL" <<'PY'
import re, sys
from pathlib import Path

pad = Path(sys.argv[1])
token = re.sub(r"\s+", "", pad.read_text(errors="replace"))
if not re.fullmatch(r"sk-ant-oat[A-Za-z0-9_-]{80,}", token):
    sys.exit(1)
pad.write_text(token + "\n")
pad.chmod(0o600)
print(f"klaar: {pad} ({len(token)} tekens, wordwrap verwijderd)")
PY
  then
    exit 0
  fi
fi

printf 'Browser gaat openen. Log in op het Claude-account waarvan de meting mag draaien.\n'
printf 'Daarna sluit dit vanzelf; de token wordt niet getoond.\n\n'

# Python opent de pty op 400 kolommen (niet 80), koppelt jouw toetsenbord
# door, en haalt de token uit de uitvoer — ook als hij tóch wrapt.
export SANDBOX_TOKEN_PAD="$DOEL"
python3 - <<'PY'
import fcntl, os, pty, re, select, struct, sys, termios
from pathlib import Path

doel = Path(os.environ["SANDBOX_TOKEN_PAD"])
ANSI = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-~]"
    r"|\x1b\]8;;[^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|\x1b\][^\x07]*\x07"
)
TOKEN_CHAR = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")


def strip_ansi(s: str) -> str:
    return ANSI.sub("", s)


def extract(ruw: str):
    tekst = strip_ansi(ruw).replace("\r\n", "\n").replace("\r", "\n")
    prefix = "sk-ant-oat"
    gevonden = None
    i = 0
    while True:
        j = tekst.find(prefix, i)
        if j < 0:
            break
        if j > 0 and tekst[j - 1] in TOKEN_CHAR:
            i = j + 1
            continue
        k = j + len(prefix)
        body = []
        wraps = 0
        while k < len(tekst):
            c = tekst[k]
            if c in TOKEN_CHAR:
                body.append(c)
                k += 1
                continue
            # harde wrap: volgende regel begint met token-tekens
            if c == "\n" and wraps < 3 and len(body) < 80:
                nxt = k + 1
                if nxt < len(tekst) and tekst[nxt] in TOKEN_CHAR:
                    wraps += 1
                    k += 1
                    continue
            break
        token = prefix + "".join(body)
        if len(token) >= 100:
            gevonden = token
        i = j + 1
    return gevonden, tekst


def diagnose(tekst: str) -> str:
    regels = tekst.split("\n")
    bits = []
    for n, regel in enumerate(regels):
        if "sk-ant-oat" in regel:
            nxt = regels[n + 1] if n + 1 < len(regels) else ""
            bits.append(
                f"regel {n}: {len(regel)} tekens, volgende: {len(nxt)} tekens"
            )
    return "; ".join(bits) or "geen sk-ant-oat-regel gezien"


def set_winsize(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


pid, fd = pty.fork()
if pid == 0:
    os.execvp("claude", ["claude", "setup-token"])

set_winsize(fd, 40, 400)
buf = bytearray()
try:
    stdin_fd = sys.stdin.fileno()
    while True:
        r, _, _ = select.select([fd, stdin_fd], [], [])
        if stdin_fd in r:
            stuk = os.read(stdin_fd, 1024)
            if not stuk:
                break
            os.write(fd, stuk)
        if fd in r:
            try:
                stuk = os.read(fd, 4096)
            except OSError:
                break
            if not stuk:
                break
            buf.extend(stuk)
            os.write(sys.stdout.fileno(), stuk)
except OSError:
    pass
os.close(fd)
os.waitpid(pid, 0)

ruw = buf.decode("utf-8", errors="replace")
token, schoon = extract(ruw)
if token is None:
    sys.stderr.write(
        "FOUT: geen volledige token in de uitvoer. "
        f"{diagnose(schoon)}\n"
        "Login afgebroken, of dit account heeft geen Pro/Max.\n"
    )
    sys.exit(2)

if doel.exists():
    doel.rename(doel.with_name(doel.name + ".bak"))
doel.write_text(token + "\n")
doel.chmod(0o600)
print(f"klaar: {doel} ({len(token)} tekens, prefix {token[:10]}…)")
PY
