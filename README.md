# kiloaded

Starts Kilo in the background. Why pay for cloud when you've got a spare system/VM free?

`kiloaded` installs the [Kilo CLI](https://kilo.ai/docs/cli) into your user account and runs `kilo serve` as a systemd user service. The service runs as you — same UID, groups, home directory, config, and file permissions — so it can use your existing Kilo login and work on the same trees. No root, no separate service account.

## Install

On Linux with systemd user services, Node.js, npm, and curl:

```sh
curl -fsSL https://raw.githubusercontent.com/tweedge/kiloaded/main/install.sh | sh
```

That puts the `kiloaded` command in `~/.local/bin`, installs the Kilo CLI under `~/.local/share/kiloaded`, adds a `kilo` launcher if you don't already have one, and enables the `kiloaded.service` user unit. By default the server listens on `http://127.0.0.1:4096`. The installer also tries to enable login lingering so the service starts at boot; `--no-linger` leaves it tied to your login session instead.

If `~/.local/bin` is not on your `PATH`, add it first or pass `KILOADED_BIN_DIR`:

```sh
curl -fsSL https://raw.githubusercontent.com/tweedge/kiloaded/main/install.sh | KILOADED_BIN_DIR="$HOME/bin" sh
```

To choose a version, port, or address, pass install options after `sh -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/tweedge/kiloaded/main/install.sh | sh -s -- --port 4096
```

From a checkout, run `./kiloaded install`. `./install.sh` always downloads the published wrapper and then runs it, so use it when you want to refresh the installed command.

## Use

```sh
kiloaded status        # what is installed, whether it is running, and the URL
kiloaded logs -f       # follow the service journal
kiloaded update        # install the latest Kilo CLI and restart the service
kiloaded remove        # stop and remove the service and CLI
```

Attach to the running server from another terminal:

```sh
kilo attach http://127.0.0.1:4096
```

`kiloaded install` takes `--version`, `--port`, `--hostname`, `--no-start`, and `--no-linger`. `kiloaded update` takes `--version`. `kiloaded remove --keep-cli` removes the service but leaves the downloaded CLI and `kilo` launcher in place. With `--no-start`, start the service later with `systemctl --user start kiloaded`.

## What it changes

- `~/.local/share/kiloaded/` — versioned Kilo CLI installs, the active `current` symlink, and the generated launcher.
- `~/.config/kiloaded/config` — the port and address used by the service.
- `~/.config/systemd/user/kiloaded.service` — the user unit.
- `~/.local/bin/kiloaded` — the installed command; `~/.local/bin/kilo` — a CLI launcher, only if you did not already have one.

`kiloaded remove` leaves Kilo's own settings and authentication in `~/.config/kilo` and `~/.local/share/kilo` untouched. It also leaves login lingering enabled, since lingering is a per-user setting that other services may rely on. The installed `kiloaded` command stays in place so you can reinstall or inspect things; delete `~/.local/bin/kiloaded` yourself if you want it gone.

## Requirements and limits

Linux only, with systemd user services. Node.js and npm are needed for install and update; the running service uses the packaged native Kilo binary. The default address is loopback-only. If you bind to a non-loopback address, set `KILO_SERVER_PASSWORD` in a systemd drop-in (`systemctl --user edit kiloaded`) or put the service behind something that does authentication.

See [AGENTS.md](AGENTS.md) for the design, test commands, and operational notes.
