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

**Base:** cm-main

**Branch:** backlog/release-tag-script-and-record

**Summary:** Added `scripts/release-tag.sh` and `docs/playerbots/TOURNAMENT-RELEASE.md` in one commit (39a45a4). The script takes `<tag-name> [--push]` and refuses, creating nothing, on three gates in cheap-first order: a dirty tree (via `prov_is_dirty`, so untracked files count — an untracked .cpp is in the build context and changes the binary while `git diff` stays silent), a tag name already in use (it never moves an existing release tag), and a running server that `scripts/verify-running-commit.sh` does not report as built from HEAD (covering both DRIFT and the UNKNOWN of nothing running). Ordering is deliberate: refusing an already-taken name must not require docker to be up. On success it writes an annotated tag whose message carries the tag name, full sha, image tag, the fact that verify passed at tag time, and a pointer to the release doc; then it tags `${TW_IMAGE}:<tag>` from `${TW_IMAGE}:<short-sha>`, first stripping any tag component off `TW_IMAGE` — `lib/provenance.sh` defaults it to the bare repo `tortoise-cm` but `.env` sets the full ref `tortoise-cm:c06b2fb`, and the plan's naive form yields `tortoise-cm:c06b2fb:9a1b2c3`, an invalid reference that would make the lookup miss on a host that actually has the image (a registry port like `host:5000/repo` is correctly not read as a tag). A genuinely missing image is a warning and the git tag stands. `--push` is opt-in; otherwise the exact publish command is printed. The release record documents what plans 2026-08-16-00 through -09 delivered, the rollback path, and the compiled fallbacks this release raises (50/200 → 1000/1000, accounts 50 → 500, now agreeing with `aiplayerbot.conf.dist.in`), and carries the three required sections explicitly marked unfilled with the exact commands and tables to fill in. No tag was cut and no measurement was fabricated.

**In-game check:** This change adds no C++ and touches nothing the server executes, so **in-game confirmation is the generic smoke test only**: the world comes up, `rndbot` bots spawn and move, a client can log in. Nothing else in the world should differ, and if it does, this branch is not the cause.

What genuinely needs confirming is the script's behaviour, and almost all of it is scriptable rather than human. Fully automatable, no game client needed:

1. `bash -n scripts/release-tag.sh` exits 0. (Confirmed here.)
2. `bash scripts/release-tag.sh` with no arguments prints usage and exits 2; `bash scripts/release-tag.sh "bad name"` exits 2 with `FATAL: 'bad name' is not a valid git tag name.` (Both confirmed here.)
3. **Dirty-tree refusal:** `touch ./dirty-probe && bash scripts/release-tag.sh probe-tag; echo $?` → prints `FATAL: working tree is dirty.`, lists `?? dirty-probe`, exits 1, and `git tag -l probe-tag` is **empty**. Then `rm -f ./dirty-probe`. (Confirmed here against the untracked script itself.)
4. **Existing-tag refusal:** `bash scripts/release-tag.sh pre-upstream-merge-20260811` on a clean tree → `FATAL: tag ... already exists at 3b2744c...`, exit 1, and `git rev-parse refs/tags/pre-upstream-merge-20260811^{commit}` still reads `3b2744c` afterwards — the existing tag was not moved. (Confirmed here.)
5. **Unverified-server refusal:** with mangosd down or built from another commit, `bash scripts/release-tag.sh probe-tag` prints the `verify-running-commit.sh` verdict, then `FATAL: the running server is not built from HEAD`, exits 1, and creates no tag. (Confirmed here: nothing was running on this host, verify returned UNKNOWN, exit 1, no tag.)

Requires a real build of this commit, so it belongs to the batch/operator step rather than to a human at a client — the accept path. After `./scripts/rebuild.sh` and `./scripts/validate-stack.sh --image tortoise-cm:<short-sha> --keep-up` report PASS, `./scripts/release-tag.sh <name>` (no `--push`) should print `==> created annotated tag <name> at <short-sha>`, `==> tagged image tortoise-cm:<name>`, and `not pushed. To publish: git push origin refs/tags/<name>`. Then `git cat-file -p refs/tags/<name>` must show the tag name, full sha, image tag, the verify-passed line and the pointer to `docs/playerbots/TOURNAMENT-RELEASE.md`, and `docker images --filter reference=tortoise-cm` must list the new tag. **Do not run this as part of routine validation** — it creates a real release tag; the artifact explicitly says the tag is not cut by this work. I exercised this path with a stubbed `verify-running-commit.sh` and deleted both probe tags afterwards; it produced a correct annotated object, took the warning path for a missing image, and produced `probe-repo:<tag>` from `TW_IMAGE=probe-repo:somepriortag` (the case the plan's naive `${TW_IMAGE}:${SHORT}` gets wrong).

The one part that is truly human, and is deliberately left unfilled in the document rather than done here: the §1 playability checklist at 1000 bots (character-select and enter-world times, fps in a capital and in an empty zone, rubber-banding, `.gm on` + `.appear <bot>`, chat and spell latency). That cannot be automated — which is why it is a checklist in the release record and not a claim.

Two notes for whoever runs this next. (a) `scripts/verify-running-commit.sh` tests `[[ -d "$TW_SRC_DIR/.git" ]]`, which is false in a git **worktree** (there `.git` is a file holding a `gitdir:` pointer), so it exits 2 with `FATAL: no git repo` when run from one. Pre-existing, not introduced here, and harmless in the main checkout where releases are cut — `release-tag.sh` itself handles both forms — but it means gate 3 refuses for the wrong reason inside a worktree. (b) Two throwaway image tags, `probe-repo:b46b5f8` and `probe-repo:probe-046`, are left on this host from the accept-path test. They are extra tags on the same image ID as `tortoise-cm:c06b2fb` and consume no additional space; `docker rmi` is blocked by policy here, so removing them is an operator action (`docker rmi probe-repo:b46b5f8 probe-repo:probe-046` — safe, the image stays alive under its `tortoise-cm:c06b2fb` tag).

**Minor findings:**
- scripts/release-tag.sh: The gate-3 refusal message interpolates the raw `${TW_IMAGE}` (`./scripts/validate-stack.sh --image ${TW_IMAGE}:${SHORT}`) instead of the `IMAGE_REPO` value the script deliberately strips a trailing tag from further down, so with the current `.env` (`TW_IMAGE=tortoise-cm:20260818-5`) the remediation command it prints is `tortoise-cm:20260818-5:9a1b2c3`, not a valid image reference.
- scripts/release-tag.sh: The up-front name validation, whose stated purpose is to stop a half-cut release, only rejects names starting with `.` or `-`, so a git-legal name containing `/` (e.g. `release/v1`) passes both checks, the annotated git tag is created, and `docker tag tortoise-cm:release/v1` then fails as an invalid reference — leaving exactly the git-tag-without-image state the check exists to prevent.
- scripts/release-tag.sh: Gate 3 executes `"$HERE/verify-running-commit.sh"` directly, but that file is committed mode 100644, so on any checkout with real POSIX permissions (e.g. an ext4 clone rather than the metadata-less `/mnt/c` mount) the exec fails with 126 and the script reports "the running server is not built from HEAD" for a reason that has nothing to do with provenance; invoking it as `bash "$HERE/verify-running-commit.sh"` removes the dependence on the mode bit.

**Drain note (the TW_IMAGE bug this tick caught is REAL ON THIS HOST RIGHT NOW):** the Summary reports that the plan's naive `${TW_IMAGE}:<short-sha>` form is wrong because TW_IMAGE may already carry a tag. Confirmed 2026-08-18: .env currently reads `TW_IMAGE=tortoise-cm:20260818-5`, so the naive form yields `tortoise-cm:20260818-5:9a1b2c3` — an invalid docker reference. Note the failure mode is inverted from the usual: it would MISS on a host that actually has the image, which is precisely the host where a release is cut. Stripping the tag component (while correctly not mistaking a registry port like `host:5000/repo` for one) is the right fix and should be kept.

**Drain note (finding 1 is the same bug surviving in the error message — worth fixing together):** the script strips the tag correctly in the code path, but the gate-3 refusal message interpolates the raw ${TW_IMAGE} rather than the stripped IMAGE_REPO. So with today's .env the remediation command it prints to the operator is `./scripts/validate-stack.sh --image tortoise-cm:20260818-5:9a1b2c3` — the exact invalid reference the script exists to avoid, handed to a human at the moment they are already blocked. One-line fix, same variable.

**Drain note (finding 3 CONFIRMED, and it is a known repo hazard recurring):** `git ls-tree origin/cm-main -- scripts/verify-running-commit.sh` reports mode **100644** — not executable — and release-tag.sh:96 invokes it directly as `"$HERE/verify-running-commit.sh"`. On this host that works only because /mnt/c is a metadata-less mount where every file appears executable; on any ext4 clone the exec fails with 126 and the script reports "the running server is not built from HEAD", i.e. a provenance verdict for a permissions fault, in the one script whose whole purpose is trustworthy provenance. Invoking it as `bash "$HERE/verify-running-commit.sh"` removes the dependence. This is the second instance of the same repo hazard this session: artifact 041 had to run `git update-index --chmod=+x` on two recovered scripts that came across mode 100644 for exactly this reason. Worth a sweep of scripts/ for non-executable .sh files that other scripts exec directly.

**Drain note (finding 2 defeats gate 2's stated purpose):** the up-front name validation exists to stop a half-cut release, but it only rejects names beginning with `.` or `-`. A git-legal name containing `/` (e.g. `release/v1`) passes, the annotated git tag IS created, and `docker tag tortoise-cm:release/v1` then fails as an invalid reference — leaving exactly the git-tag-without-a-matching-image state the check was written to prevent. Slash-containing tag names are a common convention, so this is a likely input rather than a contrived one.

**Drain note (this tick was appropriately careful with irreversible actions):** it did not cut a real tag, exercised the accept path against a stubbed verify-running-commit.sh, and deleted both probe tags afterwards — confirmed, `git tag -l "probe*"` returns nothing. It also left all 8 integration/* branches intact, which matters because each is the only ref keeping its image's stamped commit reachable and a release script is exactly where a tidy-up step would delete them.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/55, build tortoise-cm:20260818-6.
