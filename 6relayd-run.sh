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
# Pidfile path is explicit, not radvd's compiled-in default: Entware's radvd
# (opkg-installed, seen as both 2.18 and 2.20 across units) writes to
# /opt/var/run/radvd.pid on some builds and /var/run/radvd.pid on others,
# depending on how it was configured/packaged. Trusting /var/run/radvd.pid
# unconditionally made the keepalive below see "no pidfile" on units where
# radvd actually used /opt/var/run — it always concluded radvd was dead and
# killed+restarted a perfectly healthy daemon every 10s, forever. -p pins
# the path so start and keepalive always agree, regardless of the build.
RADVD_PID=/tmp/lp-radvd.pid

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
    # and a stray second radvd advertises duplicate RAs). The pidfile is
    # pinned by -p at launch (see RADVD_PID above), so this is the
    # authoritative handle on every radvd build.
    RPID=$(cat "$RADVD_PID" 2>/dev/null)
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
        setsid sh -c "radvd -n -C $RADVD_CONF -p $RADVD_PID" </dev/null >>/tmp/lp-radvd.log 2>&1 &
        # radvd writes its pidfile shortly after start. The launch is async,
        # and the keepalive runs immediately after this returns — if it sees
        # "no pidfile" it starts a SECOND daemon, which then fails the pidfile
        # lock and keeps advertising anyway (duplicate RAs). Wait for the
        # pidfile so the keepalive can never observe the gap.
        _i=0
        while [ "$_i" -lt 50 ] && [ ! -s "$RADVD_PID" ]; do
            sleep 0.1
            _i=$((_i + 1))
        done
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
        RPID=$(cat "$RADVD_PID" 2>/dev/null)
        if [ -z "$RPID" ] || ! kill -0 "$RPID" 2>/dev/null; then
            start_radvd
        fi
    fi
    sleep 10
done
