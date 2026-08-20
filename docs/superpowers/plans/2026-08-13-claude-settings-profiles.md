# Claude Code Settings Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the project's default Claude Code profile baseline GitHub CLI access, and add a new `settings.dev.json` profile with bounded elevated access for local dev work (bash build tools, python, docker) — without ever using `bypassPermissions`.

**Architecture:** This project already uses named, swappable `.claude/settings.*.json` profiles loaded via the `--settings` CLI flag, layered on top of the always-loaded `.claude/settings.json` (the "default profile" — arrays like `permissions.allow`/`deny` merge across layered settings sources). `.claude/settings.autonomous.json` is the existing wide-open profile (`permissions.defaultMode: bypassPermissions`) used for unattended `/loop` work; it is being cleaned up by another agent and MUST NOT be touched here. This plan (1) adds a GitHub CLI allow-rule to the default profile, and (2) creates a sibling `settings.dev.json` profile that adds explicit allow-rules for the project's actual dev tools (git, gh, docker, cmake, python, make/ninja, and the `scripts/` helpers) plus a small deny-list covering the specific destructive operations this repo has already been burned by or warned against (force-push, hard-reset, `rm -rf`, and — per `scripts/rebuild.sh`'s own comment "NEVER `docker compose down -v`" — the volume-destroying docker commands).

**Tech Stack:** Claude Code settings.json schema (permissions.allow/deny/defaultMode), jq for JSON validation, git for the `.gitignore` update.

**Spec:** No separate spec doc — this plan implements the user's direct request (captured verbatim below) for a config-only change; brainstorming was skipped because there's no design space to explore (the schema and file locations are fixed by the harness and the existing repo convention).

> "I want to enhance the default profile that auto loads every time a session is started, so that it has basic elevated access, to start, that will just be github, on top of that, I want to create a new profile, called settings.dev.json, that will have further elevated access, like bash, python, and other tools needed for dev work, but will not be wide open like the autonomous one is that bypasses everything. Do not touch existing profiles — the others are being cleaned up by another agent."

## Global Constraints

- Do not modify `.claude/settings.autonomous.json` or `.claude/settings.local.json` — out of scope, owned by another in-flight cleanup.
- `settings.dev.json` must never set `permissions.defaultMode` to `bypassPermissions`, and must never contain a bare `Bash(*)` allow rule — elevated but enumerated, not wide open.
- New/changed files: `.claude/settings.json` (edit), `.claude/settings.dev.json` (create), `.gitignore` (edit, one line).
- The "default profile" is `.claude/settings.json` (project-scoped, committed, auto-loads for every session in this repo) — not the global `~/.claude/settings.json`, which already holds unrelated personal preferences (model, theme, plugins) and has no `permissions` block. This matches the existing sibling-profile convention in `.claude/` (`settings.json`, `settings.autonomous.json`, `settings.local.json` all live there). If this assumption is wrong, stop after Task 1's verification step and confirm with the user before starting Task 2.

---

### Task 1: Add GitHub CLI access to the default profile

**Files:**
- Modify: `.claude/settings.json`

**Interfaces:**
- Consumes: nothing (leaf config file)
- Produces: `.claude/settings.json` with `permissions.allow` containing `"Bash(gh *)"` alongside the pre-existing `"Bash(git *)"` — this is the baseline that `settings.dev.json` in Task 2 layers on top of.

- [ ] **Step 1: Confirm current content and write the verification query**

Read the file to confirm it still matches the known baseline (guards against clobbering a concurrent edit from the "other agent" doing profile cleanup):

```bash
cat .claude/settings.json
```

Expected current content:

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)"
    ]
  }
}
```

If the content differs from this, STOP and re-read this plan's assumptions before proceeding — someone else may have already changed this file.

- [ ] **Step 2: Run the verification query and confirm it fails (rule not yet present)**

```bash
jq -e '.permissions.allow | index("Bash(gh *)")' .claude/settings.json
```

Expected: exit code 1, output `null` — `Bash(gh *)` is not in the array yet.

- [ ] **Step 3: Edit the file to add GitHub CLI access**

Add `"Bash(gh *)"` to the `permissions.allow` array, keeping the existing `"Bash(git *)"` entry:

```json
{
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(gh *)"
    ]
  }
}
```

- [ ] **Step 4: Run the verification query again and confirm it passes**

```bash
jq -e '.permissions.allow | index("Bash(gh *)")' .claude/settings.json
```

Expected: exit code 0, output `1` (the array index of the new entry).

- [ ] **Step 5: Validate the file is still well-formed against the settings schema shape**

```bash
jq -e '.permissions.allow | all(type=="string")' .claude/settings.json
jq empty .claude/settings.json && echo "valid JSON"
```

Expected: both commands succeed (`true` then `valid JSON`).

- [ ] **Step 6: Commit**

```bash
git add .claude/settings.json
git commit -m "$(cat <<'EOF'
Grant the default Claude Code profile baseline GitHub CLI access

Every session in this repo now gets gh(1) alongside the existing git
access, without needing the dev or autonomous profile.
EOF
)"
```

---

### Task 2: Create the `settings.dev.json` profile

**Files:**
- Create: `.claude/settings.dev.json`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: layers on top of `.claude/settings.json` from Task 1 when loaded via `claude --settings .claude/settings.dev.json` (permission arrays merge across settings sources — see the "Full Settings JSON Schema" `permissions` block: `allow`/`deny` are plain string arrays with no exclusivity semantics between sources). This file repeats the `git`/`gh` allow-rules from Task 1 for readability/self-containedness even though the merge would already supply them.
- Produces: `.claude/settings.dev.json` — a standalone, git-ignored profile file. Nothing downstream in this repo depends on its contents; it is invoked manually by the user via `--settings`.

- [ ] **Step 1: Confirm the file does not already exist**

```bash
test -f .claude/settings.dev.json && echo "EXISTS - stop and investigate" || echo "clear to create"
```

Expected: `clear to create`.

- [ ] **Step 2: Write the failing verification queries**

These are the checks the new file must satisfy — run them now to confirm they fail because the file doesn't exist yet:

```bash
jq -e '.permissions.defaultMode != "bypassPermissions"' .claude/settings.dev.json
jq -e '.permissions.allow | index("Bash(docker *)")' .claude/settings.dev.json
```

Expected: both fail (`No such file or directory`).

- [ ] **Step 3: Create `.claude/settings.dev.json`**

The allow-list covers the tools this repo's own dev workflow actually uses: `git`/`gh` (matching Task 1), `docker` (the whole build/verify/promote flow in `scripts/rebuild.sh` runs through `docker build`/`docker run`/`docker tag`), `cmake` (the direct, non-container build path documented in `INSTALL-LINUX.md`/`INSTALL-WINDOWS.md`), `make`/`ninja` (CMake generators), `python`/`python3`/`pip`/`pip3` (the standalone scripts under `tools/**/*.py` and `sql/tools/*.py`), and the two `scripts/*.sh` entry points. The deny-list blocks the specific destructive shapes of those same tools: force-push and hard-reset (irreversible history rewrites), `rm -rf` (irreversible deletes), and `docker compose down -v`/`--volumes` plus `docker volume rm` and `docker system prune` — `scripts/rebuild.sh` itself warns "NEVER `docker compose down -v` — that volume is the entire world," so this profile enforces that warning at the permission layer instead of relying on the operator remembering it. `permissions.defaultMode` is left as `"default"` explicitly (not omitted) so the file self-documents that it does not bypass anything, in contrast to `settings.autonomous.json`.

```json
{
  "permissions": {
    "defaultMode": "default",
    "allow": [
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(docker *)",
      "Bash(cmake *)",
      "Bash(make *)",
      "Bash(ninja *)",
      "Bash(python *)",
      "Bash(python3 *)",
      "Bash(pip *)",
      "Bash(pip3 *)",
      "Bash(./scripts/*)",
      "Bash(bash scripts/*)"
    ],
    "deny": [
      "Bash(git push --force*)",
      "Bash(git reset --hard*)",
      "Bash(rm -rf*)",
      "Bash(docker compose down -v*)",
      "Bash(docker compose down --volumes*)",
      "Bash(docker volume rm*)",
      "Bash(docker system prune*)"
    ]
  }
}
```

- [ ] **Step 4: Run the verification queries again and confirm they pass**

```bash
jq -e '.permissions.defaultMode != "bypassPermissions"' .claude/settings.dev.json
jq -e '.permissions.allow | index("Bash(docker *)")' .claude/settings.dev.json
jq -e '.permissions.allow | any(. == "Bash(*)")' .claude/settings.dev.json; echo "exit=$? (expected 1 - no bare Bash(*) rule)"
```

Expected: first two commands exit 0; the third prints `exit=1` (confirming no wide-open `Bash(*)` rule was accidentally added — `jq -e` exits 1 when the filter result is `false`).

- [ ] **Step 5: Validate the file against the settings schema shape**

```bash
jq -e '.permissions.allow | all(type=="string")' .claude/settings.dev.json
jq -e '.permissions.deny | all(type=="string")' .claude/settings.dev.json
jq -e '.permissions.defaultMode as $m | ["acceptEdits","auto","bypassPermissions","default","dontAsk","plan"] | index($m) != null' .claude/settings.dev.json
jq empty .claude/settings.dev.json && echo "valid JSON"
```

Expected: all four commands succeed.

- [ ] **Step 6: Add the git-ignore entry**

`.gitignore` already excludes `settings.autonomous.json` with an explanatory comment (line 23-24: `# Personal Claude Code profile for the autonomous /loop (bypasses permission prompts)` / `/.claude/settings.autonomous.json`). Add a matching entry for the new profile directly below it, since it's likewise a personal elevated-access profile invoked manually rather than the team-wide default:

Read `.gitignore` first to get exact current line numbers, then insert after the `settings.autonomous.json` line:

```gitignore

# Personal Claude Code profile for elevated dev-tool access (docker/cmake/python — not bypassed, see .claude/settings.dev.json)
/.claude/settings.dev.json
```

- [ ] **Step 7: Verify the ignore rule takes effect**

```bash
git check-ignore -v .claude/settings.dev.json
```

Expected: prints a match against the `.gitignore` line just added (confirms the pattern is anchored correctly and actually matches).

```bash
git status --porcelain --ignored .claude/
```

Expected output includes `!! .claude/settings.dev.json` (ignored) — NOT `??` (untracked-but-visible). `.claude/settings.json` from Task 1 should now show as staged/committed (absent from this listing, or `A`/nothing if already committed in Task 1).

- [ ] **Step 8: Commit the `.gitignore` change**

`settings.dev.json` itself is ignored and won't be staged by `git add .`; only the `.gitignore` edit is tracked.

```bash
git add .gitignore
git commit -m "$(cat <<'EOF'
Ignore the new settings.dev.json Claude Code profile

Mirrors the existing settings.autonomous.json exclusion: this is a
personal elevated-access profile invoked manually via --settings, not
part of the team-wide default profile.
EOF
)"
```

- [ ] **Step 9: Manual smoke check (not automatable — do this yourself once)**

Launch a session with the new profile layered on the default and confirm a previously-prompted dev command now runs without a permission prompt, while a denied one still blocks:

```
claude --settings .claude/settings.dev.json
```

Then in that session, run a harmless docker command (e.g. `docker version`) and confirm no permission prompt appears, and separately attempt `git reset --hard HEAD` and confirm it is blocked/prompted rather than silently allowed.

---

## Self-Review Notes

- **Spec coverage:** "enhance default profile ... basic elevated access ... just github" → Task 1. "create settings.dev.json ... bash, python, other dev tools ... not wide open like autonomous" → Task 2 (enumerated allow-list, `defaultMode: "default"`, no `Bash(*)`). "do not touch existing profiles" → Global Constraints + Task 1 Step 1 guard read. No gaps found.
- **Placeholder scan:** no TBD/TODO markers; every allow/deny rule is a concrete, final string; both JSON files are given in full, not "similar to above."
- **Type consistency:** both tasks use the same `jq -e` verification idiom and the same schema field names (`permissions.allow`, `permissions.deny`, `permissions.defaultMode`) drawn directly from the settings schema reference gathered via the update-config skill.
