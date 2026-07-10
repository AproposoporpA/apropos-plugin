# Apropos Time-Recording Plugin — Design Spec

- **Date:** 2026-07-10
- **Status:** Draft for review
- **Author:** dev-apropos (with Eric Barone)
- **Local workspace:** `A:\Product Development\Program\Claude Plugin`
- **Distribution:** public GitHub marketplace repo `AproposoporpA/apropos-plugin`

## 1. Purpose

Deliver an installable Claude Code plugin named **`apropos`** that records Apropos
time **reliably** — the current scripts drop time silently (§2.1), and fixing that is
the primary objective. Secondarily, the plugin is the **team-wide rollout vehicle** to
move Joel, Barrett, and Caleb off the legacy once-per-session `time-track.sh` onto the
per-turn model, replacing the manual `install-per-turn-tracking.ps1` + hand-pasted
`CLAUDE.md` step with a clean `/plugin install` + `/setup`.

## 2. Primary Goal: Reliability

**The point of this plugin is reliable time recording.** The current scripts drop
time silently in several ways (see §2.1). The plugin's job is to make every turn
produce — or durably queue — exactly one start-marker, regardless of model behavior
or a flaky network. Accuracy (good description/worktype/task) is layered on top but
can **never** be a reason to record nothing.

### 2.1 Failure modes in the current scripts (what we are fixing)

The existing `time-track-per-turn.sh` records nothing when any of these occur:

1. The model didn't write the per-turn `description` file → skip. *(Recording depends
   on the LLM cooperating every single turn — the biggest gap.)*
2. The model didn't write a numeric `worktype` → skip.
3. The DB/network/`R:` share is momentarily unavailable → the write fails and is
   swallowed (`|| true`) → **time lost, no retry.**
4. The 10-second hook timeout fires mid-write → killed → lost.
5. Session ID or username not resolved → skip.

### 2.2 Division of responsibility

- **Credentialed write** stays in the skill on `R:` (`Record-Time.ps1`, **unchanged**)
  — the only component that holds the credential. We do not rewrite it.
- **Reliability layer is LOCAL, in the plugin's hook.** Always-fire + fallbacks,
  dedup, and the durable pending-queue + flush/retry run on the machine. This is a
  hard requirement, not a preference: the queue must survive `R:`/network being down,
  and a script *on* `R:` cannot run when `R:` is unreachable. So the reliability layer
  cannot live in the skill.

This is deliberate:

- **Security** — no credentials or DB access in the public repo; the credential lives
  only in the `R:` skill.
- **Reliability** — the local queue protects against exactly the transient `R:`/network
  outages that lose time today.

## 3. Security Model (settled)

- The public plugin ships **code only** — **no credentials, no direct DB access**.
- Both the **write** path (`Record-Time.ps1` → `dbo.CLAUDE_TimeEntry_INSERT`) and the
  new **read/lookup** path (org/project → task resolution) live in **skills on the
  `R:` share**, which hold the Apropos credential and are reachable only on the RICO
  network.
- **Off-network guarantee:** a machine that cannot reach the `R:` skills cannot write
  to Apropos. On a RICO machine that is temporarily offline, entries queue locally and
  flush when connectivity returns (§5.1). An outside downloader has the plugin shell
  but no credential and no `R:` skill to call, so its queue can never flush —
  **downloading the plugin grants no ability to record time.**
- **Backstops already in place (out of scope):** Azure SQL firewall locked to RICO
  IPs; `claudeaproposreadonly` is least-privilege (read-only on tables + `EXECUTE`
  on the insert proc).
- **Hard rule:** the Apropos connection string must **never** be committed to the
  public repo. Any script copied into the plugin has its connection string removed;
  the credential exists only in the `R:` skill files.

## 4. Architecture

### 4.1 Skill layer (`R:\Intranet\ClaudeAI\skills\work-management\time`, internal)

Holds the **credential** and the **DB write** — nothing else changes here.

- **`Record-Time.ps1` (existing, UNCHANGED)** — the credentialed write:
  `dbo.CLAUDE_TimeEntry_INSERT`. Accepts person, description, worktype, task/project,
  event type, and backdated `StartTimeUTC`. This is the only credentialed component
  and we do not rewrite it.
- **(Phase 2, additive) `Resolve-Task.ps1`** — resolve org/project → most-recently-
  active task against the Apropos DB. A new read `.ps1` (per convention: always write
  `.ps1` files for SQL, parameterized, never `SELECT *`). Additive; does not alter the
  write path. Gated on verifying the live Apropos schema.

### 4.2 Plugin layer (public repo, no secrets) — the reliability layer

Mirrors the MMRY plugin structure. This is where the reliability logic lives, because
it must run locally to survive `R:`/network outages.

- `.claude-plugin/plugin.json` — manifest (`name: apropos`).
- `hooks/hooks.json` + `hooks-handlers/`:
  - **`UserPromptSubmit`** — the reliability hook. Each turn it: (1) **flushes** any
    queued pending entries; (2) determines description/worktype/task with **fallbacks**
    (§5.1); (3) applies **dedup**; (4) calls the `R:` `Record-Time.ps1` to write,
    **backdated 60s**; (5) on any failure/timeout/`R:`-unavailable, **enqueues** the
    entry to a local pending file for the next flush. Session-keyed files under
    `/tmp/claude-timetrack/`; the local queue under `~/.claude/apropos-time/`.
  - **`SessionStart`** — injects the per-turn convention (worktype IDs, file rules,
    person IDs) as additional context. Single source of truth.
- `commands/` — `/time-ericb`, `/time-joelp`, `/time-barrettg`, `/time-calebb`, plus
  break/lunch/out. Each calls `R:` `Record-Time.ps1`. Manual commands may override the
  person (e.g. "record time for Joel").
- `skills/` — reference copy of the `time` SKILL.md (usage/flow only; no credentials).
- `setup/` — `/setup` command + install script: backs up and removes any legacy
  hand-pasted `CLAUDE.md` time-tracking block (idempotent).
- `README.md`.

## 5. Behavior

### 5.1 Recording (per turn) — reliability first

- **Always fire (or queue) exactly one entry per response.** Missing model files must
  never cause a skip.
- **Description** = the model's per-turn `description` file if present and non-empty;
  otherwise **fall back to the user's prompt text** (trimmed to 500 chars).
- **Worktype** = the model's per-turn `worktype` file if numeric; otherwise **default
  to 13 (Engineering)**.
- `StartTime` **backdated 60 seconds**.
- **Dedup** (de-duplicate only, never a reason to record nothing): skip the write when
  the segment key `worktype|task|project` equals the last entry's **and** < 15 min
  elapsed. Start-marker model — duration is the gap to the next entry; no end times.
- **Durable delivery:** the write is attempted against `R:` `Record-Time.ps1`. On
  success, done. On failure/timeout/`R:`-unreachable, the entry is appended to the
  **local pending queue**; every subsequent turn flushes the queue (oldest first)
  until it drains. Nothing is lost to a transient outage.
- **Fail-safe:** the hook always exits 0 and never blocks the user.

### 5.2 Resolution rules

- **Person:** Windows username → Person ID (resolved in the local hook).
- **Worktype:** numeric `TimeTracking_Worktype.ID` written per turn by the agent
  (convention delivered via SessionStart). Default fallback 13 (Engineering).
- **Task/org/project (task auto-resolution is Phase 2):**
  1. If a task is **stated explicitly**, use it.
  2. *(Phase 2)* Else if an **organization or project** is known, resolve the task via
     `Resolve-Task.ps1`, choosing the **most-recently-active** task for that org/project.
  3. If ambiguous or nothing resolves, record at the **project/org level**
     (`@projectID` / `@organizationID`) so **no time is ever lost**; can be reassigned
     later. This fallback holds in Phase 1 (before auto-resolution exists) too.

### 5.3 Convention delivery

Injected each session via the **`SessionStart`** hook (zero-touch, always current,
single source of truth). Not written into the user's `CLAUDE.md`. `/setup` offers to
remove pre-existing hand-pasted blocks.

## 6. Distribution & Rollout

- New **public** marketplace repo `AproposoporpA/apropos-plugin`, registered in
  `known_marketplaces.json` (github source), structured like `MMRY-AI/mmry-plugin`.
- Team installs via `/plugin install` then `/setup`.
- Rollout target: Joel, Barrett, Caleb migrate from legacy `time-track.sh`; Eric
  migrates from his manual per-turn setup to the plugin.

## 7. Testing (reliability is the priority)

- **Always-fire:** with NO model `description`/`worktype` files, the hook still
  produces an entry using the prompt-text fallback + worktype 13.
- **Dedup:** same segment < 15 min → skip; changed worktype/task/project → fire.
- **Backdating:** recorded `StartTime` is ~60s in the past.
- **Durable queue:** when the write command fails (simulated), the entry lands in the
  local pending queue; on the next turn with the write restored, the queue **flushes**
  and drains; entries are not duplicated on flush.
- **Fail-safe:** missing `R:` skill / offline → hook exits 0, no thrown error, entry
  queued (not lost), user never blocked.
- **Phase 2 task resolution:** explicit task passes through; org/project → most-recent
  task; no candidates → 0 (project/org-level fallback). Tests use an injected query —
  never hit the DB.
- **`/setup`:** idempotent; backs up `CLAUDE.md` before removing a legacy block.
- **SessionStart injection:** convention text (worktype table, file rules) appears in
  output; contains no secret.
- **Secret scan:** repo tree contains no connection string / password / credential.

## 8. Out of Scope

- Azure SQL firewall lockdown and DB account least-privilege (already done).
- A public Apropos API (does not exist yet; not part of this work).
- Migrating other teammates' machines is a rollout activity, not a code deliverable.

## 8a. Phasing

- **Phase 1 (reliability + rollout):** the local reliability hook (always-fire +
  fallbacks + dedup + durable queue/flush), SessionStart injection, commands, `/setup`,
  README. `Record-Time.ps1` unchanged. Delivers reliable recording and the team
  rollout. No new `R:` logic.
- **Phase 2 (accuracy):** add `Resolve-Task.ps1` on `R:` for org/project → task
  auto-resolution, gated on verifying the live Apropos schema. Additive; does not
  change Phase 1 behavior.

## 9. Open Items / Confirmations

- VCS confirmed: repo is under version control at `AproposoporpA/apropos-plugin`.
- Phase 2 SQL: verify the live Apropos schema (tables/columns for org/project → task
  and last-activity) before finalizing `Resolve-Task.ps1`'s query.
