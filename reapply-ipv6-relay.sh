#!/bin/sh
# Re-applies the 6relayd IPv6 recipe after a firmware update (rootfs /lib may get wiped).
# Auto-detects whether /lib/systemd/system is writable: on firmware builds with a
# hard read-only rootfs the units live in /etc/systemd/system instead (which those
# builds DO scan at boot — proven by sshd.service itself being enabled from there).
mkdir -p /usrdata/at-stock-ui /usrdata/scripts
UNITDIR=/lib/systemd/system
if ! (touch "$UNITDIR/.rwtest" 2>/dev/null && rm -f "$UNITDIR/.rwtest"); then
  UNITDIR=/etc/systemd/system
fi
mkdir -p "$UNITDIR/multi-user.target.wants" "$UNITDIR/timers.target.wants"
# Legacy: the original 520 install used "lettucepi" unit names. A leftover
# enabled lettucepi unit runs 6relayd-run.sh concurrently with the service
# (it did — every 5s — until the pidfile guard started refusing it). Retire it.
for u in lettucepi-6relayd.service lettucepi-6relayd-watchdog.service lettucepi-6relayd-watchdog.timer; do
    systemctl disable "$u" 2>/dev/null
    systemctl stop "$u" 2>/dev/null
done
for u in rm520-6relayd.service rm520-6relayd-watchdog.service rm520-6relayd-watchdog.timer; do
  if [ ! -f "$UNITDIR/$u" ]; then
    [ -f "/etc/systemd/system/$u" ] && cp "/etc/systemd/system/$u" "$UNITDIR/$u"
  fi
done
if [ "$UNITDIR" = /lib/systemd/system ]; then
  # /etc mirrors stay IDENTICAL to the live units. On writable builds /etc
  # shadows /lib in systemd's search order, but identical copies make that
  # harmless — and the /etc copies are what survives an OTA that wipes /lib.
  # (Never let the two diverge: a stale /etc copy silently overrides /lib.)
  cp "$UNITDIR/rm520-6relayd.service" "$UNITDIR/rm520-6relayd-watchdog.service" "$UNITDIR/rm520-6relayd-watchdog.timer" /etc/systemd/system/ 2>/dev/null || true
fi
ln -sf "$UNITDIR/rm520-6relayd.service" "$UNITDIR/multi-user.target.wants/rm520-6relayd.service"
ln -sf "$UNITDIR/rm520-6relayd-watchdog.timer" "$UNITDIR/timers.target.wants/rm520-6relayd-watchdog.timer"
systemctl daemon-reload
systemctl start rm520-6relayd.service rm520-6relayd-watchdog.timer 2>/dev/null
echo '6relayd recipe re-applied (unit dir: '"$UNITDIR"')'
