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
| `kept/` | `kept` | Kept — Google Keep style notes |
| `immich/` | `immich` | Immich — photo library |

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

### SELinux

The host runs SELinux **Permissive**, and `/mnt/0_data` has no `security.selinux` extended
attributes at all — everything on it is `unlabeled_t`. Docker runs with `--selinux-enabled`, so
every container write to a bind mount raises an AVC denial. Nothing is blocked, but
`setroubleshootd` analyses each denial and will peg a CPU core during anything write-heavy.

`setroubleshoot-server` was removed. In Permissive mode it is pure overhead — it only produces
human-readable reports about denials that were never enforced — so removing it weakens nothing.

Bind-mounted directories are labelled with `semanage` + `restorecon`, not plain `chcon`, which
records no rule and is undone by any future relabel:

```bash
sudo semanage fcontext -a -t container_file_t '/mnt/0_data/nextcloud(/.*)?'
sudo restorecon -R /mnt/0_data/nextcloud
```

Same for `/home/nextcloud/html`, `/home/nextcloud/postgres`, `/home/homeassistant/config` and
`/home/mediaman/docker-automatic-media-server`. The `/home/<user>` directories themselves stay
`user_home_t` — only what containers actually touch is relabelled.

Do **not** "fix" this by adding `:z`/`:Z` to compose volumes: Docker relabels the whole mount
recursively on every container start, which on a large data directory stalls every restart
including the nightly backup's stop/start cycle, and `:Z` breaks two services sharing one
directory. Do **not** `audit2allow` either — the label is wrong, and a policy module papering
over it is the worse fix.

### Storage mounts

Root and `/home` are xfs on LVM (`sda`). Two ext4 data disks carry the media:

| Mount | Device | Role |
|---|---|---|
| `/mnt/0_data` | `sdb1` | Bulk storage — tv, movies, mma, torrent downloads, the Immich photo library |
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
| `kept/` | `kept` | 2023:2023 |
| `immich/` | `immich` | 2024:2024 |

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

# kept
sudo groupadd -g 2023 kept
sudo useradd -m -u 2023 -g 2023 -s /bin/bash kept
sudo usermod -aG docker kept

# immich
sudo groupadd -g 2024 immich
sudo useradd -m -u 2024 -g 2024 -s /bin/bash immich
sudo usermod -aG docker immich

id mediaman; id homeassistant; id nextcloud; id kept; id immich   # confirm the numbers
```

If an ID is already taken, `groupadd`/`useradd` fail rather than silently picking another —
fix the collision instead of changing the ID.

Next stack gets 2025, and so on. Add it to the table.

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

Note that `binhex/arch-delugevpn` **logs `VPN_USER` and `VPN_PASS` in plaintext** at info
level on every start. Treat `docker compose logs deluge` as containing credentials, and rotate
them if that output is ever pasted anywhere.

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
no automated install and serves self-signed HTTPS on 443, which doesn't fit the shared
`map $host $upstream` used by everything else.

Photos are **not** in Nextcloud — they live in Immich, see below. What's left here is
Documents, Notes, calendars and contacts, so the data directory is small (a few hundred KB at
the time of writing). The bulk-disk layout is kept anyway, so putting large files back later
needs no migration — `/home` is only 76G:

```bash
sudo mkdir -p /mnt/0_data/nextcloud /home/nextcloud/{html,postgres}
sudo chown 33:33 /mnt/0_data/nextcloud /home/nextcloud/html
sudo chown 2022:2022 /home/nextcloud
```

`NEXTCLOUD_DATA_DIR=/var/www/data` points the instance at the bind mount. There is no bind
mount into `/home/nextcloud/data` — the real path is referenced directly.

**Do not pin `overwriteprotocol` or `overwritehost`.** They are deliberately absent from the
compose file and deleted from `config.php`, so `X-Forwarded-Proto` decides the scheme per
request and both `http://` and `https://` work correctly. With `OVERWRITEPROTOCOL=http` set,
Nextcloud answers HTTPS requests with `Location: http://...` — silently downgrading TLS
clients to plaintext and breaking the web UI through mixed-content blocking. `OVERWRITECLIURL`
*is* set, because cron has no request to infer a scheme from.

Note the ordering trap: `occ config:system:delete <key>` followed by `docker compose up -d`
re-applies the value from the env var. Remove it from the compose file **first**, then delete,
then confirm with `config:system:get`.

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

Long-running `occ` jobs survive an ssh disconnect without tmux by running detached inside the
container, writing to a log on the bind mount:

```bash
docker exec -d -u www-data nextcloud \
  sh -c 'php occ preview:generate-all > /var/www/data/preview.log 2>&1'
sudo tail -f /mnt/0_data/nextcloud/preview.log
```

Delete those logs afterwards, or `files:scan` indexes them as user files.

### kept

[Kept](https://github.com/ericerkz/kept) — a self-hosted, Google Keep style notes app with
checklists. Single container, SQLite, native iOS and Android apps, and a Google Keep Takeout
importer. It honours `PUID`/`PGID`, so unlike Nextcloud the 2023 IDs apply to the data files.

Published on host port **6868**, not its native 6767 — that collides with Bazarr. `PORT: 6767`
stays as-is; only the left side of the port mapping changes.

```bash
sudo mkdir -p /home/kept/data
sudo chown -R 2023:2023 /home/kept
```

Notes:

- **Requires HTTPS.** Note creation calls `crypto.randomUUID()`, which browsers only expose in
  a secure context. On plain HTTP the Close button hangs and nothing is ever saved — with no
  error shown and no request in the server log, because the request is never sent. See **TLS
  certificates** below.
- `KEPT_CORS_ALLOW_ALL=1` is set because the native app shells use a different origin than the
  web UI. Acceptable here: the instance is reachable only from the LAN and over WireGuard.
- `KEPT_ALLOW_RESTORE` is deliberately unset — with it enabled, anyone holding an auth token
  can overwrite the entire database from a backup file. Set it only while actually restoring.
- Realtime collaboration uses a WebSocket at `/api/realtime`. The existing `location /` block
  already forwards `Upgrade`/`Connection`, so no extra proxy config is needed.
- The project moves fast — consider pinning a version tag rather than `:latest`, since the
  nightly backup's `up -d` would otherwise upgrade it unattended.

### immich

[Immich](https://immich.app) — the photo library. Replaced Nextcloud's Photos and Memories,
which were too slow to browse and had no usable Android widget. Published on host port 2283.

Adapted from the [official compose file](https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml),
with three deliberate deviations:

- **`immich-machine-learning` removed.** No face recognition or semantic search wanted. It
  must ALSO be disabled in Administration → Settings → Machine Learning, or the server queues
  jobs for a container that isn't there — on first import that was ~50,000 dead jobs competing
  with the actual work. The Smart Search, Face Detection, Facial Recognition, Duplicate
  Detection and OCR queues can then be cleared and paused.
- **`restart: unless-stopped`** instead of upstream's `always`, so a docker daemon restart
  during the nightly backup can't bring containers up while the stack is meant to be stopped.
- **`IMMICH_VERSION` pinned to a release** rather than the moving `v3` tag. Immich ships
  breaking changes between majors — 1.x → 2.x → 3.x within 2026 — so read the release notes
  before bumping.

The database image is **not** interchangeable with vanilla postgres: it carries the
vectorchord/pgvectors extensions Immich requires. It and valkey are digest-pinned upstream;
leave those alone.

Immich has no `PUID`/`PGID` — it runs as root in the container, so the 2024 IDs are
organisational, like Nextcloud's 2022.

```bash
sudo mkdir -p /mnt/0_data/immich /home/immich/postgres
sudo chown -R 2024:2024 /home/immich /mnt/0_data/immich
```

`UPLOAD_LOCATION` points at the bulk disk (the library is ~190 GB); `DB_DATA_LOCATION` stays
under `/home/immich` so restic covers it. Network shares are not supported for the database.

Set the **storage template** before importing anything — "template changes only apply to new
assets", so changing it later means a migration job over every file. `{{y}}/{{MM}}/{{filename}}`
matches how the library was already laid out.

Bulk import uses the official CLI, pointed at the container directly rather than through nginx
so large videos don't hit the proxy's read timeout:

```bash
docker run --rm -v /path/to/photos:/import:ro \
  -e IMMICH_INSTANCE_URL=http://192.168.0.62:2283/api \
  -e IMMICH_API_KEY='<key>' \
  ghcr.io/immich-app/immich-cli:latest upload --recursive --dry-run /import
```

Notes from doing it once:

- Always `--dry-run` first; it reports the file count and byte total so you can reconcile
  against the source before committing.
- Mount the source `:ro` so the CLI cannot touch the originals.
- Dedup is by file hash, so re-running is safe and overlapping folders don't double up. But
  **editing a file changes its hash** — fixing EXIF after upload means deleting and re-uploading,
  not re-scanning.
- Don't use `--album`: it names albums after the containing folder, which for a `year/month`
  tree gives 300 albums called "5".

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

An nginx container fronts everything on ports 80 and 443, mapping `<service>.<domain>` to host
ports via a `map $host $upstream` block, with unmatched names falling through to Heimdall. The
actual config isn't in this repo — it's restored from backup.

Port 443 needs **its own `server` block** in `services.conf`, reusing the same map. Without one,
the linuxserver image's `default.conf` answers 443 with its bundled self-signed certificate and
serves the "Welcome to our server" page. Every Nextcloud-style client app then prompts to trust
a fingerprint, you accept, and it fails with "could not connect to server" — because after the
prompt it reaches nginx's default vhost rather than the application. Two apps were nearly
written off as buggy over this.

The domain is `h.example.com`, a sub-label of a domain we actually own. An earlier setup used
`saturn.io`, which we do **not** own: that made a real certificate impossible, and any client
falling back to public DNS would have resolved our service names against a stranger's zone.

The sub-label rather than the apex is deliberate. A Pi-hole wildcard on `example.com` would
hijack `ving.example.com` and the apex from inside the house, needing a growing exception list,
and a `*.example.com` private key sitting on this nginx could impersonate our public
infrastructure. Flat names with one explicit Pi-hole entry per service would also work; the
sub-label was chosen for less ongoing maintenance.

Resolution is one wildcard record on the LAN DNS server, e.g. for Pi-hole v6:

```bash
sudo pihole-FTL --config misc.dnsmasq_lines '["address=/h.example.com/192.168.0.62"]'
sudo systemctl restart pihole-FTL
```

Two things that cost me time:

- The LAN DNS server must be the *only* resolver handed out by DHCP. A secondary entry means
  clients query both, so these names resolve intermittently.
- Pick a suffix whose TLD is in the Public Suffix List. Firefox-based browsers send `.lan` and
  `.internal` to search instead of navigating, and you can't fix that per-device at scale.

### TLS certificates

A Let's Encrypt wildcard for `h.example.com` + `*.h.example.com`, issued by `acme.sh` over
**DNS-01** against Cloudflare. Nothing is exposed to the internet and no permanent public DNS
record exists — DNS-01 needs only a `_acme-challenge` TXT record, which acme.sh adds and
removes during issuance. Resolution stays inside Pi-hole.

```bash
curl https://get.acme.sh | sh -s email=<you@example.com>
acme.sh --set-default-ca --server letsencrypt

export CF_Token="<Cloudflare token: Zone:Zone:Read + Zone:DNS:Edit, scoped to the zone>"
acme.sh --issue --dns dns_cf -d h.example.com -d '*.h.example.com'

KEYS=/home/mediaman/docker-automatic-media-server/reverse/config/keys
acme.sh --install-cert -d h.example.com --ecc \
  --key-file       "$KEYS/cert.key" \
  --fullchain-file "$KEYS/cert.crt" \
  --reloadcmd      "chown 2020:2020 $KEYS/cert.key $KEYS/cert.crt && docker exec reverse nginx -s reload"
```

Both names are needed — the wildcard does not cover the bare `h.example.com`. `--ecc` is needed
on install because acme.sh issues ECDSA by default and stores it in a separate directory.
Installing to `cert.crt`/`cert.key` means nginx needs no config change: it already points at
`/config/keys/`.

acme.sh installs its own cron entry and renews automatically, re-running that reloadcmd. It
takes the renewal date from the CA's ARI endpoint, roughly 30 days before expiry.

Why this matters beyond the browser warning — with a self-signed certificate, or none:

- **Secure-context APIs are unavailable.** `crypto.randomUUID()` doesn't exist, so Kept can't
  create notes at all. Nextcloud loses copy-to-clipboard, service workers and passkeys.
- **iOS refuses CalDAV** without a trusted certificate.
- **Android client apps** fail after the fingerprint prompt, per the 443 block note above.

Two certificate traps that cost time:

- The linuxserver image's stock certificate is `CN=*` with **no extensions at all** — no
  `subjectAltName`. Modern clients ignore CN entirely and require a SAN, so it can never match
  a hostname no matter what you tap "trust" on.
- Verify with `openssl x509 -noout -dates -issuer -ext subjectAltName`, and by `curl` *without*
  `-k`. A page loading is not evidence the certificate is right.

### Reaching these names remotely

Remote access is WireGuard on the ASUS router (VPN → VPN Server → WireGuard), not on the
server. Split tunnel: `AllowedIPs = 192.168.0.0/24,10.6.0.0/24`, endpoint
`<router-ddns-name>:51820`, clients on `10.6.0.0/24`.

Two changes are needed or `<service>.h.example.com` will not resolve over the tunnel, even
though `192.168.0.62:<port>` works fine:

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
fine — but `dig @192.168.0.59 jellyfin.h.example.com` times out.

**2. Each client config must point at Pi-hole.** The router generates `DNS = 10.6.0.1`, which is
the router itself; it resolves via its own WAN DNS, not Pi-hole, so it answers these names from
public DNS. There is no DNS field on this firmware's WireGuard page, so edit every exported
config:

```bash
sed -i 's/^DNS = .*/DNS = 192.168.0.59/' client.conf
qrencode -t ansiutf8 < client.conf     # scan straight from the terminal
```

**Only that one address.** Listing a second resolver — `10.6.0.1,192.168.0.59` — gives working
internet but breaks the homelab names: the router replies NXDOMAIN, which is a *valid* answer,
so the client never fails over to Pi-hole. Same reason DHCP's "DNS Server 2" is left empty.

Pointing the router's own **WAN → DNS Server 1** at `192.168.0.59` also works and needs no
client edits, but it was rejected deliberately: the router would then depend on Pi-hole to
resolve its own DDNS updates, so a Pi outage during a WAN IP change would kill remote access.

Exported configs contain private keys. They do not belong in this repo.

While connected, Android sends *all* DNS to the tunnel's resolver, so every lookup goes via
Pi-hole at home — ad blocking follows you around, and if the Pi is down, connected clients have
no DNS at all.

Testing notes:

- Termux's `dig` ignores the Android system resolver and defaults to `8.8.8.8`, so a bare
  `dig +short jellyfin.h.example.com` returns nothing even when everything works. Test in a
  browser, or name the server: `dig @192.168.0.59 jellyfin.h.example.com`.
- Test from mobile data, never from the home wifi — hairpin NAT gives a misleading result.
- Android **Private DNS** and browser **DoH** bypass the tunnel's resolver entirely, so the
  names fail to resolve. Turn Private DNS off.

## Gotchas

- Verify a proxy by page title, not HTTP status — nginx's default vhost answers 200 with its
  own "Welcome to our server" page, so status codes look like success when routing is broken.
- Docker's published ports bypass firewalld; `network_mode: host` does not. Host-networked
  services need an explicit `firewall-cmd --add-port`.
- Emby is mapped to host port 8097 to avoid colliding with Jellyfin on 8096, and Kept to 6868
  to avoid Bazarr on 6767.
- nginx site configs go in `reverse/config/nginx/site-confs/`. Files in `reverse/config/` root
  are not read at all.
- Nextcloud answers `/` with a 302 to `/login`, so a `curl` without `-L` returns a body with no
  `<title>` — that's not a failure. A 400 from Nextcloud means the hostname isn't in
  `trusted_domains`.
- `/usr/local/sbin` is a **symlink to `/usr/local/bin`** on this Fedora. A script appearing at
  both paths is one file, not two copies — do not "clean up" the duplicate.
- systemd sets no `HOME` for a root service. `restic` needs it for its cache and `rclone` for
  `/root/.config/rclone/rclone.conf`, so `homelab-backup.sh` exports `HOME=/root` explicitly.
  Without it the timer fails in seconds while manual runs succeed, because `sudo` supplies
  `HOME`. When a scheduled job "works when I run it by hand", check the systemd environment
  first.
- Docker does not always release a published port the instant a container stops, so an
  immediate `up -d` can fail with "address already in use". `homelab-backup.sh` retries once
  after 15 seconds; a container left in that failed state needs `docker compose rm -sf` and a
  fresh `up -d`, because restarting reuses the broken network config.

## Backups

See [`backup/`](backup/) — nightly `restic` to Jottacloud via `rclone`, stopping all stacks
first so the databases are consistent. Covers every stack home directory: compose files,
`.env`, VPN configs, nginx config, TLS certificates, and all service appdata. Media libraries
are not backed up.

**Photo libraries are deliberately excluded.** Every phone auto-uploads to Jottacloud
independently, so backing them up would put a second copy of the same files into the same
provider. That means `/mnt/0_data/immich` is not a restic path at all, and any future
Nextcloud `Photos` folder is excluded by glob — so re-using Nextcloud for photos later can't
silently start shipping hundreds of GB.

What **is** backed up is the half that exists nowhere else:

| Path | Why |
|---|---|
| `/home/nextcloud` | PostgreSQL — accounts, groups, quotas, shares, calendars, contacts |
| `/home/immich` | PostgreSQL — albums, corrected dates, all organisation |
| `/home/kept` | SQLite notes |
| `/mnt/0_data/nextcloud` | Documents and Notes — small, and Jottacloud does *not* have these |

That last one matters: while Nextcloud held the photos it was excluded, and Jottacloud was the
justification. Once the photos moved to Immich the only things left were Documents and Notes,
which have no second copy anywhere — so the exclusion became a gap and the path was added.
Photos and the regenerable preview cache stay excluded:

```
--exclude '/mnt/0_data/nextcloud/*/files/Photos'
--exclude '/mnt/0_data/nextcloud/appdata_*/preview'
```

Stopping each stack gives PostgreSQL and SQLite a clean shutdown, which is what makes a
file-level copy of their data directories consistent. No `pg_dump` step is needed.

Immich's organisation — albums, every corrected date, every manual fix — lives only in its
Postgres. The photos themselves can be re-downloaded from Jottacloud; that work cannot.

A separate **hourly container health check** (`backup/container-health.sh`, run by
`container-health.timer`) compares `docker compose config --services` against
`ps --services --status running` for every stack and alerts on anything missing. It needs no
hardcoded container list, so new services are covered automatically.

That exists because the backup only looks at 04:00, and because a failed restart used to be
invisible: `finish()` brought each stack up with `|| true`, so on 2026-09-01 Deluge failed to
bind a port, stayed down for six hours, and the run still reported success. `finish()` now
retries once and reports `/fail` if any stack is still down — a backup that succeeds but leaves
a stack down is not a success.

`/root/.acme.sh/` holds the ACME account key and the Cloudflare API token. It is deliberately
**not** in the restic paths: a rebuild means re-issuing the certificate, which takes about a
minute with a fresh token, and that avoids putting a live credential in the backup.

Anything not in this repo — nginx config, `.env`, Home Assistant's `config/` — comes from
there. Failures alert via healthchecks.io.

Pi-hole's own config is exported nightly and folded into the same repository — see
[`pihole/`](pihole/).
