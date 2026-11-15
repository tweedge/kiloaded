# AGENTS.md — conventions and institutional knowledge for kiloaded

Read this before changing code, docs, or the service unit. The README documents the shipped behavior; this file documents the design decisions and the things that will bite you if you rediscover them the hard way.

## Documentation style: soft wrap, never hard wrap

All prose in markdown files (README.md, AGENTS.md) uses **soft wrapping**: one paragraph = one line, however long. Do not reflow paragraphs to 80 columns. Tables and code blocks wrap naturally; paragraphs do not. This follows the convention in the other repos.

## What this repository is

`kiloaded` is a small Linux-only wrapper that installs the Kilo CLI from its official npm package and runs `kilo serve` as a systemd **user** service. It is deliberately a one-script manager, not a package manager and not a system service installer. The inspiration is the systemd-managed `kilo console` feature request in Kilo-Org/kilocode#11865, updated for the current CLI: `kilo console` is deprecated, so the background service runs the headless `kilo serve` command instead.

Non-goals: macOS, Windows, non-systemd init systems, system-wide `/etc/systemd/system` units, dedicated service accounts, Docker, and managing Kilo's authentication or settings. If someone asks for one of those, that is a different tool.

## Repository layout

- `kiloaded` — the entire manager: argument parsing, npm install, versioned CLI store, config, unit rendering, lifecycle commands, status, and logs. It must stay a single POSIX `sh` file so `install.sh` can download and run it without a support library.
- `install.sh` — the curl entrypoint. It downloads `kiloaded` into `~/.local/bin` (or `KILOADED_BIN_DIR`) and then runs `kiloaded install` with the caller's arguments.
- `tests/run.sh` — hermetic end-to-end tests with fake `npm`, `systemctl`, `loginctl`, `journalctl`, `node`, and `uname`. No network, no real systemd, no multi-hundred-MB download.
- `tests/fakes/` — those test doubles. Keep them strict enough that a regression in the manager fails a test, but do not let them grow into a second implementation.
- `tests/smoke.sh` — the opt-in real test: real npm, real Kilo binary, real `kilo serve` health check, update across versions, remove.
- `.github/workflows/ci.yml` — syntax, shellcheck, hermetic tests, and a real smoke job on pushes/workflow dispatch.
- `README.md` — user-facing install and command reference, kept high level.
- `AGENTS.md` — this file.

Do not add a `lib/` split, a Makefile, or a build step without a strong reason. The installer's whole value is that it is one readable shell file.

## Design invariants

### Per-user, not per-system

The service is a systemd **user** unit. It deliberately has no `User=` or `Group=`: the user manager launches it with the installing user's UID, supplementary groups, `HOME`, and file permissions. That is what “inheriting the user's permission” means here, and it is why the service can use the user's existing Kilo auth and reach the same project directories. Do not add `User=`, do not install to `/etc/systemd/system`, and do not create a service account.

`check_user` refuses a `SUDO_USER` install because `sudo kiloaded install` would create the unit for root while the operator thinks they installed it for themselves. Direct root installs are allowed but warn loudly; tests run as root in some containers, so the refusal must stay narrow to the `SUDO_USER` case.

Lingering is enabled best-effort with `loginctl enable-linger` so a user service survives logout and starts at boot. Failure is a warning, not an install failure: polkit may deny it, and a service that starts at login is still useful. `remove` never disables lingering because lingering is a per-user setting shared with every other user service; disabling it would be a surprising side effect.

### XDG layout

The manager honors `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME`; it rejects relative values because the systemd unit needs absolute paths. The runtime layout is:

- `$XDG_DATA_HOME/kiloaded/cli/<version>/` — one npm install per Kilo version.
- `$XDG_DATA_HOME/kiloaded/cli/current` — a relative symlink to the active version.
- `$XDG_DATA_HOME/kiloaded/libexec/kilo` — the stable, generated launcher used by the unit and by `~/.local/bin/kilo`.
- `$XDG_CONFIG_HOME/kiloaded/config` — the saved port and hostname.
- `$XDG_CONFIG_HOME/systemd/user/kiloaded.service` — the unit.

Kilo's own settings and credentials live under `~/.config/kilo` and `~/.local/share/kilo` (or the corresponding XDG overrides). Never write there during install, update, or remove. `remove` preserves those directories on purpose. The manager's own config file is plain `KEY=value` text parsed line-by-line, never sourced; malformed values are ignored with a warning so `install` can rewrite a clean config instead of dying on a hand-mangled file.

### CLI isolation and atomic update

The CLI is installed with `npm install --prefix <temp> @kilocode/cli@<spec>`, never with `npm install -g`. A global install would collide with the user's package manager and with an existing `kilo` command. The temp directory is created under the CLI store so the final move is on the same filesystem.

The install flow is: npm into a temp directory, read the real version from the package's `package.json`, verify the temp binary with `--version`, move the temp directory into `cli/<version>`, verify the final path, then atomically swap the `current` symlink (`ln -s` to a temporary name and `mv -Tf`). Every reuse path (current, exact cached version, or a cached version found after npm) also runs `verify_exec`; a broken current or cached directory is replaced instead of being reported as installed. If verification fails and the version directory was newly created, remove it and leave the old `current` untouched. `update` adds a service-level rollback: if the new version fails to start, relink the old version, rewrite the launcher, restart, and report the rollback.

`update` prunes every non-current version only after the new service is active. That keeps one known-good version available until the restart actually succeeds. `wait_active` requires the unit to stay active for a short stability window (default 3 seconds) after the first `is-active`, so a binary that crashes just after `exec` does not count as a successful update and cannot trigger the prune. On a failed update the new version directory remains for debugging; do not prune in the failure path.

### Stable wrapper, not a versioned ExecStart

The unit's `ExecStart` points at `libexec/kilo`, not at `cli/current/...` and not at a versioned path. The wrapper resolves the active version through the `current` symlink, so an update doesn't require rewriting the unit or running `daemon-reload` just to change the binary. The unit stays stable across CLI updates; the wrapper is regenerated when the native-vs-node execution mode changes.

The wrapper prefers the packaged native binary at `node_modules/@kilocode/cli/bin/.kilo`. That binary is what avoids `node: not found` under systemd. When it exists, the wrapper also sets `KILO_TREE_SITTER_WASM_DIR` to the co-located `bin/tree-sitter` directory if the user hasn't already set it; that mirrors the npm package's JS launcher and keeps tree-sitter working when the native binary is executed directly. If `.kilo` is missing (for example, an npm postinstall was blocked), fall back to the absolute node path plus the package's `bin/kilo` JS launcher. The node path is captured at install/update time so the unit does not depend on systemd's `PATH`.

Do not put `KILO_TREE_SITTER_WASM_DIR` in the unit: the wrapper is the single place that knows whether the native or node path is active. Do not point `~/.local/bin/kilo` directly at `.kilo`; the wrapper is what supplies the tree-sitter environment.

### Unit rendering

`render_unit` is deterministic and must stay that way. The unit has a `Generated by kiloaded` marker, `Type=simple`, absolute paths, `WorkingDirectory` set to `$HOME`, `Restart=on-failure`, `RestartSec=5`, `TimeoutStopSec=20`, `KillMode=mixed`, and `WantedBy=default.target`. `ExecStart` passes `--print-logs` so `kiloaded logs` shows the server's own log lines, not just the startup warning. The unit snapshots `HOME`, `PATH`, `SHELL`, `LANG`, `LC_ALL`, and the XDG directory variables from the install environment because a user manager does not inherit an interactive shell's environment. That snapshot is also why updating the install (or reinstalling) is the way to refresh a stale `PATH`.

Do not add `After=network-online.target` or `Wants=network-online.target` to a user unit. Those are system-manager targets; a user manager does not have them, and the dependency is noise at best. `kilo serve` can start offline and reconnect later.

`install`, `update`, and `remove` refuse to touch a `kiloaded.service` that lacks the `Generated by kiloaded` marker. Do not remove that check: it is what keeps the manager from clobbering an unrelated unit with the same name. Add the marker to any future unit template.

All systemd argument values in `ExecStart` go through `systemd_quote`, which escapes backslashes, double quotes, `%` specifiers, and `$` expansion; `Environment` values use `systemd_env_quote`, which does the same except for `$` because environment values are not variable-expanded. `WorkingDirectory` is written unquoted: systemd treats quotes there as literal characters, and the whole value after `=` is the path, spaces included; `%` is doubled with `systemd_path` so a literal percent survives. Keep absolute paths. The unit comments explain the user-unit permission model; do not remove them casually, because they are the answer to “why is there no User=?”.

### `kilo serve`, not `kilo console`

The issue that inspired this repo asked for `kilo console install/uninstall/...`, but the current CLI marks `kilo console` as deprecated. The service therefore runs `kilo serve --hostname <host> --port <port>`, the headless server that `kilo attach` talks to. The default is `127.0.0.1:4096`, matching the CLI documentation's attach examples. `kilo serve --port 0` picks a random port, which is wrong for a managed service; always pin a port.

### Port, address, and authentication

The default binding is loopback-only. `kilo serve` prints a warning when `KILO_SERVER_PASSWORD` is unset; that is acceptable on loopback. If the user passes a non-loopback `--hostname`, surface the warning and document that they need to set `KILO_SERVER_PASSWORD` in a `systemctl --user edit kiloaded` drop-in or put the service behind an authenticating proxy. Do not bake a password or any other secret into the unit file: the unit is mode 0644 and may be world-readable.

Additional environment variables (for example `KILO_SERVER_PASSWORD`, `SSH_AUTH_SOCK`, or a proxy setting) belong in a systemd drop-in, not in the manager's config, because a drop-in is the standard systemd mechanism and keeps secrets out of generated files that are rewritten on every update. The manager intentionally does not write an `EnvironmentFile`; an absolute, quoted `Environment=` snapshot is simpler and avoids the `EnvironmentFile` path-quoting edge cases.

### Removal semantics

`remove` is best-effort with systemctl so it still cleans up files if the user manager is no longer reachable. It stops and disables the unit, removes the unit file, reloads systemd, removes the manager's data and config, and removes `~/.local/bin/kilo` only when that path is a symlink into the manager's data directory. It never overwrites a pre-existing regular `kilo` binary, and it never touches `~/.config/kilo` or `~/.local/share/kilo`. `--keep-cli` skips the CLI/data removal but still removes the service and config.

The `kiloaded` command itself is installed by `install.sh`, not by the manager's own install path. `remove` leaves that command in place so the user can reinstall or run commands after; README says so. If that changes, update the docs and add a test that checks the wrapper is not deleted while running.

## Testing conventions

### Hermetic suite

`./tests/run.sh` is the default test command. It must stay fast, offline, and systemd-free. Every test starts from a fresh `HOME` and XDG tree under a temp directory, puts `tests/fakes` first on `PATH`, and uses `KILOADED_SYSTEMD_RUNTIME` to point the systemd check at a temp directory. The fake npm creates the exact `node_modules/@kilocode/cli` layout, including `bin/.kilo`, `bin/tree-sitter`, and a runnable `--version`; the fake systemctl records calls and can fail a selected call or fail a call once for rollback tests.

The suite covers fresh install, idempotent install, pinned versions, update, update rollback, update-before-install, remove, `--keep-cli`, non-Linux rejection, missing systemd rejection, invalid flags (including overlong ports), npm failure, systemctl failure, linger success/failure, status, logs, HOME/XDG paths with spaces, a pre-existing `kilo` launcher, `--no-start`, and pinned update. It also covers install verification failure, repair of a broken current install, corrupt-config recovery, crash-after-start detection, best-effort removal, foreign-unit protection, IPv6 URL formatting, the `install.sh` bootstrap (including HOME unset with `KILOADED_BIN_DIR`), and `systemd-analyze verify` when that tool is available. When adding a lifecycle feature, add a test that asserts both the resulting files and the systemctl call order. When adding a failure mode, assert that the previous install is still usable and that no partial unit/current link is left behind.

`KEEP_TEST_DIR=1 ./tests/run.sh` keeps the temp trees and prints their path; the failure output dumps the manager's stdout/stderr and the fake command logs.

### Test hooks

These environment variables exist for tests and unusual installations. Do not remove them without updating the tests:

- `KILOADED_SYSTEMD_RUNTIME` — replaces the `/run/systemd/system` existence check.
- `KILOADED_SYSTEMCTL`, `KILOADED_LOGINCTL`, `KILOADED_JOURNALCTL` — absolute command paths.
- `KILOADED_NPM`, `KILOADED_NODE` — absolute npm/node paths.
- `KILOADED_BIN_DIR` — where `install.sh` and the `kilo` launcher live.
- `KILOADED_STABLE_SECONDS` — post-start active-stability window (default 3; tests use 0).
- `KILOADED_REF` — install.sh's raw GitHub ref, for testing a tag or branch.
- `KILOADED_REAL`, `KILOADED_SMOKE_FROM`, `KILOADED_SMOKE_PORT` — smoke-test controls.

### Real smoke test

`KILOADED_REAL=1 ./tests/smoke.sh` is the only test allowed to touch the network. It installs a real previous version (default 7.8.26), starts the generated wrapper as `kilo serve`, waits for `/global/health`, checks the version, runs a real update to latest, starts the new wrapper, checks again, and removes everything. It takes roughly a minute and downloads a few hundred MB; that is why it is opt-in and a separate CI job. The health endpoint is `/global/health` and returns JSON such as `{"healthy":true,"version":"7.8.27"}`; `/health` is a 404 and must not be used.

The smoke test uses fake systemctl/loginctl/journalctl because CI has no systemd user manager, but real npm/node/curl. Do not add more fakes to the smoke path; its value is exercising the real CLI package and binary.

### Syntax and lint

Every shell change must pass:

```sh
for f in kiloaded install.sh tests/run.sh tests/smoke.sh tests/fakes/*; do
    dash -n "$f"
    bash -n "$f"
done
shellcheck -s sh kiloaded install.sh tests/run.sh tests/smoke.sh tests/fakes/*
./tests/run.sh
```

Shellcheck is enforced in CI. The only intentional suppression is `SC2016` for the literal `${KILO_TREE_SITTER_WASM_DIR:-}` text in the generated wrapper. The `rm -rf "${CLI_ROOT:?}/..."` is a safety guard, not a suppression. Do not add blanket disables.

### CI

`.github/workflows/ci.yml` runs the syntax checks, shellcheck, and hermetic suite on every push and pull request. The real smoke job runs on pushes and `workflow_dispatch` (not pull requests) because it needs network and downloads the CLI. Actions are pinned to full commit SHAs, following the other repos; bump the SHA when updating.

## Operational notes and gotchas

- **The npm package is large.** `@kilocode/cli` downloads a native binary of a few hundred MB. npm caches it, but a cold install takes time and disk. Do not add a progress bar; keep npm's own output. If someone wants a curl-only installer, that is a separate tool and needs release-asset verification.
- **npm postinstall can be blocked.** Some npm configurations skip lifecycle scripts. The optional platform package still contains `bin/kilo`, and the JS launcher can find it, so the node fallback is intentional. The hermetic fake creates `.kilo` directly to exercise the native path.
- **Node is only needed for install/update and the fallback.** The normal service runs the native `.kilo` binary. Do not add a runtime node requirement to the service, and do not assume the systemd user manager's `PATH` contains node.
- **The user manager needs a bus.** `systemctl --user` fails in a bare SSH session without `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` or a running user manager. `require_systemd` checks `systemctl --user show-environment` and reports this instead of writing a unit that can never start. Lingering makes the manager available at boot.
- **PATH is snapshotted at install time.** If the user's node/npm/tool path changes, re-run `kiloaded install` (or `update`) to regenerate the unit. Do not try to source `.profile` from the unit.
- **Secrets belong in a drop-in.** Use `systemctl --user edit kiloaded` to add `Environment=KILO_SERVER_PASSWORD=...` or `Environment=SSH_AUTH_SOCK=...`. The generated unit and config are mode 0644/0600 but still should not contain secrets.
- **`kilo serve` is unsecured on loopback.** The warning is expected. Non-loopback binds need a password or an authenticating proxy.
- **Port 4096 is the default for a reason.** It is the URL used in the CLI docs' attach examples. Changing it is a user option, not a release decision.
- **The health endpoint is `/global/health`.** `/` is empty, `/health` is 404, `/doc` is the OpenAPI document.
- **`systemctl --user daemon-reload` is required after writing the unit**, and `restart` is what picks up a new wrapper. `enable` alone does not restart an already-running service.
- **Lingering is per-user.** Never disable it on remove; another service may depend on it.
- **Root is a warning, not a supported target.** The service runs as root if installed by root. That is sometimes useful in a container but is not the intended deployment; do not add root-specific behavior.
- **The manager is Linux-only.** `mv -T`, `readlink`, `stat -c`, `loginctl`, and systemd user units are deliberate Linux dependencies. Don't “port” it by adding macOS branches; a macOS tool would need launchd and a different unit model.
- **install.sh trusts the repository.** It downloads the wrapper from `raw.githubusercontent.com` and executes it. There is no signature or checksum yet. Pinning `KILOADED_REF` to a tag is the current mitigation; if a checksum/release-asset flow is added, document it in README and AGENTS and test it.
- **The generated unit is intentionally not an EnvironmentFile.** Absolute quoted `Environment=` lines make the wrapper path and PATH snapshot explicit. Adding `EnvironmentFile=` reintroduces path quoting and optional-file edge cases for little benefit.
- **`kilo console` is deprecated.** Do not switch the service back to it. If Kilo removes `kilo serve` or changes its flags, update `render_unit`, the smoke test, and the README together.

## Release and change process

- Bump `KILOADED_VERSION` in `kiloaded` for user-visible manager changes, and mention it in the commit/PR. The version command prints it.
- `install.sh` fetches `KILOADED_REF` (default `main`). Re-running the installer refreshes the `kiloaded` command itself; `kiloaded update` only updates the Kilo CLI. Keep that distinction in README.
- If the Kilo CLI changes its npm package layout, update `resolve_exec_root`, the fake npm layout, the smoke test's version expectations, and this file together. The current layout is `node_modules/@kilocode/cli/bin/{kilo,.kilo,tree-sitter}` plus optional `@kilocode/cli-<platform>-<arch>` packages.
- If the unit changes, regenerate it in a temp HOME and, when available, run `systemd-analyze verify` on the result. CI does not have a running systemd, so the hermetic tests assert the rendered text and the smoke test exercises the wrapper, not the unit parser.
- Keep README high level. Put failure modes, test hooks, and design rationale here, not there.

## Process notes from building this

- **The dev container does not run systemd.** It has no `/run/systemd/system` and no running user manager, so the hermetic suite uses a temp runtime directory and fake commands. That is not a reason to weaken the production check; it is why `KILOADED_SYSTEMD_RUNTIME` exists.
- **The issue's `process.execPath` approach is still the right fallback.** Kilo ships a native binary now, so the normal path is `.kilo` and the unit avoids node entirely. The node path stays for package layouts or postinstall failures where `.kilo` is missing.
- **The package's JS launcher sets a tree-sitter env var.** Running `.kilo` directly without `KILO_TREE_SITTER_WASM_DIR` can break parsing, so the generated wrapper mirrors that behavior. This was a deliberate difference from “just point ExecStart at the binary”.
- **Do not rely on `kilo serve`'s default port.** The default is `0`, which means random. A managed service needs a stable attach URL.
- **The real smoke test was run against 7.8.26 -> 7.8.27.** It installed both real packages, served both binaries, checked `/global/health`, and removed everything. Keep that path working when bumping versions.
- **Test failures should show the manager's stdout/stderr and the relevant logs.** The harness dumps both on assertion failure; use that instead of adding ad-hoc debug prints to `kiloaded`.
