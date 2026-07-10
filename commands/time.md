---
description: Record an ad-hoc Apropos time entry for the logged-in user.
---
Record time for the **logged-in user** — resolve their Apropos Person ID from the Windows username (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298), then run:
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "$ARGUMENTS"`
If a task was named (`#30038`) add `-TaskID 30038`; if a project was named add `-ProjectID <id>`. If `$ARGUMENTS` is empty, summarize the current work as the description. Report success or the error.
