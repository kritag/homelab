#!/bin/bash
# Alert if any container that should be running isn't.
#
# The nightly backup only notices problems at 04:00. This catches a container
# that dies at any hour, for any reason. Compares `docker compose config
# --services` (what should exist) against `--status running` (what does).
#
# Installed at /usr/local/sbin/container-health.sh, run by container-health.timer.
set -uo pipefail
cd /

HC="$(cat /root/.healthchecks-containers-url 2>/dev/null || true)"
hc() { [ -n "$HC" ] && curl -fsS -m 10 --retry 3 "${HC}${1}" >/dev/null || true; }

# user:compose-file:project-dir
STACKS=(
  "mediaman:/home/mediaman/docker-compose.yaml:/home/mediaman"
  "homeassistant:/home/homeassistant/docker-compose.yaml:/home/homeassistant"
  "nextcloud:/home/nextcloud/docker-compose.yaml:/home/nextcloud"
)

# Services that are expected to be absent (one-shot jobs, deliberately stopped).
# Format: "user/service". Add here rather than silencing the whole stack.
EXCLUDE=()

problems=0
report=""

for entry in "${STACKS[@]}"; do
  IFS=: read -r user file dir <<< "$entry"
  args=(-f "$file" --project-directory "$dir")

  expected=$(runuser -u "$user" -- docker compose "${args[@]}" config --services 2>/dev/null | sort)
  running=$(runuser -u "$user" -- docker compose "${args[@]}" ps --services --status running 2>/dev/null | sort)

  if [ -z "$expected" ]; then
    report+="ERROR: could not read service list for $user"$'\n'
    problems=1
    continue
  fi

  while read -r svc; do
    [ -z "$svc" ] && continue
    skip=0
    for ex in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
      [ "$ex" = "$user/$svc" ] && skip=1
    done
    [ "$skip" -eq 1 ] && continue
    report+="DOWN: $user/$svc"$'\n'
    problems=1
  done < <(comm -23 <(echo "$expected") <(echo "$running"))
done

if [ "$problems" -eq 0 ]; then
  echo "All containers running."
  hc ""
else
  printf '%s' "$report" >&2
  hc "/fail"
  exit 1
fi
