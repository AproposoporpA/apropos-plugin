---
description: Record an ad-hoc Apropos time entry for Eric Barone (Person 321).
---
Record time for **Eric Barone (Person ID 321)** by running:
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID 321 -Description "$ARGUMENTS"`
If a task was named (`#29100`) add `-TaskID 29100`; if a project was named add `-ProjectID <id>`. If `$ARGUMENTS` is empty, summarize the current work as the description. Report success or the error.
