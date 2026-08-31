# apropos — reliable Apropos time recording

Records one Apropos start-marker per activity, being task plus work type plus project, with fallbacks and a durable local queue so time is never lost to a missing description or a flaky network.

## Install
1. `/plugin marketplace add AproposoporpA/apropos-plugin`
2. `/plugin install apropos`
3. `/setup`
4. Restart Claude Code.

## Reliability
- Always records (or queues) one entry per ACTIVITY, being task + worktype + project. A turn continuing an activity already open amends that entry instead of inserting beside it; a new one opens when the activity changes or after `APROPOS_MERGE_MAX_SECS` (default 1800). Open entries are shared across concurrent sessions and guarded by the queue lock. `APROPOS_MERGE=off` restores one entry per turn.
- If a specific description wasn't written, it falls back to the last assistant message from the transcript, preferring a labelled summary, and refuses candidates that are conversational acknowledgements, carry a file path, name the tooling, or fall under `APROPOS_DERIVE_MIN` (default 40) characters. Only then does it use a `[needs description] <project>` tag, and the project name is dropped when it is itself an AI reference. `APROPOS_DERIVE=off` disables the fallback.
- Backdates the start to the prompt; skips only exact-duplicate segments (<15 min).
- If the write fails or `R:`/network is down, the entry is queued locally (`~/.claude/apropos-time/`) and flushed on a later turn.

## Security
No credentials or database access ship in this repo. The credentialed write lives only in the internal `R:` skill (`Record-Time.ps1`), reachable on the RICO network. Off-network entries queue and flush later; a downloaded copy of this plugin cannot write to Apropos.

## Commands
`/time` (records for the logged-in user, resolved from the Windows username), `/break`, `/lunch`, `/out`, `/setup`.

## Tests
`bash tests/run-all.sh`
