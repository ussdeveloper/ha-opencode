# Changelog – ha-opencode-serve

## [2.0.6] – 2026-11-08

### Fixed
- Opening a session no longer throws `<MetaProvider /> should be in the tree`. The cache-bust query was only on the first script, so the session page loaded a second copy of the app.

## [2.0.5] – 2026-11-08

### Fixed
- The sidebar signs in to OpenCode by itself. The connect screen never appeared: it only opens after the app is running and the API returns 401, and the pairing link points at an address inside the container.

## [2.0.4] – 2026-11-08

### Fixed
- Stylesheet preload no longer requests `/_assets/*.css` from the Home Assistant root. The OpenCode preloader builds that path in code, and link, script, and image URLs aimed at the domain root now stay on the ingress path.

## [2.0.3] – 2026-11-08

### Fixed
- The sidebar showed "Unrecognised route" because the app router kept the ingress path. Asset URLs are cache-busted so the browser does not keep the previous scripts.

## [2.0.2] – 2026-11-08

### Fixed
- Sidebar panel was blank after 2.0.1. OpenCode answered, but its script URLs pointed at the Home Assistant root and returned 404.
- The ingress proxy now rewrites those URLs onto the ingress path and leaves compressed bodies alone unless it is changing them.

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
