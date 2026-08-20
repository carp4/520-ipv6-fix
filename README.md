# 520 IPv6 Fix — 6relayd / radvd passthrough

![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-RM520N--GL-orange)
![Install](https://img.shields.io/badge/install-one%20line-blue)

Fixes the **"silent IPv6 death"** on the Quectel RM520N-GL: the stock
QCMAP-managed radish keeps running but silently stops sending Router
Advertisements, so LAN clients never get — or never keep — a global IPv6
address.

## What's actually wrong

Quectel's firmware uses `radish` to advertise the carrier /64 to LAN clients.
On many units it stops advertising entirely after a while, and because the
radish RAs carry **infinite lifetimes**, stale prefixes also never expire on
clients. Result: test-ipv6.com scores 0/10 while the modem itself is
perfectly healthy — Windows just picks a dead prefix as its source address.

This project replaces radish's advertising job with a self-managed `radvd`
that:

- reads the carrier /64 from the data interface (`rmnet_data0/1/2`)
- routes it to `bridge0` with the WAN's `autoconf=0`, so the /64 is never
  claimed on-link on the WAN (the ambiguity that breaks return traffic)
- advertises it with radvd (RDNSS: Cloudflare `2606:4700:4700::1111`)
- **withdraws stale prefixes** — when the carrier hands out a new /64 on a
  re-dial, old prefixes are re-advertised with zero lifetimes so clients
  drop them immediately instead of stalling for hours
- strips QCMAP's ULA so clients hold a clean single global
- survives reboots and re-dials (prefix state persisted to
  `/usrdata/at-stock-ui/ipv6.prefix`)

## Requirements

- Quectel **RM520N-GL** modem with SSH or ADB root access
- **radvd** — the installer auto-installs it via opkg (Entware) if the
  firmware build shipped without it
- Your carrier must **route a /64 to the modem** (verified across T-Mobile,
  Verizon, and AT&T). If your carrier hands out only a single address or an
  on-link /64, the routed-passthrough model doesn't apply.

## Install — one command, run ON the modem

```sh
curl -fsSL https://raw.githubusercontent.com/carp4/520-ipv6-fix/main/install-on-device.sh | sh
```

- SSH into the modem as root first, then paste the line.
- It asks for confirmation first (**1** = install, **0** = exit) and never
  installs blindly: it prompts on the interactive terminal (root shell,
  `adb shell`, or `curl ... | sh` pasted at a terminal), and a non-TTY run
  (e.g. `printf '1\n' | ssh root@<modem> 'sh /tmp/install-on-device.sh'`)
  accepts one confirmation line from stdin, so no pty is required.
- Idempotent — safe to re-run on an already-fixed modem.
- **No reboot required.** The service starts immediately and survives
  reboots (persistent rootfs + manual wants symlinks, see below).

Prefer deploying from a laptop? The repo also ships a one-shot SSH driver:

```sh
./install-ipv6-fix.sh <modem-ip> [ssh-user]
```

## CRITICAL: how boot persistence works on this firmware

The units always live in **`/lib/systemd/system/`** (the rootfs). The
installer remounts the rootfs rw if it looks read-only. This matters because
on these firmware builds `/etc` is a separate UBI volume that mounts **after**
systemd has processed the boot transaction — `systemctl enable` writes into
`/etc/systemd/system/*.wants/`, which boot systemd never scans, so units
enabled there silently never start (observed: enabled + symlink present +
reboot → `inactive (dead)`, `NRestarts=0`). Enabling is therefore done by
**manual wants symlinks in `/lib`**, and `systemctl is-enabled` will lie.

The installer also keeps **identical mirror copies in
`/etc/systemd/system/`**: systemd prefers /etc over /lib, but identical
copies make that preference harmless, and the /etc copies are what survive
an OTA that wipes `/lib` — they're the reapply script's recovery source.
Never let the two diverge.

## Verify

```sh
systemctl is-active rm520-6relayd.service        # active
systemctl is-active rm520-6relayd-watchdog.timer # active
cat /tmp/lp-radvd.pid                            # radvd pid (alive)
radvd -c -C /tmp/lp-radvd.conf                   # config: syntax ok
cat /usrdata/at-stock-ui/ipv6.prefix             # current carrier /64
ip -6 addr show bridge0                          # globals being served
```

Note: `ps w | grep radvd` shows **two** processes — radvd 2.18 forks a child
even in `-n` mode. That pair is normal; the pidfile owns the parent.

## After a firmware update (OTA)

A firmware update wipes `/lib` (rootfs). Re-apply on the modem with:

```sh
sh /usrdata/scripts/reapply-ipv6-relay.sh
```

It restores the units from the `/etc` mirrors, re-creates the wants symlinks,
retires the legacy `lettucepi` units, and restarts the service.

## Rollback

Run in this order — the watchdog fires every 60s and will restart the
service if it's still installed:

```sh
rm /lib/systemd/system/rm520-6relayd.service \
   /lib/systemd/system/rm520-6relayd-watchdog.service \
   /lib/systemd/system/rm520-6relayd-watchdog.timer \
   /lib/systemd/system/multi-user.target.wants/rm520-6relayd.service \
   /lib/systemd/system/timers.target.wants/rm520-6relayd-watchdog.timer \
   /etc/systemd/system/rm520-6relayd.service \
   /etc/systemd/system/rm520-6relayd-watchdog.service \
   /etc/systemd/system/rm520-6relayd-watchdog.timer
systemctl daemon-reload
systemctl stop rm520-6relayd.service rm520-6relayd-watchdog.timer 2>/dev/null
[ -f /tmp/lp-radvd.pid ] && kill "$(cat /tmp/lp-radvd.pid)" 2>/dev/null
rm -f /tmp/lp-radvd.conf
```

(`pkill` is unreliable on this firmware — the pidfile kill is the way.)

## Files

| File | Purpose |
|------|---------|
| `6relayd-run.sh` | Main loop: prefix tracking, routing, radvd, stale-prefix withdrawal |
| `6relayd-watchdog.sh` | Restarts the service if it dies |
| `rm520-6relayd.service` | Runs the main loop, `Restart=always` |
| `rm520-6relayd-watchdog.service` / `.timer` | Watchdog, every 60s (OnBootSec=90) |
| `install-on-device.sh` | Self-contained on-device installer (the one-liner) |
| `install-ipv6-fix.sh` | SSH deployer for laptop use |
| `reapply-ipv6-relay.sh` | Post-OTA re-apply helper |

## Notes

- Verified across T-Mobile, Verizon, and AT&T (whole-/64 routed to the
  modem). Other carriers may behave differently.
- License: MIT — use it, fix it, share it. No warranty, and test on a unit
  you can afford to reboot before trusting it with your main line.