# Apropos Time-Recording Plugin — Implementation Plan (Phase 1: Reliability)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the public `apropos` plugin so every turn reliably records (or durably queues) exactly one Apropos start-marker — never dropping time due to missing model files or a flaky `R:`/network — and roll the team onto it.

**Architecture:** The credentialed write (`Record-Time.ps1` on `R:`) is **unchanged**. The plugin adds a **local** reliability layer in a bash `UserPromptSubmit` hook: always-fire with fallbacks, dedup, and a durable local pending-queue with flush/retry. The queue is local because it must survive `R:`/network outages. A `SessionStart` hook injects the per-turn convention. Manual commands and `/setup` round it out.

**Tech Stack:** Bash (hook + queue lib + tests), PowerShell 7 (`Record-Time.ps1`, unchanged; invoked by the hook), JSON (`plugin.json`, `hooks.json`), Markdown (commands, convention, docs). Tests are plain bash assertion scripts — no framework. `jq` is a dev/test dependency and the runtime's preferred JSON parser (with a grep fallback).

## Global Constraints

- Plugin name exactly `apropos`. Public repo `AproposoporpA/apropos-plugin`. Workspace `A:\Product Development\Program\Claude Plugin`.
- **No credentials / connection strings / direct DB access in the repo — ever.** The credential lives only in `R:` `Record-Time.ps1`.
- `Record-Time.ps1` is **not modified** in Phase 1.
- Skill dir (default) `R:/Intranet/ClaudeAI/skills/work-management/time`; override for tests via env `APROPOS_SKILL_DIR`. Writer override for tests via env `APROPOS_WRITER`.
- Local queue dir: `~/.claude/apropos-time/`; queue file `pending.tsv`.
- Per-turn temp files: `/tmp/claude-timetrack/` (`description-$SID.txt`, `worktype-$SID.txt`, `task-$SID.txt`, `project-$SID.txt`, `last-entry-$SID.txt`).
- Recording: **always fire (or queue) one entry per turn.** Description = model file if non-empty else the user's prompt text (≤500 chars) else a session placeholder. Worktype = model file if numeric else `13`. `StartTime` backdated 60s. Dedup skips only when segment key `worktype|task|project` equals the last entry's **and** < 900s elapsed — dedup never causes a *lost* entry, only prevents a near-duplicate.
- Person IDs: `ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298`. Unknown username → cannot attribute → no record (this is not a transient failure).
- Every hook exits 0 always.
- One commit per task. DRY, YAGNI, TDD.

---

### Task 1: Plugin manifest + test harness

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `tests/helpers.sh`
- Create: `tests/test-manifest.sh`

**Interfaces:**
- Produces: manifest with `name: "apropos"`; `tests/helpers.sh` exposing `assert_eq`, `assert_contains`, `assert_not_contains`, `pass`, and `finish` (sets exit code from `$_TEST_FAILS`).

- [ ] **Step 1: Write the failing test**

`tests/helpers.sh`:
```bash
#!/usr/bin/env bash
_TEST_FAILS=0
assert_eq()          { if [[ "$1" == "$2" ]]; then echo "  ok: $3"; else echo "  FAIL: $3 (expected '$1' got '$2')"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_contains()    { if [[ "$1" == *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' not found)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
assert_not_contains(){ if [[ "$1" != *"$2"* ]]; then echo "  ok: $3"; else echo "  FAIL: $3 ('$2' unexpectedly present)"; _TEST_FAILS=$((_TEST_FAILS+1)); fi; }
pass()               { echo "  ok: $1"; }
finish()             { if (( _TEST_FAILS > 0 )); then echo "TESTS FAILED ($_TEST_FAILS)"; exit 1; else echo "ALL TESTS PASSED"; exit 0; fi; }
```

`tests/test-manifest.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
M="$DIR/.claude-plugin/plugin.json"
[[ -f "$M" ]] && pass "plugin.json exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$M" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid JSON"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_eq "apropos" "$(jq -r '.name' "$M" 2>/dev/null)" "name is apropos"
if grep -rniE 'ClaudeAI2026|claudeaproposreadonly|password=|connectionstring' "$DIR" --include='*.json' --include='*.sh' --include='*.md' -l 2>/dev/null | grep -v '/docs/'; then
  echo "  FAIL: possible secret in repo"; _TEST_FAILS=$((_TEST_FAILS+1));
else pass "no secrets outside docs"; fi
finish
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/test-manifest.sh` → FAIL (missing).
- [ ] **Step 3: Implement** — `.claude-plugin/plugin.json`:
```json
{
  "name": "apropos",
  "description": "Reliable per-turn Apropos time recording with a local durable queue. Calls the internal RICO write skill; contains no credentials.",
  "version": "0.1.0",
  "author": { "name": "AproposoporpA" }
}
```
- [ ] **Step 4: Run to verify it passes** — `bash tests/test-manifest.sh` → ALL TESTS PASSED.
- [ ] **Step 5: Commit**
```bash
git add .claude-plugin/plugin.json tests/helpers.sh tests/test-manifest.sh
git commit -m "feat: add apropos manifest and bash test harness"
```

---

### Task 2: Durable queue library (`lib/queue.sh`)

**Files:**
- Create: `hooks-handlers/lib/queue.sh`
- Create: `tests/test-queue.sh`

**Interfaces:**
- Produces:
  - `q_enqueue <queuefile> <person> <desc> <worktype> <task> <project> <startUtc>` — appends one TSV line; description base64-encoded (safe for tabs/newlines).
  - `q_flush <queuefile> <write_cb>` — for each line oldest-first, decode desc and call `write_cb person desc worktype task project startUtc`; on success drop the line; on first failure, stop and retain that line and all remaining (preserving order); rewrite the file; delete it if empty. Returns 0 always.
- `write_cb` contract: a shell command/function taking `person desc worktype task project startUtc`, returning 0 on delivery success, non-zero on failure.

- [ ] **Step 1: Write the failing test**

`tests/test-queue.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
source "$DIR/hooks-handlers/lib/queue.sh"
WORK="$(mktemp -d)"; QF="$WORK/pending.tsv"; LOG="$WORK/log"

# base64 roundtrip incl. special chars
q_enqueue "$QF" 321 $'Fix tab\there and "quotes"' 13 0 0 "2026-07-10 12:00:00"
q_enqueue "$QF" 344 "Second entry" 23 29100 0 "2026-07-10 12:01:00"

ok_cb(){ printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$LOG"; return 0; }
q_flush "$QF" ok_cb
[[ ! -f "$QF" ]] && pass "queue drained/removed on success" || { echo "  FAIL: queue remains"; _TEST_FAILS=$((_TEST_FAILS+1)); }
L="$(cat "$LOG")"
assert_contains "$L" '321|Fix tab	here and "quotes"|13|0|0|2026-07-10 12:00:00' "entry 1 decoded correctly (order preserved)"
assert_contains "$L" '344|Second entry|23|29100|0|' "entry 2 delivered"

# all-fail retains everything
rm -f "$LOG"
q_enqueue "$QF" 321 "A" 13 0 0 "t1"
q_enqueue "$QF" 321 "B" 13 0 0 "t2"
fail_cb(){ return 1; }
q_flush "$QF" fail_cb
assert_eq "2" "$(wc -l < "$QF" | tr -d ' ')" "all entries retained on total failure"

# partial: first succeeds, rest fail and are retained in order
rm -f "$QF" "$LOG"
q_enqueue "$QF" 321 "first" 13 0 0 "t1"
q_enqueue "$QF" 321 "second" 13 0 0 "t2"
q_enqueue "$QF" 321 "third" 13 0 0 "t3"
CNT="$WORK/cnt"; echo 0 > "$CNT"
partial_cb(){ n=$(cat "$CNT"); n=$((n+1)); echo $n > "$CNT"; if [[ $n -eq 1 ]]; then printf '%s\n' "$2" >> "$LOG"; return 0; else return 1; fi; }
q_flush "$QF" partial_cb
assert_eq "2" "$(wc -l < "$QF" | tr -d ' ')" "2 undelivered retained after partial"
assert_contains "$(cat "$LOG")" "first" "first delivered"
FIRSTLINE="$(head -1 "$QF")"
assert_contains "$FIRSTLINE" "$(printf 'second' | base64 | tr -d '\n')" "retained queue keeps order (second first)"

rm -rf "$WORK"
finish
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/test-queue.sh` → FAIL (queue.sh missing).
- [ ] **Step 3: Implement** — `hooks-handlers/lib/queue.sh`:
```bash
#!/usr/bin/env bash
# Durable local time-entry queue. TSV lines:
#   person <TAB> descB64 <TAB> worktype <TAB> task <TAB> project <TAB> startUtc
# Description is base64-encoded so it may contain tabs/newlines/quotes safely.

q_enqueue() {
  local qf="$1" person="$2" desc="$3" wt="$4" task="$5" proj="$6" start="$7"
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  local b64; b64=$(printf '%s' "$desc" | base64 | tr -d '\n')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$qf"
}

q_flush() {
  local qf="$1" cb="$2"
  [[ -f "$qf" ]] || return 0
  local tmp; tmp="$(mktemp)"
  local stopped=0
  while IFS=$'\t' read -r person b64 wt task proj start; do
    [[ -z "$person" ]] && continue
    if [[ $stopped -eq 1 ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$tmp"
      continue
    fi
    local desc; desc="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    if "$cb" "$person" "$desc" "$wt" "$task" "$proj" "$start"; then
      :   # delivered — drop
    else
      stopped=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$person" "$b64" "$wt" "$task" "$proj" "$start" >> "$tmp"
    fi
  done < "$qf"
  mv "$tmp" "$qf"
  [[ -s "$qf" ]] || rm -f "$qf"
  return 0
}
```
- [ ] **Step 4: Run to verify it passes** — `bash tests/test-queue.sh` → ALL TESTS PASSED.
- [ ] **Step 5: Commit**
```bash
git add hooks-handlers/lib/queue.sh tests/test-queue.sh
git commit -m "feat: add durable local time-entry queue with retry-preserving flush"
```

---

### Task 3: Reliability hook (`time-track-per-turn.sh`)

**Files:**
- Create: `hooks-handlers/time-track-per-turn.sh`
- Create: `tests/mocks/mock-writer.sh`
- Create: `tests/test-hook.sh`

**Interfaces:**
- Consumes: `lib/queue.sh`; `Record-Time.ps1` at `$APROPOS_SKILL_DIR/Record-Time.ps1` (or `$APROPOS_WRITER` override).
- Produces: hook reads stdin (session_id + prompt), resolves person from `$USERNAME`, computes description/worktype/task/project with fallbacks, applies dedup, enqueues the entry (backdated 60s) unless deduped, then flushes the queue. Exits 0.
- `write_entry person desc wt task proj start`: if `$APROPOS_WRITER` set, exec it with those args; else invoke `pwsh -File $APROPOS_SKILL_DIR/Record-Time.ps1` with `-PersonID -Description -WorkTypeID -StartTimeUTC` plus `-TaskID` (if task>0) or `-ProjectID` (if project>0). Returns the writer's exit code; returns 1 if the writer/script is absent.

- [ ] **Step 1: Write the failing test**

`tests/mocks/mock-writer.sh`:
```bash
#!/usr/bin/env bash
# Logs args; fails (exit 1) while $WRITER_FAIL file exists.
printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$WRITER_LOG"
[[ -f "$WRITER_FAIL" ]] && exit 1
exit 0
```

`tests/test-hook.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
HOOK="$DIR/hooks-handlers/time-track-per-turn.sh"
WORK="$(mktemp -d)"
export HOME="$WORK"                 # queue lands in $HOME/.claude/apropos-time
export TMPDIR="$WORK"
export APROPOS_WRITER="$DIR/tests/mocks/mock-writer.sh"
export WRITER_LOG="$WORK/writer.log"
export WRITER_FAIL="$WORK/FAIL"
export USERNAME="ericbarone"
chmod +x "$DIR/tests/mocks/mock-writer.sh"
run(){ echo "$1" | bash "$HOOK"; }

# 1. No model files -> fallback to prompt text + worktype 13, delivered
run '{"session_id":"s1","prompt":"Investigating the widget bug"}'
L="$(cat "$WRITER_LOG" 2>/dev/null)"
assert_contains "$L" "321|Investigating the widget bug|13|" "fallback prompt+wt13 recorded"

# 2. Model files override the fallback
rm -f "$WRITER_LOG"
mkdir -p /tmp/claude-timetrack 2>/dev/null || true
TT="${TMPDIR}/claude-timetrack"; mkdir -p "$TT"
# The hook uses /tmp/claude-timetrack; redirect via env for tests:
export APROPOS_TRACK_DIR="$TT"
printf 'Refactored auth module' > "$TT/description-s2.txt"
printf '50' > "$TT/worktype-s2.txt"
run '{"session_id":"s2","prompt":"ignored because model wrote files"}'
assert_contains "$(cat "$WRITER_LOG")" "321|Refactored auth module|50|" "model files used over prompt"

# 3. Dedup: same segment within 15 min -> second not recorded
rm -f "$WRITER_LOG"
printf 'seg work' > "$TT/description-s3.txt"; printf '13' > "$TT/worktype-s3.txt"
run '{"session_id":"s3","prompt":"a"}'
printf 'seg work again' > "$TT/description-s3.txt"; printf '13' > "$TT/worktype-s3.txt"
run '{"session_id":"s3","prompt":"b"}'
assert_eq "1" "$(grep -c '321|' "$WRITER_LOG")" "duplicate segment recorded once"

# 4. Write failure -> queued; next turn (writer restored, new worktype) -> both delivered
rm -f "$WRITER_LOG"; touch "$WRITER_FAIL"
printf 'will fail then queue' > "$TT/description-s4.txt"; printf '92' > "$TT/worktype-s4.txt"
run '{"session_id":"s4","prompt":"x"}'
[[ -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "failed write queued locally" || { echo "  FAIL: not queued"; _TEST_FAILS=$((_TEST_FAILS+1)); }
rm -f "$WRITER_FAIL"; rm -f "$WRITER_LOG"
printf 'next turn' > "$TT/description-s4.txt"; printf '23' > "$TT/worktype-s4.txt"
run '{"session_id":"s4","prompt":"y"}'
assert_contains "$(cat "$WRITER_LOG")" "will fail then queue" "queued entry flushed on recovery"
[[ ! -f "$HOME/.claude/apropos-time/pending.tsv" ]] && pass "queue drained after recovery" || { echo "  FAIL: queue not drained"; _TEST_FAILS=$((_TEST_FAILS+1)); }

# 5. Unknown user -> nothing recorded, exit 0
rm -f "$WRITER_LOG"; export USERNAME="stranger"
run '{"session_id":"s5","prompt":"hello"}'; RC=$?
assert_eq "0" "$RC" "hook exits 0 for unknown user"
[[ ! -f "$WRITER_LOG" ]] && pass "unknown user records nothing" || { echo "  FAIL: recorded for unknown"; _TEST_FAILS=$((_TEST_FAILS+1)); }

rm -rf "$WORK"
finish
```

> Test note: the hook must honor `APROPOS_TRACK_DIR` (default `/tmp/claude-timetrack`) so tests can isolate temp files. Add that override to the implementation.

- [ ] **Step 2: Run to verify it fails** — `bash tests/test-hook.sh` → FAIL (hook missing).
- [ ] **Step 3: Implement** — `hooks-handlers/time-track-per-turn.sh`:
```bash
#!/usr/bin/env bash
# apropos plugin — UserPromptSubmit reliability hook.
# Always records (or durably queues) exactly one start-marker per turn.
# Credentialed write stays in R: Record-Time.ps1; this layer is local so it
# survives R:/network outages. Exits 0 always.
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/queue.sh"

TRACK_DIR="${APROPOS_TRACK_DIR:-/tmp/claude-timetrack}"
SKILL_DIR="${APROPOS_SKILL_DIR:-R:/Intranet/ClaudeAI/skills/work-management/time}"
QUEUE="${HOME}/.claude/apropos-time/pending.tsv"
mkdir -p "$TRACK_DIR" "${HOME}/.claude/apropos-time" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"

# Parse session id + prompt (prefer jq; grep fallback for session id).
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)"
else
  SID="$(printf '%s' "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/.*:"//;s/"$//')"
  PROMPT=""
fi
SID="${SID:-${CLAUDE_CODE_SESSION_ID:-nosession}}"

# Person resolution (cannot record without it — not a transient failure).
u="$(printf '%s' "${USERNAME:-${USER:-}}" | tr '[:upper:]' '[:lower:]')"
case "$u" in
  ericbarone) PERSON=321 ;; joelperez) PERSON=344 ;;
  barrettgoldberg) PERSON=276 ;; calebbarone) PERSON=1298 ;;
  *) exit 0 ;;
esac

# write_entry callback used by q_flush.
write_entry() {
  if [[ -n "${APROPOS_WRITER:-}" ]]; then "$APROPOS_WRITER" "$@"; return $?; fi
  local person="$1" desc="$2" wt="$3" task="$4" proj="$5" start="$6"
  local entry="$SKILL_DIR/Record-Time.ps1"
  [[ -f "$entry" ]] || return 1
  local args=(-PersonID "$person" -Description "$desc" -WorkTypeID "$wt" -StartTimeUTC "$start")
  if [[ -n "$task" && "$task" != "0" ]]; then args+=(-TaskID "$task")
  elif [[ -n "$proj" && "$proj" != "0" ]]; then args+=(-ProjectID "$proj"); fi
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" "${args[@]}" >/dev/null 2>&1
}

descf="$TRACK_DIR/description-$SID.txt"
wtf="$TRACK_DIR/worktype-$SID.txt"
taskf="$TRACK_DIR/task-$SID.txt"
projf="$TRACK_DIR/project-$SID.txt"
lastf="$TRACK_DIR/last-entry-$SID.txt"

# Description: model file -> prompt -> placeholder. Trim to 500.
DESC=""
[[ -s "$descf" ]] && DESC="$(cat "$descf")"
[[ -z "${DESC//[[:space:]]/}" && -n "$PROMPT" ]] && DESC="$PROMPT"
[[ -z "${DESC//[[:space:]]/}" ]] && DESC="Auto-captured work (session $SID)"
DESC="${DESC:0:500}"

# Worktype: numeric model file -> default 13.
WT="13"; [[ -s "$wtf" ]] && { v="$(tr -d '[:space:]' < "$wtf")"; [[ "$v" =~ ^[0-9]+$ ]] && WT="$v"; }

# Optional sticky task/project.
TASK="0"; [[ -s "$taskf" ]] && TASK="$(tr -d '[:space:]#' < "$taskf")"; [[ "$TASK" =~ ^[0-9]+$ ]] || TASK="0"
PROJ="0"; [[ -s "$projf" ]] && PROJ="$(tr -d '[:space:]' < "$projf")"; [[ "$PROJ" =~ ^[0-9]+$ ]] || PROJ="0"

SEG="$WT|$TASK|$PROJ"
NOW="$(date -u +%s)"
DEDUP=0
if [[ -f "$lastf" ]]; then
  line="$(head -1 "$lastf")"; lt="${line%%|*}"; lk="${line#*|}"
  if [[ "$lt" =~ ^[0-9]+$ && "$lk" == "$SEG" && $((NOW - lt)) -lt 900 ]]; then DEDUP=1; fi
fi

# Consume one-shot model files regardless (rewritten next turn).
rm -f "$descf" "$wtf" 2>/dev/null || true

if [[ $DEDUP -eq 0 ]]; then
  START="$(date -u -d '1 minute ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -v-1M '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  q_enqueue "$QUEUE" "$PERSON" "$DESC" "$WT" "$TASK" "$PROJ" "$START"
  printf '%s|%s\n' "$NOW" "$SEG" > "$lastf"
fi

# Always attempt to flush (delivers this entry and any prior queued ones).
q_flush "$QUEUE" write_entry
exit 0
```
- [ ] **Step 4: Run to verify it passes** — `bash tests/test-hook.sh` → ALL TESTS PASSED.
- [ ] **Step 5: Commit**
```bash
git add hooks-handlers/time-track-per-turn.sh tests/mocks/mock-writer.sh tests/test-hook.sh
git commit -m "feat: reliability hook — always-fire fallbacks, dedup, durable queue+flush"
```

---

### Task 4: SessionStart convention injection

**Files:**
- Create: `hooks-handlers/session-init.sh`
- Create: `hooks-handlers/convention.md`
- Create: `tests/test-session-init.sh`

**Interfaces:**
- Produces: `session-init.sh` resolves plugin root via `CLAUDE_PLUGIN_ROOT` (backslash-normalized; filesystem fallback) and prints `convention.md` to stdout; exits 0.

- [ ] **Step 1: Write the failing test** — `tests/test-session-init.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
export CLAUDE_PLUGIN_ROOT="$DIR"
OUT="$(bash "$DIR/hooks-handlers/session-init.sh"; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "Engineering" "has worktype names"
assert_contains "$OUT" "description-" "explains description file"
assert_contains "$OUT" "worktype-" "explains worktype file"
assert_contains "$OUT" "backdate" "explains backdating"
assert_not_contains "$OUT" "ClaudeAI2026" "no secret"
finish
```
- [ ] **Step 2: Run to verify it fails** — FAIL (missing).
- [ ] **Step 3: Implement** — `hooks-handlers/session-init.sh`:
```bash
#!/usr/bin/env bash
# apropos plugin — SessionStart hook. Injects the per-turn convention. Exit 0.
P="${CLAUDE_PLUGIN_ROOT:-}"; P="${P//\\//}"
if [[ -z "$P" || ! -f "$P/hooks-handlers/convention.md" ]]; then
  P="$(find "${HOME}/.claude/plugins" -path "*apropos*/hooks-handlers/convention.md" 2>/dev/null | head -1 | sed 's|/hooks-handlers/convention.md$||')"
fi
[[ -n "$P" && -f "$P/hooks-handlers/convention.md" ]] && cat "$P/hooks-handlers/convention.md"
exit 0
```
`hooks-handlers/convention.md`:
```markdown
## Apropos per-turn time tracking (auto-injected by the apropos plugin)

Time entries are START MARKERS only — the start of a new activity ends the prior one; Apropos derives duration from the gap. One entry is recorded (or durably queued) EVERY turn; the plugin backdates the start 60s and skips only exact-duplicate segments (same worktype+task/project within 15 min). If you write nothing, it still records using your prompt text + worktype 13 — so ACCURACY is your job, but time is never lost.

Before ending each response, write these session-keyed files in `/tmp/claude-timetrack/`:
- `description-${CLAUDE_CODE_SESSION_ID}.txt` — one specific sentence about this turn (<=500 chars). Rewrite every turn.
- `worktype-${CLAUDE_CODE_SESSION_ID}.txt` — one numeric worktype ID (below). Rewrite every turn.
- `task-${CLAUDE_CODE_SESSION_ID}.txt` — task display ID (strip `#`). Sticky; write once when known.
- `project-${CLAUDE_CODE_SESSION_ID}.txt` — Apropos project ID. Sticky; use when no task.

Worktype IDs: 7 Program Management | 13 Engineering | 18 Project Management | 19 Quality Assurance | 23 Documentation | 30 Support | 31 Estimate | 32 Training: General | 48 Admin: Business Development | 50 Architecture | 56 Admin: HR | 57 Admin: Finance | 58 Admin: Marketing | 59 Admin: Operations | 66 Office Festivities | 80 Product Management | 84 Sys Admin | 86 Testing: ALPHA | 87 Configuration | 91 Copywriting | 92 Database | 93 Design | 97 Front End Development | 102 Research & Development | 108 Technical Management | 109 Testing: BETA | 110 Testing: Browser | 117 Travel.

Default 13 (Engineering). SQL/proc 92. Docs 23. Support 30. Architecture/design 50. Build/deploy/hooks/settings 84 or 87.

Do NOT announce writing these files — background convention, not a deliverable.
```
- [ ] **Step 4: Run to verify it passes** — ALL TESTS PASSED.
- [ ] **Step 5: Commit**
```bash
git add hooks-handlers/session-init.sh hooks-handlers/convention.md tests/test-session-init.sh
git commit -m "feat: add SessionStart convention injection"
```

---

### Task 5: `hooks.json` wiring

**Files:** Create `hooks/hooks.json`, `tests/test-hooks-json.sh`.

**Interfaces:** registers `UserPromptSubmit`→`time-track-per-turn.sh` (timeout 15) and `SessionStart`→`session-init.sh` (timeout 10), invoked via `bash "${CLAUDE_PLUGIN_ROOT}/hooks-handlers/<name>"`.

- [ ] **Step 1: Failing test** — `tests/test-hooks-json.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"; H="$DIR/hooks/hooks.json"
[[ -f "$H" ]] && pass "exists" || { echo "  FAIL: missing"; _TEST_FAILS=$((_TEST_FAILS+1)); }
jq empty "$H" 2>/dev/null && pass "valid JSON" || { echo "  FAIL: invalid"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_contains "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$H")" "time-track-per-turn.sh" "UPS wired"
assert_contains "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$H")" "session-init.sh" "SessionStart wired"
finish
```
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — `hooks/hooks.json`:
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
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit**
```bash
git add hooks/hooks.json tests/test-hooks-json.sh
git commit -m "feat: wire UserPromptSubmit and SessionStart hooks"
```

---

### Task 6: Manual commands + reference skill

**Files:** Create `commands/time-ericb.md`, `commands/time-joelp.md`, `commands/time-barrettg.md`, `commands/time-calebb.md`, `commands/break.md`, `commands/lunch.md`, `commands/out.md`, `skills/time/SKILL.md`, `tests/test-commands.sh`.

**Interfaces:** command files instruct calling `Record-Time.ps1` with the correct person / EventTypeID (Break 3, Lunch 7, Out 8).

- [ ] **Step 1: Failing test** — `tests/test-commands.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
for f in time-ericb time-joelp time-barrettg time-calebb break lunch out; do
  [[ -f "$DIR/commands/$f.md" ]] && pass "$f.md exists" || { echo "  FAIL: $f.md"; _TEST_FAILS=$((_TEST_FAILS+1)); }
done
assert_contains "$(cat "$DIR/commands/lunch.md")" "7" "lunch EventTypeID 7"
assert_contains "$(cat "$DIR/commands/break.md")" "3" "break EventTypeID 3"
assert_contains "$(cat "$DIR/commands/out.md")" "8" "out EventTypeID 8"
assert_contains "$(cat "$DIR/commands/time-joelp.md")" "344" "joel person 344"
[[ -f "$DIR/skills/time/SKILL.md" ]] && pass "reference skill" || { echo "  FAIL: skill"; _TEST_FAILS=$((_TEST_FAILS+1)); }
assert_not_contains "$(cat "$DIR/skills/time/SKILL.md")" "ClaudeAI2026" "skill has no secret"
finish
```
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.** `commands/time-ericb.md` (repeat for joelp=344, barrettg=276, calebb=1298 — change name + ID in both the description and the `-PersonID`):
```markdown
---
description: Record an ad-hoc Apropos time entry for Eric Barone (Person 321).
---
Record time for **Eric Barone (Person ID 321)** by running:
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID 321 -Description "$ARGUMENTS"`
If a task was named (`#29100`) add `-TaskID 29100`; if a project was named add `-ProjectID <id>`. If `$ARGUMENTS` is empty, summarize the current work as the description. Report success or the error.
```
`commands/lunch.md`:
```markdown
---
description: Record a Lunch (Meal Break, EventTypeID 7) for the logged-in user.
---
Resolve the logged-in user's Person ID from the Windows username (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298), then run immediately (no confirmation):
`pwsh -NoProfile -File "R:/Intranet/ClaudeAI/skills/work-management/time/Record-Time.ps1" -PersonID <id> -Description "Lunch" -EventTypeID 7`
```
`commands/break.md` — same as lunch.md with `-Description "Break" -EventTypeID 3` and text "Rest Break (EventTypeID 3)".
`commands/out.md` — same with `-Description "Out" -EventTypeID 8` and text "Shift End (EventTypeID 8)".
`skills/time/SKILL.md` — copy the current `time` SKILL.md verbatim (it contains no credentials; verify). Usage reference only.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit**
```bash
git add commands/ skills/ tests/test-commands.sh
git commit -m "feat: add manual /time-* and break/lunch/out commands + reference skill"
```

---

### Task 7: `/setup` command + install script

**Files:** Create `setup/setup.sh`, `commands/setup.md`, `tests/test-setup.sh`.

**Interfaces:** `setup.sh` (respects `$HOME`): if `--remove-legacy` and the user's `CLAUDE.md` contains the legacy per-turn block marker, back it up (`CLAUDE.md.bak-<ts>`) and remove the block (marker line through the line before the next `## ` heading). Idempotent. Prints `SETUP OK`. Also warns if `jq` is missing (runtime prefers it).

- [ ] **Step 1: Failing test** — `tests/test-setup.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DIR/tests/helpers.sh"
WORK="$(mktemp -d)"; export HOME="$WORK"; mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/CLAUDE.md" <<'EOF'
# User
## Time tracking - per-turn Apropos convention
old hand-pasted block
## Keep me
EOF
OUT="$(bash "$DIR/setup/setup.sh" --remove-legacy; echo rc=$?)"
assert_contains "$OUT" "rc=0" "exits 0"
assert_contains "$OUT" "SETUP OK" "reports OK"
MD="$(cat "$HOME/.claude/CLAUDE.md")"
assert_not_contains "$MD" "old hand-pasted block" "legacy block removed"
assert_contains "$MD" "Keep me" "unrelated content kept"
ls "$HOME/.claude/"CLAUDE.md.bak-* >/dev/null 2>&1 && pass "backup made" || { echo "  FAIL: no backup"; _TEST_FAILS=$((_TEST_FAILS+1)); }
OUT2="$(bash "$DIR/setup/setup.sh" --remove-legacy)"
assert_contains "$OUT2" "SETUP OK" "idempotent second run"
rm -rf "$WORK"; finish
```
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** — `setup/setup.sh`:
```bash
#!/usr/bin/env bash
# apropos /setup: remove any legacy hand-pasted per-turn block from CLAUDE.md
# (the plugin now injects the convention via SessionStart). Idempotent.
set -euo pipefail
MD="${HOME}/.claude/CLAUDE.md"
MARKER="## Time tracking - per-turn Apropos convention"
if [[ "${1:-}" == "--remove-legacy" && -f "$MD" ]] && grep -qF "$MARKER" "$MD"; then
  cp "$MD" "${MD}.bak-$(date +%Y%m%d-%H%M%S)"
  awk -v m="$MARKER" '$0==m{skip=1;next} skip==1&&/^## /{skip=0} skip==1{next} {print}' "$MD" > "${MD}.tmp" && mv "${MD}.tmp" "$MD"
  echo "Removed legacy per-turn block from CLAUDE.md (backup saved)."
fi
command -v jq >/dev/null 2>&1 || echo "WARN: jq not found — install it for best prompt-fallback fidelity."
echo "SETUP OK"
```
`commands/setup.md`:
```markdown
---
description: Set up the apropos time-tracking plugin for this user.
---
Run: `bash "${CLAUDE_PLUGIN_ROOT}/setup/setup.sh" --remove-legacy`
Then tell the user to restart Claude Code so the hooks + SessionStart injection load, and confirm `apropos` appears in `/plugin`.
```
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit**
```bash
git add setup/setup.sh commands/setup.md tests/test-setup.sh
git commit -m "feat: add idempotent /setup that removes legacy CLAUDE.md block"
```

---

### Task 8: README + full-suite runner

**Files:** Create `README.md`, `tests/run-all.sh`.

- [ ] **Step 1: Add runner** — `tests/run-all.sh`:
```bash
#!/usr/bin/env bash
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; rc=0
for t in "$DIR"/tests/test-*.sh; do echo "== $(basename "$t") =="; bash "$t" || rc=1; done
[[ $rc -eq 0 ]] && echo "SUITE GREEN" || echo "SUITE RED"; exit $rc
```
- [ ] **Step 2: Run** — `bash tests/run-all.sh` → `SUITE GREEN` (all Task 1–7 tests pass).
- [ ] **Step 3: Implement README** — `README.md`:
```markdown
# apropos — reliable Apropos time recording

Records one Apropos start-marker every turn, with fallbacks and a durable local queue so time is never lost to a missing description or a flaky network.

## Install
1. `/plugin marketplace add AproposoporpA/apropos-plugin`
2. `/plugin install apropos`
3. `/setup`
4. Restart Claude Code.

## Reliability
- Always records (or queues) one entry per turn — no model files needed (falls back to your prompt text + worktype 13).
- Backdates the start 60s; skips only exact-duplicate segments (<15 min).
- If the write fails or `R:`/network is down, the entry is queued locally (`~/.claude/apropos-time/`) and flushed on a later turn.

## Security
No credentials or database access ship in this repo. The credentialed write lives only in the internal `R:` skill (`Record-Time.ps1`), reachable on the RICO network. Off-network entries queue and flush later; a downloaded copy of this plugin cannot write to Apropos.

## Commands
`/time-ericb`, `/time-joelp`, `/time-barrettg`, `/time-calebb`, `/break`, `/lunch`, `/out`, `/setup`.
```
- [ ] **Step 4: Run full suite** — `bash tests/run-all.sh` → `SUITE GREEN`.
- [ ] **Step 5: Commit & push**
```bash
git add README.md tests/run-all.sh
git commit -m "docs: add README and full-suite test runner"
git push
```

---

## Self-Review

**1. Spec coverage:** Reliability/always-fire → Task 3 (fallbacks) + Task 2 (queue). Silent-skip fixes: (1)(2) desc/worktype fallback → Task 3; (3)(4) network/timeout → Task 2 queue + Task 3 flush; (5) session→`nosession`, unknown user handled → Task 3. Backdate/dedup → Task 3. SessionStart convention → Task 4. hooks wiring → Task 5. Commands → Task 6. `/setup` → Task 7. Distribution/README → Task 8. Security (no secrets) → Task 1 scan + Task 8 README. ✔

**2. Placeholder scan:** No TBD/TODO. Phase 2 (`Resolve-Task.ps1`) is intentionally deferred below, not a placeholder within Phase 1.

**3. Type/interface consistency:** `q_enqueue`/`q_flush` signatures identical across Task 2 defn, tests, and Task 3 usage. `write_entry`/`write_cb` arg order `person desc wt task proj start` consistent in queue lib, mock-writer, and hook. `APROPOS_WRITER`/`APROPOS_SKILL_DIR`/`APROPOS_TRACK_DIR` used consistently between hook and test. EventTypeIDs 3/7/8 consistent. Person IDs consistent.

## Phase 2 (separate, gated — not part of this plan's execution)

Add `R:/Intranet/ClaudeAI/skills/work-management/time/Resolve-Task.ps1` to resolve org/project → most-recently-active task against Apropos, with an injectable query for tests (never hits the DB in test). The hook would pass a project/org hint and use the resolved task when no explicit task is set. **Gate:** verify the live Apropos schema (org/project/task tables + last-activity column) before writing the query. Deliver as its own spec-slice + plan after Phase 1 is in production.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-10-apropos-time-plugin.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks.
2. **Inline Execution** — execute here with checkpoints.

Which approach?
