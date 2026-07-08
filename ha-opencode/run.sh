#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ha-opencode entrypoint
# 1. Reads options from /data/options.json (HA add-on standard)
# 2. Starts ttyd web terminal on port 7681
# 3. Optionally starts OpenCode AI in a tmux session
# 4. Keeps the container alive
# ──────────────────────────────────────────────────────────────
set -euo pipefail

OPTS="/data/options.json"
TERMINAL_PORT="${TERMINAL_PORT:-7681}"

# ── Banner ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║        ha-opencode – OpenCode Terminal       ║"
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

# ── OpenCode startup (in tmux session) ───────────────────────
start_opencode() {
    echo "[INFO] Starting OpenCode AI in tmux session 'opencode'..."

    # Kill existing session if any
    tmux kill-session -t opencode 2>/dev/null || true

    # Create new detached session
    tmux new-session -d -s opencode -c "$OPENCODE_WORKSPACE" \
        -e "OPENCODE_WORKSPACE=$OPENCODE_WORKSPACE"

    # Allow time for session to initialize
    sleep 1

    # Send the opencode continue command
    tmux send-keys -t opencode "clear" Enter
    tmux send-keys -t opencode "echo 'OpenCode AI – ready'" Enter

    if [ -n "$OPENCODE_MODEL" ]; then
        tmux send-keys -t opencode "opencode --model \"$OPENCODE_MODEL\" --continue" Enter
    else
        tmux send-keys -t opencode "opencode --continue" Enter
    fi

    echo "[OK]   OpenCode started in tmux session (attach: tmux attach -t opencode)"
}

# ── Start ttyd web terminal ─────────────────────────────────
start_ttyd() {
    local ttyd_args=()

    ttyd_args+=("--port" "$TERMINAL_PORT")
    ttyd_args+=("--writable")
    ttyd_args+=("--max-clients" "5")
    ttyd_args+=("--ping-interval" "30")
    ttyd_args+=("--once")

    if [ -n "$TERMINAL_PASSWORD" ]; then
        ttyd_args+=("--credential" "admin:${TERMINAL_PASSWORD}")
        echo "[INFO] Terminal auth enabled (basic auth)"
    else
        echo "[INFO] Terminal auth disabled (no password set)"
    fi

    echo "[INFO] Starting ttyd web terminal on port $TERMINAL_PORT..."
    exec ttyd "${ttyd_args[@]}" bash -l
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
if [ "$OPENCODE_AUTO_START" = "true" ]; then
    start_opencode
fi

echo "[INFO] ha-opencode is ready!"
echo "   → Terminal: http://<ha-ip>:7681"
echo "   → Sidebar : OpenCode panel"
echo ""

start_ttyd
