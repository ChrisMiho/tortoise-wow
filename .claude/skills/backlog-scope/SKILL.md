---
name: backlog-scope
description: Turn a raw bug/idea into a scoped backlog artifact under docs/backlog/, ready for the autonomous drain workflow to implement
---

# Backlog Scope

Turns one raw idea (a brain-dumped bug report, a "this feels off" observation) into
a single artifact file the `backlog-drain` skill can later pick up and implement
without any further input from you. Since drain runs fully autonomously to PR with
no other checkpoint, this conversation is the only chance to get the scope right.

## Process

1. **Read the idea.** If the user's description already answers a question below,
   don't re-ask it — only ask for what's actually missing.
2. **Ask one question at a time** until you can fill in every section below:
   - **Problem:** what breaks, under what conditions, and (if known) how it was
     traced. Match the terse, bug-report voice of this repo's commit log and
     README fix tables — run `git log --oneline -20` if unsure of the voice.
   - **Suspected cause / area:** file(s) or subsystem, if the user has a hunch.
     "Not sure" is a valid answer — leave it as an area/subsystem guess only.
   - **Acceptance criteria:** concrete, checkable conditions for "this is fixed."
     Push back on vague criteria ("bots behave better") until it's checkable.
   - **Risk:** low / medium / high — your judgment plus the user's, based on
     blast radius (a single spell fix vs. shared threading/pointer code).
   - **Area:** a short subsystem tag, e.g. `playerbots/battlegrounds`,
     `spells/mage`, `navmesh`.
   - **Depends on:** does this fix require another *unimplemented or
     unmerged* backlog artifact's change to already exist — e.g. it edits a
     function that artifact adds, or its acceptance criteria assume that fix
     landed first? If so, ask which artifact (list `docs/backlog/*.md` if the
     user doesn't remember the number) and record it as
     `depends-on: <NNN>-<slug>.md`. Most artifacts have no dependency — leave
     it blank rather than guessing one.
   - **Feasibility:** does implementing or verifying this require data, an
     environment, or a build/tooling capability that might not exist in the
     drain's environment (a specific database state, a running server,
     in-game content that must already exist)? If there's real doubt, note it
     under **Notes** so `backlog-issue` can recognize an infeasible
     acceptance criterion instead of treating it as an ordinary
     implementation failure.
3. **Determine the next artifact number.** Numbers are **never reused**, so
   derive the high-water mark from git history rather than from the files
   currently on disk — artifacts get deleted once their work lands, and an
   emptied directory must not restart the sequence at `001`. A recycled number
   silently repoints every old commit, PR and `depends-on:` reference at a
   different issue.

   ```bash
   git log --all --name-only --format= -- 'docs/backlog/[0-9]*.md' \
     | sort -u | grep -oE '[0-9]{3}-' | tr -d '-' | sort -n | tail -1
   ```

   Take the highest of **three** sources and add one, zero-padded to 3 digits:

   - the git-history high-water mark from the command above,
   - the counter in the `<!-- BACKLOG-COUNTER -->` block of
     `docs/backlog/README.md`,
   - any numbered files currently in `docs/backlog/`.

   They should agree. When they do not, the highest wins — that is the whole
   point of checking more than one. Only start at `001` if all three are empty,
   meaning no artifact has ever existed in this repository.
4. **Slugify the title** (lowercase, hyphens, no punctuation) for the filename.
5. **Write the artifact** to `docs/backlog/<NNN>-<slug>.md`, following the
   format in `docs/backlog/README.md` exactly, with `status: pending`.
   Include `depends-on:` in the frontmatter if step 2 identified one; omit the line's value (leave it blank) otherwise.
5b. **Bump the counter.** Update the `<!-- BACKLOG-COUNTER -->` block in
   `docs/backlog/README.md` to the number just used and the next one, in the
   same commit as the new artifact. Skipping this is not fatal — step 3 still
   derives the right number from git history — but it leaves the counter stale
   and misleading to anyone reading it.
6. **Confirm** the file path back to the user and ask if they have another idea
   to scope, looping back to step 1 if so.
