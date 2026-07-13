# apropos — reliable Apropos time recording

Records one Apropos start-marker every turn, with fallbacks and a durable local queue so time is never lost to a missing description or a flaky network.

## Install
1. `/plugin marketplace add AproposoporpA/apropos-plugin`
2. `/plugin install apropos`
3. `/setup`
4. Restart Claude Code.

## Reliability
- Always records (or queues) one entry per turn. If a specific description wasn't written, it falls back to the last assistant message from the transcript (real context), and only to a `[needs description] <project>` tag if that's unavailable.
- Backdates the start 60s; skips only exact-duplicate segments (<15 min).
- If the write fails or `R:`/network is down, the entry is queued locally (`~/.claude/apropos-time/`) and flushed on a later turn.

## Security
No credentials or database access ship in this repo. The credentialed write lives only in the internal `R:` skill (`Record-Time.ps1`), reachable on the RICO network. Off-network entries queue and flush later; a downloaded copy of this plugin cannot write to Apropos.

## Commands
`/time` (records for the logged-in user, resolved from the Windows username), `/break`, `/lunch`, `/out`, `/setup`.

## Tests
`bash tests/run-all.sh`
