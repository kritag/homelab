# homelab

Docker Compose stacks for my home server. Config only — no data, no secrets.
State lives in backups, not here.

## Pattern: one stack per user

Each stack gets its own Unix account, its own compose project, and its own `.env`:

| Directory | User | What it is |
|---|---|---|
| `media/` | `mediaman` | *arr apps, Deluge behind VPN, Jellyfin/Emby/Plex, Heimdall, nginx |
| `homeassistant/` | `homeassistant` | Home Assistant |
| `nextcloud/` | `nextcloud` | Nextcloud, PostgreSQL, Redis |

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
| `/mnt/0_data` | `sdb1` | Bulk storage — tv, movies, mma, torrent downloads, Nextcloud user data |
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

Nextcloud is the exception: its directory under `/mnt/0_data` is owned `33:33`, not `2020:2020`
— see **nextcloud** below. Create it *after* the recursive chown above, or it gets clobbered.

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
| `nextcloud/` | `nextcloud` | 2022:2022 |

```bash
# media
sudo groupadd -g 2020 mediaman
sudo useradd -m -u 2020 -g 2020 -s /bin/bash mediaman
sudo usermod -aG docker mediaman

# homeassistant
sudo groupadd -g 2021 homeassistant
sudo useradd -m -u 2021 -g 2021 -s /bin/bash homeassistant
sudo usermod -aG docker homeassistant

# nextcloud
sudo groupadd -g 2022 nextcloud
sudo useradd -m -u 2022 -g 2022 -s /bin/bash nextcloud
sudo usermod -aG docker nextcloud

id mediaman; id homeassistant; id nextcloud      # confirm the numbers
```

If an ID is already taken, `groupadd`/`useradd` fail rather than silently picking another —
fix the collision instead of changing the ID.

Next stack gets 2023, and so on. Add it to the table.

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

### nextcloud

Official `nextcloud:34-apache` plus `postgres:17-alpine`, `redis:7-alpine`, and a fourth
container running the same image with `entrypoint: /cron.sh` for background jobs. Published on
host port 8080.

The official image ignores `PUID`/`PGID` — Apache is hardcoded to `www-data` (uid 33). So
unlike the media stack, the data directories are chowned `33:33`, and the 2022 user owns only
the home directory and runs `docker compose`. This is the tradeoff for env-var-driven install:
the admin account and database wiring live in the compose file, so the stack rebuilds
unattended. `linuxserver/nextcloud` honours 2022 and tracks upstream just as closely, but has
no automated install and serves self-signed HTTPS on 443, which doesn't fit the single
`proxy_pass http://$upstream` block in the nginx config.

User data lives on the bulk disk, not in the home directory — `/home` is only 76G:

```bash
sudo mkdir -p /mnt/0_data/nextcloud /home/nextcloud/{html,postgres}
sudo chown 33:33 /mnt/0_data/nextcloud /home/nextcloud/html
sudo chown 2022:2022 /home/nextcloud
```

`NEXTCLOUD_DATA_DIR=/var/www/data` points the instance at the bind mount. There is no bind
mount into `/home/nextcloud/data` — the real path is referenced directly.

No TLS: access is over WireGuard, so the tunnel already encrypts. `OVERWRITEPROTOCOL=http`.
The "accessing site insecurely via HTTP" and HSTS setup-check warnings are therefore expected
and should not be "fixed". The real cost is that copy-to-clipboard and service workers don't
work in the browser, and passkeys/WebAuthn are unavailable — TOTP is the usable second factor.

Settings covered by a compose environment variable are re-applied by the entrypoint on
container start and override the web UI. Change those in compose, not in Administration
settings — this bites hardest with the `SMTP_*` variables, which the upstream docs warn about
explicitly. Everything else — accounts, groups, quotas, apps, sharing — is stored in
PostgreSQL and is safe to manage from the UI.

Post-install, with no web equivalent:

```bash
docker exec -u www-data nextcloud php occ maintenance:repair --include-expensive
docker exec -u www-data nextcloud php occ config:system:set maintenance_window_start --type=integer --value=21
docker exec -u www-data nextcloud php occ config:system:set default_phone_region --value=NO
```

Hour 21 is UTC — 23:00–03:00 local, chosen to clear the 04:00 backup so the heavy daily jobs
don't fight it for I/O. Set a default quota before anyone connects a phone, or one client
auto-uploading video can fill `/mnt/0_data` and take the media stack down with it.

## Filling in `.env`

| Variable | Where it comes from |
|---|---|
| `PUID` / `PGID` | The stack user's fixed IDs — `2020` / `2020` for media |
| `TZ` | e.g. `Europe/Oslo` |
| `VPN_USER` / `VPN_PASS` | VPN provider credentials |
| `VPN_PROV` / `VPN_CLIENT` | Provider name, and `openvpn` or `wireguard` |
| `LAN_NETWORK` | LAN CIDR, e.g. `192.168.0.0/24` — required, or the VPN container blocks LAN access |
| `RADARR_API_KEY` / `SONARR_API_KEY` | Radarr/Sonarr → Settings → General, after first start |
| `POSTGRES_PASSWORD` / `REDIS_PASSWORD` | Nextcloud — generate with `openssl rand -base64 24` |
| `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` | Nextcloud — only read on first install |

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

### Reaching these names remotely

Remote access is WireGuard on the ASUS router (VPN → VPN Server → WireGuard), not on the
server. Split tunnel: `AllowedIPs = 192.168.0.0/24,10.6.0.0/24`, endpoint
`<router-ddns-name>:51820`, clients on `10.6.0.0/24`.

Two changes are needed or `<service>.saturn.io` will not resolve over the tunnel, even though
`192.168.0.62:<port>` works fine:

**1. Pi-hole must answer the WireGuard subnet.** The router routes VPN clients without NAT, so
queries arrive from `10.6.0.x` — a foreign subnet — and Pi-hole v6's default `LOCAL` listening
mode silently drops them:

```bash
sudo pihole-FTL --config dns.listeningMode ALL
sudo systemctl restart pihole-FTL
```

Safe, because the Pi has no port forward — only the LAN and VPN clients can reach it.

The symptom, if this is wrong: from a connected client,
`curl -o /dev/null -w '%{http_code}' http://192.168.0.59/admin/` returns 302 — so routing is
fine — but `dig @192.168.0.59 jellyfin.saturn.io` times out.

**2. Each client config must point at Pi-hole.** The router generates `DNS = 10.6.0.1`, which is
the router itself; it resolves via its own WAN DNS, not Pi-hole, so it answers `*.saturn.io`
from the real public zone. There is no DNS field on this firmware's WireGuard page, so edit
every exported config:

```bash
sed -i 's/^DNS = .*/DNS = 192.168.0.59/' client.conf
qrencode -t ansiutf8 < client.conf     # scan straight from the terminal
```

**Only that one address.** Listing a second resolver — `10.6.0.1,192.168.0.59` — gives working
internet but breaks `*.saturn.io`: the router replies NXDOMAIN, which is a *valid* answer, so
the client never fails over to Pi-hole. Same reason DHCP's "DNS Server 2" is left empty.

Pointing the router's own **WAN → DNS Server 1** at `192.168.0.59` also works and needs no
client edits, but it was rejected deliberately: the router would then depend on Pi-hole to
resolve its own DDNS updates, so a Pi outage during a WAN IP change would kill remote access.

Exported configs contain private keys. They do not belong in this repo.

While connected, Android sends *all* DNS to the tunnel's resolver, so every lookup goes via
Pi-hole at home — ad blocking follows you around, and if the Pi is down, connected clients have
no DNS at all.

Testing notes:

- Termux's `dig` ignores the Android system resolver and defaults to `8.8.8.8`, so a bare
  `dig +short jellyfin.saturn.io` returns nothing even when everything works. Test in a browser,
  or name the server: `dig @192.168.0.59 jellyfin.saturn.io`.
- Test from mobile data, never from the home wifi — hairpin NAT gives a misleading result.
- Android **Private DNS** and browser **DoH** bypass the tunnel's resolver entirely. Both bite
  here specifically because `saturn.io` is a real registered domain that resolves publicly, so
  the failure is a confident wrong answer rather than an obvious error.
~

## Gotchas

- Verify a proxy by page title, not HTTP status — nginx's default vhost answers 200 with its
  own "Welcome to our server" page, so status codes look like success when routing is broken.
- Docker's published ports bypass firewalld; `network_mode: host` does not. Host-networked
  services need an explicit `firewall-cmd --add-port`.
- Emby is mapped to host port 8097 to avoid colliding with Jellyfin on 8096.
- nginx site configs go in `reverse/config/nginx/site-confs/`. Files in `reverse/config/` root
  are not read at all.
- Nextcloud answers `/` with a 302 to `/login`, so a `curl` without `-L` returns a body with no
  `<title>` — that's not a failure.

## Backups

See [`backup/`](backup/) — nightly `restic` to Jottacloud via `rclone`, stopping all three
stacks first so the databases are consistent. Covers all three home directories: compose
files, `.env`, VPN configs, nginx config, and all service appdata. Media libraries are not
backed up.

Nextcloud's user data (`/mnt/0_data/nextcloud`) is also excluded: every phone auto-uploads to
Jottacloud independently, so backing it up would put a second copy of the same photos in the
same provider. Only `/home/nextcloud` is backed up — PostgreSQL (accounts, groups, quotas,
shares, file IDs), `config.php` and `.env`, which is the half that can't be reconstructed.
The tradeoff to be aware of: anything created *directly* in Nextcloud rather than uploaded
from a phone — laptop uploads, scans, server-side albums — never passes through Jottacloud and
so has no second copy anywhere.

Stopping the Nextcloud stack gives PostgreSQL a clean shutdown, which is what makes a
file-level copy of its data directory consistent. No `pg_dump` step is needed.

Anything not in this repo — nginx config, `.env`, Home Assistant's `config/` — comes from
there. Failures alert via healthchecks.io.

Pi-hole's own config is exported nightly and folded into the same repository — see
[`pihole/`](pihole/).
