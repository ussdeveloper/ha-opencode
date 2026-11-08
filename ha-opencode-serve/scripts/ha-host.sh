#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# ha-host – open an interactive shell on the HA OS host
# Usage: ha-host
# ──────────────────────────────────────────────────────────────
set -euo pipefail

echo "Entering Home Assistant host OS shell..."
echo "  Tip: 'exit' or Ctrl+D to return to the container."
echo ""

# Try bash first, fall back to sh
exec nsenter -t 1 -m -u -i -n -p -- /bin/bash -l 2>/dev/null || \
exec nsenter -t 1 -m -u -i -n -p -- /bin/sh -l
