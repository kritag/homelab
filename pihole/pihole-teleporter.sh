#!/bin/bash
# Weekly Pi-hole config export. Installed at /usr/local/sbin/pihole-teleporter.sh
# on the Raspberry Pi, run by pihole-teleporter.timer.
#
# The archive holds the full config: pihole.toml, adlists, groups, clients and
# local DNS records. The docker host rsyncs this directory and folds it into
# repo, so the Pi itself needs no cloud credentials.
set -euo pipefail

DIR=/home/pi/pihole-backups
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

pihole-FTL --teleporter

chown -R pi:pi "$DIR"
chmod 600 "$DIR"/*.zip

# Keep the newest 3; the host's restic retention covers history beyond that.
ls -1t "$DIR"/*.zip 2>/dev/null | tail -n +4 | xargs -r rm --
