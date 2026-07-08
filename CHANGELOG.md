# Changelog – ha-opencode

All notable changes to this project will be documented in this file.

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

[0.1.1]: https://github.com/ussdeveloper/ha-opencode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ussdeveloper/ha-opencode/releases/tag/v0.1.0
