---
status: done
risk: medium
area: ops/release
depends-on:
---

# There is no way to tag a build that has been verified rather than merely built

**Problem:** Nothing cuts a release tag, and the obvious way to do it is the
dangerous one. **A tag on an unverified image is worse than no tag: it looks
authoritative and is not.** This repo already built provenance tooling
(`scripts/verify-running-commit.sh`, `scripts/validate-stack.sh`) precisely
because a commit that does not describe the running binary is the failure mode
here — a tag naming such a commit bakes that mismatch in permanently. There is
also no record of what the tournament build was verified to *do*, so a future
rollback would be to a name with no meaning attached.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md` Task 7
Step 1, plus the release-record skeleton from Tasks 5-7.

**Acceptance criteria:**

- `scripts/release-tag.sh <tag-name> [--push]` exists and **refuses**, exiting
  non-zero and creating nothing, when: the working tree is dirty; the running
  server is not built from HEAD (via `scripts/verify-running-commit.sh`); or the
  tag already exists. It never moves an existing release tag.
- On success it creates an **annotated** tag whose message records the tag name,
  the full commit sha, the image tag, that `verify-running-commit.sh` passed at
  tag time, and a pointer to `docs/playerbots/TOURNAMENT-RELEASE.md`.
- It also tags the image `${TW_IMAGE}:<tag>` from `${TW_IMAGE}:<short-sha>` so the
  rollback path in `docs/DOCKER.md` works by name rather than by remembering a
  sha — and, when that image is not on this host, it says so as a warning and
  leaves the git tag standing rather than failing.
- `--push` is opt-in; without it the script prints the exact command to publish.
- `bash -n scripts/release-tag.sh` exits 0.
- `docs/playerbots/TOURNAMENT-RELEASE.md` exists and contains: what this build is
  (the plan series `2026-08-16-00` through `-09` and what it delivers); a
  "verified at tag time" table; the rollback instructions; and the defaults
  changed in this release (compiled `MinRandomBots`/`MaxRandomBots` 50/200 → 1000
  and `RandomBotAccountCount` 50 → 500, now agreeing with
  `aiplayerbot.conf.dist.in`).
- The document carries **three explicitly unfilled sections**, each with the exact
  commands and the table to fill in, marked as human measurements rather than left
  looking complete:
  1. **Capacity at 1000 bots** — the automated `STANDUP` line, plus the
     playability check (character-select and enter-world times, frame rate in a
     capital city and in an empty zone, movement responsiveness, `.gm on` +
     `.appear <bot>`, chat and spell latency) and a plain verdict.
  2. **Bot population during a tournament** — not a measurement but a recorded
     decision: tournaments run with the random pool at **zero**, so the only
     characters online are the 20 playing plus a GM spectator. State the reason
     (bot AI is single-core; memory at 1000 bots is comfortable at 4.27 GiB, so
     contention is the concern, not RSS) and note that the "match against a
     populated world" comparison is deliberately **not** run, because the
     operating configuration does not call for one. If a populated backdrop is
     ever wanted for the stream, that comparison is the thing to run first.
  3. **Tag-time verification** — filled in when the tag is actually cut.

**Notes:**

- **The tag is not cut by this artifact, and neither measurement is taken by it.**
  Writing the script and the record is the deliverable; running `release-tag.sh`
  is an operator action gated on Tasks 4-6 having passed. Do not create a tag, do
  not push anything, and do not fill in the three sections with estimates — an
  unfilled section marked as such is honest; a plausible-looking filled one is a
  fabricated release record.
- **Plan 09 Task 5 (client playability at 1000 bots) is deliberately not a
  separate backlog artifact.** `docs/playerbots/BOT-MEMORY-INVESTIGATION.md`
  states in bold that "client still playable" is UNVERIFIED at every bot count
  *because the check cannot be automated*. Its entire output is a filled-in
  section of this document, so it lives here as a checklist rather than as an
  artifact an unattended agent would either block on or fabricate. The 1000-bot
  claim is about the **alive world**, which is a separate configuration from a
  tournament — it still needs verifying, it is just not a tournament property.
- **Plan 09 Task 6 (a match against a full world) is not scoped at all.** It
  exists to answer whether a tournament is watchable with 1000 bots also
  thinking; that question was closed by decision rather than measurement —
  tournaments run with the random pool at zero. Recording that, and what would
  have to be measured if the decision were ever reversed, replaces it.
- **If the client is not playable at 1000, do not tag a release whose headline
  claim is a population nobody can join.** The correct response is to bisect with
  `standup-1000.sh --target N` for the highest playable count and record *that* as
  the supported figure — the compiled default may stay at 1000 while the
  documented supported population is lower, as long as the document says which is
  which and why.
- `scripts/lib/provenance.sh` (`prov_is_dirty`, `prov_head_sha`, `prov_short_sha`,
  `prov_branch`) and `scripts/verify-running-commit.sh` are already on `cm-main`.
- **Prove the refusals before trusting the accept path** — a gate that has never
  been seen to refuse is not known to work. Creating a stray untracked file and
  confirming the script exits 1 with **no tag created** is the check; it can be
  done here, offline.
- Docker on this host is at a deliberate fresh slate (2026-08-16): only
  `tortoise-cm:c06b2fb` survives and `.env` points `TW_IMAGE` at it, so the
  image-tagging branch will take its warning path until a real build exists.
- **Never `docker compose down -v`** — `tortoise-wow-v2_dbdata` is the entire
  world.
