---
status: blocked
risk: medium
area: playerbots/transport
---

# getGameObjectsNear walks every GO spawn in the world on every call

**Hold — not a failed attempt.** Set to `blocked` on 2026-08-15 as a deliberate
scheduling hold, so `backlog-drain` does not pick it up while the drain is
focused solely on the bot-memory effort (artifact 011 and the optimization
artifacts its plan produces). This artifact is in `playerbots/transport`, not
`playerbots/memory`.

Nothing is wrong with it: it has never been attempted, has no `depends-on`, and
is a conventional code change that was ready to drain. `blocked` is used here
only because the artifact format has no "not yet, by choice" status —
`out-of-scope` would wrongly tell a future reader to scope a replacement
artifact instead of reopening this one, and `blocked` correctly stays out of
drain's two-consecutive-failure circuit breaker. **To resume: set
`status: pending` and delete this block.** Nothing else needs undoing.

Note also that `docs/backlog/README.md`'s required pilot run has still never
happened, and the `backlog-batch` `--env-file` fix is still untested — both are
prerequisites for any unattended drain, independent of this hold.

**Problem:** `WorldPosition::getGameObjectsNear` (and its creature twin) runs
`sObjectMgr.DoGOData(worker)`, which iterates the entire `m_GameObjectDataMap`
— every gameobject spawn in the world, not just the current map — and the
`FindPointGameObjectData` predicate always returns `false`, so the loop never
breaks early (`src/game/ObjectMgr.h:1234`).

The map, entry and radius arguments are all applied *inside* the predicate.
They decide which spawns land in the result vector; none of them shortens the
walk. So the cost is the same whether the caller asks for one entry within
200y or for everything on the map.

That walk sits under the elevator/tram fallback in
`WorldPosition::getTransports`, which `MovementAction::UseTransport` calls for
every bot waiting at a transport, every tick. With ~1000 bots this is a
meaningful CPU sink. Other hot callers exist:
`TravelNode.cpp:2417` (`getGameObjectsNear(0, entry)`) and
`RandomPlayerbotMgr.cpp:3017`.

This was originally filed as part of artifact 004 with the proposed fix "pass a
bounded radius instead of `0.0f`". That was withdrawn: a radius cannot fix
this (see above), and bounding the tram lookup actively broke it — callers pass
a *dock* position and select the nearest match themselves, and the six Deeprun
Tram cars sit in two clusters ~2460y apart on map 369, so a 200y filter hid
three of them from either platform.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/WorldPosition.cpp:1298-1310`
(`getCreaturesNear` / `getGameObjectsNear`), `:1287`
(`FindPointGameObjectData::operator()`), `src/game/ObjectMgr.h:1234`
(`DoGOData`).

**Acceptance criteria:**
- Looking up GO spawns by entry no longer walks the whole spawn map. Build an
  index (e.g. entry → spawn ids, or map+entry → spawn ids) once and query it,
  so an entry-filtered lookup is proportional to the number of matches.
- Results are unchanged for every existing caller: same spawns, no distance
  filtering introduced where callers relied on its absence. In particular
  `getTransports(entry)` from a dock position must still find a tram car
  ~2500y away on the same map.
- The index is populated from the same data `DoGOData` reads, and stays correct
  across the GM `.gobject add` / `.gobject delete` paths that mutate
  `m_GameObjectDataMap` (`NewGOData` / `DeleteGOData`) — either by updating the
  index there or by documenting and accepting the staleness explicitly.
- Thread safety is considered: map updates can run on multiple threads, so a
  lazily-built shared index needs to be either built once during load or
  guarded.

**Notes:** Per `docs/playerbots/BOT-TRANSPORT-INVESTIGATION.md` ("D2", the
paragraph on why a radius bound is the wrong fix). Split out of artifact 004,
which now fixes only the guid bug and the missing null check.

**Re-validated 2026-08-14** against `feature/loop-refinement`. The defect is
unchanged and the acceptance criteria still hold, but three things above are now
inaccurate or weaker than when this was filed:

1. **Line references have drifted.** The predicate is at `WorldPosition.cpp:1296`
   (not `:1287`); `getCreaturesNear`/`getGameObjectsNear` are at `:1307`/`:1314`
   (not `:1298-1310`); the `TravelNode` call is at `:2444` (not `:2417`).
   `ObjectMgr.h:1234` and `RandomPlayerbotMgr.cpp:3017` are still exact.
2. **The per-tick argument is narrower than stated.** This was filed while
   `Map::GetTransports` was the stub artifact 001 fixed. That fix landed
   (`Map.h:473`), so boats and zeppelins now match at
   `WorldPosition.cpp:575-577` and return before reaching the scan. The fallback
   fires only for type-11 elevators/trams or when the entry misses on the
   current map — a far smaller set of bots than "every bot waiting at a
   transport". Bots already *on* a transport never reach it either
   (`MovementActions.cpp:459-479`).
3. **The load-time cost is the stronger case, and this artifact underweights
   it.** `TravelNode.cpp:2444` does a full-map walk *once per transport path*
   inside elevator/tram node generation — O(paths x spawns) — and
   `TravelNode.cpp:2317`, `RandomPlayerbotMgr.cpp:3017` and `:3049` each add an
   unconditional full walk at graph generation. Note those callers pass
   `entry = 0` and want everything, so an entry index does not help them; they
   need their own treatment.

Two caveats on cost and sequencing: `m_GameObjectDataMap` is a
`robin_hood::unordered_map` (`ObjectMgr.h:288`) — flat open-addressing, so the
walk is a linear scan over a contiguous array rather than pointer-chasing, and
the constant factor is better than "meaningful CPU sink" implies. Nothing here
has been profiled, and nothing in the transport stack has been verified in-game,
so this optimizes a path not yet proven to work.

*Renumbered from `010` to `012` on 2026-08-14* so that
`011-bot-memory-baseline-and-investigation.md` drains first — the drain has no
priority field, only the numeric prefix, so reordering means renaming. There is
no artifact `010`; the gap is this move, not a deleted file. This artifact was
never picked up under either number. The dated plan documents under
`docs/superpowers/plans/` still refer to it as `010` in their historical
narrative, annotated in place.
