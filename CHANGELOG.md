# Changelog – ha-opencode

## [0.1.0] – 2026-07-08

### Added
- Initial release: web terminal via ttyd on port 7681
- Full dev tools: bash, git, python3, nodejs, docker-cli, vim, tmux, jq, htop, ripgrep, fd, and more
- OpenCode AI installed globally (`opencode-ai` npm package)
- Auto-start OpenCode in tmux session at boot
- Home Assistant sidebar panel via HA ingress
- Helper scripts: `ha-cli.sh`, `opencode-attach.sh`, `backup-config.sh`
- Multi-arch support: amd64, aarch64, armv7, armhf
- Optional terminal password (basic auth)
- Configurable OpenCode workspace and model
- Access to Docker socket and Supervisor API
- Mounted folders: config, ssl, share, backup, media, addons
