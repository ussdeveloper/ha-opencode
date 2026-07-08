# Changelog – ha-opencode

All notable changes to this project will be documented in this file.

## [0.1.7] – 2026-07-08

### Added
- **Default rules and system prompt now visible in add-on configuration** – no more hidden defaults
- `opencode_system_prompt` pre-filled with full HA-aware system prompt (capabilities, principles, response style)
- `opencode_rules` pre-filled with condensed environment rules (paths, tools, safety rules, Supervisor API quick reference)
- Users can see and edit these directly in the HA add-on config UI or YAML editor

### Changed
- Built-in fallback defaults in `run.sh` still apply when fields are explicitly cleared to empty string

## [0.1.6] – 2026-07-08

### Fixed
- **Tmux session not attaching through sidebar panel** – rewrote `opencode-terminal.sh` with resilient error handling (no more `set -e` failures)
- Fallback to plain bash after 5 consecutive tmux failures instead of silent crash
- Tmux session now created detached first, then attached separately – more reliable through ttyd
- Added `--check-origin=false` to ttyd for HA ingress proxy compatibility
- Script path changed to absolute `/usr/local/bin/opencode-terminal.sh` in ttyd launch
- Better logging: shows attach/detach status, fail count, and recovery instructions

## [0.1.5] – 2026-07-08

### Added
- **Direct host shell channel** – `host-shell` and `ha-host` scripts using `nsenter` to execute commands on the HA OS host from within the container
- `util-linux` package (provides `nsenter` for host namespace entry)
- `/host` symlink → `/proc/1/root` for direct host filesystem access
- New shell aliases: `host` (host-shell), `ha-host`, `host-root`
- Default AGENTS.md extended with comprehensive host shell documentation, usage examples, and when-to-use guidance
- Default system prompt updated with host command execution capability

## [0.1.4] – 2026-07-08

### Changed
- **Full unrestricted host access enabled** – host_network, host_pid, host_dbus, host_ipc, host_uts
- Extended Linux capabilities: SYS_ADMIN, NET_ADMIN, SYS_RAWIO, SYS_MODULE, SYS_NICE, SYS_RESOURCE, SYS_TIME
- Host devices: /dev/mem, /dev/tty
- `/addons` changed from read-only to read-write (clone & build local add-ons)
- `protected: false` – add-on can be freely stopped/restarted
- Default AGENTS.md expanded with install/uninstall add-ons, host operations, full Supervisor API reference
- Default system prompt updated for full privileged access awareness
- New safety rule: host-level operations caution

## [0.1.3] – 2026-07-08

### Added
- **Built-in default AGENTS.md** – comprehensive HA-aware ruleset auto-generated when `opencode_rules` is not set. Covers mounted paths, available tools, add-on management, config editing workflow, safety rules, and Supervisor API usage.
- **Built-in default system prompt** – teaches OpenCode it's running inside ha-opencode, its capabilities, guiding principles, and safe response style.
- **Always-on opencode.json** – generated on every startup (even without custom options), always references the system-prompt.md for consistent context.
- Safety directives: backup-before-edit, validate-before-restart, incremental changes, modern HA syntax preference.
- Environment awareness: full path table, tool catalog, Supervisor API quick reference.

### Changed
- `setup_opencode_config()` now always writes AGENTS.md and system-prompt.md – user options override the built-in defaults rather than leaving files absent.
- `opencode.json` is always generated (not only when custom options are set).

## [0.1.2] – 2026-07-08

### Added
- **Configurable OpenCode system prompt** via `opencode_system_prompt` option
- **Configurable OpenCode rules** via `opencode_rules` option (written as `AGENTS.md`)
- **Configurable custom instructions** via `opencode_instructions` option
- `run.sh` now auto-generates `opencode.json` and instruction files from add-on config
- All OpenCode customization manageable directly from HA add-on options – no manual file edits needed

## [0.1.1] – 2026-07-08

### Changed
- **Terminal now auto-attaches to OpenCode tmux session** – no more plain bash on connect
- New `opencode-terminal.sh` wrapper: always opens tmux session with `opencode --continue`
- Loops on detach/disconnect so the user always lands back in OpenCode
- Updated `run.sh`: ttyd launches `opencode-terminal.sh` instead of `bash -l`
- All documentation, comments, and scripts translated to English
- Version bump for HA Supervisor update detection

## [0.1.0] – 2026-07-08

### Added
- Initial release: web terminal via ttyd on port 7681
- Full dev tools: bash, git, python3, nodejs, docker-cli, vim, tmux, jq, htop, ripgrep, fd, and more
- OpenCode AI installed globally (`opencode-ai` npm package)
- Auto-start OpenCode in detached tmux session at boot
- Home Assistant sidebar panel via HA ingress
- Helper scripts: `ha-cli.sh`, `opencode-attach.sh`, `backup-config.sh`
- Multi-arch support: amd64, aarch64, armv7, armhf
- Optional terminal password (basic auth)
- Configurable OpenCode workspace and model
- Access to Docker socket and Supervisor API
- Mounted folders: config, ssl, share, backup, media, addons

[0.1.7]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ussdeveloper/ha-opencode/releases/tag/v0.1.0
