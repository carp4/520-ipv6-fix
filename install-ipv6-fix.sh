#!/bin/sh
# install-ipv6-fix.sh — laptop-side driver for the 520 IPv6 relay fix.
#
# Usage:  ./install-ipv6-fix.sh <modem-ip> [ssh-user]
#         ./install-ipv6-fix.sh 192.168.1.1
#
# Pushes install-on-device.sh (the self-contained installer) to an
# RM520N-GL modem over SSH and runs it there.
# Idempotent — safe to re-run on an already-fixed modem.
#
# Notes:
#   * No scp needed — the installer is pushed through `cat`, so this works
#     even on firmware builds without scp/sftp-server.
#   * SSH ControlMaster: one auth (key or password) covers all hops. On
#     builds with broken pubkey auth (home dir/StrictModes), sshpass can
#     supply the password once:  sshpass -p 'PASSWORD' ./install-ipv6-fix.sh IP
#   * The interactive gate (press 1) runs on the modem; on a non-TTY session
#     the installer reads one confirmation line from stdin (fed here), so no
#     pty is needed — non-TTY runs are also immune to the pty/process-sweep
#     teardown seen on these modems.
#   * Everything else (radvd install, unit-dir detect, legacy cleanup,
#     verification) is handled by the on-device installer itself.

set -e

IP="${1:?usage: $0 <modem-ip> [ssh-user]}"
USER="${2:-root}"
DIR=$(dirname "$(readlink -f "$0")")
MUX=/tmp/ssh-mux-%r@%h-%p
SSH="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=$MUX -o ControlPersist=300"

echo "==> connecting to $USER@$IP"
$SSH "$USER@$IP" '[ "$(id -u)" = 0 ] || { echo "ERROR: need a root login (ssh root@'"$IP"')" >&2; exit 1; }; echo "    connected, root OK"; if command -v radvd >/dev/null 2>&1; then echo "    radvd present"; else echo "    radvd missing — installer will try opkg"; fi'

echo "==> pushing on-device installer"
$SSH "$USER@$IP" 'cat > /tmp/install-on-device.sh' < "$DIR/install-on-device.sh"

echo "==> running installer on the modem"
printf '1\n' | $SSH "$USER@$IP" 'sh /tmp/install-on-device.sh'

echo "==> cleaning up + closing mux"
$SSH "$USER@$IP" 'rm -f /tmp/install-on-device.sh' 2>/dev/null || true
$SSH -O exit "$USER@$IP" 2>/dev/null || true
echo "==> done on $IP"