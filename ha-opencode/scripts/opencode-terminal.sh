#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# opencode-terminal.sh
# Wrapper for ttyd – always opens a tmux session with opencode.
# If the session exists → attach. If not → create and start opencode.
# Loops on detach/disconnect so the user always lands back in opencode.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

SESSION="opencode"
WORKSPACE="${OPENCODE_WORKSPACE:-/config}"
MODEL="${OPENCODE_MODEL:-}"

# Ensure workspace exists
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

echo "╔══════════════════════════════════════════╗"
echo "║   ha-opencode – OpenCode AI Terminal     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "   Workspace : $WORKSPACE"
echo "   Model     : ${MODEL:-<default>}"
echo "   Tip       : Ctrl+B D to detach, 'oca' to reattach"
echo ""

while true; do
    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "→ Attaching to existing OpenCode session..."
        tmux attach-session -t "$SESSION"
        EXIT_CODE=$?
    else
        echo "→ Creating new OpenCode session..."
        cd "$WORKSPACE"

        # Build opencode command
        OPENCODE_CMD="opencode"
        if [ -n "$MODEL" ]; then
            OPENCODE_CMD="$OPENCODE_CMD --model \"$MODEL\""
        fi
        OPENCODE_CMD="$OPENCODE_CMD --continue"

        # Create tmux session running opencode
        tmux new-session -s "$SESSION" \
            -e "OPENCODE_WORKSPACE=$WORKSPACE" \
            "echo 'OpenCode AI – starting...' && $OPENCODE_CMD; echo 'OpenCode exited. Restarting in 3s...'; sleep 3"
        EXIT_CODE=$?
    fi

    echo ""
    echo "→ Session ended (exit code: $EXIT_CODE). Reconnecting in 2s..."
    sleep 2
done
