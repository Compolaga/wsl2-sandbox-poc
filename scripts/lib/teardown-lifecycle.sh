#!/usr/bin/env bash
# Kleine teardown-adapter naar de centrale Python-lifecycle. Voert zelf geen
# cleanup uit en veronderstelt dat de caller de actieve-policycheck al deed.

lifecycle_cleanup_gate() { # <repo-root> <lifecycle-tool> <claude-version>
  local root="$1" tool="$2" claude_version="$3"
  if [ ! -f "$root/local/trial-lifecycle.jsonl" ]; then
    echo "WAARSCHUWING: legacy teardown zonder local/trial-lifecycle.jsonl."
    echo "Lifecyclebewijs ontbreekt; vergelijk alle resterende cleanup handmatig met de beginstaat."
    return 0
  fi

  mkdir -p "$root/local"
  if [ ! -f "$root/local/runtime-after-rollback.txt" ]; then
    {
      echo "recordedAt: $(date -Iseconds)"
      echo "claude: $claude_version"
      echo "policy: niet actief volgens teardown-preflight"
    } > "$root/local/runtime-after-rollback.txt"
  fi
  python3 "$tool" record runtime-verified --root "$root" \
    --evidence local/runtime-after-rollback.txt --if-absent || return 2
  python3 "$tool" plan cleanup --root "$root" || return 2
}
