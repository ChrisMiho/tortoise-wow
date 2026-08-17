# Tournament rosters

A team is a JSON file, not a console transcript. Everything you would tweak per
team lives in `config/tournament/teams/<id>.json`, and
`scripts/tournament/roster.sh` reconciles that file against the world.

Run everything here from **WSL**, not Git Bash: `jq` is not on Git Bash's PATH on
this host and the scripts exit 2 without it.

## The one thing that will bite you

**Character names must be alphabetic, and at most 12 characters.** A digit is
rejected at character *load*, not at creation
(`CheckPlayerName` → `isValidString` with `numericOrSpace=false`,
`src/game/ObjectMgr.cpp:7051-7069`), and `PlayerbotMgr.cpp:2506` prints
`"Bot is now online"` before the login is even attempted. So a digit-named bot
looks like it logged in and instantly vanished, and leaves behind a row with
`at_login=1` that can never come online and has to be deleted by hand.

The generated name is `namePrefix` + the slot word (`one`…`ten`), so the *prefix*
being fine is not enough — `Sentinels` is alphabetic and 9 characters, but
`Sentinelsthree` is 14 and fails. `team-validate.sh` checks the generated names,
not the prefix. Do not bypass it.

Two more constraints worth knowing before you edit a team file:

- `rndbot` console replies go to a null player session and vanish. Nothing here
  infers success from console output — every write is verified by reading
  `tw_char.characters` afterwards, and you should do the same by hand.
- Console EOF shuts the world down (compose is `restart: "no"`). Every
  subcommand below batches all of its lines into a single `docker attach`, which
  is why there is a script instead of a paste block.

## Commands

```bash
./scripts/tournament/team-validate.sh                       # validate every team file
./scripts/tournament/roster.sh status  stormwind-sentinels  # read-only reconcile
./scripts/tournament/roster.sh ensure  stormwind-sentinels  # create what is missing
./scripts/tournament/roster.sh login   stormwind-sentinels  # bring the team online
./scripts/tournament/roster.sh logout  stormwind-sentinels  # take it offline (keeps characters)
```

All four refuse to run when `team-validate` would fail on that team.

### `status`

Read-only, and the only one of the four that touches the database — the other
three are defined in terms of its output. One line per slot:

```
<name> <exists|missing> <online|offline> <level> <at_login>
ROSTER <team-id> present=<n>/10 online=<n>/10 broken=<n>
```

A missing slot prints `-` for level and `at_login` rather than a `0` that would
read as a real measurement. **`status` always exits 0** — it reports, it does not
judge, so `broken=2` is a finding for you rather than a failed command. It issues
one query for the whole roster, so it is cheap enough to poll.

### `ensure [--login]`

Creates every missing character in one console batch, then polls
`tw_char.characters` until `present=10/10` or 120 s. `--login` asks the create to
log the bot in immediately.

It **refuses outright while any row is broken** (`at_login != 0`), even when
nothing is missing: those names were rejected at load, creating around them hides
the fault, and the fix is a hand-written `DELETE`. It prints `already complete`
and exits 0 when there is nothing to do, so it is safe to re-run.

### `login` / `logout`

`login` sends `rndbot add <name>` for each slot in one batch, then blocks until
`online=10/10` or 180 s. `logout` sends `rndbot remove <name>` for each slot;
**it never deletes a character row** — it is the between-rounds swap, not a
teardown, and the team has to still exist next round.

`characters.online` is written on save, so it trails reality by up to
`PlayerSave.Interval` (60 s). A `status` taken straight after `logout` can still
read `online` for slots that have already gone. Re-run `status` a minute later
before concluding anything.

## Adding a team

1. Copy an existing file in `config/tournament/teams/`, and change `id`,
   `displayName`, `namePrefix`, and the roster. `id` must match the filename.
2. `namePrefix` must be alphabetic, and must still produce names of at most 12
   characters once the slot words (`one`…`ten`) are appended.
3. The ten slots must be exactly `one two three four five six seven eight nine
   ten`, in that order — the name is prefix+slot, so a duplicate slot is a
   duplicate name, and the second create fails while the console says nothing.
4. Every race must be playable by the declared faction (`A`: Human, Dwarf,
   NightElf, Gnome; `H`: Orc, Undead, Tauren, Troll). Every role must be `tank`,
   `healer` or `dps`.
5. `./scripts/tournament/team-validate.sh <new-id>` must exit 0 **before** you
   run `ensure`.

Ten slots is not a knob: a bot account holds at most nine characters
(`PlayerbotMgr.cpp:2325`), so a team is deliberately not something a caller gets
to resize.

## After a mangosd restart

**The roster does not come back on its own.** The random bot pool re-logs its
own bots after a restart, but its login list does not include these — so every
slot reads `exists offline` until somebody asks for them. Run
`roster.sh login <team>` for whichever teams should be up, and confirm with
`status` rather than with the console.
