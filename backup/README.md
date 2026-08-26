# Backups

Nightly `restic` backup of both stacks to Jottacloud via `rclone`. Encrypted client-side, so
the provider never sees plaintext.

| File | Installed to |
|---|---|
| `homelab-backup.sh` | `/usr/local/sbin/homelab-backup.sh` (mode 700) |
| `homelab-backup.service` | `/etc/systemd/system/` |
| `homelab-backup.timer` | `/etc/systemd/system/` |

## What is and isn't backed up

**In:** `/home/mediaman` and `/home/homeassistant` — compose files, `.env`, VPN provider
configs, nginx config, and all per-service appdata. That includes the parts that are genuinely
expensive to lose: the *arr databases, Jellyfin's `data/` (library, users, watch state,
downloaded subtitles, Intro Skipper fingerprints), Plex's `Plug-in Support/Databases` and
`Preferences.xml`, and Home Assistant's `config/` including `.storage`.

**Out:** the media libraries under `/mnt/*_data` — terabytes, and re-acquirable. Also excluded
are scraped artwork (Jellyfin `metadata/`, Plex `Metadata/`, `Media/`), caches, transcode
scratch and logs. A restore therefore comes back complete and then re-scrapes artwork in the
background over the following hours.

Roughly 1.5 GB per snapshot, deduplicated, so incrementals are small.

`~/git` is excluded because those repos have GitHub as their remote — which only holds for
work that's actually been pushed.

## Why the stacks are stopped

Everything here uses SQLite in WAL mode. Copying a live `.db` alongside its `-wal` can produce
a backup that restores into a corrupt database. Stopping the containers checkpoints the WAL
first. Cost is a few minutes of downtime at 04:00; the alternative is backups that look fine
until the day you need one.

The script `trap`s `EXIT` to restart both stacks even if the backup fails, so a network blip
can't leave the house without lights.

## Setup on a new host

```bash
sudo dnf install -y restic rclone
```

### 1. rclone remote

```bash
sudo rclone config
```

`n` → name `jotta` → type `jottacloud` → leave `client_id`/`client_secret` blank →
**Standard authentication** → paste a personal login token from
<https://www.jottacloud.com/web/secure> → accept the default device (`Jotta`) and mountpoint
(`Archive`) → `y` → `q`.

The token is single-use and short-lived, so reach the `login_token>` prompt *before* generating
it. Use `sudo` so the config lands in root's home where the timer can read it. Don't set a
config password — it would break unattended runs.

```bash
sudo chmod 600 /root/.config/rclone/rclone.conf
sudo rclone lsd jotta:
```

### 2. restic repository

```bash
openssl rand -base64 32 | sudo tee /root/.restic-password
sudo chmod 600 /root/.restic-password
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password init
```

**Store that password somewhere other than this machine.** It's the only part of this setup
that cannot be regenerated — an encrypted repo you can't decrypt is indistinguishable from no
backup at all. The rclone token, by contrast, is disposable: on a new host you just generate
another.

### 3. Install and schedule

```bash
sudo install -m 700 backup/homelab-backup.sh /usr/local/sbin/homelab-backup.sh
sudo install -m 644 backup/homelab-backup.service backup/homelab-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-backup.timer
systemctl list-timers homelab-backup.timer
```

`Persistent=true` means a run missed while the host was off fires on next boot.

### 4. First run, watched

```bash
sudo /usr/local/sbin/homelab-backup.sh
```

## Restoring

List what's there:

```bash
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password snapshots
```

Single file:

```bash
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password \
  restore latest --target /tmp/restore-test \
  --include /home/homeassistant/config/configuration.yaml
```

Full rebuild, in order: create the users with their fixed UIDs (see the top-level README —
mismatched IDs give you containers that can't read their own config), restore to `/`, then
`docker compose up -d` in each home.

```bash
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password \
  restore latest --target /
```

Test a restore periodically. An untested backup is a guess.

## Checking on it

```bash
systemctl list-timers homelab-backup.timer
journalctl -u homelab-backup.service -n 50
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password snapshots
```

Integrity check, worth running occasionally:

```bash
sudo restic -r rclone:jotta:restic-homelab --password-file /root/.restic-password \
  check --read-data-subset 5%
```

Nothing alerts on failure — a silently broken timer is the most likely way this setup rots, so
glance at `list-timers` now and then.

## Not covered

Pi-hole's config on the Raspberry Pi. Rebuilding it is two commands, both documented in the
top-level README, so this is a deliberate gap rather than an oversight.
