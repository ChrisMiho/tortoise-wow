#!/usr/bin/env bash
# Bot ramp helper — run as deck in WSL
set -euo pipefail

# Two directories, two jobs — do not collapse them.
#
# ROOT is the live stack dir. It owns etc/aiplayerbot.conf (bind-mounted into
# the container, so editing it here is what the server actually reads) and
# .dbpass. It also contains an OLD docker-compose.yml for the retired
# tortoise-wow-v2 project with tw2-* containers.
#
# REPO is this checkout, and it owns the compose project this stack now runs
# under: tortoise-cm, with tcm-* containers. Running `docker compose` from ROOT
# would drive the retired project — the config edit would land correctly and
# then the restart would target containers that no longer exist, so the ramp
# would silently measure a server that never picked up the new bot count.
ROOT="${TW_STACK_ROOT:-/home/deck/tortoise-wow-server-V2}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: bot-ramp.sh <bot-count> [apply|gates [--csv FILE] [--note TXT]|wait [threshold] [timeout_sec]|csv FILE [--note TXT]]}"
MODE="${2:-apply}"  # apply | wait | gates | csv

# <bot-count> is ONE integer, applied to both Min and MaxRandomBots — it is not
# a "min/max" pair, which the old usage string invited. A literal `200/200`
# would be spliced into apply's `sed "s/^...= .*/... = ${TARGET}/"` and break
# the s/// delimiter, and the same value would reach the CSV unquoted in a
# column every reader parses as a number.
[[ "$TARGET" =~ ^[0-9]+$ ]] \
  || { echo "FATAL: bot count must be a plain integer (one value for both Min and Max), got: $TARGET" >&2; exit 1; }

[ -f "$ROOT/etc/aiplayerbot.conf" ] || { echo "FATAL: no aiplayerbot.conf under $ROOT/etc — set TW_STACK_ROOT" >&2; exit 1; }
[ -f "$REPO/docker-compose.yml" ]   || { echo "FATAL: no docker-compose.yml at $REPO" >&2; exit 1; }

# Read AFTER the guards above, not before: with a wrong $ROOT this would
# otherwise die on a bare `tr: .../.dbpass: No such file or directory` and the
# friendly "set TW_STACK_ROOT" FATAL would never print.
PASS=$(tr -d '\r\n' < "$ROOT/.dbpass")

# Every compose call goes through this, never a bare `docker compose`.
compose() { docker compose --project-directory "$REPO" "$@"; }

# The `cd "$ROOT"` below is load-bearing: apply's sed/grep and show_gates' dials
# grep all address the conf as the relative `etc/aiplayerbot.conf`. But it also
# silently re-bases any relative path the OPERATOR typed. The documented
# invocation is `--csv docs/playerbots/ramp-2026-08-14.csv`, which after the cd
# resolves against the live stack dir — a directory with no docs/ — so the
# write fails with one error line buried under a screenful of gates output, and
# a plateau that took 40 minutes to reach is gone. Worse, if that path ever did
# exist there, rows would land silently in the DIVERGED checkout.
# So: remember where we came from, and resolve operator paths against it.
INVOKED_FROM="$PWD"
cd "$ROOT"

# Resolve an operator-supplied path against the invoking cwd, not $ROOT.
# Absolute paths pass through untouched.
resolve_from_invocation() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s\n' "$INVOKED_FROM/$1" ;;
  esac
}

# lib/provenance.sh gives us the running image's stamped revision for the CSV
# `image_rev` column. Sourced (not re-derived) per the 011 instruction to reuse
# what already exists there rather than writing a parallel implementation.
# shellcheck source=lib/provenance.sh
. "$REPO/scripts/lib/provenance.sh"

online_count() {
  # tr -d '\r': mysql's output through `docker exec` can carry a trailing \r
  # (wait-rndbots-online.sh already stripped this). Left in, it silently
  # fails wait mode's ^[0-9]+$ REACHED check and would land in the CSV row
  # unstripped, where a stray \r mid-record is a row-splitting hazard for
  # any CSV reader.
  docker exec -e MYSQL_PWD="$PASS" tcm-db mysql -uroot -N -B -e \
    "SELECT COUNT(*) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%' AND c.online=1;" \
    | tr -d '\r'
}

# Every section below is individually guarded (`|| true`) rather than left to
# a single failure under `set -e`: `gates --csv` (this task) writes its CSV
# row only after this function returns, so one hiccup here must not both
# blank the rest of the human-readable dump AND lose the sample. The operator
# still wants to see whichever sections did resolve.
show_gates() {
  local hf
  echo "=== WSL free ==="
  free -h || true
  # 011 makes host free >= 4 GB the TIGHT stop gate (the VM holds 24 of the
  # host's 32 GB) and requires it reported "at every ramp point". `free` above
  # is the VM only and cannot see it, and until now host_free_bytes() was
  # reached solely from csv_row — so the dump the operator actually reads to
  # decide whether to continue omitted the one gate most likely to bind.
  # Best-effort like everything else here: host_free_bytes() already timeouts
  # its PowerShell interop and always returns 0, and the awk is `|| true`, so
  # this section can print "unknown" but can never abort or hang `gates`.
  # (host_free_bytes is defined below with the rest of the samplers; bash
  # resolves it at call time and gates only ever runs from the case block.)
  echo "=== host free ==="
  hf=$(host_free_bytes) || hf=""
  if [[ "$hf" =~ ^[0-9]+$ ]]; then
    awk -v b="$hf" 'BEGIN {
      g = b / 1073741824
      printf "Windows host free: %.2f GiB%s\n", g, (g < 4 ? "   <-- LOW: stop gate is >= 4 GiB" : "")
    }' || true
  else
    echo "Windows host free: unknown (interop unavailable) — check Task Manager before continuing"
  fi
  echo "=== docker stats ==="
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' || true
  echo "=== compose ps ==="
  compose ps || true
  echo "=== online RNDBOT ==="
  online_count || true
  echo "=== dials ==="
  grep -E '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer' \
    etc/aiplayerbot.conf || true
}

# --------------------------------------------------------------- CSV plumbing
#
# Every function below is best-effort: under `set -euo pipefail`, a bare
# failing command substitution would kill the whole script, but a single flaky
# read (mangosd mid-restart, a PowerShell hiccup) must not abort a ramp point
# that may have taken 40 minutes to reach. Each function guards its own
# commands with `|| var=""` / regex validation and always returns 0.

# 14 columns. The schema is fixed NOW, before the baseline exists, because
# these rows must stay comparable against a 2000/3000-bot run months from now
# and adding a column after the fact is the expensive case (011, *Scope*).
#
#   schema_version  — first, so a reader can branch on it before trusting any
#                     other column. Bump it whenever this list changes.
#   configured_bots — what the CONF holds, distinct from target_bots, which is
#                     only what the operator typed on the command line.
CSV_SCHEMA_VERSION=1
CSV_COLUMNS="schema_version,timestamp_utc,image_rev,target_bots,configured_bots,online_bots,mangosd_rss_bytes,mem_source,vm_total_bytes,vm_available_bytes,host_free_bytes,container_restarts,oom_killed,notes"

csv_header() {
  printf '%s\n' "$CSV_COLUMNS"
}

# Minimal RFC 4180 quoting for the free-text --note field: double any embedded
# quote and wrap in quotes. The other columns are numbers or fixed tokens and
# never contain a comma, so only notes needs this.
csv_quote() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

# The revision the running image was built from. Best-effort: empty field if
# mangosd isn't running or the image predates provenance stamping —
# prov_image_label() already returns "" rather than failing in that case, so
# only prov_running_image_id() (a bare `docker inspect`) needs guarding here.
# Hardcodes tcm-mangosd rather than provenance.sh's $TW_MANGOSD on purpose:
# every other Docker call in this file (mangosd_pid, mangosd_vmrss_kb,
# sample_mangosd_rss, container_restarts, oom_killed, wait's status check)
# hardcodes the literal container name. An overridden $TW_MANGOSD would make
# this one field silently report a different container's image revision
# beside the rest of the row's RSS/restart/OOM data for tcm-mangosd.
csv_image_rev() {
  local image_id
  image_id=$(prov_running_image_id "tcm-mangosd") || image_id=""
  [ -n "$image_id" ] || { echo ""; return 0; }
  prov_image_label "$image_id" "$PROV_LABEL_REV"
}

# Find the mangosd PID inside tcm-mangosd's own PID namespace. PID 1 there is
# tini (see Dockerfile ENTRYPOINT) which reaps zombies and is not the process
# whose memory we want, so this walks /proc rather than assuming a fixed PID.
# Pure shell + `cat` only: the runtime image is debian-slim and has no `ps`.
mangosd_pid() {
  docker exec tcm-mangosd sh -c '
    for f in /proc/[0-9]*/comm; do
      c=$(cat "$f" 2>/dev/null) || continue
      case "$c" in
        mangosd)
          p="${f#/proc/}"
          printf "%s" "${p%/comm}"
          exit 0
          ;;
      esac
    done
    exit 1
  ' 2>/dev/null
}

# VmRSS in kB for a PID inside tcm-mangosd, read from /proc/<pid>/status. The
# pid travels as an env var (docker exec -e) rather than being interpolated
# into the script text, so it can't break the quoting.
mangosd_vmrss_kb() {
  docker exec -e MRSS_PID="$1" tcm-mangosd sh -c '
    while read -r key val _; do
      case "$key" in
        VmRSS:) printf "%s" "$val"; exit 0 ;;
      esac
    done < "/proc/$MRSS_PID/status"
    exit 1
  ' 2>/dev/null
}

# Convert docker stats' `{{.MemUsage}}` (e.g. "4.67GiB / 23.5GiB") to integer
# bytes for the used side, before " / ". This is the fallback source only —
# see sample_mangosd_rss for why VmRSS is preferred when it's available.
parse_memusage_bytes() {
  local raw="${1:-}" used val unit mult
  used="${raw%% / *}"
  used="${used// /}"
  [[ "$used" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]+)$ ]] || return 1
  val="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]}"
  case "$unit" in
    B)   mult=1 ;;
    KiB) mult=1024 ;;
    MiB) mult=$((1024 * 1024)) ;;
    GiB) mult=$((1024 * 1024 * 1024)) ;;
    TiB) mult=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  awk -v v="$val" -v m="$mult" 'BEGIN { printf "%.0f\n", v * m }'
}

# Sets RSS_BYTES and RSS_SOURCE ("vmrss" or "dockerstats"; both empty if
# everything failed). Never exits non-zero, so it is safe to call bare under
# `set -e`. Prefers true RSS from /proc/<pid>/status inside the container;
# falls back to `docker stats` MemUsage, which is cache-inclusive and
# therefore worse for a memory investigation but works even without a PID.
sample_mangosd_rss() {
  RSS_BYTES=""
  RSS_SOURCE=""

  local pid kb
  pid=$(mangosd_pid) || pid=""
  if [ -n "$pid" ]; then
    kb=$(mangosd_vmrss_kb "$pid") || kb=""
    if [[ "$kb" =~ ^[0-9]+$ ]]; then
      RSS_BYTES=$((kb * 1024))
      RSS_SOURCE="vmrss"
      return 0
    fi
  fi

  local memusage bytes
  memusage=$(docker stats --no-stream --format '{{.MemUsage}}' tcm-mangosd 2>/dev/null) || memusage=""
  if [ -n "$memusage" ]; then
    bytes=$(parse_memusage_bytes "$memusage") || bytes=""
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
      RSS_BYTES="$bytes"
      RSS_SOURCE="dockerstats"
    fi
  fi
  return 0
}

# Sets VM_TOTAL_BYTES and VM_AVAIL_BYTES from `free -b` — the WSL VM, not the
# Windows host (see host_free_bytes for that). Best-effort: empty on failure.
vm_free_bytes() {
  VM_TOTAL_BYTES=""
  VM_AVAIL_BYTES=""
  local line
  line=$(free -b 2>/dev/null | awk '/^Mem:/{print $2, $7}') || line=""
  if [[ "$line" =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    VM_TOTAL_BYTES="${BASH_REMATCH[1]}"
    VM_AVAIL_BYTES="${BASH_REMATCH[2]}"
  fi
  return 0
}

# The Windows host's free physical memory, in bytes — `free` inside WSL cannot
# see this, and 011 requires it because the host's ~8 GB is now the tight stop
# gate against the VM's 24 GB. Best-effort via PowerShell interop: any failure
# here (interop disabled, powershell.exe missing, a hiccup) yields an empty
# field and must never abort the sample.
#
# Note on the metric: FreePhysicalMemory is Windows "Free" memory, not
# "Available" (Free + Standby cache) — it reads several GB below what Task
# Manager's "Available" column shows for the same instant. That's the
# conservative direction for a stop gate (it never overstates headroom), so
# it's left as-is; this is a heads-up for whoever cross-checks a low reading
# against Task Manager and finds the numbers don't match, not a bug.
host_free_bytes() {
  local kb
  # 15s timeout: powershell.exe can't abort the sample on its own, but it CAN
  # hang it — and WSL<->Windows interop stalling under host memory pressure is
  # exactly the condition this gate exists to detect, so an unbounded call
  # here could turn "gate tripped" into "script hung" at the worst moment.
  # `timeout`'s exit 124 on expiry is already caught by the `|| kb=""` below.
  kb=$(timeout 15 powershell.exe -NoProfile -Command \
    '(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory' 2>/dev/null | tr -d '\r') || kb=""
  [[ "$kb" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo $((kb * 1024))
}

# What the conf actually holds for MaxRandomBots, as opposed to `target_bots`
# which is $TARGET from argv — i.e. what the operator TYPED, never what the
# server is running. Without this column a `gates 400` taken after an
# `apply 400` that silently didn't take is indistinguishable from a real one:
# the row claims 400 while the server ran 200, and nothing in the data says so.
# Reads the relative path like the rest of this script (see `cd "$ROOT"`).
# Best-effort: empty field on any failure, like its neighbours.
configured_bots() {
  local line v
  line=$(grep -m1 -E '^AiPlayerbot\.MaxRandomBots[[:space:]]*=' etc/aiplayerbot.conf 2>/dev/null) || { echo ""; return 0; }
  v="${line#*=}"
  v="${v//[[:space:]]/}"
  [[ "$v" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo "$v"
}

# Stop gate: "no ... container restarts" (011). Best-effort: empty field if
# the container is gone rather than aborting the sample. Note this alone
# can't distinguish a routine restart from an OOM kill — see oom_killed().
container_restarts() {
  local n
  n=$(docker inspect -f '{{.RestartCount}}' tcm-mangosd 2>/dev/null) || { echo ""; return 0; }
  [[ "$n" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo "$n"
}

# Stop gate: "no Docker OOM" (011), split from container_restarts() because
# they answer different questions. mangosd is `restart: unless-stopped` in
# docker-compose.yml AND deliberately exits 0 to trigger its own restart
# (AutoHonorRestart=1 in mangosd.conf, expecting Docker as the supervisor —
# see docker-compose.yml's mangosd comment), so RestartCount climbing during
# a healthy ramp is normal and cannot by itself evidence an OOM kill.
# Best-effort: empty field if the container is gone.
oom_killed() {
  local v
  v=$(docker inspect -f '{{.State.OOMKilled}}' tcm-mangosd 2>/dev/null) || { echo ""; return 0; }
  case "$v" in
    true|false) echo "$v" ;;
    *) echo "" ;;
  esac
}

# One CSV row for the current instant. $TARGET and $CSV_NOTE come from the
# script's own arguments; everything else is sampled fresh.
csv_row() {
  local ts img_rev conf_bots online host_free restarts oom note
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  img_rev=$(csv_image_rev) || img_rev=""
  conf_bots=$(configured_bots)
  online=$(online_count 2>/dev/null) || online=""
  # Same regex validation every other field gets, even though online_count()
  # now strips \r at the source — cheap insurance against anything else
  # non-numeric (an SQL error slipping onto stdout, say) landing in the row.
  [[ "$online" =~ ^[0-9]+$ ]] || online=""
  sample_mangosd_rss
  vm_free_bytes
  host_free=$(host_free_bytes)
  restarts=$(container_restarts)
  oom=$(oom_killed)
  note=$(csv_quote "${CSV_NOTE:-}")

  # 14 fields, in $CSV_COLUMNS order. Keep this printf, $CSV_COLUMNS and every
  # doc that quotes the column set in lockstep.
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$CSV_SCHEMA_VERSION" "$ts" "$img_rev" "$TARGET" "$conf_bots" "$online" \
    "$RSS_BYTES" "$RSS_SOURCE" "$VM_TOTAL_BYTES" "$VM_AVAIL_BYTES" \
    "$host_free" "$restarts" "$oom" "$note"
}

# Last resort for a sample that cannot reach its file. A ramp point can cost
# 40 minutes of waiting, so the row goes to stderr with its header rather than
# being lost — the operator can paste it out of scrollback.
csv_rescue() {
  echo "  The sample itself is NOT lost. Copy these two lines out of scrollback:" >&2
  printf '%s\n' "$CSV_COLUMNS" >&2
  printf '%s\n' "$1" >&2
}

# Emit the header only the first time a given file is created, then append
# bare rows thereafter — a whole ramp accumulates into one file across many
# invocations of this script.
csv_write() {
  local file existing row

  # Relative means "relative to where the operator ran this", not to $ROOT.
  file=$(resolve_from_invocation "$1")

  # Sample BEFORE attempting any write, so a failing write can still hand the
  # row back on stderr instead of discarding it.
  row=$(csv_row)

  # The documented path is docs/playerbots/<file>.csv, a directory that may not
  # exist yet on a fresh checkout or under a --csv path the operator invented.
  # Failure here is not fatal on its own — the write below reports it properly.
  mkdir -p "$(dirname "$file")" 2>/dev/null || true

  # -s, not -f: an existing but EMPTY file (e.g. `touch out.csv` before the
  # first ramp point) must still get a header, or every row written after it
  # is headerless forever.
  if [ -s "$file" ]; then
    # Schema guard. If a later version of this script adds a column and appends
    # to a file written by this one, every new row is silently misaligned
    # against the existing header and nothing downstream can detect it. These
    # rows exist to be compared against a run months from now, so refuse.
    existing=$(head -n 1 "$file" | tr -d '\r') || existing=""
    if [ "$existing" != "$CSV_COLUMNS" ]; then
      echo "FATAL: CSV schema mismatch — refusing to append to $file" >&2
      echo "  expected: $CSV_COLUMNS" >&2
      echo "  found:    $existing" >&2
      echo "  Write this run to a NEW file, or migrate the old one deliberately." >&2
      csv_rescue "$row"
      exit 1
    fi
  elif ! csv_header > "$file"; then
    echo "FATAL: cannot write CSV header to $file" >&2
    csv_rescue "$row"
    exit 1
  fi

  if printf '%s\n' "$row" >> "$file"; then
    echo "csv: appended sample to $file"
  else
    echo "FATAL: cannot append the sample to $file" >&2
    csv_rescue "$row"
    exit 1
  fi
}

case "$MODE" in
  gates)
    CSV_FILE=""
    CSV_NOTE=""
    EXTRA=("${@:3}")
    i=0
    while [ "$i" -lt "${#EXTRA[@]}" ]; do
      case "${EXTRA[$i]}" in
        --csv)
          i=$((i + 1))
          CSV_FILE="${EXTRA[$i]:?--csv requires a file path}"
          ;;
        --note)
          i=$((i + 1))
          CSV_NOTE="${EXTRA[$i]:?--note requires text}"
          ;;
        *)
          echo "unknown gates option: ${EXTRA[$i]}" >&2
          exit 1
          ;;
      esac
      i=$((i + 1))
    done
    show_gates
    # `if`, not `&&`: with CSV_FILE empty, an AND-list's exit status IS its
    # left operand's — [ -n "" ] is 1, and that becomes the whole script's
    # exit status even though everything above succeeded. `gates` with no
    # --csv must exit 0 on a clean run, not silently read as failure to
    # anything chaining ramp steps with && or running under set -e.
    if [ -n "$CSV_FILE" ]; then
      csv_write "$CSV_FILE"
    fi
    ;;
  csv)
    CSV_FILE="${3:?usage: bot-ramp.sh <bot-count> csv <file> [--note TXT]}"
    CSV_NOTE=""
    EXTRA=("${@:4}")
    i=0
    while [ "$i" -lt "${#EXTRA[@]}" ]; do
      case "${EXTRA[$i]}" in
        --note)
          i=$((i + 1))
          CSV_NOTE="${EXTRA[$i]:?--note requires text}"
          ;;
        *)
          echo "unknown csv option: ${EXTRA[$i]}" >&2
          exit 1
          ;;
      esac
      i=$((i + 1))
    done
    csv_write "$CSV_FILE"
    ;;
  wait)
    # Merged with the former wait-rndbots-online.sh: threshold/timeout stay
    # task3's positional contract, but timeout is now SECONDS (not
    # iterations), polling is every 10s (wait-rndbots-online's cadence, not
    # task3's 30s), and BLOCKED detection is wait-rndbots-online's — mangosd
    # not "running" after a 3-poll grace period, since it legitimately
    # restarts right after `apply`.
    THRESH="${3:-90}"
    TIMEOUT_SEC="${4:-900}"
    # NOTE: REACHED means "the online count crossed $THRESH", NOT "RSS has
    # plateaued". Bot inventory/talent construction continues well past login.
    # See the handoff's §5 for the sampling procedure that turns this into a
    # plateau before a ramp row is taken.
    #
    # mangosd deliberately exits 0 to trigger its own Docker-supervised restart
    # (AutoHonorRestart=1; see docker-compose.yml's mangosd comment and
    # oom_killed() below), so a poll can legitimately land in the seconds-long
    # restarting/exited window. One such poll used to abort the whole wait.
    # Require $BLOCKED_LIMIT CONSECUTIVE non-running polls (~30s at the 10s
    # cadence) so BLOCKED keeps meaning "it is not coming back".
    BLOCKED_STREAK=0
    BLOCKED_LIMIT=3
    echo "Waiting for online RNDBOT >= $THRESH (timeout ${TIMEOUT_SEC}s)..."
    start=$(date +%s)
    poll=0
    while true; do
      poll=$((poll + 1))
      status=$(docker inspect -f '{{.State.Status}}' tcm-mangosd 2>/dev/null) || status="missing"
      n=$(online_count 2>/dev/null) || n=""
      now=$(date +%s)
      elapsed=$((now - start))
      echo "$(date +%H:%M:%S) status=$status online=${n:-err} elapsed=${elapsed}s"
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge "$THRESH" ]; then
        echo "REACHED online=$n"
        show_gates
        exit 0
      fi
      if [ "$status" != "running" ]; then
        BLOCKED_STREAK=$((BLOCKED_STREAK + 1))
      else
        BLOCKED_STREAK=0
      fi
      # The `poll > 3` grace period is kept on top of the streak: `wait` is run
      # straight after `apply`, whose restart is expected to be in flight.
      if [ "$BLOCKED_STREAK" -ge "$BLOCKED_LIMIT" ] && [ "$poll" -gt 3 ]; then
        echo "BLOCKED: mangosd status=$status for $BLOCKED_STREAK consecutive polls"
        exit 2
      fi
      if [ "$elapsed" -ge "$TIMEOUT_SEC" ]; then
        echo "TIMEOUT online=${n:-err} (wanted >= $THRESH)"
        show_gates
        exit 1
      fi
      sleep 10
    done
    ;;
  apply)
    echo "Setting Min/MaxRandomBots = $TARGET"
    sed -i "s/^AiPlayerbot.MinRandomBots = .*/AiPlayerbot.MinRandomBots = ${TARGET}/" etc/aiplayerbot.conf
    sed -i "s/^AiPlayerbot.MaxRandomBots = .*/AiPlayerbot.MaxRandomBots = ${TARGET}/" etc/aiplayerbot.conf
    # Post-condition, BEFORE the restart. Both `sed -i` calls above exit 0
    # whether or not they matched anything, and the human-readable grep below
    # asserts nothing — it still succeeds on the DisableActivityPriorities /
    # botActiveAlone alternates even if both RandomBots lines are absent or
    # reformatted. Without these two checks a non-matching sed restarts mangosd
    # and reports success while the server keeps the OLD bot count, and every
    # sample taken afterwards is labelled with a value the server never ran.
    # 011 explicitly authorises repeated manual conf edits, so this is one
    # hand-edit away from firing.
    # -F: the pattern is a literal line, not a regex (those dots are dots).
    # Spacing matches the live conf exactly: "AiPlayerbot.MinRandomBots = 40".
    grep -qxF "AiPlayerbot.MinRandomBots = ${TARGET}" etc/aiplayerbot.conf \
      || { echo "FATAL: MinRandomBots not set to $TARGET in $ROOT/etc/aiplayerbot.conf — mangosd NOT restarted" >&2; exit 1; }
    grep -qxF "AiPlayerbot.MaxRandomBots = ${TARGET}" etc/aiplayerbot.conf \
      || { echo "FATAL: MaxRandomBots not set to $TARGET in $ROOT/etc/aiplayerbot.conf — mangosd NOT restarted" >&2; exit 1; }
    grep -E '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer' \
      etc/aiplayerbot.conf
    echo "Restarting mangosd..."
    compose restart mangosd
    sleep 5
    compose ps
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 1
    ;;
esac
