# Apropos Time-Recording Plugin — Design Spec

- **Date:** 2026-07-10
- **Status:** Draft for review
- **Author:** dev-apropos (with Eric Barone)
- **Local workspace:** `A:\Product Development\Program\Claude Plugin`
- **Distribution:** public GitHub marketplace repo `AproposoporpA/apropos-plugin`

## 1. Purpose

Package the existing per-turn Apropos time-tracking into an installable Claude Code
plugin named **`apropos`**, and use it as the **team-wide rollout vehicle** to move
Joel, Barrett, and Caleb off the legacy once-per-session `time-track.sh` onto the
per-turn model Eric already runs. The plugin replaces the manual
`install-per-turn-tracking.ps1` + hand-pasted `CLAUDE.md` step with a clean
`/plugin install` + `/setup`.

## 2. Core Principle

**The plugin is a thin orchestration shell. All business logic lives in the skill
layer on the internal `R:` share.** The plugin only wires hooks/commands and calls
the skills.

This is deliberate:

- **Security** — no logic or credentials to reverse-engineer in the public repo.
- **Maintainability** — update a skill on `R:` and every machine picks it up
  immediately; no plugin republish needed for logic/data changes (e.g. worktype
  list, resolution rules).

## 3. Security Model (settled)

- The public plugin ships **code only** — **no credentials, no direct DB access**.
- Both the **write** path (`Record-Time.ps1` → `dbo.CLAUDE_TimeEntry_INSERT`) and the
  new **read/lookup** path (org/project → task resolution) live in **skills on the
  `R:` share**, which hold the Apropos credential and are reachable only on the RICO
  network.
- **Off-network guarantee:** a machine that cannot reach the `R:` skills cannot read
  or write Apropos. Downloading the public plugin grants the orchestration shell but
  **no ability to record time** — the skill it calls is absent.
- **Backstops already in place (out of scope):** Azure SQL firewall locked to RICO
  IPs; `claudeaproposreadonly` is least-privilege (read-only on tables + `EXECUTE`
  on the insert proc).
- **Hard rule:** the Apropos connection string must **never** be committed to the
  public repo. Any script copied into the plugin has its connection string removed;
  the credential exists only in the `R:` skill files.

## 4. Architecture

### 4.1 Skill layer (`R:\Intranet\ClaudeAI\skills\work-management\time`, internal)

Holds **all** logic and the credential.

- **`time` skill (existing, extended)** — owns all recording logic:
  - Person resolution: Windows username → Apropos Person ID
    (ericbarone=321, joelperez=344, barrettgoldberg=276, calebbarone=1298).
  - Duplicate-segment detection: same `worktype + task/project` within 15 min → skip.
  - 1-minute backdating of `StartTime`.
  - Write via `Record-Time.ps1` → `dbo.CLAUDE_TimeEntry_INSERT`.
- **Read/lookup logic** — resolve org/project → task number against the Apropos DB.
  Added to the `time` skill, or a sibling read skill if that is cleaner; either way
  the logic and credential stay in the skill layer. Implemented as a `.ps1` script
  (per convention: always write `.ps1` files for SQL access, never inline).

### 4.2 Plugin layer (public repo, no secrets)

Mirrors the MMRY plugin structure:

- `.claude-plugin/plugin.json` — manifest (`name: apropos`).
- `hooks/hooks.json` + `hooks-handlers/`:
  - **`UserPromptSubmit`** — records time every response by calling the `time` skill
    (skill handles backdating + dedup). Session-keyed files under
    `/tmp/claude-timetrack/` per current design.
  - **`SessionStart`** — injects the per-turn convention (worktype IDs, per-turn file
    rules, person IDs) as additional context. Single source of truth.
- `commands/` — `/time-ericb`, `/time-joelp`, `/time-barrettg`, `/time-calebb`, plus
  break/lunch/out. Each calls the `time` skill. Manual commands may override the
  person (e.g. "record time for Joel").
- `skills/` — reference copy of the `time` SKILL.md (usage/flow only; no credentials).
- `setup/` — `/setup` command + install scripts (`.ps1`/`.sh`/`.bat`):
  wires the two hooks into the user's `settings.json` (idempotent, backs up first),
  and offers to remove old hand-pasted `CLAUDE.md` time-tracking blocks to avoid
  duplication.
- `README.md`.

## 5. Behavior

### 5.1 Recording (per turn)

- Record a time entry on **every response**.
- `StartTime` **backdated 1 minute**.
- **Skip** when it is a duplicate segment: same `worktype + task/project` as the last
  entry **and** < 15 min elapsed. (Start-marker model — duration is the gap to the
  next entry; no end times.)

### 5.2 Resolution rules

- **Person:** Windows username → Person ID (existing skill logic).
- **Worktype:** numeric `TimeTracking_Worktype.ID` written per turn by the agent
  (convention delivered via SessionStart). Default fallback 13 (Engineering).
- **Task/org/project:**
  1. If a task is **stated explicitly**, use it.
  2. Else if an **organization or project** is known, resolve the task via Apropos,
     choosing the **most-recently-active** task for that org/project.
  3. If ambiguous or nothing resolves, record at the **project/org level**
     (`@projectID` / `@organizationID`) so **no time is ever lost**; can be
     reassigned later.

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

## 7. Testing

- Hook dry-run with a fake session ID: verify **fire** vs. **dedup skip**.
- Verify 1-minute backdating on the recorded entry.
- Verify **off-network / missing skill fails safe**: no write, no thrown error, user
  never blocked.
- Verify task resolution: explicit task; org/project → most-recent task; ambiguous →
  project/org-level fallback.
- Verify `/setup` idempotency and that it backs up `settings.json` before editing.
- Verify SessionStart injection appears and `/setup` cleanup removes duplicate
  `CLAUDE.md` blocks.

## 8. Out of Scope

- Azure SQL firewall lockdown and DB account least-privilege (already done).
- A public Apropos API (does not exist yet; not part of this work).
- Migrating other teammates' machines is a rollout activity, not a code deliverable.

## 9. Open Items / Confirmations

- VCS: confirm before `git init` / first commit of this repo (per dev-apropos
  guardrail — VCS for this repo is TBD until confirmed).
- Whether read/lookup logic extends the existing `time` skill or becomes a sibling
  read skill (decide during planning; does not change the security boundary).
