#!/usr/bin/env bash
# apropos /setup: remove any legacy hand-pasted per-turn block from CLAUDE.md
# (the plugin now injects the convention via SessionStart). Idempotent.
set -euo pipefail
MD="${HOME}/.claude/CLAUDE.md"
MARKER="## Time tracking - per-turn Apropos convention"
if [[ "${1:-}" == "--remove-legacy" && -f "$MD" ]] && grep -qF "$MARKER" "$MD"; then
  cp "$MD" "${MD}.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v m="$MARKER" '$0==m{skip=1;next} skip==1&&/^## /{skip=0} skip==1{next} {print}' "$MD" > "${MD}.tmp" && mv "${MD}.tmp" "$MD"
  echo "Removed legacy per-turn block from CLAUDE.md (backup saved)."
fi
command -v jq >/dev/null 2>&1 || echo "WARN: jq not found — install it for best prompt-fallback fidelity."
echo "SETUP OK"
