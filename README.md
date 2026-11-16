# kiloaded

Starts Kilo in the background and keeps it connected to Kilo Cloud, so you can start and steer Kilo jobs from your phone or any other Kilo surface. Why pay for cloud compute when you've got a spare system/VM free?

`kiloaded` installs the [Kilo CLI](https://kilo.ai/docs/cli) into your user account and runs `kilo serve` as a systemd user service. The service runs as you — same UID, groups, home directory, config, and file permissions — so it can use your existing Kilo login and work on the same trees. No root, no separate service account.

Remote control is on by default: after every service start (including reboots and crash restarts) the service registers itself with Kilo Cloud, and `install`/`update` run Kilo's device-code login when the host is not logged in yet. The login prints a URL and code you can open from any browser — your phone included. A `kiloaded-recover` timer also re-registers the server when the relay drops, so a brief network outage, a WAN failover (new public IP), or a relay that silently closed heals itself instead of leaving your phone unable to connect until the next restart. Pass `--no-remote` if you want a purely local server.

## Install

On Linux with systemd user services, Node.js, npm, and curl:

```sh
curl -fsSL https://raw.githubusercontent.com/tweedge/kiloaded/main/install.sh | sh
```

That puts the `kiloaded` command in `~/.local/bin`, installs the Kilo CLI under `~/.local/share/kiloaded`, adds a `kilo` launcher if you don't already have one, and enables the `kiloaded.service` user unit. By default the server listens on `http://127.0.0.1:4096`. If you are not logged in to Kilo yet, the installer starts the device-code login and waits for you to approve it (you can do that from your phone); with no terminal attached, install finishes without logging in and prints how to finish later. The installer also tries to enable login lingering so the service starts at boot; `--no-linger` leaves it tied to your login session instead.

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
kiloaded status        # install state, the URL, and the remote-control state
kiloaded logs -f       # follow the service journal
kiloaded login         # (re-)run the Kilo device-code login
kiloaded update        # install the latest Kilo CLI and restart the service
kiloaded remove        # stop and remove the service and CLI
```

`status` reports `remote: enabled (connected)` when the server is registered with Kilo Cloud, `enabled (not connected)` when the relay is on but cannot authenticate (usually meaning the host is not logged in), and `disabled` when remote control is off. When remote control is on it also reports `relay recovery: active`, which means the `kiloaded-recover.timer` is re-checking the relay every 15 seconds (set `KILOADED_RECOVER_SECONDS` at install/update time to change the interval).

Attach to the running server from another terminal:

```sh
kilo attach http://127.0.0.1:4096
```

`kiloaded install` takes `--version`, `--port`, `--hostname`, `--no-remote`, `--no-start`, and `--no-linger`. Set `KILOADED_RECOVER_SECONDS` (default 15) to change how often the relay-recovery timer runs. `kiloaded update` takes `--version`. `kiloaded remove --keep-cli` removes the service but leaves the downloaded CLI and `kilo` launcher in place. With `--no-start`, start the service later with `systemctl --user start kiloaded`.

## What it changes

- `~/.local/share/kiloaded/` — versioned Kilo CLI installs, the active `current` symlink, the generated launcher, and the remote-control and relay-recovery helpers.
- `~/.config/kiloaded/config` — the port, address, and remote-control switch used by the service.
- `~/.config/systemd/user/kiloaded.service` — the user unit, including an `ExecStartPost` that re-registers the server with Kilo Cloud after every start.
- `~/.config/systemd/user/kiloaded-recover.service` and `.timer` — a timer that re-registers the server with Kilo Cloud when the relay drops, so short outages and WAN failovers recover without a restart.
- `~/.local/bin/kiloaded` — the installed command; `~/.local/bin/kilo` — a CLI launcher, only if you did not already have one.

`kiloaded remove` leaves Kilo's own settings and authentication in `~/.config/kilo` and `~/.local/share/kilo` untouched. It also leaves login lingering enabled, since lingering is a per-user setting that other services may rely on. The installed `kiloaded` command stays in place so you can reinstall or inspect things; delete `~/.local/bin/kiloaded` yourself if you want it gone.

## Requirements and limits

Linux only, with systemd user services. Node.js and npm are needed for install and update; the running service uses the packaged native Kilo binary. curl is needed for remote control (the installer already requires it). The default address is loopback-only: the remote relay is an outbound connection the server dials itself, so no inbound ports are opened. If you bind to a non-loopback address, set `KILO_SERVER_PASSWORD` in a systemd drop-in (`systemctl --user edit kiloaded`) or put the service behind something that does authentication; the remote-control helper picks the drop-in credentials up automatically.

Remote control means any device signed in to the same Kilo account can start agents on this machine — that is the feature. `--no-remote` keeps the server local-only.

See [AGENTS.md](AGENTS.md) for the design, test commands, and operational notes.
