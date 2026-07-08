#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Safe config editor – backs up configuration.yaml before editing
# Usage: backup-config [file]
# ──────────────────────────────────────────────────────────────
set -euo pipefail

CONFIG_FILE="${1:-/config/configuration.yaml}"
BACKUP_DIR="/backup/config-snapshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

if [ -f "$CONFIG_FILE" ]; then
    BACKUP_PATH="${BACKUP_DIR}/$(basename "$CONFIG_FILE")_${TIMESTAMP}.bak"
    cp "$CONFIG_FILE" "$BACKUP_PATH"
    echo "Backup saved: $BACKUP_PATH"
    echo "  Now safe to edit: $CONFIG_FILE"
else
    echo "File not found: $CONFIG_FILE"
    exit 1
fi
