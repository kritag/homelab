# homelab

Docker Compose stacks for my home server (Fedora). Config only — no data, no
secrets. State lives in backups, not here. Domain, DDNS name and disk UUIDs are
placeholders — substitute your own. LAN addresses are RFC1918 and left as-is so
the commands run.

## Stacks

One stack = one Unix user = one compose project. Compose file lives in the
user's home, so the project dir is `~` and the project name is the username.
Next stack gets 2025.

| Dir              | User            | UID:GID   | Contents                                                                |
| ---------------- | --------------- | --------- | ----------------------------------------------------------------------- |
| `media/`         | `mediaman`      | 2020:2020 | \*arr apps, qBittorrent behind VPN, Jellyfin/Plex, Heimdall, nginx |
| `homeassistant/` | `homeassistant` | 2021:2021 | Home Assistant                                                          |
| `nextcloud/`     | `nextcloud`     | 2022:2022 | Nextcloud, PostgreSQL, Redis, cron                                      |
| `kept/`          | `kept`          | 2023:2023 | Kept — notes                                                            |
| `immich/`        | `immich`        | 2024:2024 | Immich — photos                                                         |

UIDs are pinned because every file under appdata and media is owned by that
number; a restore onto different IDs leaves containers unable to read their own
config. The `docker` group is root-equivalent — separate users are
organisational, not a security boundary.

## Host setup

```bash
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker

# binhex VPN containers need ip_tables and do not load it themselves
sudo modprobe ip_tables
echo ip_tables | sudo tee /etc/modules-load.d/ip_tables.conf

# SELinux is disabled on this host (see Gotchas)
sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
sudo grubby --update-kernel=ALL --args=selinux=0
sudo install -Dm644 /dev/stdin /etc/systemd/system/docker.service.d/no-selinux.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
systemctl show docker -p ExecStart | rg selinux    # must be empty

# Plex is host-networked, so firewalld applies (published ports bypass it)
sudo firewall-cmd --add-port=32400/tcp --permanent && sudo firewall-cmd --reload
```

Docker data-root is `/home/docker-data` (`/etc/docker/daemon.json`) — `/` is
35G, `/home` 76G. `/var/lib/docker` does not exist.

### Storage

| Mount         | Device | Role                      |
| ------------- | ------ | ------------------------- |
| `/mnt/0_data` | `sdb1` | tv, movies, immich        |
| `/mnt/1_data` | `sdc1` | movies — small, near full |

```bash
# /etc/fstab — by UUID (device order is not stable), nofail or a dead disk drops the
# host to emergency mode. Get the UUIDs with: lsblk -f
UUID=<uuid-sdb1>  /mnt/0_data  ext4  defaults,nofail  0  2
UUID=<uuid-sdc1>  /mnt/1_data  ext4  defaults,nofail  0  2

sudo mkdir -p /mnt/0_data/{movies,tv,torrents} /mnt/1_data/{movies,torrents}
sudo chown -R 2020:2020 /mnt/0_data /mnt/1_data
sudo mkdir -p /mnt/0_data/nextcloud && sudo chown 33:33 /mnt/0_data/nextcloud   # after the chown above
```

Both disks hold movies because `1_data` filled up; mounted as `/movies` (1_data)
and `/movies1` (0_data). Wrong ownership surfaces as \*arr import failures, not
permission errors.

## Cold start

```bash
sudo groupadd -g 2020 mediaman
sudo useradd -m -u 2020 -g 2020 -s /bin/bash mediaman
sudo usermod -aG docker mediaman        # new logins only: use `sudo -u mediaman -H bash`
id mediaman                             # confirm the numbers

sudo -u mediaman -H bash
cp media/docker-compose.yaml ~/docker-compose.yaml
cp media/.env.example ~/.env            # fill it in
docker compose up -d
```

Repeat per stack with its own UID from the table. `useradd` fails on a taken ID
rather than picking another — fix the collision, don't change the ID.

## Per-stack notes

**media** — appdata in `~/docker-automatic-media-server/<svc>/config`.

```bash
mkdir -p ~/docker-automatic-media-server/qbittorrent/config/{openvpn,wireguard}
# drop the provider .ovpn + certs into openvpn/, or wg0.conf into wireguard/
```

- `binhex/arch-qbittorrentvpn` **logs `VPN_USER`/`VPN_PASS` in plaintext** every
  start — treat `docker compose logs qbittorrent` as credential-bearing.
- `WEBUI_PORT` must equal both sides of the published port (`8181:8181`); binhex
  builds the container's iptables rules from it. 8080 is taken by Nextcloud.
- `LAN_NETWORK` must include `172.16.0.0/12` — requests from
  nginx/radarr/sonarr/cleanuparr arrive with a docker-bridge source and are
  otherwise dropped.
- qBittorrent: uncheck **Enable Host header validation** or nginx gets 401. Save
  path `/downloads`, "keep incomplete in" off, categories enabled.
- Verify the tunnel: `docker exec qbittorrent curl -s https://ipinfo.io/ip` must
  differ from the host's. HTTP leaving via the tunnel does not prove the
  BitTorrent socket does — use the ipleak.net magnet after any client change.
- Do **not** add `/downloads` as a Radarr/Sonarr root folder; it triggers
  `DownloadClientRootFolderCheck` and invites importing into the download
  tree.
- Radarr/Sonarr **move** rather than copy when the client item is gone or
  `CanMoveFiles` is true. For that: qBittorrent seeding-limit action = **Stop
  torrent** (not Remove), and **Remove Completed** on in Radarr/Sonarr.
  Removing at 0 min in the client instead is a race — if the torrent vanishes
  before the ~1 min queue scan, the files never import.

**homeassistant** — only `TZ` in `.env`; the image ignores PUID/PGID and runs as
root. HTTP and proxy settings are in the UI (Settings → System → Network); a
`http:` block in `configuration.yaml` is silently ignored.

**nextcloud** — official image ignores PUID/PGID (Apache is uid 33), so data
dirs are `33:33` and 2022 owns only the home dir. Photos are in Immich; what's
left is Documents, Notes, calendars, contacts.

```bash
sudo mkdir -p /home/nextcloud/{html,postgres}
sudo chown 33:33 /home/nextcloud/html && sudo chown 2022:2022 /home/nextcloud

docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive
docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=21
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value=<CC>   # ISO country code

# long jobs, detached, survive an ssh drop
docker exec -d -u www-data nextcloud sh -c 'php occ preview:generate-all > /var/www/data/preview.log 2>&1'
```

- **Never pin `overwriteprotocol`/`overwritehost`** — with them set, Nextcloud
  answers HTTPS with `Location: http://`, downgrading TLS clients.
  `OVERWRITECLIURL` stays (cron has no request). Remove the env var from
  compose *before* `occ config:system:delete`, or `up -d` re-applies it.
- Any setting backed by a compose env var is re-applied on every start and
  overrides the UI — worst with `SMTP_*`. Accounts, groups, quotas, apps,
  sharing live in Postgres; manage in UI.
- Set a default quota before any phone connects, or one auto-upload fills
  `/mnt/0_data`.
- Delete `occ` logs from the data dir afterwards or `files:scan` indexes them as
  user files.
- Hour 21 is UTC = 23:00–03:00 local, clearing the 04:00 backup.

**kept** — honours PUID/PGID.
`sudo mkdir -p /home/kept/data && sudo chown -R 2023:2023 /home/kept`

- **Requires HTTPS**: note creation uses `crypto.randomUUID()`, secure-context
  only. On plain HTTP the Close button hangs with no error and no request in
  the log.
- `KEPT_CORS_ALLOW_ALL=1` for the native app shells. `KEPT_ALLOW_RESTORE` stays
  unset — with it, any auth token can overwrite the whole DB. Pin a version
  tag; the nightly `up -d` would otherwise upgrade it unattended.

**immich** — no PUID/PGID (runs as root). `UPLOAD_LOCATION` on the bulk disk
(~190 GB), `DB_DATA_LOCATION` under `/home/immich` so restic covers it.

```bash
sudo mkdir -p /mnt/0_data/immich /home/immich/postgres
sudo chown -R 2024:2024 /home/immich /mnt/0_data/immich

docker run --rm -v /path/to/photos:/import:ro \
  -e IMMICH_INSTANCE_URL=http://192.168.0.62:2283/api -e IMMICH_API_KEY='<key>' \
  ghcr.io/immich-app/immich-cli:latest upload --recursive --dry-run /import
```

- ML container removed **and** must be disabled in Administration → Settings →
  Machine Learning, or the server queues tens of thousands of jobs against
  nothing.
- `IMMICH_VERSION` pinned to a release, not the moving `v3` tag — breaking
  changes between majors. The DB image carries vectorchord/pgvectors and is
  not interchangeable with vanilla postgres; it and valkey are digest-pinned
  upstream.
- Set the **storage template** before importing — it only applies to new assets.
  `{{y}}/{{MM}}/{{filename}}` matches the existing layout.
- Always `--dry-run` first; mount source `:ro`. Dedup is by hash, so re-runs are
  safe, but editing a file changes its hash. Don't use `--album` on a
  `year/month` tree — 300 albums named "5".

## `.env`

| Variable                                      | Source                                                |
| --------------------------------------------- | ----------------------------------------------------- |
| `PUID`/`PGID`                                 | The stack user's fixed IDs                            |
| `TZ`                                          | e.g. `Europe/Oslo`                                    |
| `VPN_USER`/`VPN_PASS`/`VPN_PROV`/`VPN_CLIENT` | Provider creds; `openvpn` or `wireguard`              |
| `LAN_NETWORK`                                 | `192.168.0.0/24,172.16.0.0/12`                        |
| `QBIT_WEBUI_PORT`                             | `8181`                                                |
| `RADARR_API_KEY`/`SONARR_API_KEY`             | Radarr/Sonarr → Settings → General, after first start |
| `POSTGRES_PASSWORD`/`REDIS_PASSWORD`          | `openssl rand -base64 24`                             |
| `NEXTCLOUD_ADMIN_USER`/`_PASSWORD`            | Read only on first install                            |

## First-run order

Prowlarr (indexers + FlareSolverr) → Sonarr/Radarr (qBittorrent client, root
folders, Prowlarr) → API keys into `.env` then `docker compose up -d recyclarr`
→ Jellyfin/Plex libraries → Seerr → Bazarr.

## Hostnames and TLS

nginx fronts everything on 80/443, mapping `<svc>.h.example.com` to host ports
via `map $host $upstream`, unmatched names falling through to Heimdall. Config
is not in this repo — restored from backup, and it lives in
`reverse/config/nginx/site-confs/` (files in `reverse/config/` root are not
read).

```bash
# LAN DNS — one wildcard, Pi-hole v6 on 192.168.0.59
sudo pihole-FTL --config misc.dnsmasq_lines '["address=/h.example.com/192.168.0.62"]'
sudo systemctl restart pihole-FTL

# Let's Encrypt wildcard, DNS-01 via Cloudflare, nothing exposed to the internet
curl https://get.acme.sh | sh -s email=<you@example.com>
acme.sh --set-default-ca --server letsencrypt
export CF_Token="<Zone:Zone:Read + Zone:DNS:Edit, scoped>"
acme.sh --issue --dns dns_cf -d h.example.com -d '*.h.example.com'

KEYS=/home/mediaman/docker-automatic-media-server/reverse/config/keys
acme.sh --install-cert -d h.example.com --ecc \
  --key-file "$KEYS/cert.key" --fullchain-file "$KEYS/cert.crt" \
  --reloadcmd "chown 2020:2020 $KEYS/cert.key $KEYS/cert.crt && docker exec reverse nginx -s reload"

openssl x509 -noout -dates -issuer -ext subjectAltName -in "$KEYS/cert.crt"
```

- Port 443 needs **its own `server` block** reusing the same map. Without it the
  linuxserver image's `default.conf` answers 443 with its self-signed cert,
  and every client app prompts to trust a fingerprint then fails with "could
  not connect" — it reached the default vhost.
- Both names are needed; the wildcard does not cover bare `h.example.com`.
  `--ecc` is required on install. acme.sh self-manages renewal via its own
  cron (~30 days before expiry, per ARI).
- No permanent public DNS record exists — DNS-01 only needs a temporary
  `_acme-challenge` TXT.
- Use a sub-label of a domain you actually own. An earlier setup used a domain
  we did not own: no real cert is possible, and any client falling back to
  public DNS resolves your service names against a stranger's zone. The
  sub-label also stops a Pi-hole wildcard on the apex hijacking real public
  hosts in the same zone.
- Without a trusted cert: `crypto.randomUUID()` is absent (Kept cannot save),
  iOS refuses CalDAV, Nextcloud loses clipboard/service workers/passkeys.
- Pick a suffix whose TLD is in the Public Suffix List — Firefox sends
  `.lan`/`.internal` to search instead of navigating.

## Remote access

WireGuard on the ASUS router (VPN → VPN Server → WireGuard), not on the server.
Split tunnel, `AllowedIPs = 192.168.0.0/24,10.6.0.0/24`, endpoint
`<router-ddns-name>:51820`, clients on `10.6.0.0/24`.

```bash
sudo pihole-FTL --config dns.listeningMode ALL    # v6 default LOCAL drops the 10.6.0.x queries
sudo systemctl restart pihole-FTL

sed -i 's/^DNS = .*/DNS = 192.168.0.59/' client.conf   # router generates 10.6.0.1 = itself
qrencode -t ansiutf8 < client.conf
```

- **Exactly one resolver.** `10.6.0.1,192.168.0.59` gives working internet but
  breaks homelab names: the router answers NXDOMAIN, a *valid* reply, so the
  client never fails over. Same reason DHCP's "DNS Server 2" is empty.
- Symptom of a wrong `listeningMode`: `curl http://192.168.0.59/admin/` returns
  302 (routing fine) but `dig @192.168.0.59 jellyfin.h.example.com` times out.
- Test from mobile data, not home wifi — hairpin NAT misleads. Termux `dig`
  ignores the system resolver and defaults to 8.8.8.8, so name the server
  explicitly.
- Android **Private DNS** and browser **DoH** bypass the tunnel resolver
  entirely — turn off.
- Router WAN → DNS Server 1 = Pi-hole also works but was rejected: the router
  would then need Pi-hole to resolve its own DDNS updates.
- Exported configs hold private keys. Not in this repo.

## Gotchas

- Verify a proxy by **page title, not HTTP status** — nginx's default vhost
  answers 200 with "Welcome to our server".
- Published ports bypass firewalld; `network_mode: host` does not.
- Nextcloud answers `/` with a 302 to `/login`, so `curl` without `-L` has no
  `<title>` — not a failure. A 400 means the hostname isn't in
  `trusted_domains`.
- `/usr/local/sbin` is a **symlink to `/usr/local/bin`** here — a script at both
  paths is one file. Do not "clean up" the duplicate.
- systemd sets no `HOME` for root services; restic and rclone both need it, so
  `homelab-backup.sh` exports `HOME=/root`. When a scheduled job "works by
  hand", check the systemd environment first.
- Docker does not always release a published port when a container stops — an
  immediate `up -d` fails with "address already in use". Needs
  `docker compose rm -sf` then `up -d`; restarting reuses the broken network
  config.
- binhex
  `[warn] Unable to identify Docker network interfaces, exiting script...` means
  a **published port failed to bind**, leaving the container with no endpoint.
  Check `docker inspect <c> --format '{{json .NetworkSettings.Networks}}'`
  for `[]` and read the first `up` error. Not ip_tables, not `LAN_NETWORK`.
- `docker compose up -d <svc>` will not rebuild a container whose config is
  unchanged — and reports `Running`. Use `rm -sf` or `--force-recreate`.
- SELinux is **disabled**, not Permissive: `setenforce 0` is not persistent, and
  the 2026-09-03 reboot came up Enforcing and broke `kept`. Removing
  `--selinux-enabled` only affects new containers — the label is baked into
  each existing one, so every container must be recreated
  (`down --remove-orphans && up -d --force-recreate`, never `-v`) or its
  overlay mount fails with "invalid argument". `daemon.json`'s
  `"selinux-enabled": false` does not work.
- After an unclean reboot, dockerd can panic with `page 2 already freed`
  (bbolt): move `/home/docker-data/network/files/*` aside,
  `systemctl reset-failed docker`, start, then bring each stack up with
  `down --remove-orphans` first — existing containers hold the old network
  IDs. Recreates orphan anonymous volumes; `docker volume prune -f` after.

## Backups

Nightly `restic` → Jottacloud via `rclone`, 04:00, stacks stopped first so
Postgres/SQLite shut down cleanly (no `pg_dump` needed). See
[`backup/`](backup/) and [`pihole/`](pihole/).

| Path                                    | Why                                                        |
| --------------------------------------- | ---------------------------------------------------------- |
| `/home/mediaman`, `/home/homeassistant` | compose, `.env`, VPN configs, nginx config, certs, appdata |
| `/home/nextcloud`                       | Postgres — accounts, quotas, shares, calendars, contacts   |
| `/home/immich`                          | Postgres — albums, corrected dates, all organisation       |
| `/home/kept`                            | SQLite notes                                               |
| `/mnt/0_data/nextcloud`                 | Documents and Notes — no second copy anywhere              |
| `/var/backups/pihole`                   | Teleporter exports                                         |

Media and photo libraries are **deliberately excluded** — every phone
auto-uploads to Jottacloud already, so `/mnt/0_data/immich` is not a restic path
at all:

```
--exclude '/mnt/0_data/nextcloud/*/files/Photos'
--exclude '/mnt/0_data/nextcloud/appdata_*/preview'
```

- Immich's photos can be re-downloaded; its albums and corrected dates cannot.
- `/root/.acme.sh/` (ACME key + Cloudflare token) is deliberately not backed up
  — re-issuing takes a minute and this keeps a live credential out of the
  repo.
- Adding a path invalidates restic's parent selection (host + path set), so that
  one run re-reads everything and looks like a full backup. Expected.
- Hourly `container-health.timer` diffs `docker compose config --services`
  against running containers per stack. It only checks *running* — a binhex
  container with a dead tunnel stays green.
- `finish()` retries a failed stack start once and reports `/fail`. It used to
  use `|| true`, which hid Deluge being down for six hours on 2026-09-01 while
  the run reported success.
