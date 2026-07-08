#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# opencode-terminal.sh
# Wrapper for ttyd – always opens a tmux session with opencode.
# If the session exists → attach. If not → create and start opencode.
# Loops on detach/disconnect so the user always lands back in opencode.
# Falls back to plain bash if tmux fails repeatedly.
# ──────────────────────────────────────────────────────────────
# NOTE: set -e is intentionally NOT used here – this is a resilient
# wrapper that must survive tmux attach failures, ttyd disconnects,
# and opencode crashes.
set -u

SESSION="opencode"
WORKSPACE="${OPENCODE_WORKSPACE:-/config}"
MODEL="${OPENCODE_MODEL:-}"
FAIL_COUNT=0
MAX_FAILS=5

# ── Locale & terminal encoding ───────────────────────────────
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export TERM="${TERM:-xterm-256color}"

# Ensure workspace exists
mkdir -p "$WORKSPACE" 2>/dev/null || true
cd "$WORKSPACE" 2>/dev/null || cd /config || true

echo "╔══════════════════════════════════════════════╗"
echo "║    ha-opencode – OpenCode AI Terminal        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "   Workspace : $WORKSPACE"
echo "   Model     : ${MODEL:-<default>}"
echo "   Tip       : Ctrl+B then D to detach"
echo ""

while true; do
    # Fallback: if tmux keeps failing, give the user a plain bash shell
    if [ "$FAIL_COUNT" -ge "$MAX_FAILS" ]; then
        echo ""
        echo "⚠️  Tmux has failed $FAIL_COUNT times – falling back to plain bash."
        echo "   OpenCode may still be running in tmux session '$SESSION'."
        echo "   Type 'oca' or 'tmux attach -t $SESSION' to try reconnecting."
        echo ""
        exec bash -l
    fi

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        echo "→ Attaching to existing OpenCode session..."
        tmux attach-session -t "$SESSION" 2>/dev/null && {
            FAIL_COUNT=0
            echo ""
            echo "→ Detached. Reconnecting in 2s..."
            sleep 2
            continue
        } || {
            echo "→ Attach failed – session may be busy or TTY unavailable."
            FAIL_COUNT=$((FAIL_COUNT + 1))
            sleep 2
            continue
        }
    else
        echo "→ Creating new OpenCode session..."
        cd "$WORKSPACE" 2>/dev/null || cd /config || true

        # Build opencode command
        OPENCODE_CMD="opencode"
        if [ -n "$MODEL" ]; then
            OPENCODE_CMD="$OPENCODE_CMD --model $MODEL"
        fi
        OPENCODE_CMD="$OPENCODE_CMD --continue"

        # Create detached tmux session running opencode
        if tmux new-session -d -s "$SESSION" \
            -e "OPENCODE_WORKSPACE=$WORKSPACE" \
            -e "LANG=$LANG" \
            -e "LC_ALL=$LC_ALL" \
            -e "TERM=$TERM" \
            "$OPENCODE_CMD; echo ''; echo 'OpenCode exited. Press Enter to restart...'; read" \
            2>/dev/null; then
            echo "→ Session created. Attaching now..."
            if tmux attach-session -t "$SESSION" 2>/dev/null; then
                FAIL_COUNT=0
                echo ""
                echo "→ Detached. Reconnecting in 2s..."
                sleep 2
                continue
            else
                echo "→ Attach failed – session is running detached in background."
                echo "   Type 'oca' to reattach manually."
                FAIL_COUNT=$((FAIL_COUNT + 1))
                exec bash -l
            fi
        else
            echo "→ Failed to create tmux session – retrying..."
            FAIL_COUNT=$((FAIL_COUNT + 1))
            sleep 2
            continue
        fi
    fi
done
