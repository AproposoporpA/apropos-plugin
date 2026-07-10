---
description: Record a Break (Rest Break, EventTypeID 3) for the logged-in user.
---
Resolve the logged-in user's Person ID from the Windows username (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298), then run immediately (no confirmation):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "Break" -EventTypeID 3`
