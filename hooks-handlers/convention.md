## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. One entry is recorded (or durably queued) EVERY turn; the plugin backdates the start 60s and skips only exact-duplicate segments (same worktype+task/project within 15 min).

**Writing a specific description each turn is REQUIRED, not optional.** You always have the context of what you just did, so there is no excuse for a vague entry. If you don't write one, the plugin falls back to your last assistant message from the transcript (`[auto] …`), and only to a `[needs description] <project>` placeholder if that's unavailable — both are worse than a purposeful one-line summary plus the right worktype. Always write a concrete description of what was actually done this turn.

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn, following the Description rules below (<=255 chars). Rewrite every turn.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Rewrite every turn.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — task display ID (strip `#`). Sticky; write once when known.
- `project-${CLAUDE_CODE_SESSION_ID}.txt` — Apropos project ID. Sticky; use when no task.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default 13 (Engineering). SQL/proc 92. Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87.

### Description rules

1. **Past tense — completed work.** "Replaced the Barbie experience products…", never present/gerund ("Replacing…").
2. **255 characters or less** (Apropos limit; the hook also trims to 255).
3. **The person's own perspective — what they did.** No "helped", "assisted", "coached", "guided", "supported".
4. **No AI wording.** Never mention AI, Claude, an assistant, automation, agents, tools, prompts, or "auto".
5. **No client/project/task prefix.** Don't prepend "FAO Schwarz:" or "…on the FAO staging site" — the entry is already linked to its task/project. Just state the work.
6. **Follow the time skill.** Person auto-resolves from the Windows username (Barrett=276, Eric=321, Joel=344, Caleb=1298); each entry links to an Intervals task (`task-…txt`) or Apropos project (`project-…txt`).

Do NOT announce writing these files — background convention, not a deliverable.
