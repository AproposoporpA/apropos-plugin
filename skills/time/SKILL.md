---
name: time
description: Records time entries into Apropos for the logged-in user. Use for "/time" or "record time".
---

# Record Time Entry

Records a time entry into the Apropos database using the `CLAUDE_TimeEntry_INSERT` stored procedure.

## Invocation

Invoke as `/time <description>` (or say "record time"). It records for the **logged-in user**, resolved from the Windows username — you don't pick a person.

> **Tool Reference:** See `R:/Intranet/ClaudeAI/tools/apropos.md` for connection details, stored procedures, and person IDs.

Windows username → Apropos Person ID:

| Person | Apropos Person ID | Windows Username |
|--------|-------------------|------------------|
| Eric Barone | 321 | ericbarone |
| Joel Perez | 344 | joelperez |
| Barrett Goldberg | 276 | barrettgoldberg |
| Caleb Barone | 1298 | calebbarone |

## How It Works

When invoked, the skill:

1. Identifies the person from the logged-in Windows username
2. Asks the user for a work description (if not provided as args)
3. Calls the Apropos stored procedure to insert the time entry

### Stored Procedure

```sql
EXEC [dbo].[CLAUDE_TimeEntry_INSERT] @resourceID = 321, @workDescription = 'description'

-- With an Intervals task:
EXEC [dbo].[CLAUDE_TimeEntry_INSERT] @resourceID = 321, @workDescription = 'description', @integrationTaskDisplayID = 29100
```

Required parameters:
- **@resourceID:** Apropos Person ID
- **@workDescription:** Work description

Optional parameters (defaults handled by the proc):
- **@integrationTaskDisplayID:** Intervals task ID (the `#number` from task URLs). The proc resolves this to the internal Apropos taskID automatically.
- **@starttime:** UTC timestamp (defaults to GETUTCDATE())
- **@organizationID, @initiativeID, @projectID, @taskID:** Scope the entry
- **@workTypeID:** Work type category
- **@billable:** Bit flag (defaults to 0)

## How to Use

### Step 1: Identify the Person

Default to the **logged-in user**: determine the Windows username (from the session environment, user profile path, or `$env:USERNAME`) and match it to the table above. Do not ask who to record for.

The only exception: if the user explicitly says "record time for Joel" (naming someone else), use that person instead.

**Recording for multiple people:** A user may say "record time for me and Joel" or "record time for me and Barrett". In this case, run the script once for each person with the same description.

If the person's ID is marked TODO, inform the user that the Apropos Person ID needs to be configured first.

### Step 2: Get the Work Description

If the user provided a description as arguments (e.g., `/time Reviewed deployment pipeline`), use that.

If the user says something like "whatever I'm working on" or doesn't provide a description, summarize the current conversation/task as the description. For example, if you've been helping build a new feature, use "Building payment gateway integration".

If there is no conversation context to draw from, ask: "What work description should I record for this time entry?"

### Step 3: Execute the Script

```powershell
# Without a task:
& 'R:\Intranet\ClaudeAI\skills\work-management\time\Record-Time.ps1' -PersonID <ID> -Description "<description>"

# With an Intervals task:
& 'R:\Intranet\ClaudeAI\skills\work-management\time\Record-Time.ps1' -PersonID <ID> -Description "<description>" -TaskID <IntervalsTaskID>
```

If the user mentions a task number (e.g., "record time on task #29100"), pass it as `-TaskID`.

### Step 4: Confirm

Report the result to the user:
- Success: "Time entry recorded for [Person] - [Description]"
- Error: Show the error and suggest next steps

## Database Connection

See `R:/Intranet/ClaudeAI/tools/apropos.md` for connection details and permissions.

## Break / Lunch / End-of-Day Convention

When Eric says he's stepping away — "going to lunch," "taking a break," "leaving for the day," "done for the day," or similar — immediately record a time entry with the appropriate description to close out the current work segment:

| Trigger phrase | Description | EventTypeID | EventType name |
|----------------|-------------|-------------|----------------|
| Going to lunch / lunch | `Lunch` | 7 | Meal Break |
| Taking a break / brb | `Break` | 3 | Rest Break |
| Leaving for the day / done for the day / heading out / out | `Out` | 8 | Shift End |

Pass description and EventTypeID. No worktype, no task ID. Run via `Record-Time.ps1` immediately — do not ask for confirmation.

Resolve the PersonID from the Windows username of the logged-in user (same as Step 1 above). Do not hardcode Eric's ID — any team member can use this.

```powershell
# Lunch (replace {PersonID} with the logged-in user's Apropos ID)
& 'R:\Intranet\ClaudeAI\skills\work-management\time\Record-Time.ps1' -PersonID {PersonID} -Description "Lunch" -EventTypeID 7

# Break
& 'R:\Intranet\ClaudeAI\skills\work-management\time\Record-Time.ps1' -PersonID {PersonID} -Description "Break" -EventTypeID 3

# Leaving for the day
& 'R:\Intranet\ClaudeAI\skills\work-management\time\Record-Time.ps1' -PersonID {PersonID} -Description "Out" -EventTypeID 8
```

When Eric returns and sends the next message, the per-turn hook fires a new entry for the next activity automatically — closing the break segment.

## Example Session

```
User: /time Reviewed and updated the deployment pipeline

Claude: Recording time entry for Eric Barone...

[Runs Record-Time.ps1 -PersonID 321 -Description "Reviewed and updated the deployment pipeline"]

Time entry recorded for Eric Barone:
  Description: Reviewed and updated the deployment pipeline
  Timestamp: 2026-02-09 (UTC)
```
