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
