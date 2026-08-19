---
status: pending
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
