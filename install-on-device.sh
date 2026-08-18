#!/bin/sh
# install-on-device.sh — self-contained on-device installer for the 520 IPv6 fix.
#
# Runs ON the RM520N / RM521F / RM550V / RM551E modem (root shell). Idempotent —
# safe to re-run on an already-fixed modem, and harmless on a fixed one.
#
# Generated from the repo sources — do not hand-edit; regenerate instead.
#
# What it does:
#   1. installs radvd if missing (some firmware builds ship without it)
#   2. installs 6relayd-run.sh + 6relayd-watchdog.sh into /usrdata/at-stock-ui/
#   3. detects the unit dir: /lib/systemd/system when writable, else
#      /etc/systemd/system (hard read-only rootfs builds scan /etc at boot)
#   4. installs unit files + wants symlinks into the detected dir; on writable
#      builds removes /etc shadow copies (they would override /lib)
#   5. retires the legacy "lettucepi" units (original install's names) so they
#      cannot run 6relayd-run.sh concurrently with the service
#   6. installs the post-OTA reapply script into /usrdata/scripts/
#   7. daemon-reload, starts service + watchdog timer, verifies
#
# This is NOT the old IPv6ExtRouterMode fix (that one bricked 3 modems).
# This is the radvd passthrough recipe proven on production RM520N units.

set -e
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root (e.g. ssh root@<modem> then re-run)" >&2; exit 1; }

# Confirmation gate — never installs blindly. With `curl ... | sh` stdin is the
# pipe, so the prompt reads the controlling terminal (/dev/tty); a non-TTY run
# has no one to ask and refuses to proceed.
echo
echo "This installs the 520 IPv6 fix (6relayd/radvd passthrough) on THIS modem."
echo "Idempotent — safe to re-run on an already-fixed modem."
echo
while :; do
    printf 'Press 1 to install, 0 to exit: '
    if ! read -r ans < /dev/tty; then
        echo
        echo "No interactive terminal — exiting, nothing was changed." >&2
        exit 1
    fi
    case "$ans" in
        1) break ;;
        0) echo "Exiting — nothing was changed."; exit 0 ;;
        *) echo "Invalid choice — press 1 to install or 0 to exit." ;;
    esac
done
echo "Installing..."

# --- 1. radvd presence -----------------------------------------------------
if ! command -v radvd >/dev/null 2>&1; then
    if command -v opkg >/dev/null 2>&1 || [ -x /opt/bin/opkg ]; then
        echo "==> radvd missing — installing via opkg (may take a minute)"
        export PATH=/opt/bin:/opt/sbin:$PATH
        opkg update
        opkg install radvd
    else
        echo "ERROR: radvd is not installed and no opkg (Entware) is available." >&2
        echo "       Install radvd manually, then re-run this installer." >&2
        exit 1
    fi
    command -v radvd >/dev/null 2>&1 || { echo "ERROR: radvd still not available after install" >&2; exit 1; }
fi
echo "==> radvd: $(command -v radvd)"

# --- 2. unit dir detect ----------------------------------------------------
UNITDIR=/lib/systemd/system
if ! (touch "$UNITDIR/.rwtest" 2>/dev/null && rm -f "$UNITDIR/.rwtest"); then
    UNITDIR=/etc/systemd/system
fi
echo "==> unit dir: $UNITDIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> writing payloads"
cat > "$TMP/6relayd-run.sh" <<'PL_END'
#!/bin/sh
# 6relayd-run.sh — RM520 IPv6 passthrough launcher (ExecStart of the service).
#
# Reproduces exactly how the RM520N-GL does IPv6 — a clean ROUTED passthrough, no
# NAT, no ND-proxy, no ULA. LAN devices get a single real global in the carrier /64.
#
# The mechanism (learned by rooting the RM520 and diffing): T-Mobile ROUTES the whole
# /64 to the modem. The one thing that made it fail on early units was the WAN claiming
# that /64 as on-link (autoconf), which put the /64 on BOTH rmnet and bridge0 at equal
# metric and routed client return-traffic ambiguously. Fix: autoconf=0 on the WAN so
# it does NOT claim the /64 on-link, then route the /64 to the LAN and let radvd serve
# the RA to clients (the RM520 uses radish for the RA; a stripped QCMAP cannot
# drive radish, so we use radvd — same result).
#
# This process is the prefix tracker: it keeps the WAN /64 routed to the LAN and radvd
# advertising it, following the carrier prefix across reconnects, and keeps radvd alive.
export PATH=/opt/bin:/opt/sbin:$PATH:/usr/sbin:/sbin

# Single-instance guard. systemd is the real owner: the unit (Type=simple,
# Restart=always) guarantees exactly one instance, and the watchdog only ever
# restarts the SERVICE — it must never run this script itself. So a run with
# --systemd (the unit's ExecStart) writes its pid to claim ownership but skips
# the check — systemd serializes starts, so a restarting service never trips
# its own guard (which would otherwise make it exit 0 and thrash in
# auto-restart forever).
#
# Runs WITHOUT --systemd (manual/one-shot) check the pidfile first: two manual
# runs must not overlap — concurrent instances raced on writing
# /tmp/lp-radvd.conf (cat > / cat >> interleaving) and corrupted it, which made
# radvd exit with a syntax error — silently killing IPv6 for every client.
#
# NOT flock: the busybox flock on these modems does not support locking an
# open fd (flock -n 9 locks a *file named "9"*, silently succeeding every
# time), so a flock guard is a no-op here.
PIDF=/tmp/6relayd.pid
if [ "$1" != "--systemd" ]; then
    if [ -f "$PIDF" ]; then
        OP=$(cat "$PIDF" 2>/dev/null)
        # Live only if the pid is alive AND is still this script — a stale
        # pidfile whose pid got reused by an unrelated process must not block.
        if [ -n "$OP" ] && kill -0 "$OP" 2>/dev/null && grep -q "6relayd-run.sh" "/proc/$OP/cmdline" 2>/dev/null; then
            echo "[$(date)] another 6relayd instance (pid $OP) is running — exiting" >> /tmp/lp-radvd.log
            exit 0
        fi
    fi
fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT

# Data call interface is usually rmnet_data0 but some modems/bands use
# rmnet_data1+ — pick whichever actually holds a global address at startup.
WAN=rmnet_data0
for _w in rmnet_data0 rmnet_data1 rmnet_data2; do
    if ip -6 addr show "$_w" 2>/dev/null | grep -q "scope global"; then
        WAN=$_w
        break
    fi
done
LAN=bridge0
RADVD_CONF=/tmp/lp-radvd.conf

# Prefix state is PERSISTED. It used to live only in the shell variable LAST, which meant
# the renumbering withdrawal below fired only for a re-dial observed while this process was
# running: after a reboot the script restarted with LAST="" and silently skipped it, so
# clients kept the dead global for days (test-ipv6.com scores 0/10 while the box itself is
# perfectly healthy, because Windows picks the dead prefix as its source address).
DIR=/usrdata/at-stock-ui
PFXF=$DIR/ipv6.prefix          # the prefix currently being served
STALEF=$DIR/ipv6.stale         # recently-retired prefixes, newest first
MAXSTALE=3

# WAN must NOT auto-add the carrier /64 as on-link (that was the ambiguity source).
echo 0 > /proc/sys/net/ipv6/conf/$WAN/autoconf 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null

wan_net() { ip -6 addr show "$WAN" 2>/dev/null | awk '/scope global/{print $2}' | head -1 | cut -d/ -f1 | cut -d: -f1-4; }

# "$STALEF" is the retired-prefix list; newest first, capped so the RA cannot grow without
# bound. A prefix already in the list is not duplicated.
stale_list() { [ -f "$STALEF" ] && tr '\n' ' ' < "$STALEF"; }
stale_add() {
    sa="$1"; [ -n "$sa" ] || return 0
    { echo "$sa"; [ -f "$STALEF" ] && grep -vx "$sa" "$STALEF"; } | head -n $MAXSTALE > "$STALEF.t"
    cat "$STALEF.t" > "$STALEF"; rm -f "$STALEF.t"
}

# $1 = current prefix. $2.. = previous prefixes to advertise as DEAD.
# The carrier hands out a NEW /64 on every re-dial. Clients keep the old global until
# its lifetime runs out (hours) and — since apps prefer IPv6 — stall on the dead
# address the whole time. Re-advertising the old prefix with zero lifetimes is the
# RFC 4861/4862 renumbering signal that makes clients drop it immediately.
write_radvd() {
    cur="$1"; shift
    TMPC="${RADVD_CONF}.tmp"
    {
        cat <<CONF
interface $LAN {
    AdvSendAdvert on;
    MinRtrAdvInterval 3;
    MaxRtrAdvInterval 10;
    AdvManagedFlag off;
    AdvOtherConfigFlag off;
    prefix ${cur}::/64 { AdvOnLink on; AdvAutonomous on; };
CONF
        for d in "$@"; do
            [ -n "$d" ] || continue
            [ "$d" = "$cur" ] && continue
            cat <<CONF
    prefix ${d}::/64 {
        AdvOnLink off; AdvAutonomous on;
        AdvValidLifetime 0; AdvPreferredLifetime 0;
    };
CONF
        done
        cat <<CONF
    RDNSS 2606:4700:4700::1111 2606:4700:4700::1001 { };
};
CONF
    } > "$TMPC" && mv -f "$TMPC" "$RADVD_CONF"
}
start_radvd() {
    # Stop any existing radvd via its pidfile, then sweep /proc as a fallback
    # (pkill -f is unreliable on this firmware — it matched nothing all day —
    # and a stray second radvd advertises duplicate RAs). radvd writes
    # /var/run/radvd.pid even in -n mode and locks it, so the pidfile is the
    # authoritative handle.
    RPID=$(cat /var/run/radvd.pid 2>/dev/null)
    [ -n "$RPID" ] && kill "$RPID" 2>/dev/null
    for p in /proc/[0-9]*; do
        case "$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)" in
            radvd*) kill "${p#/proc/}" 2>/dev/null ;;
        esac
    done
    sleep 1
    # Validate before launch — a corrupt config (e.g. from a multi-instance
    # race before the single-instance guard shipped) made radvd exit silently.
    # Fail loud into the log instead so the failure is visible in one place.
    if radvd -c -C "$RADVD_CONF" >>/tmp/lp-radvd.log 2>&1; then
        setsid sh -c "radvd -n -C $RADVD_CONF" </dev/null >>/tmp/lp-radvd.log 2>&1 &
    else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)] radvd config check FAILED — not starting" >> /tmp/lp-radvd.log
    fi
}

# Resume tracking across a restart. This one line is what makes a prefix change that
# spans a reboot get withdrawn at all.
LAST=$(cat "$PFXF" 2>/dev/null)
while :; do
    NET=$(wan_net)
    if [ -n "$NET" ]; then
        # strip QCMAP's ULA — clients hold ONLY a clean global
        ip -6 addr show "$LAN" 2>/dev/null | awk '/inet6 fd/{print $2}' | while read a; do ip -6 addr del "$a" dev "$LAN" 2>/dev/null; done
        # Any GLOBAL on the LAN that is not the current prefix is a leftover from an older
        # carrier /64. Harvest it before deleting: the box holding it is good evidence the
        # clients are holding it too, and that is exactly what has to be withdrawn. This is
        # also what heals a box that was already stranded before this code shipped — the
        # dead prefixes are rediscovered from the interface rather than remembered.
        for a in $(ip -6 addr show "$LAN" 2>/dev/null | awk '/inet6 [23]/{print $2}'); do
            p=$(echo "${a%%/*}" | cut -d: -f1-4)
            [ "$p" = "$NET" ] && continue
            stale_add "$p"
            ip -6 addr del "$a" dev "$LAN" 2>/dev/null
        done
        # WAN must not hold the /64 on-link; route it to the LAN instead
        ip -6 route del "${NET}::/64" dev "$WAN" 2>/dev/null
        ip -6 route replace "${NET}::/64" dev "$LAN" metric 255 2>/dev/null
        if [ "$NET" != "$LAST" ]; then
            # Re-dial (or a reboot onto a new prefix). Tear down the old route and record
            # the old prefix as dead. Gated on the DEAD list rather than on LAST being set,
            # so a restart with a persisted or harvested prefix still withdraws.
            if [ -n "$LAST" ]; then
                ip -6 route del "${LAST}::/64" dev "$LAN" metric 255 2>/dev/null
                stale_add "$LAST"
            fi
            DEAD=$(stale_list)
            if [ -n "$DEAD" ]; then
                # ~20s advertising every known-dead prefix at zero lifetimes, so clients
                # drop those globals now instead of stalling on them for hours.
                write_radvd "$NET" $DEAD
                start_radvd
                sleep 20
            fi
            write_radvd "$NET"
            start_radvd
            LAST="$NET"
            printf '%s\n' "$NET" > "$PFXF"
        elif [ ! -f "$RADVD_CONF" ]; then
            # No prefix change this boot but no config either (e.g. after a
            # crash) — regenerate before the keepalive below can restart radvd.
            write_radvd "$NET"
            start_radvd
        fi
        # Keepalive via radvd's own pidfile (kill -0) — a pgrep pattern match
        # was unreliable here and let a dead radvd look alive.
        RPID=$(cat /var/run/radvd.pid 2>/dev/null)
        if [ -z "$RPID" ] || ! kill -0 "$RPID" 2>/dev/null; then
            start_radvd
        fi
    fi
    sleep 10
done
PL_END
cat > "$TMP/6relayd-watchdog.sh" <<'PL_END'
#!/bin/sh
# Watchdog: the ONLY thing it does is (re)start the service. It must never run
# 6relayd-run.sh itself — systemd guarantees a single service instance, and the
# run-script's pidfile guard would make a watchdog-owned instance race the
# service for the guard, leaving the service thrashing in auto-restart.
# reset-failed is needed so a service left in "failed" state accepts start.
if ! systemctl is-active rm520-6relayd.service >/dev/null 2>&1; then
    systemctl reset-failed rm520-6relayd.service 2>/dev/null
    systemctl start rm520-6relayd.service 2>/dev/null
fi
PL_END
cat > "$TMP/rm520-6relayd.service" <<'PL_END'
[Unit]
Description=RM520 IPv6 passthrough (6relayd)
After=network.target
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/bin/sh /usrdata/at-stock-ui/6relayd-run.sh --systemd
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
PL_END
cat > "$TMP/rm520-6relayd-watchdog.service" <<'PL_END'
[Unit]
Description=6relayd IPv6 passthrough watchdog

[Service]
Type=oneshot
ExecStart=/bin/sh /usrdata/at-stock-ui/6relayd-watchdog.sh
PL_END
cat > "$TMP/rm520-6relayd-watchdog.timer" <<'PL_END'
[Unit]
Description=Run the 6relayd watchdog every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=5s

[Install]
WantedBy=timers.target
PL_END
cat > "$TMP/reapply-ipv6-relay.sh" <<'PL_END'
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
PL_END

echo "==> installing scripts"
mkdir -p /usrdata/at-stock-ui /usrdata/scripts
cp "$TMP/6relayd-run.sh" "$TMP/6relayd-watchdog.sh" /usrdata/at-stock-ui/
chmod 755 /usrdata/at-stock-ui/6relayd-run.sh /usrdata/at-stock-ui/6relayd-watchdog.sh

echo "==> installing systemd units + wants symlinks"
mkdir -p "$UNITDIR/multi-user.target.wants" "$UNITDIR/timers.target.wants"
cp "$TMP/rm520-6relayd.service" "$TMP/rm520-6relayd-watchdog.service" "$TMP/rm520-6relayd-watchdog.timer" "$UNITDIR/"
chmod 644 "$UNITDIR/rm520-6relayd.service" "$UNITDIR/rm520-6relayd-watchdog.service" "$UNITDIR/rm520-6relayd-watchdog.timer"

if [ "$UNITDIR" = /lib/systemd/system ]; then
    # /etc mirrors stay IDENTICAL to the live units: on writable builds /etc
    # shadows /lib in systemd's search order, but identical copies make that
    # harmless — and the /etc copies are what survives an OTA that wipes /lib.
    cp "$UNITDIR/rm520-6relayd.service" "$UNITDIR/rm520-6relayd-watchdog.service" "$UNITDIR/rm520-6relayd-watchdog.timer" /etc/systemd/system/ 2>/dev/null || true
else
    # Read-only /lib build: the units live in /etc only (those builds scan it).
    cp "$UNITDIR/rm520-6relayd.service" "$UNITDIR/rm520-6relayd-watchdog.service" "$UNITDIR/rm520-6relayd-watchdog.timer" /etc/systemd/system/ 2>/dev/null || true
fi

ln -sf "$UNITDIR/rm520-6relayd.service" "$UNITDIR/multi-user.target.wants/rm520-6relayd.service"
ln -sf "$UNITDIR/rm520-6relayd-watchdog.timer" "$UNITDIR/timers.target.wants/rm520-6relayd-watchdog.timer"

echo "==> retiring legacy lettucepi units"
for u in lettucepi-6relayd.service lettucepi-6relayd-watchdog.service lettucepi-6relayd-watchdog.timer; do
    systemctl disable "$u" 2>/dev/null || true
    systemctl stop "$u" 2>/dev/null || true
done

echo "==> installing post-OTA reapply script"
cp "$TMP/reapply-ipv6-relay.sh" /usrdata/scripts/reapply-ipv6-relay.sh
chmod 755 /usrdata/scripts/reapply-ipv6-relay.sh

echo "==> starting service + watchdog"
systemctl daemon-reload
systemctl stop rm520-6relayd-watchdog.timer 2>/dev/null || true
systemctl stop rm520-6relayd.service 2>/dev/null || true
for p in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$c" in
        *6relayd-run.sh*|radvd*) kill -9 "${p#/proc/}" 2>/dev/null || true ;;
    esac
done
sleep 1
rm -f /tmp/6relayd.pid /tmp/lp-radvd.conf /usrdata/at-stock-ui/ipv6.prefix /usrdata/at-stock-ui/ipv6.stale /tmp/lp-radvd.log /var/run/radvd.pid
systemctl start rm520-6relayd.service
systemctl start rm520-6relayd-watchdog.timer
sleep 5
echo "relay: $(systemctl is-active rm520-6relayd.service) timer: $(systemctl is-active rm520-6relayd-watchdog.timer)"
RPID=$(cat /var/run/radvd.pid 2>/dev/null)
if [ -n "$RPID" ] && kill -0 "$RPID" 2>/dev/null; then
    echo "radvd: running (pid $RPID)"
else
    echo "radvd: NOT running — check /tmp/lp-radvd.log"
fi
radvd -c -C /tmp/lp-radvd.conf >>/tmp/lp-radvd.log 2>&1 && echo "config: valid"

echo "==> done. Verify:"
echo "    ip -6 addr show bridge0                 # clients get globals"
echo "    cat /usrdata/at-stock-ui/ipv6.prefix    # current carrier /64"
echo "    After a firmware update re-apply with:  sh /usrdata/scripts/reapply-ipv6-relay.sh"
