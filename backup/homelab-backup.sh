#!/bin/bash
# Nightly restic backup of the docker stacks to Jottacloud.
# Installed at /usr/local/sbin/homelab-backup.sh, run by homelab-backup.timer.
#
# Both stacks are stopped for the duration: the *arr apps, Jellyfin, Plex and
# Home Assistant all use SQLite in WAL mode, and copying those files live can
# produce a backup that restores into a corrupt database.
set -euo pipefail

export RESTIC_REPOSITORY=rclone:jotta:restic-homelab
export RESTIC_PASSWORD_FILE=/root/.restic-password

APPDATA=/home/mediaman/docker-automatic-media-server
PLEX="$APPDATA/plex/config/Library/Application Support/Plex Media Server"

MEDIA=(-f /home/mediaman/docker-compose.yaml --project-directory /home/mediaman)
HASS=(-f /home/homeassistant/docker-compose.yaml --project-directory /home/homeassistant)

# Bring the stacks back up no matter how we exit — a failed backup must not
# leave the house without lights.
start_stacks() {
  runuser -u mediaman      -- docker compose "${MEDIA[@]}" up -d || true
  runuser -u homeassistant -- docker compose "${HASS[@]}"  up -d || true
}
trap start_stacks EXIT

echo "Stopping stacks for a consistent snapshot..."
runuser -u mediaman      -- docker compose "${MEDIA[@]}" stop -t 30
runuser -u homeassistant -- docker compose "${HASS[@]}"  stop -t 30

echo "Backing up..."
restic backup /home/mediaman /home/homeassistant \
  --exclude '/home/mediaman/git' \
  --exclude "$APPDATA/jellyfin/config/metadata" \
  --exclude "$PLEX/Metadata" \
  --exclude "$PLEX/Media" \
  --exclude "$PLEX/Cache" \
  --exclude '**/log' --exclude '**/logs' --exclude '**/*.log*' \
  --exclude '**/cache' --exclude '**/Cache' \
  --exclude '**/transcodes' --exclude '**/Transcode' \
  --exclude '**/Crash Reports' \
  --exclude '**/Diagnostics'

echo "Pruning..."
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

restic snapshots --latest 3
