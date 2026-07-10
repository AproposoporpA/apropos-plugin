#!/usr/bin/env bash
# apropos /setup: remove any legacy hand-pasted per-turn block from CLAUDE.md
# (the plugin now injects the convention via SessionStart). Idempotent.
set -euo pipefail
MD="${HOME}/.claude/CLAUDE.md"
# Match any legacy per-turn time-tracking heading regardless of dash style
# (hyphen or em-dash) or trailing text, and remove EVERY such block.
HDR_RE='^##[[:space:]]*Time tracking.*per-turn Apropos convention'
if [[ "${1:-}" == "--remove-legacy" && -f "$MD" ]] && grep -qE "$HDR_RE" "$MD"; then
  cp "$MD" "${MD}.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v re="$HDR_RE" '
    /^#/ { if ($0 ~ re) { skip=1; next } else { skip=0 } }
    skip { next }
    { print }
  ' "$MD" > "${MD}.tmp" && mv "${MD}.tmp" "$MD"
  echo "Removed legacy per-turn block(s) from CLAUDE.md (backup saved)."
fi
command -v jq >/dev/null 2>&1 || echo "WARN: jq not found — install it for best prompt-fallback fidelity."
echo "SETUP OK"
