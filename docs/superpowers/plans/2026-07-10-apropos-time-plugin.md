# Apropos Time-Recording Plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a public Claude Code plugin named `apropos` that records per-turn Apropos time entries by calling internal `R:` skills, so the whole team can install it via `/plugin install` + `/setup`.

**Architecture:** The public plugin is a thin orchestration shell (hooks + commands + setup). ALL business logic and the DB credential live in the internal `R:` skill layer: `Record-Turn.ps1` (dedup + backdate + person/task resolution + write) and `Resolve-Task.ps1` (org/project → task lookup). The plugin's per-turn hook is pure glue — it hands the raw turn data to the `R:` entrypoint and fails safe (exit 0) when that entrypoint is unreachable (off-network).

**Tech Stack:** Bash (hook handlers, plugin tests), PowerShell 7 / pwsh (R: skill layer + its tests), JSON (`plugin.json`, `hooks.json`), Markdown (commands, convention, docs). Tests are plain assertion scripts (bash + `pwsh -File`) — **no test framework dependency** (Pester on these machines is only v3.4).

## Global Constraints

- Plugin name is exactly `apropos`. Public repo: `AproposoporpA/apropos-plugin`. Local workspace: `A:\Product Development\Program\Claude Plugin`.
- **No credentials, no connection strings, no direct DB access in the public repo — ever.** The Apropos connection string exists only in the `R:` skill layer.
- Skill layer path (default): `R:/Intranet/ClaudeAI/skills/work-management/time`. Overridable for tests via env `APROPOS_SKILL_DIR`.
- Recording behavior: record on **every response**, `StartTime` **backdated 60 seconds**, **skip** when the segment key `worktype|task|project` matches the last entry **and** `< 900s` (15 min) elapsed.
- Person resolution from Windows username: `ericbarone=321`, `joelperez=344`, `barrettgoldberg=276`, `calebbarone=1298`. Unknown username → no record.
- Time entries are START MARKERS only — never write an end time.
- Task resolution order: (1) explicit stated task; (2) else org/project → most-recently-active task via Apropos; (3) else record at project/org level so no time is lost.
- Every hook exits 0 always — never block the user.
- Frequent commits: one commit per task minimum. DRY, YAGNI, TDD.

---

### Task 1: Plugin manifest + repo skeleton

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `tests/helpers.sh`
- Create: `tests/test-manifest.sh`

**Interfaces:**
- Produces: a valid plugin manifest with `name: "apropos"`; `tests/helpers.sh` exposing bash functions `assert_eq <expected> <actual> <msg>`, `assert_contains <haystack> <needle> <msg>`, `pass <msg>`, and a trap that prints `ALL TESTS PASSED` / `TESTS FAILED` and sets exit code.

- [ ] **Step 1: Write the failing test**

`tests/helpers.sh`:
```bash
#!/usr/bin/env bash
# Minimal assertion helpers. Source this at the top of every test.
_TEST_FAILS=0
assert_eq()       { if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 (expected '$1', got '$2')"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' not in output)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_not_contains(){ if [[ "$1" != *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' unexpectedly present)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
pass()            { echo "  ok: $1"; }
finish()          { if (( _TEST_FAILS > 0 )); then echo "TESTS FAILED ($_TEST_FAILS)"; exit 1; else echo "ALL TESTS PASSED"; exit 0; fi; }
```

`tests/test-manifest.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
MANIFEST="$DIR/.claude-plugin/plugin.json"

[[ -f "$MANIFEST" ]] && pass "plugin.json exists" || { echo "  FAIL: plugin.json missing"; _TEST_FAILS=1; }
jq empty "$MANIFEST" 2>/dev/null && pass "plugin.json is valid JSON" || { echo "  FAIL: invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
NAME="$(jq -r '.name' "$MANIFEST" 2>/dev/null)"
assert_eq "apropos" "$NAME" "manifest name is 'apropos'"
# No secrets anywhere in the repo tree (belt-and-suspenders)
if grep -rniE 'password|connectionstring|ClaudeAI2026|claudeaproposreadonly' "$DIR" --include='*.json' --include='*.sh' --include='*.md' -l 2>/dev/null | grep -v 'docs/superpowers'; then
  echo "  FAIL: possible secret found in repo"; _TEST_FAILS=$((_TEST_FAILS+1));
else pass "no secrets in json/sh/md (outside docs)"; fi
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-manifest.sh`
Expected: FAIL — "plugin.json missing".

- [ ] **Step 3: Write minimal implementation**

`.claude-plugin/plugin.json`:
```json
{
  "name": "apropos",
  "description": "Records per-turn Apropos time entries by calling internal RICO skills. Team time-tracking rollout vehicle. Contains no credentials; all DB access lives in the internal R: skill layer.",
  "version": "0.1.0",
  "author": { "name": "AproposoporpA" }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-manifest.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/plugin.json tests/helpers.sh tests/test-manifest.sh
git commit -m "feat: add apropos plugin manifest and test harness"
```

---

### Task 2 (R: skill layer): `Record-Turn.ps1` — dedup + backdate orchestrator

**Location:** internal skill layer `R:/Intranet/ClaudeAI/skills/work-management/time/` (NOT the public repo). Tests live beside it on `R:`.

**Files:**
- Create: `R:/Intranet/ClaudeAI/skills/work-management/time/Record-Turn.ps1`
- Create: `R:/Intranet/ClaudeAI/skills/work-management/time/tests/Record-Turn.Tests.ps1`

**Interfaces:**
- Consumes: existing `Record-Time.ps1` (writer). Injectable for tests via `-WriterScript` (default `Record-Time.ps1` in the same dir) and `-Resolver` (default `Resolve-Task.ps1`, added in Task 3).
- Produces: `Record-Turn.ps1` params `-SessionId <string> -TrackDir <path> -Username <string>`. Reads `description-$SessionId.txt` (required), `worktype-$SessionId.txt` (required numeric), `task-$SessionId.txt` / `project-$SessionId.txt` (optional, sticky), `last-entry-$SessionId.txt` (dedup state). Returns object `{ Action = 'fired'|'skipped-dedup'|'skipped-nodesc'|'skipped-noworktype'|'skipped-nouser'; StartTimeUtc; SegmentKey }`. Backdates StartTime 60s. On fire, deletes the description + worktype files and rewrites `last-entry`; on dedup-skip, still deletes description + worktype files.

- [ ] **Step 1: Write the failing test**

`R:/Intranet/ClaudeAI/skills/work-management/time/tests/Record-Turn.Tests.ps1`:
```powershell
$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $PSScriptRoot
$script  = Join-Path $here 'Record-Turn.ps1'
$fails   = 0
function Assert($cond,$msg){ if($cond){ "  ok: $msg" } else { "  FAIL: $msg"; $script:fails++ } }

# Test harness: a mock writer that logs its args instead of hitting the DB.
$work = Join-Path ([IO.Path]::GetTempPath()) ("rt-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$log  = Join-Path $work 'writer.log'
$mockWriter = Join-Path $work 'mock-writer.ps1'
@'
param($PersonID,$Description,$TaskID=0,$ProjectID=0,$WorkTypeID=0,$EventTypeID=0,$StartTimeUTC="")
"$PersonID|$Description|$TaskID|$ProjectID|$WorkTypeID|$StartTimeUTC" | Out-File -Append -FilePath $env:WRITER_LOG
'@ | Set-Content $mockWriter
$env:WRITER_LOG = $log
# Mock resolver that echoes back nothing (no task resolution in these tests)
$mockResolver = Join-Path $work 'mock-resolver.ps1'
'param($Task,$Project,$Org) return 0' | Set-Content $mockResolver

function NewSession {
  $sid = [guid]::NewGuid().ToString()
  Set-Content (Join-Path $work "description-$sid.txt") "Test work segment"
  Set-Content (Join-Path $work "worktype-$sid.txt") "13"
  return $sid
}

# 1. First entry fires and backdates ~60s
$sid = NewSession
$before = (Get-Date).ToUniversalTime()
$r = & $script -SessionId $sid -TrackDir $work -Username 'ericbarone' -WriterScript $mockWriter -Resolver $mockResolver
Assert ($r.Action -eq 'fired') "first turn fires"
$logged = Get-Content $log
Assert ($logged -match '^321\|Test work segment\|0\|0\|13\|') "writer called with person 321, worktype 13"
$delta = ($before - [datetime]::Parse($r.StartTimeUtc)).TotalSeconds
Assert ($delta -ge 55 -and $delta -le 120) "StartTime backdated ~60s"
Assert (-not (Test-Path (Join-Path $work "description-$sid.txt"))) "description consumed after fire"

# 2. Same segment within 15 min -> skip
Set-Content (Join-Path $work "description-$sid.txt") "Same segment continues"
Set-Content (Join-Path $work "worktype-$sid.txt") "13"
Remove-Item $log
$r2 = & $script -SessionId $sid -TrackDir $work -Username 'ericbarone' -WriterScript $mockWriter -Resolver $mockResolver
Assert ($r2.Action -eq 'skipped-dedup') "same segment within 15min skips"
Assert (-not (Test-Path $log)) "writer NOT called on dedup skip"
Assert (-not (Test-Path (Join-Path $work "description-$sid.txt"))) "description still consumed on skip"

# 3. Different worktype -> fires again
Set-Content (Join-Path $work "description-$sid.txt") "Switched to docs"
Set-Content (Join-Path $work "worktype-$sid.txt") "23"
$r3 = & $script -SessionId $sid -TrackDir $work -Username 'ericbarone' -WriterScript $mockWriter -Resolver $mockResolver
Assert ($r3.Action -eq 'fired') "new worktype fires new segment"

# 4. Missing description -> skip
$sid2 = [guid]::NewGuid().ToString()
Set-Content (Join-Path $work "worktype-$sid2.txt") "13"
$r4 = & $script -SessionId $sid2 -TrackDir $work -Username 'ericbarone' -WriterScript $mockWriter -Resolver $mockResolver
Assert ($r4.Action -eq 'skipped-nodesc') "missing description skips"

# 5. Unknown user -> skip
$sid3 = NewSession
$r5 = & $script -SessionId $sid3 -TrackDir $work -Username 'nobody' -WriterScript $mockWriter -Resolver $mockResolver
Assert ($r5.Action -eq 'skipped-nouser') "unknown username skips"

Remove-Item $work -Recurse -Force
if ($fails -gt 0) { "TESTS FAILED ($fails)"; exit 1 } else { "ALL TESTS PASSED"; exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/tests/Record-Turn.Tests.ps1"`
Expected: FAIL — `Record-Turn.ps1` not found / not runnable.

- [ ] **Step 3: Write minimal implementation**

`R:/Intranet/ClaudeAI/skills/work-management/time/Record-Turn.ps1`:
```powershell
<#
.SYNOPSIS
  Orchestrates one per-turn Apropos time recording: person resolution, task
  resolution, segment dedup, 60s backdating, then delegates the write.
  All business logic lives here (skill layer); the plugin hook is thin glue.
#>
param(
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$TrackDir,
  [Parameter(Mandatory=$true)][string]$Username,
  [string]$WriterScript = (Join-Path $PSScriptRoot 'Record-Time.ps1'),
  [string]$Resolver      = (Join-Path $PSScriptRoot 'Resolve-Task.ps1')
)

$ErrorActionPreference = 'Stop'
function Result($action, $start='', $key=''){ [pscustomobject]@{ Action=$action; StartTimeUtc=$start; SegmentKey=$key } }

# 1. Person resolution
$persons = @{ 'ericbarone'=321; 'joelperez'=344; 'barrettgoldberg'=276; 'calebbarone'=1298 }
$u = $Username.ToLower()
if (-not $persons.ContainsKey($u)) { return Result 'skipped-nouser' }
$personId = $persons[$u]

$descFile = Join-Path $TrackDir "description-$SessionId.txt"
$wtFile   = Join-Path $TrackDir "worktype-$SessionId.txt"
$taskFile = Join-Path $TrackDir "task-$SessionId.txt"
$projFile = Join-Path $TrackDir "project-$SessionId.txt"
$lastFile = Join-Path $TrackDir "last-entry-$SessionId.txt"

# 2. Required: description
if (-not (Test-Path $descFile) -or -not (Get-Content $descFile -Raw).Trim()) { return Result 'skipped-nodesc' }
$desc = (Get-Content $descFile -Raw)
if ($desc.Length -gt 500) { $desc = $desc.Substring(0,500) }
$desc = $desc.Trim()

# 3. Required: numeric worktype
if (-not (Test-Path $wtFile)) { return Result 'skipped-noworktype' }
$wt = (Get-Content $wtFile -Raw).Trim()
if ($wt -notmatch '^\d+$') { return Result 'skipped-noworktype' }

# 4. Optional sticky task/project
$task = if (Test-Path $taskFile) { (Get-Content $taskFile -Raw).Trim().TrimStart('#') } else { '' }
$proj = if (Test-Path $projFile) { (Get-Content $projFile -Raw).Trim() } else { '' }

# 5. Task resolution: if no explicit task but a project/org is known, resolve.
if (-not $task -and $proj -and (Test-Path $Resolver)) {
  $resolved = & $Resolver -Project $proj 2>$null
  if ($resolved -and "$resolved" -match '^\d+$' -and [int]$resolved -gt 0) { $task = "$resolved" }
}

# 6. Segment dedup
$segKey = "$wt|$task|$proj"
$now    = [int][double]::Parse((Get-Date -UFormat %s))
if (Test-Path $lastFile) {
  $line = (Get-Content $lastFile -First 1)
  $parts = $line -split '\|', 2
  if ($parts.Count -eq 2 -and $parts[0] -match '^\d+$' -and $parts[1] -eq $segKey) {
    if (($now - [int]$parts[0]) -lt 900) {
      Remove-Item $descFile, $wtFile -ErrorAction SilentlyContinue
      return Result 'skipped-dedup' '' $segKey
    }
  }
}

# 7. Backdate 60s, build args, delegate the write
$startUtc = (Get-Date).ToUniversalTime().AddSeconds(-60).ToString('yyyy-MM-dd HH:mm:ss')
$args = @{ PersonID=$personId; Description=$desc; WorkTypeID=[int]$wt; StartTimeUTC=$startUtc }
if ($task) { $args['TaskID'] = [int]$task } elseif ($proj) { $args['ProjectID'] = [int]$proj }
& $WriterScript @args | Out-Null

# 8. Update dedup state, consume one-shot files
"$now|$segKey" | Set-Content $lastFile
Remove-Item $descFile, $wtFile -ErrorAction SilentlyContinue
return Result 'fired' $startUtc $segKey
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/tests/Record-Turn.Tests.ps1"`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit** (plan/test copy kept in repo under `skill-layer/` mirror for reference; the live script is on `R:`)

```bash
# The R: script is not in git. Commit only the reference mirror + note.
git add docs/superpowers/plans/2026-07-10-apropos-time-plugin.md
git commit -m "docs: record Record-Turn.ps1 skill-layer design (lives on R:)"
```

---

### Task 3 (R: skill layer): `Resolve-Task.ps1` — org/project → task lookup

**Location:** `R:/Intranet/ClaudeAI/skills/work-management/time/` (internal).

**Files:**
- Create: `R:/Intranet/ClaudeAI/skills/work-management/time/Resolve-Task.ps1`
- Create: `R:/Intranet/ClaudeAI/skills/work-management/time/tests/Resolve-Task.Tests.ps1`

**Interfaces:**
- Produces: `Resolve-Task.ps1` params `-Task <int> -Project <string> -Org <string> -QueryFn <scriptblock>`. Behavior: if `$Task` > 0, return it unchanged. Else if `$Project`/`$Org` given, call `$QueryFn` (default: real Apropos query via `Invoke-Sqlcmd`-style helper reading the connection string from the local skill config) returning candidate task rows ordered by last-activity desc; return the top task ID. If zero candidates, return 0 (caller falls back to project/org level). `$QueryFn` is injectable so tests never touch the DB.

- [ ] **Step 1: Write the failing test**

`R:/Intranet/ClaudeAI/skills/work-management/time/tests/Resolve-Task.Tests.ps1`:
```powershell
$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $here 'Resolve-Task.ps1'
$fails  = 0
function Assert($c,$m){ if($c){"  ok: $m"}else{"  FAIL: $m"; $script:fails++} }

# Explicit task passes through, no query
$q = { param($project,$org) throw "should not query" }
Assert ((& $script -Task 29100 -QueryFn $q) -eq 29100) "explicit task returned unchanged"

# Project with multiple candidates -> most-recent (first row)
$q2 = { param($project,$org) @(
  [pscustomobject]@{ TaskId=555; LastActivity='2026-07-09' },
  [pscustomobject]@{ TaskId=222; LastActivity='2026-06-01' }
) }
Assert ((& $script -Project 'Acme Portal' -QueryFn $q2) -eq 555) "most-recent task chosen"

# No candidates -> 0 (fallback)
$q3 = { param($project,$org) @() }
Assert ((& $script -Project 'Empty' -QueryFn $q3) -eq 0) "no candidates returns 0"

if ($fails -gt 0) { "TESTS FAILED ($fails)"; exit 1 } else { "ALL TESTS PASSED"; exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/tests/Resolve-Task.Tests.ps1"`
Expected: FAIL — script not found.

- [ ] **Step 3: Write minimal implementation**

`R:/Intranet/ClaudeAI/skills/work-management/time/Resolve-Task.ps1`:
```powershell
<#
.SYNOPSIS
  Resolves the task number to record against: explicit task wins; else the
  most-recently-active task for the given project/org via Apropos; else 0.
  Read logic lives in the skill layer (holds the internal credential).
#>
param(
  [int]$Task = 0,
  [string]$Project = '',
  [string]$Org = '',
  [scriptblock]$QueryFn = $null
)
$ErrorActionPreference = 'Stop'
if ($Task -gt 0) { return $Task }
if (-not $Project -and -not $Org) { return 0 }

if (-not $QueryFn) {
  # Real query. Connection string comes from the local skill config (R: only) —
  # never committed. Returns candidate tasks ordered by last activity desc.
  $QueryFn = {
    param($project,$org)
    . (Join-Path $PSScriptRoot 'Get-AproposConnection.ps1')  # provides $SqlConnStr
    $sql = @"
SELECT TOP 5 t.DisplayID AS TaskId, MAX(te.StartTime) AS LastActivity
FROM dbo.Task t
LEFT JOIN dbo.TimeEntry te ON te.TaskID = t.ID
WHERE (@project = '' OR t.ProjectName = @project)
  AND (@org = '' OR t.OrganizationName = @org)
  AND t.Active = 1
GROUP BY t.DisplayID
ORDER BY LastActivity DESC
"@
    Invoke-AproposQuery -ConnStr $SqlConnStr -Sql $sql -Params @{ project=$project; org=$org }
  }
}

$rows = & $QueryFn $Project $Org
if (-not $rows -or @($rows).Count -eq 0) { return 0 }
return [int](@($rows)[0].TaskId)
```

> Note: the real `$QueryFn` references `Get-AproposConnection.ps1` / `Invoke-AproposQuery` — internal helper(s) on `R:` that hold the connection string and wrap parameterized `SqlClient` access (create in this task if not present, following `Record-Time.ps1`'s connection pattern; specify columns, parameterize inputs, never `SELECT *`). Verify actual Apropos schema/table names before finalizing the SQL; adjust `dbo.Task`/`dbo.TimeEntry` and column names to match. Tests use injected `$QueryFn` and never hit the DB.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/tests/Resolve-Task.Tests.ps1"`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-07-10-apropos-time-plugin.md
git commit -m "docs: record Resolve-Task.ps1 skill-layer design (lives on R:)"
```

---

### Task 4: Per-turn hook handler (thin glue)

**Files:**
- Create: `hooks-handlers/time-track-per-turn.sh`
- Create: `tests/mocks/mock-record-turn.ps1`
- Create: `tests/test-hook.sh`

**Interfaces:**
- Consumes: `Record-Turn.ps1` at `$APROPOS_SKILL_DIR/Record-Turn.ps1` (default skill path). Reads session files from `/tmp/claude-timetrack`.
- Produces: hook reads `session_id` from stdin JSON (`"session_id":"..."`) with env fallback `CLAUDE_CODE_SESSION_ID`; if none → exit 0. If `Record-Turn.ps1` not found → exit 0 (off-network fail-safe). Otherwise invokes `pwsh -NoProfile -File <entry> -SessionId <sid> -TrackDir <dir> -Username <user>`. Always exit 0.

- [ ] **Step 1: Write the failing test**

`tests/mocks/mock-record-turn.ps1`:
```powershell
param([string]$SessionId,[string]$TrackDir,[string]$Username)
"$SessionId|$TrackDir|$Username" | Out-File -Append -FilePath $env:HOOK_MOCK_LOG
```

`tests/test-hook.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"

WORK="$(mktemp -d)"
export APROPOS_SKILL_DIR="$WORK/skill"
mkdir -p "$APROPOS_SKILL_DIR"
cp "$DIR/tests/mocks/mock-record-turn.ps1" "$APROPOS_SKILL_DIR/Record-Turn.ps1"
export HOOK_MOCK_LOG="$WORK/hook.log"
export USERNAME="ericbarone"

# 1. Valid session -> entrypoint invoked
OUT=$(echo '{"session_id":"sess-123"}' | bash "$HOOK"; echo "rc=$?")
assert_contains "$OUT" "rc=0" "hook exits 0 on valid session"
LOG="$(cat "$HOOK_MOCK_LOG" 2>/dev/null || true)"
assert_contains "$LOG" "sess-123" "entrypoint called with session id"
assert_contains "$LOG" "ericbarone" "entrypoint called with username"

# 2. No session id -> skip, entrypoint NOT called
rm -f "$HOOK_MOCK_LOG"
unset CLAUDE_CODE_SESSION_ID
OUT=$(echo '{}' | bash "$HOOK"; echo "rc=$?")
assert_contains "$OUT" "rc=0" "hook exits 0 with no session"
[[ ! -f "$HOOK_MOCK_LOG" ]] && pass "entrypoint NOT called without session" || { echo "  FAIL: called without session"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# 3. Off-network (entrypoint missing) -> fail safe, exit 0
rm -f "$APROPOS_SKILL_DIR/Record-Turn.ps1"
OUT=$(echo '{"session_id":"sess-999"}' | bash "$HOOK"; echo "rc=$?")
assert_contains "$OUT" "rc=0" "hook exits 0 when skill unreachable"

rm -rf "$WORK"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hook.sh`
Expected: FAIL — hook script missing.

- [ ] **Step 3: Write minimal implementation**

`hooks-handlers/time-track-per-turn.sh`:
```bash
#!/usr/bin/env bash
# apropos plugin — UserPromptSubmit hook (thin glue).
# Extracts session id, then hands raw turn data to the R: skill entrypoint,
# which owns ALL logic (dedup, backdate, resolution, write). Fails safe.
TRACK_DIR="/tmp/claude-timetrack"
SKILL_DIR="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}"
ENTRY="$SKILL_DIR/Record-Turn.ps1"

INPUT=$(cat 2>/dev/null || true)
SID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//;s/"$//')
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-}}"
[[ -z "$SID" || "$SID" == "unknown" ]] && exit 0

# Off-network / skill not installed -> do nothing, never block.
[[ -f "$ENTRY" ]] || exit 0

mkdir -p "$TRACK_DIR" 2>/dev/null || true
USER_NAME="${USERNAME:-${USER:-unknown}}"

pwsh -NoProfile -ExecutionPolicy Bypass -File "$ENTRY" \
  -SessionId "$SID" -TrackDir "$TRACK_DIR" -Username "$USER_NAME" >/dev/null 2>&1 || true
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-hook.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add hooks-handlers/time-track-per-turn.sh tests/mocks/mock-record-turn.ps1 tests/test-hook.sh
git commit -m "feat: add thin per-turn hook handler that delegates to R: skill"
```

---

### Task 5: SessionStart convention injection

**Files:**
- Create: `hooks-handlers/session-init.sh`
- Create: `hooks-handlers/convention.md`
- Create: `tests/test-session-init.sh`

**Interfaces:**
- Produces: `session-init.sh` locates the plugin root via `CLAUDE_PLUGIN_ROOT` (backslash-normalized) and prints `convention.md` to stdout (Claude Code injects SessionStart stdout as context). Exits 0. `convention.md` contains the worktype ID table, the per-turn file rules, person IDs, and resolution rules.

- [ ] **Step 1: Write the failing test**

`tests/test-session-init.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
export CLAUDE_PLUGIN_ROOT="$DIR"
OUT=$(bash "$DIR/hooks-handlers/session-init.sh"; echo "rc=$?")
assert_contains "$OUT" "rc=0" "session-init exits 0"
assert_contains "$OUT" "Engineering" "convention includes worktype names"
assert_contains "$OUT" "13" "convention includes worktype ID 13"
assert_contains "$OUT" "description-" "convention explains per-turn description file"
assert_contains "$OUT" "worktype-" "convention explains per-turn worktype file"
assert_contains "$OUT" "backdated" "convention explains backdating"
assert_not_contains "$OUT" "ClaudeAI2026" "convention contains no secret"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-session-init.sh`
Expected: FAIL — `session-init.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`hooks-handlers/session-init.sh`:
```bash
#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn time-tracking
# convention into session context (single source of truth). Exits 0 always.
P="${CLAUDE_PLUGIN_ROOT:-}"
P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*/apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi
[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"
exit 0
```

`hooks-handlers/convention.md` (full content — the injected convention):
```markdown
## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. Record on EVERY response; the skill backdates the start 60s and skips duplicate segments (same worktype+task/project within 15 min).

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn (<=500 chars). Rewrite every turn.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Rewrite every turn.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — Intervals/Apropos task display ID (strip `#`). Sticky; write once when known.
- `project-${CLAUDE_CODE_SESSION_ID}.txt` — Apropos project ID. Sticky; use when no task.

If only an organization or project is known, the skill resolves the task automatically (most-recently-active), falling back to project/org level so no time is lost.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default fallback 13 (Engineering). SQL/proc work 92 (Database). Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87.

Do NOT announce writing these files — it is a background convention, not a deliverable.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-session-init.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add hooks-handlers/session-init.sh hooks-handlers/convention.md tests/test-session-init.sh
git commit -m "feat: add SessionStart convention injection"
```

---

### Task 6: hooks.json wiring

**Files:**
- Create: `hooks/hooks.json`
- Create: `tests/test-hooks-json.sh`

**Interfaces:**
- Produces: `hooks.json` registering `UserPromptSubmit` → `time-track-per-turn.sh` and `SessionStart` → `session-init.sh`, both invoked with `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/<name>"`.

- [ ] **Step 1: Write the failing test**

`tests/test-hooks-json.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
H="$DIR/hooks/hooks.json"
[[ -f "$H" ]] && pass "hooks.json exists" || { echo "  FAIL: missing"; _TEST_FAILS=1; }
jq empty "$H" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
UPS=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$H")
SS=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$H")
assert_contains "$UPS" "time-track-per-turn.sh" "UserPromptSubmit wired"
assert_contains "$UPS" "CLAUDE_PLUGIN_ROOT" "UPS uses plugin root"
assert_contains "$SS" "session-init.sh" "SessionStart wired"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hooks-json.sh`
Expected: FAIL — missing.

- [ ] **Step 3: Write minimal implementation**

`hooks/hooks.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/time-track-per-turn.sh\"", "timeout": 15 } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks-handlers/session-init.sh\"", "timeout": 10 } ] }
    ]
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-hooks-json.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add hooks/hooks.json tests/test-hooks-json.sh
git commit -m "feat: wire UserPromptSubmit and SessionStart hooks"
```

---

### Task 7: Manual commands (`/time-*`, break/lunch/out) + reference skill

**Files:**
- Create: `commands/time-ericb.md`, `commands/time-joelp.md`, `commands/time-barrettg.md`, `commands/time-calebb.md`
- Create: `commands/break.md`, `commands/lunch.md`, `commands/out.md`
- Create: `skills/time/SKILL.md` (reference copy, no credentials)
- Create: `tests/test-commands.sh`

**Interfaces:**
- Produces: command markdown files that instruct calling `Record-Time.ps1` on the resolved skill dir with the correct person/EventType. Break=EventTypeID 3, Lunch=7, Out=8.

- [ ] **Step 1: Write the failing test**

`tests/test-commands.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
for f in time-ericb time-joelp time-barrettg time-calebb break lunch out; do
  [[ -f "$DIR/commands/$f.md" ]] && pass "command $f.md exists" || { echo "  FAIL: $f.md missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
done
assert_contains "$(cat "$DIR/commands/lunch.md")" "7" "lunch uses EventTypeID 7"
assert_contains "$(cat "$DIR/commands/break.md")" "3" "break uses EventTypeID 3"
assert_contains "$(cat "$DIR/commands/out.md")" "8" "out uses EventTypeID 8"
[[ -f "$DIR/skills/time/SKILL.md" ]] && pass "reference skill present" || { echo "  FAIL: skill missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_not_contains "$(cat "$DIR/skills/time/SKILL.md")" "ClaudeAI2026" "reference skill has no secret"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-commands.sh`
Expected: FAIL — command files missing.

- [ ] **Step 3: Write minimal implementation**

`commands/time-ericb.md` (repeat per person, changing name + ID: joelp=344, barrettg=276, calebb=1298):
```markdown
---
description: Record an ad-hoc Apropos time entry for Eric Barone (Person 321).
---
Call the skill writer to record time for **Eric Barone (Person ID 321)**.

Run (resolve skill dir; default shown):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID 321 -Description "$ARGUMENTS"`

If the user named a task (`#29100`), add `-TaskID 29100`. If they named a project, add `-ProjectID <id>`. If `$ARGUMENTS` is empty, summarize the current work as the description. Report success or the error.
```

`commands/lunch.md`:
```markdown
---
description: Record a Lunch break (Meal Break, EventTypeID 7) for the logged-in user.
---
Resolve the logged-in user's Apropos Person ID from the Windows username (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298), then run immediately (no confirmation):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "Lunch" -EventTypeID 7`
```

`commands/break.md` — identical to lunch.md but `-Description "Break" -EventTypeID 3` and description text "a Rest Break (EventTypeID 3)".

`commands/out.md` — identical but `-Description "Out" -EventTypeID 8` and "Shift End (EventTypeID 8)".

`skills/time/SKILL.md` — copy the existing `time` SKILL.md verbatim EXCEPT remove any lines exposing the connection string/credentials (there are none in the current SKILL.md — verify). This is a usage reference only.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-commands.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add commands/ skills/ tests/test-commands.sh
git commit -m "feat: add manual /time-* and break/lunch/out commands + reference skill"
```

---

### Task 8: `/setup` command + install script

**Files:**
- Create: `setup/setup.sh`
- Create: `commands/setup.md`
- Create: `tests/test-setup.sh`

**Interfaces:**
- Produces: `setup.sh` that, given `HOME` (respects `$HOME`), ensures `settings.json` contains the plugin's hooks are enabled (Claude Code auto-loads plugin `hooks.json`, so setup's real job is: verify the plugin is installed, back up `settings.json` before any edit, and — if a legacy `time-track.sh`/hand-pasted convention block exists in the user's `CLAUDE.md` — offer to remove it). Idempotent. Prints `SETUP OK`.

- [ ] **Step 1: Write the failing test**

`tests/test-setup.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"; export HOME="$WORK"
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# User
## Time tracking - per-turn Apropos convention
old hand-pasted block
## Keep me
EOF
# First run: removes legacy block, backs up
OUT=$(bash "$DIR/setup/setup.sh" --remove-legacy; echo "rc=$?")
assert_contains "$OUT" "rc=0" "setup exits 0"
assert_contains "$OUT" "SETUP OK" "setup reports OK"
MD="$(cat "$HOME/.claude/CLAUDE.md")"
assert_not_contains "$MD" "old hand-pasted block" "legacy block removed"
assert_contains "$MD" "Keep me" "unrelated content preserved"
ls "$HOME/.claude/"CLAUDE.md.bak-* >/dev/null 2>&1 && pass "CLAUDE.md backed up" || { echo "  FAIL: no backup"; _TEST_FAILS=$((_TEST_FAILS+1)); }
# Second run: idempotent (no legacy block now)
OUT2=$(bash "$DIR/setup/setup.sh" --remove-legacy; echo "rc=$?")
assert_contains "$OUT2" "SETUP OK" "second run idempotent"
rm -rf "$WORK"
finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-setup.sh`
Expected: FAIL — `setup.sh` missing.

- [ ] **Step 3: Write minimal implementation**

`setup/setup.sh`:
```bash
#!/usr/bin/env bash
# apropos plugin /setup. Backs up and removes any legacy hand-pasted per-turn
# time-tracking block from the user's CLAUDE.md (the plugin now injects it via
# SessionStart). Idempotent. Hook loading itself is handled by Claude Code from
# the plugin's hooks.json, so no settings.json edit is required.
set -euo pipefail
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
REMOVE_LEGACY=0
[[ "${1:-}" == "--remove-legacy" ]] && REMOVE_LEGACY=1

MARKER="## Time tracking - per-turn Apropos convention"
if [[ $REMOVE_LEGACY -eq 1 && -f "$CLAUDE_MD" ]] && grep -qF "$MARKER" "$CLAUDE_MD"; then
  cp "$CLAUDE_MD" "${CLAUDE_MD}.bak-$(date +%Y%m%d-%H%M%S)"
  # Delete from the marker line up to (but not including) the next top-level "## " heading.
  awk -v m="$MARKER" '
    $0==m {skip=1; next}
    skip==1 && /^## / {skip=0}
    skip==1 {next}
    {print}
  ' "$CLAUDE_MD" > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
  echo "Removed legacy per-turn block from CLAUDE.md (backup saved)."
fi
echo "SETUP OK"
```

`commands/setup.md`:
```markdown
---
description: Set up the apropos time-tracking plugin for this user.
---
Run the setup script to clean up any legacy hand-pasted time-tracking block (the plugin now injects the convention automatically each session):
`bash "${CLAUDE_PLUGIN_ROOT}/setup/setup.sh" --remove-legacy`
Then tell the user to restart Claude Code so the SessionStart injection and hooks load. Confirm the `apropos` plugin shows in `/plugin`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-setup.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add setup/setup.sh commands/setup.md tests/test-setup.sh
git commit -m "feat: add /setup command that removes legacy CLAUDE.md blocks idempotently"
```

---

### Task 9: README, run-all test script, and full-suite green

**Files:**
- Create: `README.md`
- Create: `tests/run-all.sh`

**Interfaces:**
- Produces: `run-all.sh` running every `tests/test-*.sh` and reporting aggregate pass/fail; README documenting install (`/plugin marketplace add AproposoporpA/apropos-plugin`, `/plugin install apropos`, `/setup`), the security model, and the `R:` skill-layer dependency.

- [ ] **Step 1: Write the failing test**

`tests/run-all.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
for t in "$DIR"/tests/test-*.sh; do
  echo "== $(basename "$t") =="
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "SUITE GREEN" || echo "SUITE RED"
exit $rc
```

- [ ] **Step 2: Run test to verify current state**

Run: `bash tests/run-all.sh`
Expected: `SUITE GREEN` (all prior task tests pass; README existence not yet asserted).

- [ ] **Step 3: Write minimal implementation**

`README.md`:
```markdown
# apropos — Apropos time-recording plugin

Records per-turn Apropos time entries for RICO team members.

## Install
1. `/plugin marketplace add AproposoporpA/apropos-plugin`
2. `/plugin install apropos`
3. `/setup`  (removes any legacy hand-pasted CLAUDE.md block)
4. Restart Claude Code.

## How it works
- A `UserPromptSubmit` hook records one start-marker per turn (backdated 60s), skipping duplicate segments (<15 min).
- A `SessionStart` hook injects the per-turn convention (worktype IDs, file rules).
- Manual commands: `/time-ericb`, `/time-joelp`, `/time-barrettg`, `/time-calebb`, `/break`, `/lunch`, `/out`.

## Security
This public plugin contains **no credentials and no direct database access.** All DB logic and the Apropos connection string live in the internal `R:` skill layer (`R:/Intranet/ClaudeAI/skills/work-management/time`), reachable only on the RICO network. Off-network, the plugin does nothing (fails safe). Downloading this repo does not grant the ability to write to Apropos.
```

- [ ] **Step 4: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: `SUITE GREEN`.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/run-all.sh
git commit -m "docs: add README and full test-suite runner"
git push
```

---

## Self-Review

**1. Spec coverage:**
- Purpose / team rollout → Task 9 (README install), Task 8 (`/setup`). ✔
- Security model (no secrets, R: gate, off-network fail-safe) → Task 1 (secret scan), Task 4 (fail-safe test), Task 9 (README). ✔
- Thin-shell / logic-in-skill → Tasks 2–3 (R: logic) vs Task 4 (thin hook). ✔
- Recording behavior (every turn, 60s backdate, dedup) → Task 2. ✔
- Resolution rules (person / task / org / project fallback) → Task 2 (person), Task 3 (task/org/project). ✔
- SessionStart convention delivery → Task 5. ✔
- Commands + break/lunch/out → Task 7. ✔
- Distribution / marketplace → Task 9. ✔
- Testing (dedup, backdate, off-network, setup idempotency, injection) → Tasks 2,4,8,5. ✔

**2. Placeholder scan:** No "TBD/TODO" in steps. Task 3 flags a schema-verification step for the real SQL (dbo.Task/dbo.TimeEntry names) — this is a genuine verify-against-live-DB action, not a code placeholder; injected `$QueryFn` keeps tests deterministic.

**3. Type consistency:** `Record-Turn.ps1` params (`-SessionId/-TrackDir/-Username/-WriterScript/-Resolver`) match Task 4's hook invocation (first three) and the mock. `Resolve-Task.ps1` (`-Task/-Project/-Org/-QueryFn`) matches Task 2's `& $Resolver -Project $proj`. EventTypeIDs (3/7/8) consistent between Task 7 and spec. Person IDs consistent throughout.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-10-apropos-time-plugin.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session with checkpoints for review.

Which approach?
