#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# host-shell – run a single command on the HA OS host (via nsenter)
# Usage: host-shell <command...>
# Example: host-shell ha core check
#          host-shell docker ps
#          host-shell cat /etc/hostname
# ──────────────────────────────────────────────────────────────
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "Usage: host-shell <command...>"
    echo ""
    echo "Run a command directly on the Home Assistant host OS."
    echo "Uses nsenter to enter host PID/mount/network namespaces."
    echo ""
    echo "Examples:"
    echo "  host-shell ha core check"
    echo "  host-shell docker ps"
    echo "  host-shell cat /etc/os-release"
    echo "  host-shell systemctl status home-assistant"
    echo ""
    echo "For an interactive host shell, use: ha-host"
    exit 1
fi

# Enter host namespaces (PID 1 = host init/systemd) and run the command
exec nsenter -t 1 -m -u -i -n -p -- "$@"
