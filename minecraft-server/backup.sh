#!/usr/bin/env bash
#
# Backs up the Minecraft world to ./backups, keeping the last 14 days.
#
# Usage:  ./backup.sh            (also runs nightly at 05:00 via cron)
#
# The server is stopped for the few seconds it takes to copy the world. That
# guarantees the snapshot isn't half-written mid-save, which is worth far more
# than the brief interruption on a two-player server.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$DIR/backups"
KEEP_DAYS=14
STAMP="$(date +%Y-%m-%d_%H%M%S)"

cd "$DIR"

# Detect which of the two setups is actually running.
if docker ps --format '{{.Names}}' | grep -q '^mc-bedrock$'; then
  COMPOSE_FILE="docker-compose.yml"
  DATA_DIR="data"
elif docker ps --format '{{.Names}}' | grep -q '^mc-geyser$'; then
  COMPOSE_FILE="docker-compose.geyser.yml"
  DATA_DIR="data-geyser"
else
  echo "[$(date)] No server running; backing up ./data as-is."
  COMPOSE_FILE=""
  DATA_DIR="data"
fi

if [[ ! -d "$DIR/$DATA_DIR" ]]; then
  echo "[$(date)] Nothing to back up — $DATA_DIR does not exist."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
ARCHIVE="$BACKUP_DIR/world_${STAMP}.tar.gz"

if [[ -n "$COMPOSE_FILE" ]]; then
  echo "[$(date)] Stopping server for a consistent snapshot..."
  docker compose -f "$COMPOSE_FILE" stop
fi

echo "[$(date)] Archiving $DATA_DIR -> $ARCHIVE"
tar -czf "$ARCHIVE" -C "$DIR" "$DATA_DIR"

if [[ -n "$COMPOSE_FILE" ]]; then
  echo "[$(date)] Restarting server..."
  docker compose -f "$COMPOSE_FILE" start
fi

echo "[$(date)] Pruning backups older than $KEEP_DAYS days"
find "$BACKUP_DIR" -name 'world_*.tar.gz' -type f -mtime "+$KEEP_DAYS" -print -delete

echo "[$(date)] Done. Size: $(du -h "$ARCHIVE" | cut -f1)"
echo "[$(date)] Backups on disk: $(find "$BACKUP_DIR" -name 'world_*.tar.gz' | wc -l)"

# ---------------------------------------------------------------------------
# To RESTORE a backup:
#
#   cd ~/safebite/minecraft-server
#   docker compose down
#   mv data data-broken
#   tar -xzf backups/world_YYYY-MM-DD_HHMMSS.tar.gz
#   docker compose up -d
#
# Worth copying these off the VM occasionally, e.g. from your own machine:
#   scp -i ~/.ssh/mc-server ubuntu@<IP>:~/safebite/minecraft-server/backups/*.tar.gz .
# ---------------------------------------------------------------------------
