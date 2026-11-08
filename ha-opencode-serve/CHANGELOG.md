# Changelog – ha-opencode-serve

## [2.0.1] – 2026-11-08

### Fixed
- Sidebar ingress talks to `opencode serve` on port 4096 directly. The extra HTTP proxy answered in a way Supervisor treated as a bad gateway.
- Session copy from the Terminal add-on also looks in the current Supervisor data path `/mnt/data/supervisor/apps/data`.
- Base image is `ghcr.io/home-assistant/base` in the Dockerfile. `build.json` is no longer used.

## [2.0.0] – 2026-11-08

### Added
- Separate add-on `ha-opencode-serve` running OpenCode 2.2.6 `opencode serve`
- Sidebar panel via Home Assistant ingress, with a proxy that keeps the UI on the ingress path
- Auto-approve through OpenCode 2 permission rules (`auto_approve`, default on)
- Session, config, cache, and state directories stored on the add-on `/data` volume
- `migrate_v1_sessions` copies OpenCode Terminal sessions from the host when that add-on data exists, without modifying the 1.0 copy
