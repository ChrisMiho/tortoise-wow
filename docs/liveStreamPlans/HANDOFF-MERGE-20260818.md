# Handoff: land the 18 Aug drain's 24 PRs and prep the remediation drain

You have GitHub merge access. Your job is to get `cm-main` from its current
state to a state where the next `backlog-drain` run does the right thing.
Another session scoped the remediation artifacts (055–065) and is not merging
anything — that is entirely yours.

**Do not start a drain run.** Read "The trap" first; it is the reason this
handoff exists.

---

## The trap — read before touching anything

`docs/liveStreamPlans/HANDOFF-DRAIN-20260818-REMEDIATION.md` states that
`docs/backlog/` on `cm-main` is empty and that a drain tick there "sees an empty
backlog and reports nothing to do". **That is false.** Verified 18 Aug:

```bash
git ls-tree --name-only origin/cm-main docs/backlog/   # 013–045 + README, all present
```

Of those 33 artifacts, **32 read `status: pending` on `cm-main`** — only 013 is
`done`. The `done` transitions the drain wrote live on the individual PR
branches, which have not merged.

Consequence: a drain tick from today's `cm-main` picks the lowest pending
artifact, **014**, and re-implements work that is already complete and sitting
in an open PR. It would do that for 32 artifacts, opening a duplicate PR for
each. Treat the remediation handoff's Part 1 as correct on merge *order* and
unreliable on repository *state* — re-verify state yourself.

---

## Hard invariants

1. **Never delete a `backlog/*` branch on origin, merged or not.** GitHub's
   "delete branch on merge" must stay off, and do not tick the delete button.
   `backlog-drain` resolves `depends-on` with
   `git merge-base --is-ancestor origin/backlog/<slug> origin/cm-main`; a
   deleted branch makes that command *error* rather than answer, and the tick
   cannot classify the dependency. Every one of artifacts 055–065 depends on an
   artifact whose branch is in this merge set, so a deletion breaks the next
   drain immediately. Same rule for `integration/*` — that ref is the only thing
   keeping a built image's stamped commit reachable.
2. **Never run `scripts/release-tag.sh`.** It cuts a real annotated git tag. It
   is also defective (artifact 058); PR #55 is deliberately held back.
3. **Do not run `docker volume prune`, `docker system prune --volumes`, or
   Docker Desktop's cleanup.** The game world is the external volume
   `tortoise-wow-v2_dbdata` and has been lost once. `docker image prune -a`
   separately destroys `tortoise-cm:c06b2fb`, the rollback anchor.
4. **Do not run another WSG validation match to characterise bot behaviour.**
   That measurement exists three times over: ~98.5% of playerbot AI ticks end
   "no actions executed", `bg move to objective` queued 23,908 times and popped
   zero. Nothing new is learned and it costs 20 minutes a run.

---

## Verified PR map

25 PRs are open; **#20 (`memory/baseline-investigation`) is unrelated and
shelved — leave it alone.** The other 24 are the drain's. They are already
stacked: each child PR's base is its parent branch, so GitHub auto-retargets
children to `cm-main` as parents merge. Merge parents first anyway — a child
merged first replays its parent's commits and looks like real divergence.

```
#33 tournament-equip-and-store-commands   -> cm-main
 └─ #40 tournament-heal-and-kill-commands
     └─ #47 tournament-poi-and-camera-commands
#36 tournament-run-driver                 -> cm-main
 └─ #53 reconcile-bot-pool-with-match-profile
#38 telemetry-extract                     -> cm-main
 └─ #41 telemetry-entry-and-movement-reports
#39 bot-log-capture-and-match-artifacts   -> cm-main
 └─ #43 run-effect-consumer-during-a-match
#42 gear-tier-armour-weapon-split         -> cm-main
 └─ #45 viewer-effect-library
     └─ #52 viewer-effect-queue
         └─ #56 viewer-effect-consumer
#44 bg-ai-analysis-code-reading           -> cm-main
 └─ #46 bg-ai-analysis-measurement-and-scoping
#48 spectator-director-loop               -> cm-main
 └─ #49 streaming-feasibility-assessment
#50 recover-ramp-and-plateau-instruments  -> cm-main
 └─ #54 standup-1000-script

independent: #34  #35  #37  #51  #55
```

Every PR branch carries the full 013–045 artifact set, so the first merge
restores the directory and later merges mostly fast-forward individual status
lines.

---

## Merge sequence

### Wave 0 — unblock the backlog: `#44`, then `#46`

`#46` carries artifacts **046–054**, the nine playerbot-AI fixes for the
headline defect: 20 of 20 bots enter Warsong Gulch and stand still for 20
minutes. Until it lands, those artifacts exist nowhere on `cm-main` and the
highest-value work is invisible to the drain.

`#46` also sets the `docs/backlog/README.md` counter to `054`.

### Wave 1 — independent, each already built and `VALIDATE-STACK`-passed

`#33` `#34` `#35` `#36` `#37` `#38` `#39` `#42` `#48` `#50` `#51`

Scripts, docs, one config-gated C++ sampler, and one two-literal change to
`PlayerbotAIConfig.cpp` matching what the shipped conf has always said.

### Wave 2 — chains, strictly in graph order

`#40` → `#47`; `#41`; `#43`; `#45` → `#52` → `#56`; `#49`; `#53`; `#54`.

`#47` and `#56` each ship a defect that defeats their own artifact's headline
criterion (artifacts 056 and 057 fix them). Merge them anyway: both failure
modes need a live match, and no live match can run until artifact 055 fixes the
gear gate. Holding them instead is defensible if you prefer — say which you did.

### Wave 3 — hold `#55` until artifact 058 lands

`#55` (`release-tag.sh`) is the one PR to keep out of `cm-main`. Every other
known defect fails loudly or fails in-world; this one creates persistent bad
state — a real annotated git tag with no matching image, exactly what its own
gate was written to prevent. Holding it does **not** block artifact 058: the
drain sees 045 as `done`-but-unmerged and cuts 058's branch from
`backlog/release-tag-script-and-record` automatically.

### Wave 4 — the remediation scoping branch

Branch `backlog/remediation-scope-055-065`, pushed to origin, with no PR open
yet. Three commits matter:

| Commit | Contents | Want it on `cm-main`? |
|---|---|---|
| `ca71059` | artifacts 055–065, counter bump to `065` | **Yes** |
| `31bebaa` | `.claude/settings.autonomous.json`, 2 lines off `.gitignore` | Operator's call |
| `3d7f37b` | this handoff document | Yes, if you want it recorded |

**Do not merge the branch as-is.** It was cut from `drain/tournament-2`, which
is 54 commits ahead of `cm-main` and carries infrastructure changes never
proposed to `cm-main` — `CLAUDE.md`, `Dockerfile`, `docs/DOCKER.md`,
`.claude/skills/backlog-drain/SKILL.md`, `.claude/workflows/backlog-issue.js`,
`.claude/workflows/backlog-batch.js`, `scripts/rebuild.sh`. Merging the branch
drags all of it in as a side effect.

Recommended instead — cherry-pick onto a clean base:

```bash
git fetch origin
git checkout -b backlog/remediation-scope origin/cm-main
git cherry-pick ca71059 3d7f37b
git push -u origin backlog/remediation-scope
```

That yields a two-commit PR containing only the 11 artifacts, the counter bump,
and this document. Merge it **last**. Add `31bebaa` to the cherry-pick only if
you have decided the autonomous-permissions settings belong on `cm-main`; it is
unrelated to the backlog and is safe to leave on the scoping branch.

Separately decide whether `drain/tournament-2`'s infrastructure commits should
reach `cm-main` — the drain-skill fix `d079a6c` (ticks tested against the wrong
image) is among them and is worth having. That is a judgement call, not part of
this merge.

---

## Conflicts to expect

**`docs/backlog/README.md` counter — guaranteed.** `#46` sets it to `054`; the
scoping commit sets `045` → `065`. Same line. **Resolve to `065`.** Numbers are
never reused; a recycled number silently repoints every old commit, PR and
`depends-on:` reference at a different issue.

**Artifact `status:` lines — likely, and mechanical.** Each PR branch carries all
33 artifacts, so two PRs can both touch a third artifact's status line. The
correct value is always the more advanced one (`done` beats `pending`); never
regress an artifact to `pending`.

---

## After the merges

1. Rebuild once from the merged `cm-main`:
   ```bash
   BUILD_JOBS=14 ./scripts/rebuild.sh
   ```
   Foreground only — BuildKit silently cancels backgrounded or `nohup`'d builds,
   leaving no image and no error. Allow the full 600 s tool timeout; the build
   takes ~8m15s at `-j14` and was killed at exit 143 every time at `-j10`.
   **Verify with `docker images`, not the exit code.**
2. `./scripts/validate-stack.sh`, and record the resulting image tag.
3. Do **not** run a WSG validation match (invariant 4).

---

## Verification checklist before handing the drain back

Run these and paste the output — each catches a specific, silent failure:

```bash
# 1. No pending artifact still has an open PR. Expect only 046-065.
for f in docs/backlog/[0-9]*.md; do
  grep -q '^status: pending' "$f" && basename "$f" | cut -c1-3
done | tr '\n' ' '

# 2. Counter reads 065.
grep 'Highest artifact' docs/backlog/README.md

# 3. All 11 depends-on targets exist and are non-pending.
for f in docs/backlog/0[56][0-9]-*.md; do
  d=$(grep '^depends-on:' "$f" | sed 's/depends-on: *//')
  [ -n "$d" ] && printf '%s -> %s %s\n' "$(basename "$f" | cut -c1-3)" "$d" \
    "$(grep -m1 '^status:' "docs/backlog/$d" 2>/dev/null || echo MISSING)"
done

# 4. No backlog branch was deleted. Expect 33 or more.
git ls-remote --heads origin 'refs/heads/backlog/*' | wc -l
```

Expected end state: artifacts **046–054 and 055–065** pending, everything
013–045 `done`, counter `065`, `#55` still open, all `backlog/*` branches intact
on origin.

---

## What the next drain will do, so you can sanity-check the result

It picks the lowest pending artifact: **046**, the first of the nine bot-AI
fixes. That is correct and desirable.

One consequence to expect rather than treat as a failure: 046 and 047 will be
implemented *before* 055, and 055 is what unblocks in-world verification — the
gear gate leaves 9 of 20 bots at `cannot_equip`, so `gear-audit.sh` reports
`complete=5/10` and `match-run.sh` aborts before assembly. Their code changes
will land with no in-game proof that a bot moved. That is inherent to
lowest-number-first ordering — not a defect, and not a reason to re-run
anything.

---

## Environment notes that have each cost a session

- **`node` is Windows-only; `jq` is WSL-only.** `scripts/check-*.js` must run
  from Git Bash; anything in `scripts/tournament/` must run from WSL. The
  blanket rule "run scripts from WSL" is wrong for the former.
- **Calling WSL from Git Bash:** prefix with `MSYS_NO_PATHCONV=1`, and never put
  a `$VAR` inside a wrapped `wsl -d Ubuntu -- bash -lc '...'` one-liner — the
  Windows layer blanks it silently and returns plausible, wrong output.
- **`git cat-file -e <rev>:<path>` returns silent false negatives from Git
  Bash** — MSYS mangles the `rev:path` argument. Use a pathspec
  (`git ls-tree <rev> -- <path>`) instead.
- **`wsg_mysql` discards stderr**, so a failed query is indistinguishable from
  "no rows matched". Re-run through a bare `docker exec ... mysql` before
  concluding anything from an empty result.
