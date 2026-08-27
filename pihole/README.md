# Pi-hole

Pi-hole runs on a Raspberry Pi at `192.168.0.59`, separate from the docker host. It is the
LAN's only resolver, handed out by the router's DHCP, and it holds the wildcard record that
makes `<service>.<domain>` reach the reverse proxy.

Nothing here configures Pi-hole itself — it's a normal install. This directory only covers
getting its config into the backups.

## Config backup

`pihole-FTL --teleporter` exports the whole configuration — `pihole.toml`, adlists, groups,
clients, and local DNS records — as a single zip. The Pi writes one weekly (Pi-hole config
changes rarely); the docker host rsyncs the directory nightly and folds it into its restic
repository, so the Pi needs no cloud credentials of its own.

The nightly pull against a weekly export costs nothing: rsync is a no-op when the file hasn't
changed, and restic deduplicates it away.

| File | Installed to (on the Pi) |
|---|---|
| `pihole-teleporter.sh` | `/usr/local/sbin/pihole-teleporter.sh` (mode 700) |
| `pihole-teleporter.service` | `/etc/systemd/system/` |
| `pihole-teleporter.timer` | `/etc/systemd/system/` |

Timing: the export runs Sundays at 03:30 and the docker host pulls at 04:00, so Sunday night's
snapshot picks up that morning's export. The script keeps the newest 3 archives, i.e. about
three weeks, with older history coming from restic's own retention.

### Install, on the Pi

```bash
sudo install -m 700 pihole-teleporter.sh /usr/local/sbin/pihole-teleporter.sh
sudo install -m 644 pihole-teleporter.service pihole-teleporter.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now pihole-teleporter.timer
sudo /usr/local/sbin/pihole-teleporter.sh
ls -la /home/pi/pihole-backups/
```

### SSH key, on the docker host

Root pulls as the `pi` user, which is why the script writes to `/home/pi` rather than
`/var/backups` — no passwordless sudo needed on the Pi.

```bash
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519
sudo ssh-copy-id -i /root/.ssh/id_ed25519.pub pi@192.168.0.59
sudo ssh -o BatchMode=yes pi@192.168.0.59 'ls pihole-backups/'
```

That last command must succeed without a prompt, or the nightly pull fails.

## Restoring

Settings → Teleporter in the Pi-hole UI, upload the newest zip. Or from the backup:

```bash
R="-r rclone:jotta:restic-homelab --password-file /root/.restic-password"
sudo restic $R restore latest --target /tmp/ph --include /var/backups/pihole
ls /tmp/ph/var/backups/pihole/
```

On a from-scratch rebuild, the two things that must be true regardless of the import:

```bash
sudo pihole-FTL --config misc.dnsmasq_lines '["address=/<domain>/<server-ip>"]'
sudo systemctl restart pihole-FTL
```

and the router handing out the Pi as the **only** DNS server — a secondary entry means clients
query both and internal names resolve intermittently.

Note Pi-hole v6 has no `/etc/pihole/dnsmasq.d/`, and ignores `/etc/dnsmasq.d/` unless
`misc.etc_dnsmasq_d` is set true. Use `misc.dnsmasq_lines` as above.
