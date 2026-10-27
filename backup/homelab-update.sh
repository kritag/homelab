#!/bin/bash
# Pull newer images and recreate whatever changed, per stack.
#
# `up -d` only recreates containers whose image changed, so an unchanged stack
# is a no-op. Version pins in each stack's .env / image tags decide how far
# `latest` can move; this script never bypasses them.
#
# Installed at /usr/local/sbin/homelab-update.sh, run by homelab-update.timer.
set -uo pipefail
cd /
# The backup stops every stack on purpose; do not pull and start them mid-run.
case "$(systemctl is-active homelab-backup.service)" in
  active|activating) echo "Backup running, skipping."; exit 0 ;;
esac

HC="$(cat /root/.healthchecks-update-url 2>/dev/null || true)"
hc() { [ -n "$HC" ] && curl -fsS -m 10 --retry 3 "${HC}${1}" >/dev/null || true; }

# user:compose-file:project-dir
STACKS=(
  "mediaman:/home/mediaman/docker-compose.yaml:/home/mediaman"
  "homeassistant:/home/homeassistant/docker-compose.yaml:/home/homeassistant"
  "nextcloud:/home/nextcloud/docker-compose.yaml:/home/nextcloud"
  "kept:/home/kept/docker-compose.yaml:/home/kept"
  "immich:/home/immich/docker-compose.yaml:/home/immich"
)

hc "/start"
problems=0

for entry in "${STACKS[@]}"; do
  IFS=: read -r user file dir <<< "$entry"
  args=(-f "$file" --project-directory "$dir")
  echo "== $user"
  runuser -u "$user" -- docker compose "${args[@]}" pull --quiet \
    && runuser -u "$user" -- docker compose "${args[@]}" up -d --remove-orphans \
    || { echo "FAILED: $user" >&2; problems=1; }
done

# Dangling layers only; images still used by a container are kept.
docker image prune -f >/dev/null

if [ "$problems" -eq 0 ]; then hc ""; else hc "/fail"; exit 1; fi
