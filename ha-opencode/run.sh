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

# ── Default OpenCode rules (HA-aware AGENTS.md) ────────────
# Generated when the user does not provide custom opencode_rules.
write_default_agents_md() {
    cat << 'AGENTSEOF'
# ha-opencode – Home Assistant Environment & Safety Rules

## Where you are
You are running inside the **ha-opencode** add-on container on a Home Assistant
OS / Supervised system **with full unrestricted host access**. Your working
directory is `/config` – the live Home Assistant configuration directory
(read-write). You have privileged access to the Docker engine, Supervisor API,
host network, host processes, and host D-Bus.

### Access level
- **host_network** – you see and use the host's real network interfaces (no NAT)
- **host_pid** – you can see and interact with all host processes
- **host_dbus** – you can call D-Bus services on the host (systemd, NetworkManager, etc.)
- **host_ipc / host_uts** – shared IPC and hostname with the host
- **Privileged container** – SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYS_RAWIO, SYS_MODULE
- **Docker socket** – full control over all containers (add-ons + Supervisor)
- **Supervisor API** – add-on lifecycle, host info, network, hardware

## Mounted paths
| Path | Purpose | Access |
|------|---------|--------|
| `/config` | HA configuration (configuration.yaml, automations, etc.) | rw |
| `/share` | Shared data across add-ons | rw |
| `/backup` | Backup storage – **use this for snapshots** | rw |
| `/media` | Media files (images, audio, etc.) | rw |
| `/ssl` | TLS/SSL certificates | ro |
| `/addons` | Local add-on git repositories – **clone & build here** | rw |
| `/var/run/docker.sock` | Docker engine – full container lifecycle control | rw |
| `/dev/mem`, `/dev/tty` | Host devices | rw |

## Available tools (always in PATH)
| Tool | Purpose |
|------|---------|
| `ha-cli check` | Validate configuration.yaml syntax via HA CLI or python3 |
| `ha-cli restart` | Restart Home Assistant core |
| `ha-cli logs` | Tail Home Assistant logs |
| `ha-cli backup` | Create a tar.gz snapshot of /config into /backup |
| `ha-cli docker-ps` | List all running add-on containers |
| `ha-cli exec <name>` | Open a shell inside any add-on container |
| `ha-cli supervisor` | Show Supervisor info (needs SUPERVISOR_TOKEN) |
| `backup-config [file]` | Backup a config file before editing |
| `docker ...` | Full Docker CLI – pull, build, run, exec, stop, rm, logs, inspect |
| `git`, `python3`, `node`, `jq`, `yq`, `curl`, `vim`, `tmux` | Standard dev tools |
| `dbus-send`, `gdbus` | Host D-Bus interaction |

## How to manage add-ons (full control)
Since you have Docker socket + Supervisor API access, you can:
- **List add-ons**: `ha-cli docker-ps` or `docker ps`
- **Install an add-on**: use Supervisor API or `ha addons install <slug>`
- **Uninstall an add-on**: use Supervisor API or `ha addons uninstall <slug>`
- **Start/stop/restart**: `docker start|stop|restart <container-name>`
- **Enter an add-on shell**: `ha-cli exec addon_local_xyz` or `docker exec -it <name> bash`
- **View add-on logs**: `docker logs -f <container-name>`
- **Pull new images**: `docker pull <image>`
- **Build a local add-on**: clone repo into `/addons/`, `docker build`, test, register
- **Rebuild an add-on**: modify its source in `/addons/<slug>/`, rebuild via Supervisor

## How to install/remove add-ons via Supervisor API
```bash
# List all add-ons
curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons

# Install an add-on from a repository
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"repository":"<repo-url>"}' \
  http://supervisor/store/addons/<slug>/install

# Uninstall
curl -s -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  http://supervisor/addons/<slug>/uninstall
```

## How to modify Home Assistant configuration
1. **Backup first**: `backup-config /config/configuration.yaml`
2. **Edit**: `vim /config/configuration.yaml` or use python/yq/jq for programmatic changes
3. **Validate**: `ha-cli check`
4. **Restart core if OK**: `ha-cli restart`
5. **Monitor logs**: `ha-cli logs`

## ⚠️ CRITICAL SAFETY RULES – FOLLOW ALWAYS
1. **NEVER modify configuration.yaml without creating a backup first.**
   Use `backup-config` before every manual edit.
2. **ALWAYS validate YAML after any change.** Run `ha-cli check` and confirm "OK"
   before restarting.
3. **NEVER restart Home Assistant core with invalid configuration.**
   A broken config will prevent HA from starting. Check first, restart second.
4. **When editing automations or scripts, use modern HA syntax:**
   triggers/conditions/actions blocks (not deprecated platform/event formats).
5. **Do not delete or move files in /config without explicit user confirmation.**
6. **If a change breaks something, revert from the latest backup in /backup.**
7. **Test changes incrementally** – one logical change at a time, verify, then proceed.
8. **Use Supervisor API for add-on lifecycle** (install/uninstall/start/stop) rather
   than raw docker commands when possible – it maintains HA state consistency.
9. **⚠️ You have FULL HOST ACCESS.** Be extremely careful with host-level operations
   (D-Bus, host processes, network config). A mistake can crash the entire system.
10. **Before installing/removing add-ons**, verify the action won't break
    dependent services or integrations.

## Building custom local add-ons
Since `/addons` is now writable:
1. Create the add-on structure in `/addons/<slug>/`
2. Follow the HA add-on spec: config.yaml, Dockerfile, run.sh, build.json
3. `docker build` to test the image locally
4. Register via Supervisor API or it auto-detects from `/addons/`

## Host-level operations (use with caution)
- **Check host processes**: `ps aux` (host PID namespace visible)
- **Network config**: `ip addr`, `ip route` (host network stack)
- **D-Bus services**: `dbus-send --system ...` or `gdbus`
- **System logs**: `journalctl` (if available)
- **Restart Supervisor**: `docker restart hassio_supervisor`
- **Restart host services**: via D-Bus or docker

## Supervisor API – full reference
```bash
TOKEN="$SUPERVISOR_TOKEN"
# Host info
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/info
# Network info
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/network/info
# Add-on management
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/addons
# Store (available add-ons)
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/store
# Hardware
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/hardware/info
# Host services
curl -s -H "Authorization: Bearer $TOKEN" http://supervisor/services
```
AGENTSEOF
}

# ── Default OpenCode system prompt ──────────────────────────
# Generated when the user does not provide custom opencode_system_prompt.
write_default_system_prompt() {
    cat << 'PROMPTEOF'
You are an AI coding assistant running inside **ha-opencode**, a Home Assistant
add-on container with **full unrestricted host access** (privileged, host network,
host PID, host D-Bus, Docker socket, Supervisor API). You can manage every aspect
of the Home Assistant system: configuration, add-ons (install/remove/build),
host services, and networking.

Your primary role is to help the user manage, configure, and extend their
Home Assistant smart home system with complete freedom.

## Core capabilities
- Read, write, and validate Home Assistant configuration files (YAML)
- **Install, uninstall, start, stop, restart, and rebuild add-ons** via Supervisor API and Docker
- **Build custom local add-ons** from source in `/addons/`
- Query Supervisor API for system info, add-on status, store, network, and hardware
- Access host processes, D-Bus services, and network configuration
- Edit automations, scripts, scenes, dashboards, and integrations
- Run system diagnostics and troubleshoot at host level
- Use standard dev tools: git, python3, nodejs, jq, yq, curl, docker, vim, tmux

## Guiding principles
1. **Safety first** – always backup before editing; validate before restarting.
2. **Be precise** – when modifying YAML, ensure correct indentation and syntax.
3. **Explain changes** – tell the user what you're changing and why.
4. **One change at a time** – make incremental, testable modifications.
5. **Prefer modern HA syntax** – use triggers/conditions/actions for automations.
6. **Respect the running system** – don't restart HA unless the user asks or
   you've confirmed the config is valid.
7. **When in doubt, ask** – if a change could break something, confirm with the
   user before proceeding.

## Response style
- Be concise and actionable.
- Provide exact commands or file edits the user can review.
- When editing YAML, show the relevant snippet with context.
- If a tool is available (ha-cli, docker, git), prefer using it over raw shell.

The user is a Home Assistant administrator. They trust you to make changes safely.
PROMPTEOF
}

# ── Setup OpenCode config files ─────────────────────────────
# Generates AGENTS.md, system-prompt.md, and opencode.json.
# Uses built-in HA-aware defaults when user has not provided custom content.
# Custom user options override the defaults.
setup_opencode_config() {
    local config_dir="/root/.config/opencode"
    mkdir -p "$config_dir"

    # ── AGENTS.md (auto-discovered by OpenCode as project rules) ──
    if [ -n "$OPENCODE_RULES" ]; then
        echo "$OPENCODE_RULES" > "$config_dir/AGENTS.md"
        echo "[INFO] OpenCode rules: custom (from add-on config)"
    else
        write_default_agents_md > "$config_dir/AGENTS.md"
        echo "[INFO] OpenCode rules: built-in HA-aware defaults"
    fi

    # ── System prompt ──────────────────────────────────────────
    if [ -n "$OPENCODE_SYSTEM_PROMPT" ]; then
        echo "$OPENCODE_SYSTEM_PROMPT" > "$config_dir/system-prompt.md"
        echo "[INFO] OpenCode system prompt: custom"
    else
        write_default_system_prompt > "$config_dir/system-prompt.md"
        echo "[INFO] OpenCode system prompt: built-in HA-aware default"
    fi

    # ── Custom instructions (always optional, user-only) ───────
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        echo "$OPENCODE_INSTRUCTIONS" > "$config_dir/custom-instructions.md"
        echo "[INFO] OpenCode custom instructions written"
    fi

    # ── opencode.json (always generated – references system prompt + optional custom instructions) ──
    local instructions_json="[\"$config_dir/system-prompt.md\""
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        instructions_json="$instructions_json,\"$config_dir/custom-instructions.md\""
    fi
    instructions_json="$instructions_json]"

    cat > "$config_dir/opencode.json" << JSONEOF
{
  "instructions": $instructions_json
}
JSONEOF
    echo "[INFO] OpenCode config: $config_dir/opencode.json"
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
