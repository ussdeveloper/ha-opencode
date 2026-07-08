#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# HA CLI helper – useful shortcuts for Home Assistant management
# ──────────────────────────────────────────────────────────────
set -euo pipefail

show_help() {
    cat << 'EOF'
ha-cli – Home Assistant CLI shortcuts (inside ha-opencode addon)

  ha-cli check          Validate configuration.yaml
  ha-cli restart        Restart Home Assistant core
  ha-cli logs           Tail Home Assistant logs
  ha-cli backup         Create a snapshot of /config
  ha-cli docker-ps      List running add-on containers
  ha-cli exec <name>    Exec into an add-on container by name
  ha-cli supervisor     Show Supervisor info
  ha-cli help           This message

When running inside ha-opencode addon (hassio_api: true), the Supervisor
API is available via the Hass.io proxy socket and environment variables.
EOF
}

check_config() {
    echo "Checking Home Assistant configuration..."
    if command -v ha &>/dev/null; then
        ha core check
    elif [ -f /config/configuration.yaml ]; then
        echo "Validating YAML syntax of /config/configuration.yaml..."
        python3 -c "
import yaml, sys
try:
    with open('/config/configuration.yaml') as f:
        yaml.safe_load(f)
    print('YAML syntax: OK')
except Exception as e:
    print(f'YAML error: {e}')
    sys.exit(1)
"
    else
        echo "/config/configuration.yaml not found"
    fi
}

restart_core() {
    echo "Restarting Home Assistant core..."
    if command -v ha &>/dev/null; then
        ha core restart
    else
        echo "Use Supervisor UI or 'ha core restart' (needs ha CLI installed)"
    fi
}

tail_logs() {
    if [ -f /config/home-assistant.log ]; then
        tail -f /config/home-assistant.log
    else
        echo "Log file not found. Check Supervisor → System → Logs."
    fi
}

create_backup() {
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="/backup/config_backup_${TIMESTAMP}.tar.gz"
    echo "Creating backup: $BACKUP_FILE"
    tar czf "$BACKUP_FILE" -C / config/ 2>/dev/null && \
        echo "Backup saved: $BACKUP_FILE" || \
        echo "Backup failed (check permissions)"
}

docker_ps() {
    if [ -S /var/run/docker.sock ]; then
        echo "Running add-on containers:"
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || \
            echo "Cannot reach Docker socket"
    else
        echo "Docker socket not available"
    fi
}

exec_addon() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Usage: ha-cli exec <container-name>"
        docker_ps
        exit 1
    fi
    docker exec -it "$name" bash 2>/dev/null || \
        docker exec -it "$name" sh 2>/dev/null || \
        echo "Cannot exec into '$name'"
}

supervisor_info() {
    if [ -n "${SUPERVISOR_TOKEN:-}" ]; then
        echo "Supervisor API available"
        curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
            http://supervisor/info | jq . 2>/dev/null || \
            echo "Cannot reach Supervisor API"
    else
        echo "SUPERVISOR_TOKEN not set (running outside addon?)"
    fi
}

# ── Main dispatch ────────────────────────────────────────────
case "${1:-help}" in
    check)      check_config ;;
    restart)    restart_core ;;
    logs)       tail_logs ;;
    backup)     create_backup ;;
    docker-ps)  docker_ps ;;
    exec)       exec_addon "${2:-}" ;;
    supervisor) supervisor_info ;;
    help|--help|-h) show_help ;;
    *)          echo "Unknown command: $1"; show_help; exit 1 ;;
esac
