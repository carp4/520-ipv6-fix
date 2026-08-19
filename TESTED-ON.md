# Tested Units

Modems this fix has been deployed and verified on by the maintainers.
Firmware strings come from `/etc/quectel-project-version`; kernels from
`uname -a`. No IP addresses or device nicknames are listed here on purpose.

| Model / Firmware | Package date | Kernel / platform | Carrier | Fix build | Status |
|---|---|---|---|---|---|
| RM520NGL_VC — `RM520NGLAAR03A03M4G_A0.301` | 2025-05-28 | 5.4.210-perf / sdxlemur (armv7l) | AT&T | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused |
| RM520NGL_VC — `RM520NGLAAR03A03M4G_01.201` | 2024-03-01 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | Verizon 5G Home Internet | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, stale prefix from an earlier re-dial self-corrected on install, manual double-run refused |
| RM520NGL_VC — `RM520NGLAAR03A03M4G_A0.301` | 2025-05-28 | 5.4.210-perf / sdxlemur (armv7l) | Verizon Wireless | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, current prefix advertised, manual double-run refused |
| RM520NGL_PC15_VC — `RM520NGLAAR03A04M4G_A0.302` | 2026-01-17 | 5.4.210-perf / sdxlemur (armv7l) | T-Mobile | Current (single-instance guard, radvd pidfile lifecycle) | Installed, verified: 1 service instance, radvd alive via pidfile, config valid, stale prefix from a dead radvd self-corrected on install, manual double-run refused. Reinstalled after stock reflash via adb — read-only /lib build, units correctly deployed to /etc/systemd/system; relay active, timer active, radvd running, config valid |

Verification checklist applied to each unit after install:

- `systemctl is-active rm520-6relayd.service` → active, `NRestarts` stable
- exactly one `6relayd-run.sh --systemd` process, matching the service MainPID
- `/var/run/radvd.pid` exists and the pid is alive
- `radvd -c -C /tmp/lp-radvd.conf` → config valid
- `/usrdata/at-stock-ui/ipv6.prefix` equals the current WAN global prefix
- a manual `sh /usrdata/at-stock-ui/6relayd-run.sh` is refused while the
  service runs