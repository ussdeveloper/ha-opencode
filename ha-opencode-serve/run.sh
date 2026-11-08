#!/usr/bin/env bash
# ha-opencode-serve entrypoint
# Starts OpenCode 2 (`opencode serve`) and the ingress proxy that puts the
# web UI in the Home Assistant sidebar. Session data stays on /data.
set -euo pipefail

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

OPTS="/data/options.json"
INGRESS_PORT="${INGRESS_PORT:-4096}"
OPENCODE_UPSTREAM_PORT="${OPENCODE_UPSTREAM_PORT:-4097}"
export INGRESS_PORT OPENCODE_UPSTREAM_PORT
MIGRATION_MARKER="/data/.v1-session-migration.json"

echo "╔══════════════════════════════════════════════╗"
echo "║     ha-opencode-serve – OpenCode 2           ║"
echo "╚══════════════════════════════════════════════╝"

if [ -f "$OPTS" ]; then
    OPENCODE_WORKSPACE=$(jq -r '.opencode_workspace // "/config"' "$OPTS")
    OPENCODE_MODEL=$(jq -r '.opencode_model // ""' "$OPTS")
    OPENCODE_SYSTEM_PROMPT=$(jq -r '.opencode_system_prompt // ""' "$OPTS")
    OPENCODE_RULES=$(jq -r '.opencode_rules // ""' "$OPTS")
    OPENCODE_INSTRUCTIONS=$(jq -r '.opencode_instructions // ""' "$OPTS")
    AUTO_APPROVE=$(jq -r '.auto_approve // true' "$OPTS")
    MIGRATE_V1=$(jq -r '.migrate_v1_sessions // true' "$OPTS")
else
    echo "[WARN] /data/options.json not found – using defaults"
    OPENCODE_WORKSPACE="/config"
    OPENCODE_MODEL=""
    OPENCODE_SYSTEM_PROMPT=""
    OPENCODE_RULES=""
    OPENCODE_INSTRUCTIONS=""
    AUTO_APPROVE="true"
    MIGRATE_V1="true"
fi

mkdir -p "$OPENCODE_WORKSPACE" /data/logs
export OPENCODE_WORKSPACE

setup_persistence() {
    local home_path="$1"
    local persistent="$2"
    local parent
    parent="$(dirname "$home_path")"
    mkdir -p "$persistent" "$parent"

    if [ -d "$home_path" ] && [ ! -L "$home_path" ]; then
        cp -a "$home_path"/. "$persistent"/ 2>/dev/null || true
        rm -rf "$home_path"
    fi
    ln -sfn "$persistent" "$home_path"
}

setup_persistence /root/.opencode /data/opencode
setup_persistence /root/.config/opencode /data/opencode-config
setup_persistence /root/.local/share/opencode /data/opencode-local
setup_persistence /root/.cache/opencode /data/opencode-cache
setup_persistence /root/.local/state/opencode /data/opencode-state
setup_persistence "$OPENCODE_WORKSPACE/.opencode" /data/opencode-workspace

echo "[INFO] Session store: /data/opencode-local -> ~/.local/share/opencode"

if [ -d /proc/1/root ]; then
    ln -sfn /proc/1/root /host
    echo "[INFO] Host root accessible at /host"
else
    echo "[WARN] /proc/1/root is not available – v1 migration and host-shell need host_pid"
fi

setup_ssh_keys() {
    local ssh_dir="/root/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    if [ ! -f "$ssh_dir/id_ed25519" ]; then
        ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -C "ha-opencode-serve" -q
    fi
    if [ -f "$ssh_dir/id_ed25519.pub" ] && [ -d /proc/1/root ]; then
        local pubkey
        pubkey="$(cat "$ssh_dir/id_ed25519.pub")"
        nsenter -t 1 -m -u -i -n -p -- /bin/sh -c "
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            if ! grep -qF '$pubkey' /root/.ssh/authorized_keys 2>/dev/null; then
                echo '$pubkey' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
            fi
        " 2>/dev/null && echo "[OK]   SSH key installed on host" \
            || echo "[WARN] Could not push SSH key to host"
    fi
}
setup_ssh_keys

copy_tree_missing() {
    local src="$1"
    local dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    local db rel target
    while IFS= read -r -d '' db; do
        rel="${db#"$src"/}"
        target="$dest/$rel"
        if [ -e "$target" ]; then
            echo "[INFO] keep existing $rel"
            continue
        fi
        mkdir -p "$(dirname "$target")"
        if sqlite3 "$db" ".backup '$target'"; then
            echo "[INFO] sqlite backup $rel"
        else
            echo "[WARN] sqlite backup failed for $rel – copying the file"
            cp -a "$db" "$target"
            [ -f "${db}-wal" ] && cp -a "${db}-wal" "${target}-wal"
            [ -f "${db}-shm" ] && cp -a "${db}-shm" "${target}-shm"
        fi
    done < <(find "$src" -type f -name '*.db' -print0)

    local file
    while IFS= read -r -d '' file; do
        rel="${file#"$src"/}"
        case "$rel" in
            *.db|*.db-wal|*.db-shm) continue ;;
        esac
        target="$dest/$rel"
        if [ -e "$target" ]; then
            continue
        fi
        mkdir -p "$(dirname "$target")"
        cp -a "$file" "$target"
        echo "[INFO] copied $rel"
    done < <(find "$src" -type f -print0)
}

find_v1_data() {
    local roots=(
        /host/mnt/data/supervisor/addons/data
        /host/usr/share/hassio/addons/data
        /host/var/lib/hassio/addons/data
        /mnt/data/supervisor/addons/data
    )
    local root dir
    shopt -s nullglob
    for root in "${roots[@]}"; do
        [ -d "$root" ] || continue
        for dir in "$root"/ha-opencode "$root"/*_ha-opencode; do
            [ -d "$dir" ] || continue
            case "$dir" in
                *ha-opencode-serve*) continue ;;
            esac
            if [ -d "$dir/opencode-local" ] || [ -d "$dir/opencode" ] || [ -d "$dir/opencode-workspace" ]; then
                printf '%s\n' "$dir"
                shopt -u nullglob
                return 0
            fi
        done
    done
    shopt -u nullglob
    return 1
}

migrate_v1_sessions() {
    if [ "$MIGRATE_V1" != "true" ]; then
        echo "[INFO] v1 session migration disabled"
        return 0
    fi
    if [ -f "$MIGRATION_MARKER" ]; then
        echo "[INFO] v1 sessions already migrated ($(cat "$MIGRATION_MARKER"))"
        return 0
    fi

    local src
    if ! src="$(find_v1_data)"; then
        echo "[INFO] OpenCode Terminal data was not found on the host – nothing to migrate"
        return 0
    fi

    echo "[INFO] Migrating sessions from $src (copy, v1 data is left in place)"
    copy_tree_missing "$src/opencode-local" /data/opencode-local
    copy_tree_missing "$src/opencode" /data/opencode
    copy_tree_missing "$src/opencode-workspace" /data/opencode-workspace
    copy_tree_missing "$src/opencode-cache" /data/opencode-cache

    local stamp
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"source":"%s","migrated_at":"%s"}\n' "$src" "$stamp" > "$MIGRATION_MARKER"
    echo "[OK]   v1 session copy finished. OpenCode 2 imports legacy rows when it opens the database."
    echo "[INFO] Existing v2 files were not overwritten. Delete $MIGRATION_MARKER to scan again."
}
migrate_v1_sessions

write_default_prompt() {
    cat <<'EOF'
You are an AI coding assistant running inside ha-opencode-serve on Home Assistant.
The user reaches you through the OpenCode 2 web UI. Auto-approve is the default.
Back up configuration before editing it, validate YAML before restarting, and
explain each change. Prefer host-shell ha addons for add-on lifecycle.
EOF
}

write_default_rules() {
    cat <<'EOF'
# ha-opencode-serve

Workspace: /config. Sessions persist on /data.
Backup with backup-config, validate with ha-cli check, then restart only if the check passes.
Use host-shell for HA OS commands. Do not delete /config files without an explicit yes.
EOF
}

setup_opencode_config() {
    local config_dir="/root/.config/opencode"
    mkdir -p "$config_dir"

    if [ -n "$OPENCODE_RULES" ]; then
        printf '%s\n' "$OPENCODE_RULES" | tee "$config_dir/AGENTS.md" > "$OPENCODE_WORKSPACE/AGENTS.md"
    else
        write_default_rules | tee "$config_dir/AGENTS.md" > "$OPENCODE_WORKSPACE/AGENTS.md"
    fi

    if [ -n "$OPENCODE_SYSTEM_PROMPT" ]; then
        printf '%s\n' "$OPENCODE_SYSTEM_PROMPT" > "$config_dir/system-prompt.md"
    else
        write_default_prompt > "$config_dir/system-prompt.md"
    fi

    local extra=""
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        printf '%s\n' "$OPENCODE_INSTRUCTIONS" > "$config_dir/custom-instructions.md"
        extra="$config_dir/custom-instructions.md"
    fi

    local auto_json=false
    if [ "$AUTO_APPROVE" = "true" ]; then
        auto_json=true
    fi

    jq -n \
        --arg prompt "$config_dir/system-prompt.md" \
        --arg extra "$extra" \
        --arg model "$OPENCODE_MODEL" \
        --argjson auto "$auto_json" \
        '{
            "$schema": "https://opencode.ai/config.json",
            autoupdate: false,
            instructions: ([$prompt] + (if $extra != "" then [$extra] else [] end))
        }
        + (if $model != "" then {model: $model} else {} end)
        + (if $auto then {permissions: [{action: "*", resource: "*", effect: "allow"}]} else {} end)' \
        > "$config_dir/opencode.json"
    cp "$config_dir/opencode.json" "$OPENCODE_WORKSPACE/opencode.json"
    echo "[INFO] OpenCode config written to $config_dir and $OPENCODE_WORKSPACE"
}
setup_opencode_config

echo "   Workspace    : $OPENCODE_WORKSPACE"
echo "   Model        : ${OPENCODE_MODEL:-<default>}"
echo "   Auto-approve : $AUTO_APPROVE"
echo "   Migrate v1   : $MIGRATE_V1"
opencode --version || true

OPENCODE_PID=""
PROXY_PID=""
cleanup() {
    echo "[INFO] Shutting down ha-opencode-serve..."
    if [ -n "${PROXY_PID}" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi
    if [ -n "${OPENCODE_PID}" ]; then
        kill "$OPENCODE_PID" 2>/dev/null || true
    fi
    wait "${PROXY_PID:-}" "${OPENCODE_PID:-}" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

cd "$OPENCODE_WORKSPACE"
serve_cmd=(opencode serve --hostname 127.0.0.1 --port "$OPENCODE_UPSTREAM_PORT" --print-logs)
if [ "$AUTO_APPROVE" = "true" ] && opencode serve --help 2>&1 | grep -q -- '--auto'; then
    serve_cmd+=(--auto)
    echo "[INFO] opencode serve accepts --auto; enabling it"
else
    if [ "$AUTO_APPROVE" = "true" ]; then
        echo "[INFO] This OpenCode build has no serve --auto flag. Auto-approve is set in opencode.json permissions."
    fi
fi

echo "[INFO] Starting ${serve_cmd[*]}"
"${serve_cmd[@]}" &
OPENCODE_PID=$!

ready=0
for _ in $(seq 1 60); do
    if ! kill -0 "$OPENCODE_PID" 2>/dev/null; then
        echo "[ERROR] opencode serve exited before it started listening"
        wait "$OPENCODE_PID" || true
        exit 1
    fi
    if (echo >/dev/tcp/127.0.0.1/"$OPENCODE_UPSTREAM_PORT") >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.5
done

if [ "$ready" -ne 1 ]; then
    echo "[ERROR] opencode serve did not open port $OPENCODE_UPSTREAM_PORT"
    kill "$OPENCODE_PID" 2>/dev/null || true
    exit 1
fi

echo "[INFO] OpenCode is listening on 127.0.0.1:${OPENCODE_UPSTREAM_PORT}"
echo "[INFO] Sidebar proxy on 0.0.0.0:${INGRESS_PORT}"
python3 /usr/local/bin/ingress-proxy.py &
PROXY_PID=$!

set +e
wait -n "$OPENCODE_PID" "$PROXY_PID"
status=$?
set -e
kill "$PROXY_PID" "$OPENCODE_PID" 2>/dev/null || true
wait "$PROXY_PID" "$OPENCODE_PID" 2>/dev/null || true
exit "$status"
