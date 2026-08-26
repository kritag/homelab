# homelab

Docker Compose stacks for my home server. Config only — no data, no secrets.
State lives in backups, not here.

## Pattern: one stack per user

Each stack gets its own Unix account, its own compose project, and its own `.env`:

| Directory | User | What it is |
|---|---|---|
| `media/` | `mediaman` | *arr apps, Deluge behind VPN, Jellyfin/Emby/Plex, Heimdall, nginx |
| `homeassistant/` | `homeassistant` | Home Assistant |

The compose file lives in the user's home directory, so the project directory is `~` and the
project name is the username. `docker compose` walks up parent directories, so it also works
from any subdirectory of the home.

Why bother: the stacks have unrelated lifecycles. Restarting the media stack for a Radarr
update shouldn't take the lights down, and Home Assistant has no business reading the media
stack's `.env` full of VPN credentials. Adding a stack means adding a user, not editing a
1000-line compose file.

Note the `docker` group is root-equivalent, so separate users are organisational, not a
security boundary.

## Host prerequisites

Fedora. Do these once, before any stack.

### Docker

```bash
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
```

Every stack user needs to be in the `docker` group (`usermod -aG docker <user>`, below).
Group membership only applies to new logins, so log out and back in — or use
`sudo -u <user> -H bash` — after adding it.

### Kernel module for the VPN container

`binhex/arch-delugevpn` needs `ip_tables` loaded on the host, and it does not load it itself:

```bash
sudo modprobe ip_tables
echo ip_tables | sudo tee /etc/modules-load.d/ip_tables.conf
```

Without the `modules-load.d` file it survives until the next reboot and then the container
fails to start with iptables errors.

### Storage mounts

Root and `/home` are xfs on LVM (`sda`). Two ext4 data disks carry the media:

| Mount | Device | Role |
|---|---|---|
| `/mnt/0_data` | `sdb1` | Bulk storage — tv, movies, mma, torrent downloads |
| `/mnt/1_data` | `sdc1` (label `data`) | Smaller disk, near capacity — movies, torrent downloads |

Mount by UUID, not device name — `/dev/sdX` ordering isn't stable across reboots. Get the
UUIDs from `lsblk -f`; on the current hardware they are:

```
UUID=98091d21-14ac-4d11-996b-ad5a5f445a12  /mnt/0_data  ext4  defaults,nofail  0  2
UUID=1ae5eed4-0f6c-495f-84cb-623db6fbff19  /mnt/1_data  ext4  defaults,nofail  0  2
```

```bash
sudo mkdir -p /mnt/0_data /mnt/1_data
sudo systemctl daemon-reload && sudo mount -a
```

`nofail` matters: without it, a missing or dying data disk drops the host to emergency mode on
boot instead of coming up with everything else working.

Then the directory tree the compose file expects:

```bash
sudo mkdir -p /mnt/0_data/{movies,tv,mma,torrents/downloads} \
              /mnt/1_data/{movies,torrents/downloads}
sudo chown -R 2020:2020 /mnt/0_data /mnt/1_data
```

The ownership must match the media stack's `PUID`/`PGID`, or the containers can see the paths
but can't write to them — which surfaces as import failures in Sonarr/Radarr rather than an
obvious permissions error.

Both disks hold movies because `1_data` filled up and the library spilled onto `0_data`.
Sonarr/Radarr and the media servers mount both, as `/movies` (1_data) and `/movies1` (0_data).
Confusing, and worth consolidating onto one disk if capacity ever allows.

### Firewall

Docker's published ports bypass firewalld entirely, so most services need no rule. But
`network_mode: host` services do *not* bypass it — Plex needs one explicitly:

```bash
sudo firewall-cmd --add-port=32400/tcp --permanent
sudo firewall-cmd --reload
```

## Cold start

### Create the user with fixed IDs

The UID/GID must be pinned, not left to `useradd`'s next-free-number. `PUID`/`PGID` in `.env`
have to match, and every file under the appdata and media directories is owned by that
numeric ID — so a restore onto a fresh host with a different UID leaves the containers unable
to read their own config.

IDs are allocated from 2020 upward, one per stack:

| Stack | User | UID:GID |
|---|---|---|
| `media/` | `mediaman` | 2020:2020 |
| `homeassistant/` | `homeassistant` | 2021:2021 |

```bash
# media
sudo groupadd -g 2020 mediaman
sudo useradd -m -u 2020 -g 2020 -s /bin/bash mediaman
sudo usermod -aG docker mediaman

# homeassistant
sudo groupadd -g 2021 homeassistant
sudo useradd -m -u 2021 -g 2021 -s /bin/bash homeassistant
sudo usermod -aG docker homeassistant

id mediaman; id homeassistant      # confirm the numbers
```

If an ID is already taken, `groupadd`/`useradd` fail rather than silently picking another —
fix the collision instead of changing the ID.

Next stack gets 2022, and so on. Add it to the table.

### Deploy the stack

```bash
sudo -u mediaman -H bash

cp media/docker-compose.yaml ~/docker-compose.yaml
cp media/.env.example ~/.env      # then fill it in — PUID=2020, PGID=2020
docker compose up -d
```

Same shape for any other stack: its own group, its own user, its own compose project. Pick a
distinct ID per stack and record it here.

### media

Per-service appdata lives in `~/docker-automatic-media-server/<service>/config`, created on
first start. The media mounts and `ip_tables` come from **Host prerequisites** above.

Deluge additionally needs a VPN provider config placed in its config directory before it will
start:

```bash
mkdir -p ~/docker-automatic-media-server/deluge/config/{openvpn,wireguard}
# drop the provider's .ovpn (plus certs) into openvpn/, or wg0.conf into wireguard/
```

The container picks up whatever it finds there according to `VPN_CLIENT`. Those files hold
credentials and private keys — they belong in backups, never in this repo.

### homeassistant

Only needs `TZ` in `.env` — the official image ignores `PUID`/`PGID` and runs as root inside
the container, so files under `config/` end up root-owned. The 2021 IDs still matter for the
home directory itself on a restore.

HTTP settings — reverse proxy trust, port, URLs — are configured
in the UI under **Settings → System → Network**. A `http:` block in `configuration.yaml` is
silently ignored on current versions, so don't waste time there.

## Filling in `.env`

| Variable | Where it comes from |
|---|---|
| `PUID` / `PGID` | The stack user's fixed IDs — `2020` / `2020` for media |
| `TZ` | e.g. `Europe/Oslo` |
| `VPN_USER` / `VPN_PASS` | VPN provider credentials |
| `VPN_PROV` / `VPN_CLIENT` | Provider name, and `openvpn` or `wireguard` |
| `LAN_NETWORK` | LAN CIDR, e.g. `192.168.0.0/24` — required, or the VPN container blocks LAN access |
| `RADARR_API_KEY` / `SONARR_API_KEY` | Radarr/Sonarr → Settings → General, after first start |

## First-run order

1. **Prowlarr** — indexers, plus FlareSolverr as a proxy where needed
2. **Sonarr** / **Radarr** — Deluge as download client, root folders, connect Prowlarr
3. Copy their API keys into `.env`, then `docker compose up -d recyclarr`
4. **Jellyfin** / **Emby** / **Plex** — add libraries
5. **Seerr** — connect Sonarr/Radarr, set Application URL
6. **Bazarr** — subtitle providers, same libraries

## Hostnames instead of ports

An nginx container fronts everything on port 80, mapping `<service>.<domain>` to host ports
via a `map $host $upstream` block, with unmatched names falling through to Heimdall. The
actual config isn't in this repo — it's restored from backup.

Resolution is one wildcard record on the LAN DNS server, e.g. for Pi-hole v6:

```bash
sudo pihole-FTL --config misc.dnsmasq_lines '["address=/<domain>/<server-ip>"]'
sudo systemctl restart pihole-FTL
```

Two things that cost me time:

- The LAN DNS server must be the *only* resolver handed out by DHCP. A secondary entry means
  clients query both, so these names resolve intermittently.
- Pick a suffix whose TLD is in the Public Suffix List. Firefox-based browsers send `.lan` and
  `.internal` to search instead of navigating, and you can't fix that per-device at scale.

## Gotchas

- Verify a proxy by page title, not HTTP status — nginx's default vhost answers 200 with its
  own "Welcome to our server" page, so status codes look like success when routing is broken.
- Docker's published ports bypass firewalld; `network_mode: host` does not. Host-networked
  services need an explicit `firewall-cmd --add-port`.
- Emby is mapped to host port 8097 to avoid colliding with Jellyfin on 8096.
- nginx site configs go in `reverse/config/nginx/site-confs/`. Files in `reverse/config/` root
  are not read at all.

## Backups

See [`backup/`](backup/) — nightly `restic` to Jottacloud via `rclone`, stopping both stacks
first so the SQLite databases are consistent. Covers both home directories: compose files,
`.env`, VPN configs, nginx config, and all service appdata. Media libraries are not backed up.

Anything not in this repo — nginx config, `.env`, Home Assistant's `config/` — comes from
there.
