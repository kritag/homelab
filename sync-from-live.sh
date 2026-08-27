#!/bin/bash
# Refresh repo copies from the live config, then `git diff` to review.
set -euo pipefail
cd "$(dirname "$0")"
sudo cp /home/mediaman/docker-compose.yaml media/docker-compose.yaml
sudo cp /home/homeassistant/docker-compose.yaml homeassistant/docker-compose.yaml
sudo cp /home/nextcloud/docker-compose.yaml nextcloud/docker-compose.yaml
sudo chown "$(id -un):$(id -gn)" media/docker-compose.yaml homeassistant/docker-compose.yaml nextcloud/docker-compose.yaml
echo "Synced. Review with: git diff"
