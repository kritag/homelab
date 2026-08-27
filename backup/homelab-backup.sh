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

# healthchecks.io ping URL, e.g. https://hc-ping.com/<uuid>. Kept out of this
# repo; absent file simply disables alerting.
HC_URL="$(cat /root/.healthchecks-url 2>/dev/null || true)"
hc() { [ -n "$HC_URL" ] && curl -fsS -m 10 --retry 3 "${HC_URL}${1}" >/dev/null || true; }

# Bring the stacks back up no matter how we exit — a failed backup must not
# leave the house without lights — then report the outcome.
finish() {
  rc=$?
  runuser -u mediaman      -- docker compose "${MEDIA[@]}"     up -d || true
  runuser -u homeassistant -- docker compose "${HASS[@]}"      up -d || true
  runuser -u nextcloud     -- docker compose "${NEXTCLOUD[@]}" up -d || true
  if [ "$rc" -eq 0 ]; then hc ""; else hc "/fail"; fi
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
  "$PIHOLE_REMOTE" "$PIHOLE_LOCAL/" || { pihole_rc=1; echo "WARN: Pi-hole pull failed"; }

echo "Stopping stacks for a consistent snapshot..."
runuser -u mediaman      -- docker compose "${MEDIA[@]}"     stop -t 30
runuser -u homeassistant -- docker compose "${HASS[@]}"      stop -t 30
runuser -u nextcloud     -- docker compose "${NEXTCLOUD[@]}" stop -t 30

echo "Backing up..."
# /mnt/0_data/nextcloud (everyone's photos) is deliberately NOT backed up: every
# phone auto-uploads to Jottacloud as well, so restic would push a second copy of
# the same files into the same provider. /home/nextcloud is the irreplaceable half
# — PostgreSQL (accounts, groups, quotas, shares, file IDs), config.php and .env.
restic backup /home/mediaman /home/homeassistant /home/nextcloud "$PIHOLE_LOCAL" \
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
