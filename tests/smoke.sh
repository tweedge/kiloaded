#!/bin/sh
# Real end-to-end smoke test: installs the actual Kilo CLI from npm, starts the
# real `kilo serve` through the generated wrapper, checks its health endpoint,
# updates across versions, and removes everything.
#
# This needs network access and downloads Kilo (hundreds of MB), so it is opt-in:
#
#   KILOADED_REAL=1 ./tests/smoke.sh
#
# Set KILOADED_SMOKE_FROM to choose the starting version (default 7.8.26).
set -eu

if [ "${KILOADED_REAL:-0}" != "1" ]; then
    printf 'smoke: skipped (set KILOADED_REAL=1 to run the real npm/service test)\n'
    exit 0
fi

unset KILOADED_SYSTEMCTL KILOADED_LOGINCTL KILOADED_JOURNALCTL
unset KILOADED_NPM KILOADED_NODE KILOADED_REF KILOADED_BIN_DIR
unset KILOADED_STABLE_SECONDS SUDO_USER

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FROM="${KILOADED_SMOKE_FROM:-7.8.26}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/kiloaded-smoke.XXXXXX") || exit 1
PORT="${KILOADED_SMOKE_PORT:-}"
SERVE_PID=""

say() { printf 'smoke: %s\n' "$*"; }
die() {
    printf 'smoke: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$SERVE_PID" ]; then
        kill "$SERVE_PID" 2>/dev/null || true
        wait "$SERVE_PID" 2>/dev/null || true
        SERVE_PID=""
    fi
    rm -rf "$TMP"
}
trap cleanup 0
trap 'cleanup; exit 1' 1 2 15

command -v npm >/dev/null 2>&1 || die "npm is required"
command -v node >/dev/null 2>&1 || die "node is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

if [ -z "$PORT" ]; then
    PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});' 2>/dev/null || true)
fi
case "$PORT" in
    '' | *[!0-9]*) die "could not choose a test port (set KILOADED_SMOKE_PORT)" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "KILOADED_SMOKE_PORT must be from 1 to 65535"
fi

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_DATA_HOME="$TMP/data"
export XDG_STATE_HOME="$TMP/state"
export XDG_CACHE_HOME="$TMP/cache"
export XDG_RUNTIME_DIR="$TMP/run"
export KILOADED_BIN_DIR="$TMP/user-bin"
export KILOADED_SYSTEMD_RUNTIME="$TMP/systemd-runtime"
export npm_config_cache="$TMP/npm-cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
    "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$KILOADED_SYSTEMD_RUNTIME" "$KILOADED_BIN_DIR"

# Use the test doubles only for the service manager calls; npm, node, and
# uname must stay real here.
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
ln -s "$ROOT/tests/fakes/systemctl" "$FAKE_BIN/systemctl"
ln -s "$ROOT/tests/fakes/loginctl" "$FAKE_BIN/loginctl"
ln -s "$ROOT/tests/fakes/journalctl" "$FAKE_BIN/journalctl"
export PATH="$FAKE_BIN:$PATH"
export FAKE_SYSTEMCTL_LOG="$TMP/systemctl.log"
export FAKE_LOGINCTL_LOG="$TMP/loginctl.log"
export FAKE_JOURNALCTL_LOG="$TMP/journalctl.log"
export FAKE_SYSTEMCTL_ACTIVE="1"
export FAKE_SYSTEMCTL_ENABLED="1"
: >"$FAKE_SYSTEMCTL_LOG"
: >"$FAKE_LOGINCTL_LOG"
: >"$FAKE_JOURNALCTL_LOG"

DATA="$XDG_DATA_HOME/kiloaded"
UNIT="$XDG_CONFIG_HOME/systemd/user/kiloaded.service"

say "installing Kilo CLI $FROM"
"$ROOT/kiloaded" install --version "$FROM" --port "$PORT" --no-linger --no-start
[ -L "$DATA/cli/current" ] || die "current CLI symlink was not created"
[ "$(readlink "$DATA/cli/current")" = "$FROM" ] || die "expected CLI $FROM"

start_and_check() {
    _expected="$1"
    say "starting the service wrapper on port $PORT"
    "$DATA/libexec/kilo" serve --print-logs --hostname 127.0.0.1 --port "$PORT" </dev/null >"$TMP/serve.log" 2>&1 &
    SERVE_PID=$!

    _tries=0
    while [ "$_tries" -lt 60 ]; do
        if curl -fsS "http://127.0.0.1:$PORT/global/health" >"$TMP/health.json" 2>/dev/null; then
            break
        fi
        sleep 0.5
        _tries=$((_tries + 1))
    done
    [ "$_tries" -lt 60 ] || {
        cat "$TMP/serve.log" >&2
        die "health endpoint never answered"
    }
    grep -Fq '"healthy":true' "$TMP/health.json" || die "health response was not healthy: $(cat "$TMP/health.json")"
    grep -Fq "\"version\":\"$_expected\"" "$TMP/health.json" || die "health version did not match $_expected: $(cat "$TMP/health.json")"

    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    SERVE_PID=""
}

start_and_check "$FROM"

say "updating to the latest Kilo CLI"
"$ROOT/kiloaded" update
NEW=$(readlink "$DATA/cli/current")
[ "$NEW" != "$FROM" ] || die "update did not move off $FROM"
[ -f "$DATA/cli/$NEW/node_modules/@kilocode/cli/package.json" ] || die "new version is missing"
[ ! -e "$DATA/cli/$FROM" ] || die "old version was not pruned"

start_and_check "$NEW"

say "removing the service and CLI"
"$ROOT/kiloaded" remove
[ ! -e "$UNIT" ] || die "unit file was not removed"
[ ! -e "$DATA" ] || die "data directory was not removed"
[ ! -e "$KILOADED_BIN_DIR/kilo" ] || die "kilo launcher was not removed"

say "ok: install, serve, update, serve, remove"
