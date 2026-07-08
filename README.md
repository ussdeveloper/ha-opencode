# ha-opencode – OpenCode Terminal for Home Assistant

[![Stage](https://img.shields.io/badge/stage-experimental-orange)](https://github.com/ussdeveloper/ha-opencode)
[![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20aarch64%20%7C%20armv7%20%7C%20armhf-blue)](https://github.com/ussdeveloper/ha-opencode)

**Terminal webowy z pełnymi narzędziami deweloperskimi i OpenCode AI**, dostępny jako add-on Home Assistant w panelu bocznym.

## Co to robi?

- Uruchamia **web terminal** (ttyd) dostępny przez panel boczny Home Assistant
- Zawiera **pełen zestaw narzędzi**: bash, git, python3, nodejs, docker-cli, vim, tmux, jq, htop, ripgrep, fd i więcej
- Automatycznie startuje **OpenCode AI** (`opencode --continue`) w sesji tmux przy starcie add-onu
- Daje **bezpośredni dostęp** do:
  - `/config` – konfiguracja Home Assistant (rw)
  - `/var/run/docker.sock` – zarządzanie kontenerami add-onów
  - Supervisor API – restart, logi, check konfiguracji
  - `/share`, `/backup`, `/media`, `/ssl`, `/addons`

## Instalacja

### Jako repozytorium add-onów

1. W Home Assistant przejdź do **Ustawienia → Dodatki → Sklep z dodatkami**
2. Kliknij ⋮ → **Repozytoria**
3. Dodaj URL: `https://github.com/ussdeveloper/ha-opencode`
4. Odśwież listę, znajdź **OpenCode Terminal** i kliknij **Instaluj**

### Konfiguracja

```yaml
terminal_password: ""        # Hasło do terminala (opcjonalne, basic auth)
opencode_auto_start: true    # Automatyczny start OpenCode
opencode_workspace: "/config" # Katalog roboczy OpenCode
opencode_model: ""           # Model AI (pusty = domyślny)
```

## Użycie

Po zainstalowaniu add-on pojawi się jako **OpenCode** w panelu bocznym Home Assistant.

### Terminal webowy
Kliknij panel **OpenCode** – otworzy się terminal bash z dostępem do całego systemu.

### OpenCode AI
OpenCode startuje automatycznie w sesji tmux. Aby się podłączyć:
```bash
opencode-attach
# lub ręcznie:
tmux attach -t opencode
```

### Przydatne komendy
```bash
ha-cli check          # Sprawdź configuration.yaml
ha-cli restart        # Restart Home Assistant
ha-cli logs           # Logi Home Assistant
ha-cli backup         # Backup /config do /backup
ha-cli docker-ps      # Lista kontenerów add-onów
ha-cli exec <name>    # Wejdź do kontenera add-onu
backup-config         # Backup configuration.yaml przed edycją
```

## Wymagania

- Home Assistant OS / Supervised (z Supervisor)
- Dowolna architektura: `amd64`, `aarch64`, `armv7`, `armhf`

## Bezpieczeństwo

- Terminal jest dostępny przez panel boczny HA (ingress) – to samo uwierzytelnienie co HA
- Opcjonalne dodatkowe hasło basic auth na terminal
- Dostęp do dockera tylko z poziomu kontenera add-onu
- Skrypt `backup-config` automatycznie tworzy kopię przed edycją plików

## Narzędzia w kontenerze

| Kategoria | Narzędzia |
|---|---|
| Shell | bash, bash-completion, tmux |
| Edytory | vim, neovim |
| Git | git, git-lfs |
| Python | python3, pip3, homeassistant-cli, pyyaml |
| Node.js | nodejs, npm |
| Docker | docker-cli, docker-compose |
| Narzędzia | jq, yq, curl, wget, htop, btop, ncdu, ripgrep, fd, tree |
| Kompresja | unzip, zip, tar |
| AI | opencode-ai (global install) |

## Licencja

MIT
