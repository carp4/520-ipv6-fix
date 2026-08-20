520 IPv6 FIX (6relayd / radvd passthrough) - INSTALL NOTES
============================================================

Fixes the RM520N-GL "silent IPv6 death": stock QCMAP-managed radish
keeps running but stops sending Router Advertisements, so LAN clients
never get (or keep) a global IPv6 address. This replaces radish's
advertising job with a self-managed radvd, with stale-prefix withdrawal
on re-dial, ULA stripping, and crash recovery.

FILES IN THIS DIRECTORY
-----------------------
  6relayd-run.sh                   main loop: reads carrier /64 from
                                   rmnet_data0/1/2, routes it to bridge0,
                                   runs radvd (RDNSS Cloudflare), strips
                                   ULA, withdraws stale prefixes, keeps
                                   radvd alive (pidfile-based)
  6relayd-watchdog.sh              restarts the SERVICE if it dies (it
                                   must never run the main loop itself)
  rm520-6relayd.service            runs 6relayd-run.sh --systemd,
                                   Restart=always (single instance owner)
  rm520-6relayd-watchdog.service   oneshot; runs the watchdog script
  rm520-6relayd-watchdog.timer     fires the watchdog every 60s
  install-on-device.sh             self-contained on-device installer
                                   (also available as a one-liner)
  install-ipv6-fix.sh              laptop SSH driver (pushes the
                                   on-device installer; no scp needed)
  reapply-ipv6-relay.sh            post-OTA re-apply helper
  fix-520-ipv6.sh                  repair tool: installs radvd via opkg
                                   if missing, retires legacy units,
                                   cleans strays, verifies

INSTALL
-------
  On the modem (root shell), one line:
    curl -fsSL https://raw.githubusercontent.com/carp4/520-ipv6-fix/main/install-on-device.sh | sh
  or from a laptop:
    ./install-ipv6-fix.sh <modem-ip> [ssh-user]

  Requirements: root SSH or ADB on an RM520N-GL; radvd (auto-installed via
  opkg when missing); a carrier that routes a /64 to the modem (verified
  across T-Mobile, Verizon, and AT&T).
  No reboot required - the service starts immediately and survives
  reboots. The installer asks for confirmation before touching anything.

UNIT DIR
--------
  Units + wants symlinks always live in /lib/systemd/system/ (the rootfs);
  the installer remounts the rootfs rw if /lib looks read-only. /etc is a
  separate, LATE UBI volume on several builds — boot systemd never scans
  /etc/*.wants/, so enabling there silently fails (is-enabled lies, and
  units come back inactive after every reboot). systemctl enable is NOT
  used; enabling is a manual symlink in /lib.
  Identical mirror copies are kept in /etc/systemd/system/ (harmless —
  systemd prefers /etc, but identical is fine) as the post-OTA recovery
  source.

VERIFY
------
  systemctl is-active rm520-6relayd.service    -> active
  systemctl is-active rm520-6relayd-watchdog.timer -> active
  cat /tmp/lp-radvd.pid                         -> radvd pid (alive)
  radvd -c -C /tmp/lp-radvd.conf               -> syntax ok
  cat /usrdata/at-stock-ui/ipv6.prefix         -> current carrier /64
  ip -6 addr show bridge0                      -> LAN clients get globals
  (ps shows TWO radvd procs - parent + child, normal for radvd 2.18)

AFTER A FIRMWARE UPDATE (OTA)
-----------------------------
  A firmware update wipes /lib. On the modem, run:
      sh /usrdata/scripts/reapply-ipv6-relay.sh
  It restores units from the /etc mirrors, re-creates wants symlinks,
  retires legacy lettucepi units, and restarts the service.

ROLLBACK
--------
  systemctl stop rm520-6relayd.service rm520-6relayd-watchdog.timer
  rm /lib/systemd/system/rm520-6relayd.service \
     /lib/systemd/system/rm520-6relayd-watchdog.service \
     /lib/systemd/system/rm520-6relayd-watchdog.timer \
     /lib/systemd/system/multi-user.target.wants/rm520-6relayd.service \
     /lib/systemd/system/timers.target.wants/rm520-6relayd-watchdog.timer
     /etc/systemd/system/rm520-6relayd*.service /etc/systemd/system/rm520-6relayd*.timer
  systemctl daemon-reload
  [ -f /tmp/lp-radvd.pid ] && kill $(cat /tmp/lp-radvd.pid)
  rm -f /tmp/lp-radvd.conf

NOTES
-----
  - Verified across T-Mobile, Verizon, and AT&T (whole-/64 routed to the
    modem). Other carriers may behave differently.
  - pkill -f is unreliable on this firmware; the code uses /proc sweeps
    and pidfiles instead.
  - License: MIT. Test on a unit you can afford to reboot before trusting
    it with your main line.