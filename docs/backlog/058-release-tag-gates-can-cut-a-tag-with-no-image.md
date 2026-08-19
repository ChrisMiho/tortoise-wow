---
status: implemented
risk: low
area: ops/release
depends-on: 045-release-tag-script-and-record.md
---

# `release-tag.sh` can cut a git tag with no matching image

**Problem:** two defects, both in the gates that exist to prevent a half-cut
release.

1. The gate-3 refusal message interpolates the raw `${TW_IMAGE}` instead of the
   `IMAGE_REPO` value the script correctly strips a trailing tag from further
   down. With today's `.env` (`TW_IMAGE=tortoise-cm:20260818-4`) it hands a
   blocked operator the remediation command
   `./scripts/validate-stack.sh --image tortoise-cm:20260818-4:9a1b2c3` — not a
   valid image reference.
2. The up-front name validation rejects only names starting with `.` or `-`, so
   a git-legal name containing `/` (`release/v1`, a common convention) passes,
   the annotated git tag **is** created, and `docker tag tortoise-cm:release/v1`
   then fails as an invalid reference — leaving exactly the
   git-tag-without-an-image state gate 2 was written to prevent.

**Suspected cause / area:** `scripts/release-tag.sh`, the two gates.

**Acceptance criteria:**

- The gate-3 message prints the stripped `IMAGE_REPO`, producing a runnable
  command.
- `release-tag.sh 'release/v1'` is refused **before any tag is created**; verify
  with `git tag -l` that nothing was left behind.
- Both paths covered by a test that runs against a stubbed
  `verify-running-commit.sh` and deletes its probe tags afterwards.

**Notes:**

- **Do not run the real script as part of routine validation — it creates a real
  release tag.** Verify against the stub only.
- PR #55 (artifact 045) should stay unmerged until this lands; it is the one
  known defect that creates persistent bad state rather than failing loudly.

**Base:** backlog/release-tag-script-and-record

**Branch:** backlog/release-tag-gates-can-cut-a-tag-with-no-image

**Summary:** On branch backlog/release-tag-gates-can-cut-a-tag-with-no-image (cut from origin/backlog/release-tag-script-and-record), commit 1c9a7b2 fixes both gate defects in C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_35407236-38f-1\scripts\release-tag.sh. The IMAGE_REPO derivation (which strips a trailing :tag from TW_IMAGE) moved up from the tag-creation section to just above gate 3, and the gate-3 refusal now prints `--image ${IMAGE_REPO}:${SHORT}` instead of `${TW_IMAGE}:${SHORT}`, so with .env's TW_IMAGE=tortoise-cm:20260818-4 the remediation line reads `./scripts/validate-stack.sh --image tortoise-cm:9a1b2c3 --keep-up` rather than the unusable double-tagged ref. The up-front name check replaced the `.*|-*` case with the actual docker tag rule `^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$`, run right after `git check-ref-format` and before any git state is touched, so `release/v1` exits 2 with an explanatory message and no annotated tag. verify-running-commit.sh is now invoked through an overridable `TW_VERIFY` (same env-var-override pattern lib/provenance.sh already uses) so the new tests\release-tag.test.sh can drive all three gates against a stub verify script, a stub docker, and a fresh mktemp git repo pointed at by TW_SRC_DIR — never this checkout — asserting `git tag -l` is empty after each refusal and deleting the probe repo afterwards. 13 assertions pass under WSL bash.

**In-game check:** This change touches no server code, no SQL, and no container — it is an ops shell script, so there is nothing to see in-game beyond the generic "server starts, bots spawn" smoke test, and the built image is byte-identical in behaviour. State that explicitly rather than looking for a world-side effect.

What IS confirmable, and all of it is scriptable with no running stack (the artifact's Notes forbid running the real script — every step below stays on the stub):

1. `bash tests/release-tag.test.sh` from the repo root under WSL. Expect exit 0 and the tally line `13 passed, 0 failed`. This is the whole gate coverage: gate-3 message text, `release/v1`, leading `-`, leading `.`, and the happy path.
2. Read the gate-3 assertion output specifically — the run must print `ok gate 3 prints the stripped IMAGE_REPO` and `ok gate 3 does not print a double-tagged ref`. The second is the direct regression guard for defect 1: it fails if the string `tortoise-cm:20260818-4:` ever reappears in the refusal.
3. Confirm nothing leaked into the real repo: `git tag -l` in the checkout must list exactly the tags it listed before the test run (the test only ever tags a mktemp repo, and deletes it). A `tournament-v1` or `release/v1` tag appearing in this checkout after a test run is a failure of the test's own isolation and should be deleted with `git tag -d`.
4. Manual, one-time, by eye rather than by script: `sed -n '59,76p' scripts/release-tag.sh` and confirm the docker-name check sits above the `[ -d "$TW_SRC_DIR/.git" ]` block and above gate 1 — i.e. before any git state is touched. Ordering is the substance of the second fix and a future edit that moves it below gate 2 would still pass every assertion about exit codes.

When a real release is next cut for real (a human action, not part of validation), the observable confirmation is that `./scripts/release-tag.sh 'release/v1'` prints "not a valid docker tag" and exits 2 with `git tag -l` unchanged, and that a genuinely blocked gate-3 run prints a `validate-stack.sh --image` line that can be copy-pasted and runs.

**Minor findings:**
- tests/release-tag.test.sh: The `run_release 0 '-v1'` case never reaches the new docker-name regex — the script's argument loop matches `-*` first and exits 2 with "unknown arg: -v1", so the assertion passes on the wrong code path and the regex's leading-'-' rejection stays untested (a leading '.' is genuinely covered).
