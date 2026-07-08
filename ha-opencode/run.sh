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
    OPENCODE_SYSTEM_PROMPT=$(jq -r '.opencode_system_prompt // ""' "$OPTS")
    OPENCODE_RULES=$(jq -r '.opencode_rules // ""' "$OPTS")
    OPENCODE_INSTRUCTIONS=$(jq -r '.opencode_instructions // ""' "$OPTS")
else
    echo "[WARN] /data/options.json not found – using defaults"
    TERMINAL_PASSWORD=""
    OPENCODE_AUTO_START="true"
    OPENCODE_WORKSPACE="/config"
    OPENCODE_MODEL=""
    OPENCODE_SYSTEM_PROMPT=""
    OPENCODE_RULES=""
    OPENCODE_INSTRUCTIONS=""
fi

# ── Ensure workspace exists ──────────────────────────────────
mkdir -p "$OPENCODE_WORKSPACE" /data/logs
export OPENCODE_WORKSPACE
export OPENCODE_MODEL

# ── Setup OpenCode config files ─────────────────────────────
# Generates AGENTS.md and opencode.json from add-on options so
# users can customize system prompts, rules, and instructions
# directly from the Home Assistant add-on configuration.
setup_opencode_config() {
    local config_dir="/root/.config/opencode"
    mkdir -p "$config_dir"

    # ── AGENTS.md (auto-discovered by OpenCode as project rules) ──
    if [ -n "$OPENCODE_RULES" ]; then
        echo "$OPENCODE_RULES" > "$config_dir/AGENTS.md"
        echo "[INFO] OpenCode rules written to $config_dir/AGENTS.md"
    fi

    # ── System prompt ──────────────────────────────────────────
    if [ -n "$OPENCODE_SYSTEM_PROMPT" ]; then
        echo "$OPENCODE_SYSTEM_PROMPT" > "$config_dir/system-prompt.md"
        echo "[INFO] OpenCode system prompt written to $config_dir/system-prompt.md"
    fi

    # ── Custom instructions ────────────────────────────────────
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        echo "$OPENCODE_INSTRUCTIONS" > "$config_dir/custom-instructions.md"
        echo "[INFO] OpenCode custom instructions written to $config_dir/custom-instructions.md"
    fi

    # ── opencode.json (references instruction files) ───────────
    if [ -n "$OPENCODE_SYSTEM_PROMPT" ] || [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        local instructions_json="["
        local first=true

        if [ -n "$OPENCODE_SYSTEM_PROMPT" ]; then
            instructions_json="$instructions_json\"$config_dir/system-prompt.md\""
            first=false
        fi

        if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
            if [ "$first" = false ]; then
                instructions_json="$instructions_json,"
            fi
            instructions_json="$instructions_json\"$config_dir/custom-instructions.md\""
        fi

        instructions_json="$instructions_json]"

        cat > "$config_dir/opencode.json" << JSONEOF
{
  "instructions": $instructions_json
}
JSONEOF
        echo "[INFO] OpenCode config written to $config_dir/opencode.json"
    fi
}

setup_opencode_config

# ── Log configuration ────────────────────────────────────────
echo "   Workspace     : $OPENCODE_WORKSPACE"
echo "   Port          : $TERMINAL_PORT"
echo "   Auto-start    : $OPENCODE_AUTO_START"
echo "   Model         : ${OPENCODE_MODEL:-<default>}"
echo "   System prompt : ${OPENCODE_SYSTEM_PROMPT:+<set>}"
echo "   Rules         : ${OPENCODE_RULES:+<set>}"
echo "   Instructions  : ${OPENCODE_INSTRUCTIONS:+<set>}"
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
