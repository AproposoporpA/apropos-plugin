---
description: Record end of day (Shift End, EventTypeID 8) for the logged-in user.
---
Resolve the logged-in user's Person ID from the Windows username (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298), then run immediately (no confirmation):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "Out" -EventTypeID 8`
