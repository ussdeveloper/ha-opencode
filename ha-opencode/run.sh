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

# ── Locale & terminal encoding ───────────────────────────────
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export TERM="${TERM:-xterm-256color}"

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

# ── Persist OpenCode state on /data volume ──────────────────
# Without this, opencode session data lives in ~/.opencode/ which
# is inside the ephemeral container – it dies on every restart.
# Symlinking to /data/ (HA add-on persistent volume) fixes this.
setup_opencode_persistence() {
    local persistent="/data/opencode"
    local persistent_config="/data/opencode-config"

    mkdir -p "$persistent" "$persistent_config"

    # ── ~/.opencode → /data/opencode (session state, history) ──
    if [ -d /root/.opencode ] && [ ! -L /root/.opencode ]; then
        cp -a /root/.opencode/. "$persistent"/ 2>/dev/null || true
        rm -rf /root/.opencode
    fi
    ln -sf "$persistent" /root/.opencode 2>/dev/null || true

    # ── ~/.config/opencode → /data/opencode-config (AGENTS.md, opencode.json) ──
    if [ -d /root/.config/opencode ] && [ ! -L /root/.config/opencode ]; then
        cp -a /root/.config/opencode/. "$persistent_config"/ 2>/dev/null || true
        rm -rf /root/.config/opencode
    fi
    mkdir -p /root/.config 2>/dev/null || true
    ln -sf "$persistent_config" /root/.config/opencode 2>/dev/null || true

    echo "[INFO] OpenCode state persisted at $persistent + $persistent_config"
}
setup_opencode_persistence

# ── Host filesystem access ──────────────────────────────────
# With host_pid:true, /proc/1/root exposes the HA OS host root
# filesystem. Symlink /host → /proc/1/root for easy access.
if [ -d /proc/1/root ]; then
    ln -sf /proc/1/root /host 2>/dev/null || true
    echo "[INFO] Host root accessible at /host"
else
    echo "[WARN] /proc/1/root not available – host access limited"
fi

# ── SSH key bootstrap ───────────────────────────────────────
# Generate an SSH key pair and push the public key to the
# HA OS host's authorized_keys so ssh-host works seamlessly.
setup_ssh_keys() {
    local ssh_dir="/root/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [ ! -f "$ssh_dir/id_ed25519" ]; then
        echo "[INFO] Generating SSH key pair..."
        ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -C "ha-opencode" -q
    fi

    # Push public key to host's authorized_keys via nsenter
    if [ -f "$ssh_dir/id_ed25519.pub" ] && [ -d /proc/1/root ]; then
        echo "[INFO] Pushing SSH public key to host authorized_keys..."
        local pubkey
        pubkey=$(cat "$ssh_dir/id_ed25519.pub")
        nsenter -t 1 -m -u -i -n -p -- /bin/sh -c "
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            if ! grep -qF '$pubkey' /root/.ssh/authorized_keys 2>/dev/null; then
                echo '$pubkey' >> /root/.ssh/authorized_keys
                chmod 600 /root/.ssh/authorized_keys
            fi
        " 2>/dev/null && echo "[OK]   SSH key installed on host" || \
            echo "[WARN] Could not push SSH key to host – ssh-host may need manual setup"
    fi
}
setup_ssh_keys

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

## Host-level operations – direct HA OS access
Since you run in a **privileged container with host_pid**, you can execute
commands directly on the Home Assistant OS host using `nsenter`.

### Key tools
| Command | Purpose |
|---------|---------|
| `host-shell <cmd...>` | Run a single command on the HA OS host |
| `ha-host` | Open an **interactive shell** on the HA OS host |
| `host` | Alias for `host-shell` |
| `ssh-host` | **SSH into the HA OS host** (port 22222, key-based auth) |
| `ssh-host <cmd>` | Run a single command via SSH on the host |
| `/host/` | Symlink to the host root filesystem |

### SSH access (ssh-host)
The container auto-generates an SSH key pair on first start and pushes the public
key to the host's `/root/.ssh/authorized_keys` via nsenter. After that, you can:
```bash
ssh-host                  # Interactive SSH shell on the host
ssh-host ha core check    # Run a command via SSH
ssh-host docker ps        # Host's Docker (Supervisor-managed)
```
SSH connection defaults: `root@172.30.32.1:22222` (standard HA OS SSH port).
Override with env vars: `SSH_HOST`, `SSH_PORT`, `SSH_USER`.

### When to use which host access method
- **`host-shell` / `ha-host` (nsenter)**: fastest, no network, works even if SSH is down
- **`ssh-host` (SSH)**: standard protocol, familiar tooling, works with scp/sftp
- **`/host/` path**: read host files directly without spawning a shell

### How it works
`host-shell` uses `nsenter -t 1 -m -u -i -n -p` to enter the host's PID 1
(init/systemd) namespaces: mount, UTS, IPC, network, and PID. This gives you
the same environment as logging into the HA OS console directly.

### Examples
```bash
# Run HA CLI on the host
host-shell ha core check
host-shell ha core restart

# Check host OS info
host-shell cat /etc/os-release
host-shell uname -a

# Manage host services via systemd
host-shell systemctl status home-assistant
host-shell systemctl restart hassio-supervisor

# Access host filesystem directly
ls /host/etc/
cat /host/etc/hassio.json
host-shell docker ps           # host's Docker (Supervisor-managed)

# Open an interactive host shell
ha-host
# (type 'exit' to return to the container)
```

### When to use host-shell vs container commands
- **Use `host-shell`** for: HA CLI, systemd, host OS inspection, Supervisor-level ops
- **Use container commands** (`docker`, `ha-cli`) for: add-on management, container-level Docker ops
- **Use `/host/` path** for reading host files directly without spawning a shell

### Important
- `host-shell` runs commands as **root on the HA OS host** – be extremely careful
- Changes made via host-shell affect the real HA OS, not just the container
- The host filesystem is accessible read-write via `/host/` – do not modify
  system files without explicit user confirmation and a backup plan

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
host services, and networking. You have a direct **host shell channel** via
`nsenter` (`host-shell` / `ha-host`) to run commands on the HA OS host itself.

Your primary role is to help the user manage, configure, and extend their
Home Assistant smart home system with complete freedom.

## Core capabilities
- Read, write, and validate Home Assistant configuration files (YAML)
- **Install, uninstall, start, stop, restart, and rebuild add-ons** via Supervisor API and Docker
- **Build custom local add-ons** from source in `/addons/`
- **Execute commands directly on the HA OS host** via `host-shell` / `ha-host` (nsenter) and `ssh-host` (SSH, port 22222)
- **Access the host filesystem** at `/host/` (symlink to host root)
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

    # ── AGENTS.md ──────────────────────────────────────────────
    # Write to BOTH locations so OpenCode can auto-discover rules:
    #  - /config/AGENTS.md  ← project root (auto-discovered first)
    #  - ~/.config/opencode/AGENTS.md ← global fallback
    if [ -n "$OPENCODE_RULES" ]; then
        echo "$OPENCODE_RULES" | tee "$config_dir/AGENTS.md" > "/config/AGENTS.md"
        echo "[INFO] OpenCode rules: custom → /config/AGENTS.md + $config_dir/AGENTS.md"
    else
        write_default_agents_md | tee "$config_dir/AGENTS.md" > "/config/AGENTS.md"
        echo "[INFO] OpenCode rules: built-in defaults → /config/AGENTS.md + $config_dir/AGENTS.md"
    fi

    # ── System prompt ──────────────────────────────────────────
    if [ -n "$OPENCODE_SYSTEM_PROMPT" ]; then
        echo "$OPENCODE_SYSTEM_PROMPT" > "$config_dir/system-prompt.md"
        echo "[INFO] OpenCode system prompt: custom → $config_dir/system-prompt.md"
    else
        write_default_system_prompt > "$config_dir/system-prompt.md"
        echo "[INFO] OpenCode system prompt: built-in default → $config_dir/system-prompt.md"
    fi

    # ── Custom instructions (always optional, user-only) ───────
    if [ -n "$OPENCODE_INSTRUCTIONS" ]; then
        echo "$OPENCODE_INSTRUCTIONS" > "$config_dir/custom-instructions.md"
        echo "[INFO] OpenCode custom instructions → $config_dir/custom-instructions.md"
    fi

    # ── opencode.json ──────────────────────────────────────────
    # Generated in BOTH global config dir AND workspace root so
    # OpenCode finds it regardless of CWD.
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
    # Also write to workspace root (/config) for project-level discovery
    cp "$config_dir/opencode.json" "/config/opencode.json" 2>/dev/null || true
    echo "[INFO] OpenCode config: $config_dir/opencode.json + /config/opencode.json"
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
    ttyd_args+=("--ping-interval" "30")
    ttyd_args+=("--check-origin=false")

    if [ -n "$TERMINAL_PASSWORD" ]; then
        ttyd_args+=("--credential" "admin:${TERMINAL_PASSWORD}")
        echo "[INFO] Terminal auth enabled (basic auth)"
    else
        echo "[INFO] Terminal auth disabled (no password set)"
    fi

    # Choose what shell to launch
    if [ "$OPENCODE_AUTO_START" = "true" ]; then
        shell_cmd="/usr/local/bin/opencode-terminal.sh"
        echo "[INFO] Terminal will auto-attach to OpenCode tmux session"
    else
        shell_cmd="bash -l"
        echo "[INFO] Terminal starts plain bash (opencode auto-start disabled)"
    fi

    echo "[INFO] Starting ttyd web terminal on port $TERMINAL_PORT..."
    exec ttyd "${ttyd_args[@]}" -- $shell_cmd
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
