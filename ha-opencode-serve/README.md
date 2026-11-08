# OpenCode 2 – serve add-on

Separate Home Assistant add-on from **OpenCode Terminal** (`ha-opencode` 0.1.x). This one runs **OpenCode 2.2.6** as `opencode serve` and shows that web UI in the sidebar.

Slug: `ha-opencode-serve`. Architectures: `amd64`, `aarch64`. OpenCode 2 does not publish an armv7/armhf build.

## What starts

1. Session directories are symlinked onto the add-on `/data` volume so history survives restarts and reboots.
2. If `migrate_v1_sessions` is on and the OpenCode Terminal add-on data is on the host, sessions are **copied** once into this add-on's volume. The 1.0 files are not moved or deleted.
3. `opencode serve` listens on `127.0.0.1:4097`.
4. A small proxy listens on port `4096` (ingress). Home Assistant strips `/api/hassio_ingress/<token>` and sends it in `X-Ingress-Path`. The proxy puts that prefix back on asset, API, and WebSocket URLs so the page works in the sidebar.
5. The proxy signs the sidebar in to OpenCode. The UI does not ask for a server password.

## Sign-in

OpenCode 2 protects the web UI with its own server password. The documented sign-in is a one-time `/auth/connect/...` link from `opencode pair`, or the password printed as `server password` when `opencode serve` starts. That screen only appears after the app is running and the API answers `401 Authentication required`. There is no browser password popup.

Inside Home Assistant that link points at `127.0.0.1` in the container, so the browser cannot open it. The add-on stores a password in `/data/.server-password` and the proxy sends it as Basic auth (`opencode` / that password) on requests that do not already have an `Authorization` header. Anyone who can open the sidebar is already signed in to Home Assistant, and that is the access check.

`auto_approve` writes an OpenCode 2 permission rule that allows every action. `opencode serve` in 2.2.6 has no `--auto` flag (`--auto` exists on `opencode run`). If a newer binary adds `serve --auto`, the entrypoint passes it too.

## Options

| Option | Default | Meaning |
|---|---|---|
| `opencode_workspace` | `/config` | Directory OpenCode starts in |
| `opencode_model` | empty | `provider/model`, empty keeps the OpenCode default |
| `auto_approve` | `true` | Allow tool actions without a prompt |
| `migrate_v1_sessions` | `true` | Copy Terminal add-on sessions when that data exists |
| `opencode_system_prompt` | built-in | System prompt |
| `opencode_rules` | built-in | Written to `AGENTS.md` |
| `opencode_instructions` | empty | Extra instructions file |

Migration looks for the Terminal add-on data directory (`ha-opencode`, not `ha-opencode-serve`) under the Supervisor data path, usually `/mnt/data/supervisor/addons/data/ha-opencode`. It copies `opencode-local` (the SQLite database and `auth.json`), `opencode`, `opencode-workspace`, and `opencode-cache`. Files that already exist in this add-on are left alone. A marker `/data/.v1-session-migration.json` stops a second copy. Delete that file and restart to scan again. OpenCode 2 imports legacy rows when it opens the copied database.

Both add-ons write `/config/AGENTS.md` when they start. The one that started last owns that file. Session databases stay separate.

## Persistence

| Container path | Volume |
|---|---|
| `~/.local/share/opencode` | `/data/opencode-local` (database, credentials) |
| `~/.config/opencode` | `/data/opencode-config` |
| `~/.cache/opencode` | `/data/opencode-cache` |
| `~/.local/state/opencode` | `/data/opencode-state` |
| `~/.opencode` | `/data/opencode` |
| `$workspace/.opencode` | `/data/opencode-workspace` |

## Host access

`host_network` is off so ingress can use a fixed port. `host-shell`, `ha-host`, and `ssh-host` still enter the HA OS host with `nsenter` (`host_pid`). The Docker socket and the Supervisor API are mounted. Port 4096 is not published on the host; open the **OpenCode 2** sidebar entry.

This add-on is experimental. Auto-approve plus a host shell can change or break Home Assistant. Back up the system before letting it edit configuration.
