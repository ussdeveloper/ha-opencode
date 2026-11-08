#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ssh-host – SSH into the Home Assistant OS host
# Usage: ssh-host [command...]
#        ssh-host                (interactive shell)
#        ssh-host ha core check  (single command)
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# HA OS SSH defaults
SSH_HOST="${SSH_HOST:-172.30.32.1}"
SSH_PORT="${SSH_PORT:-22222}"
SSH_USER="${SSH_USER:-root}"

if [ $# -eq 0 ]; then
    echo "Connecting to HA OS host via SSH..."
    echo "  Host: $SSH_HOST  Port: $SSH_PORT  User: $SSH_USER"
    echo "  Tip: 'exit' or Ctrl+D to return to the container."
    echo ""
    exec ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SSH_USER@$SSH_HOST"
else
    exec ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SSH_USER@$SSH_HOST" "$@"
fi
