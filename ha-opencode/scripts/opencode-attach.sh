#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Attach to the running OpenCode tmux session.
# Usage: opencode-attach
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SESSION="opencode"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Attaching to OpenCode tmux session..."
    tmux attach -t "$SESSION"
else
    echo "OpenCode session is not running."
    echo "Start it with: opencode --continue"
    exit 1
fi
