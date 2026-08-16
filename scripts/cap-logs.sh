#!/usr/bin/env bash
# Cap the server's on-disk log growth at roughly 500 MB total.
#
# Run from WSL:   sudo ./scripts/cap-logs.sh
#                 ./scripts/cap-logs.sh --dry-run    # show what would be written
#
# Idempotent: safe to re-run after changing TW_LOGS or the sizes below.
#
# This covers only the logs mangosd/realmd WRITE THEMSELVES into TW_LOGS. The
# containers' stdout/stderr is a separate, second unbounded stream handled by the
# `logging:` block in docker-compose.yml — the two together are the 500 MB budget,
# and neither one alone is enough. See docs/DOCKER.md.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Same MSYS guard as rebuild.sh, and for the same reason: this writes to /etc and
# reads a POSIX path out of .env. Git Bash would rewrite both into C:\ paths.
[ -z "${MSYSTEM:-}" ] \
  || { echo "FATAL: run this from WSL, not Git Bash (MSYSTEM=$MSYSTEM)." >&2; exit 1; }

# ---------------------------------------------------------------- the budget
#
# bots.log is the whole problem. Measured at 22.6 MB/min with bots active
# (~32 GB/day) — docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md §1. Every other file
# in that directory is in the low megabytes.
#
# Size-based rotation only rotates WHEN LOGROTATE RUNS, so the ceiling is
# threshold + (write rate x cron interval), NOT the threshold. That second term
# dominates here and is why the interval matters more than the size:
#
#   50 MB threshold + (22.6 MB/min x 5 min) = ~163 MB peak live file
#   + 2 compressed generations of highly repetitive trace text (~10 MB each)
#   = ~183 MB for the bots.log family
#
# Everything else in TW_LOGS rotates on the same rule but never approaches it,
# so realistic steady state is ~220 MB on disk. With docker-compose.yml's
# 3 services x 20 MB x 2 files = 120 MB, the total lands near 340 MB — under the
# 500 MB target with room for the CSVs and any log file added later.
#
# The distro's own logrotate.timer fires ONCE A DAY. At this write rate that is
# ~32 GB between checks, so the daily run is useless here and this script
# installs its own cron entry instead.
ROTATE_SIZE="50M"
ROTATE_KEEP=2
CRON_MINUTES=5

# ------------------------------------------------- what the rotation misses
#
# Two categories are not covered by the *.log rotation above, for two different
# reasons. Measured 2026-08-16: together they were 314 MB of the 491 MB on disk
# — most of the budget, sitting in files nothing was ever going to reclaim.
#
# server_<timestamp>.log — mangosd writes a NEW FILENAME on every start.
# logrotate does cap each one at ROTATE_SIZE, but `rotate N` only ever applies
# within a single filename, so a restart simply begins a fresh 17-44 MB file and
# every previous one stays forever. That is a prune, not a rotation: keep the
# newest N and delete the rest. It matters more now than it did, because agents
# restart the stack unattended and each cycle leaves another one behind.
KEEP_BOOT_LOGS=3

# *.csv — not matched by the *.log glob at all, so travel_telemetry.csv had
# reached 64 MB unchecked, the single largest file in the directory.
#
# copytruncate costs these their header row: the server writes it once at
# startup (PlayerbotAI.cpp), so after a rotation the live file starts mid-record
# until the next restart. Accepted deliberately — the header survives in the
# compressed generation, and the alternative is unbounded growth.
CSV_ROTATE_SIZE="25M"
CSV_ROTATE_KEEP=1

# TW_LOGS is the single source of truth for where logs live; docker-compose.yml
# bind-mounts it to /opt/turtle/logs. Read it rather than hardcoding a path, so
# this script is not specific to one machine.
[ -f .env ] || { echo "FATAL: no .env in $REPO. Copy .env.example and set TW_LOGS." >&2; exit 1; }
LOGS="$(sed -n 's/^[[:space:]]*TW_LOGS[[:space:]]*=[[:space:]]*//p' .env | tr -d '"'"'"'\r' | head -1)"
[ -n "$LOGS" ] || { echo "FATAL: TW_LOGS is not set in .env." >&2; exit 1; }
[ -d "$LOGS" ] || { echo "FATAL: TW_LOGS=$LOGS is not a directory." >&2; exit 1; }

command -v logrotate >/dev/null 2>&1 \
  || { echo "FATAL: logrotate is not installed. apt-get install logrotate" >&2; exit 1; }

# Deliberately NOT /etc/logrotate.d/. A file dropped there is picked up by the
# system's daily run too, and worse, our 5-minute cron would then rotate every
# system log 288 times a day. Standalone config + its own status file keeps this
# cron entry touching nothing but the server's logs.
CONF=/etc/logrotate.turtle.conf
STATUS=/var/lib/logrotate/turtle.status
# NO DOTS in a cron.d filename — cron silently ignores files containing them,
# and the failure mode is a config that looks installed and never runs.
CRON=/etc/cron.d/turtle-logrotate
# cron runs logrotate AND the boot-log prune, so it calls one helper rather than
# carrying a pipeline inline. That is not tidiness: cron treats % as a newline in
# a command, so anything using find -printf '%T@ %p' silently breaks there. A
# helper file has no such rule.
HELPER=/usr/local/sbin/turtle-logcap

read -r -d '' CONF_BODY <<EOF || true
# Managed by scripts/cap-logs.sh — edit there, not here.
#
# copytruncate is REQUIRED, not a preference. mangosd holds the file open with
# fopen(path, "a") (BotLog.cpp:35). Plain rotation renames the file and mangosd
# keeps writing to the renamed inode forever, so the "rotated" log is the live
# one and the new file stays empty. copytruncate copies then truncates in place,
# which is safe for the same O_APPEND reason that makes \`truncate -s 0\` safe on
# a running server.
#
# su root root — the log FILES are written from inside the container and owned by
# root, while the logs/ DIRECTORY is owned by the host user. logrotate refuses to
# act on that mismatch unless told whose identity to use.
# NO delaycompress. It is the usual companion to copytruncate, but it is wrong
# here: it leaves the newest rotation uncompressed until the NEXT cycle, so the
# ceiling becomes one live file PLUS one full-size copy — ~163 MB + ~163 MB for
# bots.log instead of ~163 MB + ~10 MB, which is most of the 500 MB budget spent
# on a file we already finished copying. delaycompress protects processes that
# keep writing to the old inode after rotation; copytruncate has already
# truncated in place by then, so there is no such writer to protect.
$LOGS/*.log {
    size $ROTATE_SIZE
    rotate $ROTATE_KEEP
    compress
    missingok
    notifempty
    copytruncate
    su root root
}

# Separate stanza, smaller ceiling: these are append-only diagnostic dumps, not
# logs anyone tails, and travel_telemetry.csv alone had reached 64 MB. See the
# header-row caveat in scripts/cap-logs.sh.
$LOGS/*.csv {
    size $CSV_ROTATE_SIZE
    rotate $CSV_ROTATE_KEEP
    compress
    missingok
    notifempty
    copytruncate
    su root root
}
EOF

read -r -d '' HELPER_BODY <<EOF || true
#!/bin/sh
# Managed by scripts/cap-logs.sh — edit there, not here.
#
# Two jobs, because one tool cannot do both. logrotate caps files that keep the
# same name; nothing in logrotate can cap a family of files whose name changes
# every time the server starts.
set -u

/usr/sbin/logrotate -s $STATUS $CONF

# Keep the newest $KEEP_BOOT_LOGS per-boot logs, delete the rest. Parsing ls is
# normally a mistake, but these names are generated by the server as
# server_<ISO-ish timestamp>.log and contain no spaces or newlines by
# construction, and -t gives newest-first without needing find -printf, whose %
# characters cron would eat.
ls -1t $LOGS/server_*.log 2>/dev/null | tail -n +$((KEEP_BOOT_LOGS + 1)) | xargs -r rm -f
EOF

CRON_BODY="*/$CRON_MINUTES * * * * root $HELPER"

if [ "$DRY_RUN" = 1 ]; then
  echo "==> would write $CONF:"; echo "$CONF_BODY"; echo
  echo "==> would write $HELPER:"; echo "$HELPER_BODY"; echo
  echo "==> would write $CRON:"; echo "$CRON_BODY"; echo
  echo "==> boot logs that would be pruned (keeping newest $KEEP_BOOT_LOGS):"
  ls -1t "$LOGS"/server_*.log 2>/dev/null | tail -n +$((KEEP_BOOT_LOGS + 1)) | sed 's/^/      /' || true
  echo "==> TW_LOGS=$LOGS ($(du -sh "$LOGS" 2>/dev/null | cut -f1) on disk now)"
  exit 0
fi

[ "$(id -u)" = 0 ] || { echo "FATAL: writes to /etc — re-run with sudo." >&2; exit 1; }

# Supersede the narrower predecessor. It rotated ONLY bots.log, at a 250 MB
# threshold, leaving errors.log / loot.log / server_<date>.log uncapped and
# budgeting ~375 MB for a single file — most of the 500 MB target.
#
# Removing it is not tidiness. Two cron entries rotating the same file every five
# minutes keep INDEPENDENT .1/.2 sequences and independent status files, so each
# one compresses a copy the other has already truncated, and the pair keeps up to
# twice the intended number of generations on disk. The whole point of this script
# is a predictable ceiling, and two uncoordinated rotators do not have one.
for legacy in /etc/logrotate.turtle-bots.conf /etc/cron.d/turtle-bots-logrotate \
              /var/lib/logrotate/turtle-bots.status; do
  if [ -e "$legacy" ]; then rm -f "$legacy"; echo "==> removed superseded $legacy"; fi
done

printf '%s\n' "$CONF_BODY" > "$CONF"
chmod 644 "$CONF"
printf '%s\n' "$HELPER_BODY" > "$HELPER"
chmod 755 "$HELPER"
printf '%s\n' "$CRON_BODY" > "$CRON"
chmod 644 "$CRON"
mkdir -p "$(dirname "$STATUS")"

# Parse-check before trusting it. -d is debug/dry-run: it reports what it WOULD
# rotate and fails loudly on a malformed stanza, without touching a single file.
echo "==> validating $CONF"
logrotate -d "$CONF" >/dev/null

# Run the helper once now rather than waiting up to CRON_MINUTES. The prune is
# the half that reclaims space immediately, and leaving the directory over
# budget until the next cron tick is the state this script exists to end.
echo "==> running $HELPER once"
"$HELPER"

echo "==> installed"
echo "    config : $CONF   (${ROTATE_SIZE} threshold, keep ${ROTATE_KEEP}, compressed)"
echo "    csv    : ${CSV_ROTATE_SIZE} threshold, keep ${CSV_ROTATE_KEEP}"
echo "    prune  : newest ${KEEP_BOOT_LOGS} server_*.log kept"
echo "    helper : $HELPER"
echo "    cron   : $CRON   (every ${CRON_MINUTES} min)"
echo "    logs   : $LOGS"
echo
echo "    on-disk now: $(du -sh "$LOGS" 2>/dev/null | cut -f1)"
echo "    verify in a few minutes:  ls -la $LOGS"
echo "    dry run any time:         logrotate -d $CONF"
