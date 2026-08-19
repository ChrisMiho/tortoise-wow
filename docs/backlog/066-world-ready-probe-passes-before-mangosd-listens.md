---
status: done
risk: low
area: ops/validation
depends-on:
---

# The world-ready probe passes before mangosd listens, so validate-stack fails a good image

**Problem:** `validate-stack.sh` reported
`VALIDATE-STACK: FAIL LIVENESS — no characters came online within 300s` against
`tortoise-cm:eed1053`, an image that is fine. Bots were logging in normally: a
cold boot of that same image had 717 characters online at the first poll after
the world opened, plateauing at 1017.

The window was measuring the wrong interval. `prov_world_ready` was a host-side
`nc -z -w 3 127.0.0.1 8095`, and Docker's proxy binds the published host port
the instant the container starts — long before mangosd binds inside it. Measured
2026-08-18 on a warm boot, polling both ends every 5s:

```
t=6s   host_nc=YES  in_container_nc=no
...
t=57s  host_nc=YES  in_container_nc=YES
```

So gate 3a passed at t=6s and gate 3b started its 300s bot stopwatch there,
while the world was still loading. On a warm boot the slack absorbs it (bots at
67s, comfortably inside). On the first boot straight off a freshly built 2.3 GiB
image — cold page cache, layers and map data read from disk — world load ran
past the 305s mark and the gate blamed the bots.

Compounding it, `prov_online_count` sent both the `.dbpass` read and the query
to `/dev/null`, so an unreadable password file, a stopped `tcm-db` and a
genuinely empty world were all the same silent `0`. That is the trap
`wsg_mysql` has, and it is why the first FAIL gave no hint that the query itself
was healthy.

**Suspected cause / area:** `scripts/lib/provenance.sh` — `prov_world_ready`
(host-side probe) and `prov_online_count` (discarded stderr); the two windows in
`scripts/validate-stack.sh`.

**Acceptance criteria:**

- `prov_world_ready` returns false while mangosd is still loading. Verified by
  polling from container start: false at t=7s, true at t=58s, matching the
  in-container listen time rather than the docker-proxy bind at t=6s.
- With the stack down, `prov_world_ready` is false rather than true.
- `prov_online_count` writes the reason to stderr when it cannot get a count,
  and still prints a numeric `0` so callers keep their contract. Verified with
  no container running: `prov_online_count: query failed (rc=1): Error response
  from daemon: No such container: tcm-db`.
- The cold-boot world load is charged to the world-port window, not the bot
  window. That window is now `TW_WORLD_WINDOW` (default 900s); the bot window
  stays 300s and starts from a real world-ready.
- `./scripts/validate-stack.sh --image tortoise-cm:local` ends in
  `VALIDATE-STACK: PASS`.

**Notes:**

- No build needed — shell only. But `validate-stack`'s gate 1 compares the
  image's stamped revision against `HEAD`, so running it on a branch that has
  commits past the built image reports provenance DRIFT. Rebuild, or validate
  from the commit the image was built at.
- `scripts/standup-1000.sh` calls both helpers (lines 151, 250, 310) and gets
  the same correction for free; it was subject to the identical false-ready.
- `netcat-openbsd` is already installed in the runtime image (`Dockerfile:72`),
  so the in-container probe needs no image change.
