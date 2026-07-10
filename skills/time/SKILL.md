---
name: time
description: Records AI coaching time entries into Apropos. Use for "/time-ericb", "/time-joelp", "/time-barrettg", "/time-calebbi", or "record time".
---

# Record Time Entry

Records a time entry for AI coaching work into the Apropos database using the `CLAUDE_TimeEntry_INSERT` stored procedure.

## Invocation

Invoke as `/time-[FirstNameLastInitial]` to record time for a specific person, or simply say "record time" and it will default to the logged-in user.

> **Tool Reference:** See `R:/Intranet/ClaudeAI/tools/apropos.md` for connection details, stored procedures, and person IDs.

| Command | Person | Apropos Person ID | Windows Username |
|---------|--------|-------------------|------------------|
| `/time-ericb` | Eric Barone | 321 | ericbarone |
| `/time-joelp` | Joel Perez | 344 | joelperez |
| `/time-barrettg` | Barrett Goldberg | 276 | barrettgoldberg |
| `/time-calebb` | Caleb Barone | 1298 | calebbarone |

## How It Works

When invoked, the skill:

1. Identifies the person (from the command name, or defaults to the logged-in user)
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

Map the command to the person using the table above. Use the following priority:

1. **Explicit command:** If the user invoked via `/time-[name]`, use that person.
2. **Named in request:** If the user said "record time for Joel", use Joel.
3. **Default to logged-in user:** If the user just said "record time" without specifying anyone, default to the logged-in user. Determine the logged-in user by checking the Windows username (from the session environment, user profile path, or `$env:USERNAME`) and matching it to the table above. Do not ask who to record for — just default to them.

**Recording for multiple people:** A user may say "record time for me and Joel" or "record time for me and Barrett". In this case, run the script once for each person with the same description.

If the person's ID is marked TODO, inform the user that the Apropos Person ID needs to be configured first.

### Step 2: Get the Work Description

If the user provided a description as arguments (e.g., `/time-ericb Reviewed deployment pipeline`), use that.

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
User: /time-ericb Coached Claude on deployment best practices

Claude: Recording time entry for Eric Barone...

[Runs Record-Time.ps1 -PersonID 321 -Description "Coached Claude on deployment best practices"]

Time entry recorded for Eric Barone:
  Description: Coached Claude on deployment best practices
  Timestamp: 2026-02-09 (UTC)
```
