## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. One entry is recorded (or durably queued) EVERY turn. The entry is written when your response completes and is backdated to the moment the prompt arrived, so the marker sits at the real start of the work. An entry is skipped only when the worktype, task/project AND description are all identical to the previous entry within 15 minutes.

**Writing a specific description each turn is REQUIRED, not optional.** If you don't, the entry still records — but only as a flagged placeholder `[needs description] <project>` at worktype 13, which the user then has to find and fix. That is a failure on your part. Always write a concrete description of what was actually done this turn.

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn. Rewrite every turn.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Rewrite every turn.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — task display ID (strip `#`). Sticky; write once when known.
- `project-${CLAUDE_CODE_SESSION_ID}.txt` — Apropos project ID. Sticky; use when no task.

### Description rules — these land on client invoices

1. **Under 255 characters.** The hook truncates at 255 and so does the downstream Intervals import. Longer text is cut mid-sentence.
2. **First person, outcome-focused, readable by a non-engineer.** No file paths, script names, class or method names, version numbers, or selector/CSS detail.
3. **Never name Claude or any AI**, and never write about the user in the third person. The entry is from their perspective.
4. **Never ship a placeholder** like `[needs description]` or `[Work Description Needed]`.
5. **Past tense, completed work.** "Replaced the Barbie experience products", never "Replacing".
6. **No AI wording or AI-tell punctuation.** Never mention AI, Claude, an assistant, automation, agents, tools, or prompts. No em-dashes, en-dashes, curly quotes, or ellipses; use plain hyphens and straight quotes.
7. **No client/project/task prefix.** Do not prepend "FAO Schwarz:" or "on the FAO staging site". The entry is already linked to its task or project. Just state the work.

### Attribution rules

8. **Always attribute.** Every entry should carry a task (or at minimum a project) plus a worktype. An entry with no task and no project is a defect that has to be redone by hand.
9. **When the turn's work moves to a different client or project, change the sticky task/project file before the turn ends.** Leaving the previous task sticky bills that client for unrelated work.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default 13 (Engineering). SQL/proc 92. Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87. Meetings/email/coordination 7. Hands-on test scenarios 86. Internal admin/process 59.

Do NOT announce writing these files — background convention, not a deliverable.
