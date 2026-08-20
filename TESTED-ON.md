# Tested Units

Modems this fix has been deployed and verified on by the maintainers.
Firmware strings come from `/etc/quectel-project-version`; kernels from
`uname -a`. No IP addresses or device nicknames are listed here on purpose.

| Model / Firmware | Package date | Kernel / platform | Carrier | Fix build | Status |
|---|---|---|---|---|---|
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | AT&T unit — T-Mobile SIM (currently on AT&T PLMN 310410) | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Full-flashed to stock and reinstalled via adb (QManager, tailscale, this fix). At first install `/lib` was read-only, so units were deployed to `/etc` — boot auto-start FAILED (verified twice: enabled + wants symlink + reboot → `inactive (dead)`, NRestarts=0; `/etc` is a separate UBI volume that mounts after systemd's boot scan). Fixed by moving units + wants symlinks to `/lib` (rootfs remount) — reboot-proven (auto-start at boot, correct prefix advertised, tailscale autostart restored). Caught up to the launch-wait engine (2026-08-20); relay active, timer active, radvd running, config valid, double-run refused |
| RM520NGL_VC — `RM520NGLAAR03A03M4G_01.201` | 2024-03-01 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused. Reinstalled by maintainer via public one-liner (2026-08-20), engine md5-matched to `main`, reboot auto-start OK |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused. Caught up to launch-wait engine (2026-08-20), engine md5-matched to `main`; downstream OpenWrt router verified end-to-end (SLAAC global + ping6 3/3) |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, stale prefix from an earlier re-dial self-corrected on install, manual double-run refused. Caught up to launch-wait engine (2026-08-20), engine md5-matched to `main`; downstream OpenWrt router verified end-to-end (SLAAC global + ping6 3/3) |
| RM520NGL_VC — `RM520NGLAAR03A03M4G_A0.301` | 2025-05-28 | 5.4.210-perf / sdxlemur (armv7l) | Verizon Wireless | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused. Re-verified on launch-wait engine (2026-08-20), engine md5-matched to `main` |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | T-Mobile | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin, launch-wait) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, stale prefix from a dead radvd self-corrected on install, manual double-run refused. Caught up to launch-wait engine (2026-08-20), engine md5-matched to `main`; WAN IPv6 awaiting carrier data call at last check |
| RM520NGL_VC — `RM520NGLAAR01A08M4G_01.205` | 2024-09-27 | 5.4.210-perf / sdxlemur (armv7l) | Not reported | Current (single-instance guard, radvd pidfile lifecycle, `-p` pin) | Installed, verified: single instance, config valid, radvd pid STABLE (no 10s kill/restart churn — Entware radvd 2.20 writes its pidfile to /opt/var/run, which exposed the build-dependent pidfile-path bug; `-p` pin fixes it). Reboot confirmation pending |

Verification checklist applied to each unit after install:

- `systemctl is-active rm520-6relayd.service` → active, `NRestarts` stable
- exactly one `6relayd-run.sh --systemd` process, matching the service MainPID
- `/tmp/lp-radvd.pid` exists and the pid is alive
- `radvd -c -C /tmp/lp-radvd.conf` → config valid
- `/usrdata/at-stock-ui/ipv6.prefix` equals the current WAN global prefix
- a manual `sh /usrdata/at-stock-ui/6relayd-run.sh` is refused while the
  service runs