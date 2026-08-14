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
TARGET="${1:?usage: bot-ramp.sh <min/max> [apply|gates [--csv FILE] [--note TXT]|wait [threshold] [timeout_sec]|csv FILE [--note TXT]]}"
MODE="${2:-apply}"  # apply | wait | gates | csv
PASS=$(tr -d '\r\n' < "$ROOT/.dbpass")

[ -f "$ROOT/etc/aiplayerbot.conf" ] || { echo "FATAL: no aiplayerbot.conf under $ROOT/etc — set TW_STACK_ROOT" >&2; exit 1; }
[ -f "$REPO/docker-compose.yml" ]   || { echo "FATAL: no docker-compose.yml at $REPO" >&2; exit 1; }

# Every compose call goes through this, never a bare `docker compose`.
compose() { docker compose --project-directory "$REPO" "$@"; }

cd "$ROOT"

# lib/provenance.sh gives us the running image's stamped revision for the CSV
# `image_rev` column. Sourced (not re-derived) per the 011 instruction to reuse
# what already exists there rather than writing a parallel implementation.
# shellcheck source=lib/provenance.sh
. "$REPO/scripts/lib/provenance.sh"

online_count() {
  docker exec -e MYSQL_PWD="$PASS" tcm-db mysql -uroot -N -B -e \
    "SELECT COUNT(*) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%' AND c.online=1;"
}

show_gates() {
  echo "=== WSL free ==="
  free -h
  echo "=== docker stats ==="
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
  echo "=== compose ps ==="
  compose ps
  echo "=== online RNDBOT ==="
  online_count
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

CSV_COLUMNS="timestamp_utc,image_rev,target_bots,online_bots,mangosd_rss_bytes,mem_source,vm_total_bytes,vm_available_bytes,host_free_bytes,container_restarts,notes"

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
csv_image_rev() {
  local image_id
  image_id=$(prov_running_image_id "$TW_MANGOSD") || image_id=""
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
host_free_bytes() {
  local kb
  kb=$(powershell.exe -NoProfile -Command \
    '(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory' 2>/dev/null | tr -d '\r') || kb=""
  [[ "$kb" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo $((kb * 1024))
}

# Stop gate: "no Docker OOM or container restarts" (011). Best-effort: empty
# field if the container is gone rather than aborting the sample.
container_restarts() {
  local n
  n=$(docker inspect -f '{{.RestartCount}}' tcm-mangosd 2>/dev/null) || { echo ""; return 0; }
  [[ "$n" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
  echo "$n"
}

# One CSV row for the current instant. $TARGET and $CSV_NOTE come from the
# script's own arguments; everything else is sampled fresh.
csv_row() {
  local ts img_rev online host_free restarts note
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  img_rev=$(csv_image_rev)
  online=$(online_count 2>/dev/null) || online=""
  sample_mangosd_rss
  vm_free_bytes
  host_free=$(host_free_bytes)
  restarts=$(container_restarts)
  note=$(csv_quote "${CSV_NOTE:-}")

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$img_rev" "$TARGET" "$online" "$RSS_BYTES" "$RSS_SOURCE" \
    "$VM_TOTAL_BYTES" "$VM_AVAIL_BYTES" "$host_free" "$restarts" "$note"
}

# Emit the header only the first time a given file is created, then append
# bare rows thereafter — a whole ramp accumulates into one file across many
# invocations of this script.
csv_write() {
  local file="$1"
  if [ ! -f "$file" ]; then
    csv_header > "$file"
  fi
  csv_row >> "$file"
  echo "csv: appended sample to $file"
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
    [ -n "$CSV_FILE" ] && csv_write "$CSV_FILE"
    ;;
  csv)
    CSV_FILE="${3:?usage: bot-ramp.sh <min/max> csv <file> [--note TXT]}"
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
      if [ "$status" != "running" ] && [ "$poll" -gt 3 ]; then
        echo "BLOCKED: mangosd status=$status"
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
