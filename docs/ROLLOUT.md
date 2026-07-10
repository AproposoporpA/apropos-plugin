# apropos plugin — team rollout

For Joel, Barrett, and Caleb. Moves you from the legacy `time-track.sh` setup to
the `apropos` plugin. ~2 minutes.

## Prerequisites
- On the RICO network with the `R:` drive mapped (the plugin calls the internal
  write skill there; nothing records off-network).
- PowerShell 7 (`pwsh`) available.
- `jq` recommended (used to detect session + project). If missing, recording still
  works; the project tag in placeholders may be absent.

## Steps
Run these slash commands in Claude Code:

```
/plugin marketplace add AproposoporpA/apropos-plugin
/plugin install apropos@apropos-plugin
/apropos:setup
```

`/apropos:setup` automatically:
- removes any legacy per-turn convention block from your `CLAUDE.md`, and
- removes the legacy manual `UserPromptSubmit` hook (the `R:` `time-track-per-turn.sh`
  one) from your `settings.json` — so you do NOT double-record.

Both files are backed up first (`*.bak-<timestamp>`).

Then **fully quit and reopen Claude Code.**

## Verify
After reopening, the session should start with the injected time-tracking
convention. Do one normal turn, then check Apropos — you should see one entry under
your name with a real description (worktype auto-selected).

## What you get
- One time entry recorded every turn (start-marker), backdated 60s, duplicate
  segments skipped.
- If a write fails or the network blips, the entry is queued locally
  (`~/.claude/apropos-time/`) and flushed on the next turn or at next session start —
  no lost time.
- Manual commands still available: `/time-joelp`, `/time-barrettg`, `/time-calebb`,
  `/break`, `/lunch`, `/out`.

## Trouble
- No entries appearing: confirm `R:` is mapped and you're on the network; confirm
  `apropos` shows in `/plugin`.
- Seeing `[needs description] <project>` entries: that's the fallback when a specific
  description wasn't written that turn — filter on `[needs description]` in Apropos to
  reassign/clean them.
