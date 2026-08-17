# CLAUDE.md

## Communication style

Be concise. Short, direct sentences, one idea each. Cut preamble, hedging, and
restatement of the question — lead with the answer.

## Explaining technical topics

Cover both layers, in-game first, then the mechanism behind it:

- **In-game** — what a player, GM, or bot actually sees or does in the world.
- **Technical** — the code, packet, DB table, or config that produces it.

Name the concrete thing on each side: the spell, quest, or bot behaviour on the
in-game side; the file, function, table, or `mangosd.conf` setting on the technical
side. Don't explain one layer and leave the other implied.

Example: "Bots stop casting mid-fight after ~20 minutes (in-game) because the
playerbot AI's spell cooldown map is keyed on a 32-bit tick that wraps, so every
cooldown reads as still-pending (technical)."
