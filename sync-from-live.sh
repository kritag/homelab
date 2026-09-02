#!/bin/bash
# Refresh repo copies from the live config, then `git diff` to review.
set -euo pipefail
cd "$(dirname "$0")"

sudo cp /home/mediaman/docker-compose.yaml      media/docker-compose.yaml
sudo cp /home/homeassistant/docker-compose.yaml homeassistant/docker-compose.yaml
sudo cp /home/nextcloud/docker-compose.yaml     nextcloud/docker-compose.yaml
sudo cp /home/kept/docker-compose.yaml          kept/docker-compose.yaml
sudo cp /home/immich/docker-compose.yaml        immich/docker-compose.yaml

# Backup tooling lives outside the stacks — sync it too, or the repo drifts
# from the script that actually runs.
sudo cp /usr/local/sbin/homelab-backup.sh            backup/homelab-backup.sh
sudo cp /usr/local/sbin/container-health.sh          backup/container-health.sh
sudo cp /etc/systemd/system/container-health.service backup/
sudo cp /etc/systemd/system/container-health.timer   backup/

sudo chown -R "$(id -un):$(id -gn)" media homeassistant nextcloud kept immich backup

echo "Synced. Review with: git diff"
