#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ha-opencode entrypoint
# 1. Reads options from /data/options.json (HA add-on standard)
# 2. Starts ttyd web terminal on port 7681
# 3. The terminal auto-launches opencode-terminal.sh which
#    always opens a tmux session with opencode --continue
# 4. Keeps the container alive
# ──────────────────────────────────────────────────────────────
set -euo pipefail

OPTS="/data/options.json"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"

# ── Banner ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║       ha-opencode – OpenCode Terminal        ║"
echo "╚══════════════════════════════════════════════╝"

# ── Read options ─────────────────────────────────────────────
if [ -f "$OPTS" ]; then
    TERMINAL_PASSWORD=$(jq -r '.terminal_password // ""' "$OPTS")
    OPENCODE_AUTO_START=$(jq -r '.opencode_auto_start // true' "$OPTS")
    OPENCODE_WORKSPACE=$(jq -r '.opencode_workspace // "/config"' "$OPTS")
    OPENCODE_MODEL=$(jq -r '.opencode_model // ""' "$OPTS")
else
    echo "[WARN] /data/options.json not found – using defaults"
    TERMINAL_PASSWORD=""
    OPENCODE_AUTO_START="true"
    OPENCODE_WORKSPACE="/config"
    OPENCODE_MODEL=""
fi

# ── Ensure workspace exists ──────────────────────────────────
mkdir -p "$OPENCODE_WORKSPACE" /data/logs
export OPENCODE_WORKSPACE
export OPENCODE_MODEL

# ── Setup opencode config (first run) ────────────────────────
if [ ! -d "/root/.opencode" ]; then
    echo "[INFO] First run – initializing OpenCode config directory"
    mkdir -p /root/.opencode
fi

# ── Log configuration ────────────────────────────────────────
echo "   Workspace : $OPENCODE_WORKSPACE"
echo "   Port      : $TERMINAL_PORT"
echo "   Auto-start: $OPENCODE_AUTO_START"
echo "   Model     : ${OPENCODE_MODEL:-<default>}"
echo ""

# ── Start ttyd web terminal ──────────────────────────────────
# The terminal runs opencode-terminal.sh which:
#   - Creates a tmux session "opencode" if it doesn't exist
#   - Starts opencode --continue inside it
#   - Attaches to the session on every new connection
#   - Loops on detach/disconnect so you always land back in opencode
start_ttyd() {
    local ttyd_args=()
    local shell_cmd

    ttyd_args+=("--port" "$TERMINAL_PORT")
    ttyd_args+=("--writable")
    ttyd_args+=("--max-clients" "5")
    ttyd_args+=("--ping-interval" "30")

    if [ -n "$TERMINAL_PASSWORD" ]; then
        ttyd_args+=("--credential" "admin:${TERMINAL_PASSWORD}")
        echo "[INFO] Terminal auth enabled (basic auth)"
    else
        echo "[INFO] Terminal auth disabled (no password set)"
    fi

    # Choose what shell to launch
    if [ "$OPENCODE_AUTO_START" = "true" ]; then
        shell_cmd="opencode-terminal.sh"
        echo "[INFO] Terminal will auto-attach to OpenCode tmux session"
    else
        shell_cmd="bash -l"
        echo "[INFO] Terminal starts plain bash (opencode auto-start disabled)"
    fi

    echo "[INFO] Starting ttyd web terminal on port $TERMINAL_PORT..."
    exec ttyd "${ttyd_args[@]}" $shell_cmd
}

# ── Cleanup trap ─────────────────────────────────────────────
cleanup() {
    echo ""
    echo "[INFO] Shutting down ha-opencode..."
    tmux kill-session -t opencode 2>/dev/null || true
    echo "[OK]   Cleanup complete"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ── Main ─────────────────────────────────────────────────────
echo "[INFO] ha-opencode is ready!"
echo "   → Terminal : http://<ha-ip>:7681"
echo "   → Sidebar  : OpenCode panel"
echo "   → Tmux ses : opencode (auto-attached on connect)"
echo ""

start_ttyd
