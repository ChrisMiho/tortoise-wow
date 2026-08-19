# Handoff: build and validate the merged `cm-main`

The 18 Aug drain's 24 PRs are merged. Your job is one rebuild, one stack
validation, and one recorded image tag. **Do not start a drain run** and **do
not run a WSG match** — see "Do not" below.

---

## State you are inheriting

Merged into `cm-main` on 18 Aug (23 PRs, merge commits, no squash):

- Wave 0 — `#44`, `#46`. `#46` brought artifacts **046–054**, the nine
  playerbot-AI fixes.
- Wave 1 — `#33 #34 #35 #36 #37 #38 #39 #42 #48 #50 #51`.
- Wave 2 — `#40 #47 #41 #43 #45 #52 #56 #49 #53 #54`, in graph order.

`#47` and `#56` were merged despite each shipping a defect that defeats its own
artifact's headline criterion. Artifacts 056 and 057 fix them. Both failure
modes need a live match, and no live match can run until artifact 055 fixes the
gear gate, so nothing is observable either way until then.

**Still open, deliberately:**

| PR | Branch | Why |
|---|---|---|
| `#55` | `backlog/release-tag-script-and-record` | Cuts a real annotated git tag with no matching image (artifact 058). The only merge-set PR that creates persistent bad state. Holding it does not block 058 — the drain cuts 058's branch from this branch directly. |
| `#57` | `backlog/remediation-scope` | Artifacts 055–065, counter bump to `065`, both handoff docs, and the 014–045 status correction. **Merge this before doing anything else.** |
| `#20` | `memory/baseline-investigation` | Unrelated and shelved. Leave alone. |

### The status-line correction — why `#57` is not optional

The merge handoff predicted that merging the PRs would flip artifacts 013–045 to
`done`. **It did not.** The drain wrote those transitions only on
`drain/tournament-2`; the individual PR branches still read `status: pending`.
After all 23 merges, `cm-main` had **014–054 all pending**, and a drain tick
would have picked 014 and re-implemented already-merged work, once per artifact.

`#57`'s commit `7cc1a86` ports the 32 status lines from
`origin/backlog/remediation-scope-055-065` (which carries 013–045 as `done`).
Only the frontmatter `status:` line changes in each file.

Until `#57` merges, `cm-main` is in that trap state. Merge it first.

---

## Do this

1. **Merge `#57`.** Then confirm `cm-main` reads:
   ```bash
   git fetch origin && git checkout --detach origin/cm-main
   for f in docs/backlog/[0-9]*.md; do
     grep -q '^status: pending' "$f" && basename "$f" | cut -c1-3
   done | tr '\n' ' '        # expect exactly 046 ... 065
   grep 'Highest artifact' docs/backlog/README.md   # expect 065
   ```

2. **Rebuild once, in the foreground.**
   ```bash
   BUILD_JOBS=14 ./scripts/rebuild.sh
   ```
   Use `timeout: 600000` — the Bash tool's maximum, and it silently clamps
   anything larger. The build takes ~8m15s at `-j14`, leaving ~90s of headroom;
   at `-j10` it was killed at 10m00s with **exit 143** every time. Backgrounded
   or `nohup`'d builds are silently cancelled by BuildKit — no image, no error.
   Full recompilation every build is expected; `COPY . /src` never cache-hits.
   **Verify with `docker images`, not the exit code.**

   If you see exit 143 at 10m00s again, the build has crept back over the
   ceiling — report that rather than retrying blindly.

3. **Validate the stack.**
   ```bash
   ./scripts/validate-stack.sh
   ```

4. **Record the resulting image tag** — in the run notes and in whatever
   integration ref the build stamps. That ref is the only thing keeping the
   built image's commit reachable.

---

## Do not

1. **Never delete a `backlog/*` branch on origin**, merged or not. GitHub's
   "delete branch on merge" is off; keep it off. `backlog-drain` resolves
   `depends-on` with
   `git merge-base --is-ancestor origin/backlog/<slug> origin/cm-main`, and a
   deleted branch makes that command *error* rather than answer — the tick then
   cannot classify the dependency. All 11 of artifacts 055–065 depend on an
   artifact whose branch is in this merge set. Same rule for `integration/*`.
   Expect **35** branches from
   `git ls-remote --heads origin 'refs/heads/backlog/*' | wc -l`.
2. **Never run `scripts/release-tag.sh`.** It cuts a real annotated tag and is
   defective (artifact 058).
3. **No `docker volume prune`, `docker system prune --volumes`, or Docker
   Desktop cleanup.** The game world is the external volume
   `tortoise-wow-v2_dbdata` and has been lost once. `docker image prune -a`
   separately destroys `tortoise-cm:c06b2fb`, the rollback anchor.
4. **No WSG validation match.** That measurement already exists three times
   over: ~98.5% of playerbot AI ticks end "no actions executed";
   `bg move to objective` was queued 23,908 times and popped zero. A run costs
   20 minutes and teaches nothing new.
5. **Do not start a drain run** as part of this handoff. Hand back to the drain
   only after the build and validation pass.

---

## What the next drain will do

It picks the lowest pending artifact: **046**, the first of the nine bot-AI
fixes. Correct and desirable.

Expect this and do not treat it as a failure: 046 and 047 get implemented
*before* 055, and 055 is what unblocks in-world verification — the gear gate
leaves 9 of 20 bots at `cannot_equip`, so `gear-audit.sh` reports
`complete=5/10` and `match-run.sh` aborts before assembly. Their code changes
will land with no in-game proof that a bot moved. That is inherent to
lowest-number-first ordering.

---

## Still-open judgement call

`drain/tournament-2` is 54 commits ahead of `cm-main` and carries infrastructure
never proposed to `cm-main`: `CLAUDE.md`, `Dockerfile`, `docs/DOCKER.md`,
`.claude/skills/backlog-drain/SKILL.md`, `.claude/workflows/backlog-issue.js`,
`.claude/workflows/backlog-batch.js`, `scripts/rebuild.sh`. Among them is
`d079a6c`, a drain-skill fix for ticks being tested against the wrong image —
worth having. Nobody has decided whether to port it. **Note that `scripts/rebuild.sh`
is in that set**, so the version you run in step 2 is `cm-main`'s, not the
drain's.

Commit `31bebaa` (`.claude/settings.autonomous.json` plus two `.gitignore`
lines) was deliberately excluded from `#57` and remains only on
`backlog/remediation-scope-055-065`.

---

## Environment notes that have each cost a session

- **`node` is Windows-only; `jq` is WSL-only.** `scripts/check-*.js` must run
  from Git Bash; anything in `scripts/tournament/` must run from WSL.
- **Calling WSL from Git Bash:** prefix `MSYS_NO_PATHCONV=1`, and never put a
  `$VAR` inside a wrapped `wsl -d Ubuntu -- bash -lc '...'` one-liner — the
  Windows layer blanks it silently and returns plausible, wrong output.
- **`git cat-file -e <rev>:<path>` gives silent false negatives from Git Bash.**
  Use `git ls-tree <rev> -- <path>`.
- **`wsg_mysql` discards stderr**, so a failed query looks identical to "no rows
  matched". Re-run through a bare `docker exec ... mysql` before concluding
  anything.
- **`tw_world.item_template` is snake_case** here (`inventory_type`,
  `item_level`, `required_level`).
- **`gh pr view --json mergeable` returns `UNKNOWN`** for several seconds after
  the base branch moves. Poll until it resolves; treating `UNKNOWN` as
  not-mergeable skips PRs that are fine.

---

## Outcome — executed 18 Aug

**Build:** `BUILD_JOBS=14 ./scripts/rebuild.sh` from WSL, foreground. Compile
489 s, well inside the ceiling. All five acceptance checks passed — `mangosd`
and `realmd` exist and link cleanly, playerbots compiled in, both extractors
present.

**Image tag:** `tortoise-cm:eed1053`, image ID
`ccef0e322fbdb7002ab058b04af2fe36e435d98fd84f62c1cd147396b55a9c53`
(`ccef0e322fbd`), promoted to `tortoise-cm:local`. Built from `cm-main` at
`eed1053`, clean tree. Rollback anchor `c06b2fb` untouched.

**Validation:** `VALIDATE-STACK: PASS` — provenance `eed1053 == HEAD`, identity
matched, realm `8095:0`, 775 characters online.

**The first validation run failed, and it was the harness, not the image.**
`VALIDATE-STACK: FAIL LIVENESS — no characters came online within 300s`.
`prov_world_ready` probed the world port from the host, where Docker's proxy
binds it at container start; the host probe passed at t=6s while mangosd only
listened at t=57s, so the 300s bot window started against a still-loading world.
On the first boot off a freshly built 2.3 GiB image that overran the window.
Bots were never the problem — a cold-boot reproduction had 717 online at the
first poll after the world opened, plateauing at 1017. Fixed as artifact **066**;
`scripts/standup-1000.sh` had the same false-ready.

**Not done, deliberately:** no WSG match (invariant 4), no drain run.
