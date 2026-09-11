#!/bin/bash
# Nightly restic backup of the docker stacks to Jottacloud.
# Installed at /usr/local/sbin/homelab-backup.sh, run by homelab-backup.timer.
#
# All three stacks are stopped for the duration: the *arr apps, Jellyfin, Plex and
# Home Assistant all use SQLite in WAL mode, and copying those files live can
# produce a backup that restores into a corrupt database. Nextcloud's PostgreSQL
# gets a clean shutdown for the same reason, which makes a file-level copy of its
# data directory consistent — no pg_dump needed.
set -euo pipefail

# Run from / so the runuser'd docker compose calls don't inherit a cwd the
# service accounts can't stat — invoking this from another user's home
# otherwise fails with: error in parsing "compose-spec.json": stat .: permission denied
cd /

# systemd gives root no HOME, and both restic (its cache) and rclone (rclone.conf
# under /root/.config) need one. Without it restic aborts immediately with
# "unable to locate cache directory: neither $XDG_CACHE_HOME nor $HOME are defined".
export HOME=/root

export RESTIC_REPOSITORY=rclone:jotta:restic-homelab
export RESTIC_PASSWORD_FILE=/root/.restic-password

APPDATA=/home/mediaman/docker-automatic-media-server
PLEX="$APPDATA/plex/config/Library/Application Support/Plex Media Server"

# Pi-hole teleporter archives, pulled from the Pi (see pihole/ in this repo).
PIHOLE_REMOTE="pi@192.168.0.59:pihole-backups/"
PIHOLE_LOCAL=/var/backups/pihole

MEDIA=(-f /home/mediaman/docker-compose.yaml --project-directory /home/mediaman)
HASS=(-f /home/homeassistant/docker-compose.yaml --project-directory /home/homeassistant)
NEXTCLOUD=(-f /home/nextcloud/docker-compose.yaml --project-directory /home/nextcloud)
KEPT=(-f /home/kept/docker-compose.yaml --project-directory /home/kept)
IMMICH=(-f /home/immich/docker-compose.yaml --project-directory /home/immich)
INVIDIOUS=(-f /home/invidious/docker-compose.yaml --project-directory /home/invidious)

# healthchecks.io ping URL, e.g. https://hc-ping.com/<uuid>. Kept out of this
# repo; absent file simply disables alerting.
HC_URL="$(cat /root/.healthchecks-url 2>/dev/null || true)"
hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 "${HC_URL}${1}" >/dev/null || true; }

# Bring the stacks back up no matter how we exit — a failed backup must not
# leave the house without lights — then report the outcome.
# Bring a stack back up, retrying once. Docker does not always release published
# ports the instant a container stops, so an immediate `up -d` can fail with
# "address already in use" — on 2026-09-01 deluge lost port 58946 that way and
# stayed down for six hours. Never abort: the other stacks must still come back.
# But DO record the failure so the run reports it.
start_stack() {
  local user=$1
  shift
  if runuser -u "$user" -- docker compose "$@" up -d; then return 0; fi
  echo "WARN: $user stack failed to start, retrying in 15s" >&2
  sleep 15
  if runuser -u "$user" -- docker compose "$@" up -d; then
    echo "WARN: $user stack started only on retry" >&2
    return 0
  fi
  echo "ERROR: $user stack failed to start after retry" >&2
  return 1
}

finish() {
  rc=$?
  up_rc=0
  start_stack mediaman "${MEDIA[@]}" || up_rc=1
  start_stack homeassistant "${HASS[@]}" || up_rc=1
  start_stack nextcloud "${NEXTCLOUD[@]}" || up_rc=1
  start_stack kept "${KEPT[@]}" || up_rc=1
  start_stack immich "${IMMICH[@]}" || up_rc=1
  start_stack invidious "${INVIDIOUS[@]}" || up_rc=1

  # A backup that succeeded but left a stack down is NOT a success. This was
  # previously `|| true` per line, so a failed restart was invisible and
  # healthchecks.io was told everything was fine.
  if [ "$rc" -eq 0 ] && [ "$up_rc" -eq 0 ]; then hc ""; else hc "/fail"; fi
  if [ "$rc" -eq 0 ] && [ "$up_rc" -ne 0 ]; then rc=1; fi
  exit "$rc"
}
trap finish EXIT

hc "/start"

# Non-fatal: a missing Pi shouldn't cost us the host backup, but it must still
# surface as a failed run at the end.
pihole_rc=0
echo "Pulling Pi-hole teleporter archives..."
mkdir -p "$PIHOLE_LOCAL"
rsync -a --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
  "$PIHOLE_REMOTE" "$PIHOLE_LOCAL/" || {
  pihole_rc=1
  echo "WARN: Pi-hole pull failed"
}

echo "Stopping stacks for a consistent snapshot..."
runuser -u mediaman -- docker compose "${MEDIA[@]}" stop -t 30
runuser -u homeassistant -- docker compose "${HASS[@]}" stop -t 30
runuser -u nextcloud -- docker compose "${NEXTCLOUD[@]}" stop -t 30
runuser -u kept -- docker compose "${KEPT[@]}" stop -t 30
runuser -u immich -- docker compose "${IMMICH[@]}" stop -t 30
runuser -u invidious -- docker compose "${INVIDIOUS[@]}" stop -t 30

echo "Backing up..."
# Photo libraries are deliberately NOT backed up: every phone auto-uploads to
# Jottacloud independently, so restic would push a second copy of the same files
# into the same provider. That covers /mnt/0_data/immich (the Immich library) and
# any future Nextcloud Photos folder — excluded below so re-using Nextcloud for
# photos later doesn't silently start backing up hundreds of GB.
#
# What IS backed up is the half that exists nowhere else:
#   /home/nextcloud  PostgreSQL — accounts, groups, quotas, shares, calendars, contacts
#   /home/immich     PostgreSQL — albums, corrected dates, all organisation
#   /home/kept       SQLite notes
#   /mnt/0_data/nextcloud  Documents and Notes (small; Jottacloud does NOT have these)
restic backup /home/mediaman /home/homeassistant /home/nextcloud /home/kept /home/immich /home/invidious/ \
  /mnt/0_data/nextcloud "$PIHOLE_LOCAL" \
  --exclude '/mnt/0_data/nextcloud/*/files/Photos' \
  --exclude '/mnt/0_data/nextcloud/appdata_*/preview' \
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

if [ "$pihole_rc" -ne 0 ]; then
  echo "Backup of the stacks succeeded, but the Pi-hole pull failed." >&2
  exit 1
fi
