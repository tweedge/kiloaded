#!/bin/sh
# Hermetic test suite for kiloaded. No systemd, no npm downloads, no network.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FAKES="$ROOT/tests/fakes"
BASE_PATH="$PATH"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kiloaded-tests.XXXXXX") || exit 1
PASS=0
FAIL=0

cleanup() {
    if [ "${KEEP_TEST_DIR:-0}" = "1" ]; then
        printf 'tests kept in %s\n' "$TEST_ROOT"
        return
    fi
    rm -rf "$TEST_ROOT"
}
trap cleanup 0
trap 'cleanup; exit 1' 1 2 15

setup() {
    CASE=$(mktemp -d "$TEST_ROOT/case.XXXXXX")

    export HOME="$CASE/home"
    export XDG_CONFIG_HOME="$CASE/config"
    export XDG_DATA_HOME="$CASE/data"
    export XDG_STATE_HOME="$CASE/state"
    export XDG_CACHE_HOME="$CASE/cache"
    export XDG_RUNTIME_DIR="$CASE/run"
    export KILOADED_SYSTEMD_RUNTIME="$CASE/systemd-runtime"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
        "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$KILOADED_SYSTEMD_RUNTIME"

    unset KILOADED_SYSTEMCTL KILOADED_LOGINCTL KILOADED_JOURNALCTL
    unset KILOADED_NPM KILOADED_NODE KILOADED_BIN_DIR
    unset KILOADED_REF KILOADED_TEST_SOURCE SUDO_USER
    unset KILOADED_STABLE_SECONDS
    export KILOADED_STABLE_SECONDS="0"
    unset KILOADED_CURL KILOADED_REMOTE_TRIES KILOADED_REMOTE_INTERVAL
    unset KILOADED_RECOVER_SECONDS KILOADED_RECOVER_GRACE
    unset KILOADED_TTY FAKE_KILO_LOGGED_OUT FAKE_KILO_LOGIN_FAIL
    unset FAKE_CURL_LOG FAKE_CURL_BODY_FILE FAKE_CURL_RC
    unset FAKE_CURL_STATUS_FILE FAKE_CURL_STATUS_RC
    # A developer shell running inside the Kilo VS Code extension exports these;
    # they would leak into the rendered launcher and break the tree-sitter assert.
    unset KILO_TREE_SITTER_WASM_DIR KILOCODE_FEATURE

    export PATH="$FAKES:$BASE_PATH"
    export FAKE_UNAME="Linux"
    export FAKE_NPM_VERSION="7.8.27"
    export FAKE_NPM_LOG="$CASE/npm.log"
    export FAKE_SYSTEMCTL_LOG="$CASE/systemctl.log"
    export FAKE_LOGINCTL_LOG="$CASE/loginctl.log"
    export FAKE_JOURNALCTL_LOG="$CASE/journalctl.log"
    export FAKE_KILO_LOG="$CASE/kilo.log"
    export FAKE_JOURNAL_OUTPUT="fake journal output"
    export FAKE_SYSTEMCTL_ACTIVE="1"
    export FAKE_SYSTEMCTL_ACTIVE_ONCE="0"
    export FAKE_SYSTEMCTL_ACTIVE_ONCE_MARK="$CASE/systemctl.active-once"
    export FAKE_SYSTEMCTL_ENABLED="1"
    export FAKE_LOGINCTL_FAIL="0"
    export FAKE_LINGER="yes"
    export FAKE_SYSTEMCTL_FAIL=""
    export FAKE_SYSTEMCTL_FAIL_ONCE=""
    export FAKE_SYSTEMCTL_ONCE_MARK="$CASE/systemctl.once"
    export FAKE_NPM_FAIL="0"
    unset FAKE_NPM_BAD_BINARY
    : >"$FAKE_NPM_LOG"
    : >"$FAKE_SYSTEMCTL_LOG"
    : >"$FAKE_LOGINCTL_LOG"
    : >"$FAKE_JOURNALCTL_LOG"
    : >"$FAKE_KILO_LOG"
}

# Stdin is always /dev/null so TTY detection inside kiloaded is hermetic;
# tests that need the interactive login path set KILOADED_TTY explicitly.
run_k() {
    set +e
    "$ROOT/kiloaded" "$@" </dev/null >"$CASE/out" 2>"$CASE/err"
    STATUS=$?
    set -e
}

run_install_sh() {
    set +e
    "$ROOT/install.sh" "$@" </dev/null >"$CASE/out" 2>"$CASE/err"
    STATUS=$?
    set -e
}

# A stand-in curl for kiloaded's own remote-control calls. It records its
# arguments, optionally prints a canned body, and fails on demand.
make_test_curl_fake() {
    mkdir -p "$CASE/rcurl-bin"
    cat >"$CASE/rcurl-bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${FAKE_CURL_LOG:-/dev/null}"
case " $* " in
    *"/remote/status"*)
        if [ -n "${FAKE_CURL_STATUS_FILE:-}" ]; then
            cat "$FAKE_CURL_STATUS_FILE" 2>/dev/null || true
        fi
        exit "${FAKE_CURL_STATUS_RC:-0}"
        ;;
esac
if [ -n "${FAKE_CURL_BODY_FILE:-}" ]; then
    cat "$FAKE_CURL_BODY_FILE" 2>/dev/null || true
fi
exit "${FAKE_CURL_RC:-0}"
EOF
    chmod 755 "$CASE/rcurl-bin/curl"
    export KILOADED_CURL="$CASE/rcurl-bin/curl"
    export FAKE_CURL_LOG="$CASE/curl.log"
    : >"$FAKE_CURL_LOG"
}

make_curl_fake() {
    mkdir -p "$CASE/curl-bin"
    cat >"$CASE/curl-bin/curl" <<'EOF'
#!/bin/sh
dest=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o)
            dest="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[ -n "$dest" ] || exit 1
cp "${KILOADED_TEST_SOURCE:?}" "$dest"
EOF
    chmod 755 "$CASE/curl-bin/curl"
    export KILOADED_TEST_SOURCE="$ROOT/kiloaded"
    export PATH="$CASE/curl-bin:$PATH"
}

dump() {
    printf '%s\n' '--- stdout ---'
    cat "$CASE/out" 2>/dev/null || true
    printf '%s\n' '--- stderr ---'
    cat "$CASE/err" 2>/dev/null || true
    for _log in "$CASE/npm.log" "$CASE/systemctl.log" "$CASE/loginctl.log" "$CASE/journalctl.log" "$CASE/kilo.log"; do
        if [ -s "$_log" ]; then
            printf '%s %s %s\n' '---' "${_log##*/}" '---'
            cat "$_log"
        fi
    done
}

assert_status() {
    if [ "$STATUS" -ne "$1" ]; then
        printf 'expected exit %s, got %s\n' "$1" "$STATUS"
        dump
        return 1
    fi
}

assert_ok() {
    assert_status 0
}

assert_fail() {
    if [ "$STATUS" -eq 0 ]; then
        printf 'expected a non-zero exit, got success\n'
        dump
        return 1
    fi
}

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'expected <%s>, got <%s>\n' "$2" "$1"
        dump
        return 1
    fi
}

assert_exists() {
    if [ ! -e "$1" ]; then
        printf 'expected %s to exist\n' "$1"
        dump
        return 1
    fi
}

assert_not_exists() {
    if [ -e "$1" ]; then
        printf 'expected %s not to exist\n' "$1"
        dump
        return 1
    fi
}

assert_symlink() {
    if [ ! -L "$1" ]; then
        printf 'expected %s to be a symlink\n' "$1"
        dump
        return 1
    fi
    _actual=$(readlink "$1")
    if [ "$_actual" != "$2" ]; then
        printf 'expected %s -> <%s>, got <%s>\n' "$1" "$2" "$_actual"
        dump
        return 1
    fi
}

assert_file_mode() {
    _mode=$(stat -c '%a' "$1" 2>/dev/null || true)
    if [ "$_mode" != "$2" ]; then
        printf 'expected %s mode %s, got <%s>\n' "$1" "$2" "$_mode"
        dump
        return 1
    fi
}

assert_contains() {
    if ! grep -Fq -- "$2" "$1" 2>/dev/null; then
        printf 'expected %s to contain <%s>\n' "$1" "$2"
        if [ -f "$1" ]; then
            cat "$1"
        fi
        dump
        return 1
    fi
}

assert_not_contains() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        printf 'expected %s not to contain <%s>\n' "$1" "$2"
        dump
        return 1
    fi
}

assert_line_absent() {
    if grep -Eq -- "$2" "$1" 2>/dev/null; then
        printf 'expected %s to have no line matching <%s>\n' "$1" "$2"
        dump
        return 1
    fi
}

assert_out() {
    assert_contains "$CASE/out" "$1"
}

assert_err() {
    assert_contains "$CASE/err" "$1"
}

assert_log_absent() {
    if [ -s "$1" ]; then
        printf 'expected %s to be empty; it contains:\n' "$1"
        cat "$1"
        dump
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_help_and_version() {
    setup
    run_k help
    assert_ok
    assert_out "Usage: kiloaded"

    run_k version
    assert_ok
    assert_out "kiloaded 0.2.0"

    run_k unknown-command
    assert_status 2
    assert_err "unknown command"
}

test_install_fresh() {
    setup
    run_k install --port 5123 --no-linger
    assert_ok

    DATA="$XDG_DATA_HOME/kiloaded"
    UNIT="$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    CONFIG="$XDG_CONFIG_HOME/kiloaded/config"

    assert_symlink "$DATA/cli/current" "7.8.27"
    assert_exists "$DATA/libexec/kilo"
    assert_file_mode "$DATA/libexec/kilo" 700
    assert_exists "$UNIT"
    assert_file_mode "$UNIT" 644
    assert_exists "$CONFIG"
    assert_file_mode "$CONFIG" 600
    assert_symlink "$HOME/.local/bin/kilo" "$DATA/libexec/kilo"

    assert_contains "$UNIT" 'Generated by kiloaded'
    assert_contains "$UNIT" 'ExecStart="'
    assert_contains "$UNIT" 'serve --print-logs --hostname "127.0.0.1" --port "5123"'
    assert_contains "$UNIT" "ExecStartPost=\"$DATA/libexec/kilo-remote\""
    assert_contains "$UNIT" 'WantedBy=default.target'
    assert_contains "$UNIT" 'Restart=on-failure'
    assert_line_absent "$UNIT" '^User='
    assert_line_absent "$UNIT" 'network-online'

    assert_exists "$DATA/libexec/kilo-remote"
    assert_file_mode "$DATA/libexec/kilo-remote" 700
    assert_contains "$CONFIG" 'KILOADED_PORT=5123'
    assert_contains "$CONFIG" 'KILOADED_HOSTNAME=127.0.0.1'
    assert_contains "$CONFIG" 'KILOADED_REMOTE=1'

    assert_contains "$FAKE_NPM_LOG" '@kilocode/cli@latest'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user daemon-reload'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user enable kiloaded.service'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user restart kiloaded.service'
    assert_log_absent "$FAKE_LOGINCTL_LOG"

    assert_contains "$FAKE_KILO_LOG" 'profile'
    assert_not_contains "$FAKE_KILO_LOG" 'auth login'

    assert_out 'url: http://127.0.0.1:5123'
    assert_out 'remote control: enabled'

    assert_eq "$("$DATA/libexec/kilo" --version)" "7.8.27"
    assert_eq "$("$DATA/libexec/kilo" --print-ts)" \
        "$DATA/cli/current/node_modules/@kilocode/cli/bin/tree-sitter"
}

test_install_idempotent() {
    setup
    run_k install --port 5123 --no-linger
    assert_ok

    : >"$FAKE_NPM_LOG"
    : >"$FAKE_SYSTEMCTL_LOG"
    run_k install --no-linger
    assert_ok
    assert_log_absent "$FAKE_NPM_LOG"
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_PORT=5123'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user restart kiloaded.service'

    : >"$FAKE_NPM_LOG"
    run_k install --port 5124 --no-linger
    assert_ok
    assert_log_absent "$FAKE_NPM_LOG"
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" '--port "5124"'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_PORT=5124'
}

test_install_versions() {
    setup
    run_k install --version 7.8.26 --no-linger
    assert_ok
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.26"
    assert_contains "$FAKE_NPM_LOG" '@kilocode/cli@7.8.26'

    run_k install --version 7.8.27 --no-linger
    assert_ok
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.27"
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.27"
}

test_install_verify_failure() {
    setup
    run_k install --version 7.8.27 --no-linger
    assert_ok

    FAKE_NPM_VERSION="7.8.28"
    FAKE_NPM_BAD_BINARY="1"
    export FAKE_NPM_VERSION FAKE_NPM_BAD_BINARY
    run_k install --version 7.8.28 --no-linger
    assert_fail
    assert_err 'did not run'
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.27"
    assert_not_exists "$XDG_DATA_HOME/kiloaded/cli/7.8.28"
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.27"
}

test_install_repairs_broken_current() {
    setup
    run_k install --version 7.8.27 --no-linger
    assert_ok

    BIN="$XDG_DATA_HOME/kiloaded/cli/7.8.27/node_modules/@kilocode/cli/bin/.kilo"
    printf '%s\n' '#!/bin/sh' 'exit 1' >"$BIN"
    chmod 755 "$BIN"

    : >"$FAKE_NPM_LOG"
    run_k install --no-linger
    assert_ok
    assert_err 'is not runnable'
    assert_contains "$FAKE_NPM_LOG" '@kilocode/cli@latest'
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.27"
}

test_install_crash_after_start() {
    setup
    KILOADED_STABLE_SECONDS="1"
    FAKE_SYSTEMCTL_ACTIVE_ONCE="1"
    export KILOADED_STABLE_SECONDS FAKE_SYSTEMCTL_ACTIVE_ONCE
    run_k install --no-linger
    assert_fail
    assert_err 'did not become active'
}

test_corrupt_config() {
    setup
    run_k install --port 5123 --no-linger
    assert_ok

    printf '%s\n' 'KILOADED_PORT=not-a-port' 'KILOADED_HOSTNAME=bad host' 'KILOADED_REMOTE=banana' >"$XDG_CONFIG_HOME/kiloaded/config"
    run_k install --no-linger
    assert_ok
    assert_err 'ignoring invalid port'
    assert_err 'ignoring invalid remote setting'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_PORT=4096'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_HOSTNAME=127.0.0.1'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=1'
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" '--port "4096"'

    printf '%s\n' 'garbage' 'KILOADED_HOSTNAME=bad host' >"$XDG_CONFIG_HOME/kiloaded/config"
    run_k update
    assert_ok
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_HOSTNAME=127.0.0.1'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=1'
}

test_install_no_remote() {
    setup
    run_k install --port 5128 --no-remote --no-linger
    assert_ok
    UNIT="$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_line_absent "$UNIT" '^ExecStartPost'
    assert_not_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=0'
    assert_out 'remote control: disabled'

    run_k install --no-linger
    assert_ok
    assert_line_absent "$UNIT" '^ExecStartPost'
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=0'

    run_k install --remote --no-linger
    assert_ok
    assert_contains "$UNIT" "ExecStartPost=\"$XDG_DATA_HOME/kiloaded/libexec/kilo-remote\""
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=1'
    assert_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
}

test_install_remote_no_curl() {
    setup
    KILOADED_CURL=""
    export KILOADED_CURL
    run_k install --no-linger --no-start
    assert_ok
    UNIT="$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_err 'curl was not found'
    assert_line_absent "$UNIT" '^ExecStartPost'
    assert_not_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
    assert_contains "$UNIT" 'ExecStart='
    assert_out 'install curl and re-run'

    # A later install with curl available finishes the remote setup.
    make_test_curl_fake
    run_k install --no-linger --no-start
    assert_ok
    assert_contains "$UNIT" "ExecStartPost=\"$XDG_DATA_HOME/kiloaded/libexec/kilo-remote\""
    assert_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
}

test_remote_helper() {
    setup
    run_k install --no-linger --no-start
    assert_ok
    HELPER="$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
    make_test_curl_fake

    # Success: one POST to the configured URL.
    KILOADED_REMOTE_TRIES=1 KILOADED_REMOTE_INTERVAL=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_log_absent "$CASE/herr"
    assert_contains "$FAKE_CURL_LOG" '-X POST http://127.0.0.1:4096/remote/enable'

    # The Basic-auth credential comes from the environment, never from files.
    : >"$FAKE_CURL_LOG"
    KILO_SERVER_PASSWORD=secret KILOADED_REMOTE_TRIES=1 KILOADED_REMOTE_INTERVAL=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$FAKE_CURL_LOG" '-u kilo:secret'

    # Failure: the helper keeps trying, then warns and still exits 0.
    : >"$FAKE_CURL_LOG"
    FAKE_CURL_RC=7 KILOADED_REMOTE_TRIES=2 KILOADED_REMOTE_INTERVAL=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$CASE/herr" 'could not enable remote control after 2 attempts'
    assert_eq "$(grep -c 'remote/enable' "$FAKE_CURL_LOG")" "2"
}

test_update() {
    setup
    run_k install --port 5125 --no-linger
    assert_ok

    FAKE_NPM_VERSION="7.8.28"
    export FAKE_NPM_VERSION
    : >"$FAKE_NPM_LOG"
    : >"$FAKE_SYSTEMCTL_LOG"
    run_k update
    assert_ok
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.28"
    assert_not_exists "$XDG_DATA_HOME/kiloaded/cli/7.8.27"
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_PORT=5125'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user restart kiloaded.service'
    assert_out 'updated Kilo CLI 7.8.27 -> 7.8.28'
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.28"

    : >"$FAKE_SYSTEMCTL_LOG"
    run_k update
    assert_ok
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.28"
    assert_out 'Kilo CLI 7.8.28 is already current'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user restart kiloaded.service'
}

test_update_rollback() {
    setup
    run_k install --no-linger
    assert_ok

    FAKE_NPM_VERSION="7.8.28"
    FAKE_SYSTEMCTL_FAIL_ONCE="restart"
    export FAKE_NPM_VERSION FAKE_SYSTEMCTL_FAIL_ONCE
    run_k update
    assert_fail
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.27"
    assert_err 'rolled back to 7.8.27'
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.27"
}

test_update_not_installed() {
    setup
    run_k update
    assert_fail
    assert_err 'not installed'
    assert_log_absent "$FAKE_NPM_LOG"
}

test_remove() {
    setup
    run_k install --no-linger
    assert_ok

    mkdir -p "$XDG_CONFIG_HOME/kilo" "$XDG_DATA_HOME/kilo"
    printf 'keep me\n' >"$XDG_CONFIG_HOME/kilo/kilo.json"
    printf 'keep me too\n' >"$XDG_DATA_HOME/kilo/auth.json"
    mkdir -p "$XDG_CONFIG_HOME/systemd/user/default.target.wants"
    ln -s "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" \
        "$XDG_CONFIG_HOME/systemd/user/default.target.wants/kiloaded.service"

    : >"$FAKE_SYSTEMCTL_LOG"
    run_k remove
    assert_ok
    assert_not_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_not_exists "$XDG_CONFIG_HOME/systemd/user/default.target.wants/kiloaded.service"
    assert_not_exists "$XDG_DATA_HOME/kiloaded"
    assert_not_exists "$XDG_CONFIG_HOME/kiloaded"
    assert_not_exists "$HOME/.local/bin/kilo"
    assert_exists "$XDG_CONFIG_HOME/kilo/kilo.json"
    assert_exists "$XDG_DATA_HOME/kilo/auth.json"
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user stop kiloaded.service'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user disable kiloaded.service'
    assert_not_contains "$FAKE_LOGINCTL_LOG" 'disable-linger'
    assert_out 'were not touched'

    run_k remove
    assert_ok
}

test_remove_best_effort() {
    setup
    run_k install --no-linger
    assert_ok
    FAKE_SYSTEMCTL_FAIL="--user"
    export FAKE_SYSTEMCTL_FAIL
    run_k remove
    assert_ok
    assert_not_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_not_exists "$XDG_DATA_HOME/kiloaded"
}

test_remove_keep_cli() {
    setup
    run_k install --no-linger
    assert_ok

    run_k remove --keep-cli
    assert_ok
    assert_exists "$XDG_DATA_HOME/kiloaded/cli/current"
    assert_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo"
    assert_exists "$HOME/.local/bin/kilo"
    assert_not_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_not_exists "$XDG_CONFIG_HOME/kiloaded"
    assert_out 'kept the Kilo CLI'
}

test_non_linux() {
    setup
    FAKE_UNAME="Darwin"
    export FAKE_UNAME
    run_k install
    assert_fail
    assert_err 'only supports Linux'
    assert_not_exists "$XDG_DATA_HOME/kiloaded"
    assert_log_absent "$FAKE_NPM_LOG"
}

test_no_systemd() {
    setup
    KILOADED_SYSTEMD_RUNTIME="$CASE/no-systemd"
    export KILOADED_SYSTEMD_RUNTIME
    run_k install
    assert_fail
    assert_err 'requires systemd'
    assert_not_exists "$XDG_DATA_HOME/kiloaded"
    assert_log_absent "$FAKE_NPM_LOG"
}

test_invalid_options() {
    setup

    run_k install --port 0
    assert_status 1
    assert_err 'port must be'

    run_k install --port abc
    assert_status 1
    assert_err 'port must be'

    run_k install --port 70000
    assert_status 1
    assert_err 'port must be'

    run_k install --port 999999999999999999999999
    assert_status 1
    assert_err 'port must be'

    run_k install --hostname "bad host"
    assert_status 1
    assert_err 'hostname contains'

    run_k install --version "../nope"
    assert_status 1
    assert_err 'version contains'

    run_k install --bogus
    assert_status 2
    assert_err 'unknown install option'

    assert_not_exists "$XDG_DATA_HOME/kiloaded"
    assert_log_absent "$FAKE_NPM_LOG"
}

test_npm_failure() {
    setup
    FAKE_NPM_FAIL="1"
    export FAKE_NPM_FAIL
    run_k install --no-linger
    assert_fail
    assert_err 'npm install failed'
    assert_not_exists "$XDG_DATA_HOME/kiloaded/cli/current"
    assert_not_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
}

test_systemctl_failure() {
    setup
    FAKE_SYSTEMCTL_FAIL="enable"
    export FAKE_SYSTEMCTL_FAIL
    run_k install --no-linger
    assert_fail
    assert_err 'could not enable'
}

test_linger() {
    setup
    run_k install --port 5126
    assert_ok
    assert_contains "$FAKE_LOGINCTL_LOG" 'enable-linger'
    assert_out 'lingering enabled'

    setup
    FAKE_LOGINCTL_FAIL="1"
    export FAKE_LOGINCTL_FAIL
    run_k install --port 5126
    assert_ok
    assert_err 'could not enable lingering'
}

test_status() {
    setup
    run_k status
    assert_status 1
    assert_out 'not installed'

    run_k install --no-linger
    assert_ok
    make_test_curl_fake
    printf '{"enabled":true,"connected":true}\n' >"$CASE/remote.json"
    FAKE_CURL_BODY_FILE="$CASE/remote.json"
    export FAKE_CURL_BODY_FILE
    run_k status
    assert_ok
    assert_out 'Kilo CLI: 7.8.27'
    assert_out 'active: yes'
    assert_out 'enabled: yes'
    assert_out 'url: http://127.0.0.1:4096'
    assert_out 'remote: enabled (connected)'
    assert_contains "$FAKE_CURL_LOG" 'http://127.0.0.1:4096/remote/status'
    assert_out 'linger: yes'
}

test_logs() {
    setup
    run_k install --no-linger
    assert_ok
    run_k logs -f -n 5
    assert_ok
    assert_contains "$FAKE_JOURNALCTL_LOG" '--user -u kiloaded.service -f -n 5'
    assert_out 'fake journal output'
}

test_home_with_spaces() {
    setup
    export HOME="$CASE/home with space"
    export XDG_CONFIG_HOME="$CASE/config with space"
    export XDG_DATA_HOME="$CASE/data with space"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"

    run_k install --port 5127 --no-linger
    assert_ok

    DATA="$XDG_DATA_HOME/kiloaded"
    UNIT="$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_exists "$DATA/libexec/kilo"
    assert_contains "$UNIT" "ExecStart=\"$DATA/libexec/kilo\""
    assert_eq "$("$DATA/libexec/kilo" --version)" "7.8.27"
    assert_symlink "$HOME/.local/bin/kilo" "$DATA/libexec/kilo"
}

test_existing_launcher() {
    setup
    mkdir -p "$HOME/.local/bin"
    printf '%s\n' '#!/bin/sh' 'echo custom' >"$HOME/.local/bin/kilo"
    chmod 755 "$HOME/.local/bin/kilo"

    run_k install --no-linger
    assert_ok
    assert_err 'leaving existing'
    assert_contains "$HOME/.local/bin/kilo" 'echo custom'

    run_k remove
    assert_ok
    assert_exists "$HOME/.local/bin/kilo"
    assert_contains "$HOME/.local/bin/kilo" 'echo custom'
}

test_no_start() {
    setup
    run_k install --no-start --no-linger
    assert_ok
    assert_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.27"
    if grep -Fq -- '--user restart' "$FAKE_SYSTEMCTL_LOG"; then
        printf 'expected --no-start not to restart the service\n'
        return 1
    fi
}

test_update_pinned() {
    setup
    run_k install --no-linger
    assert_ok
    run_k update --version 7.8.26
    assert_ok
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.26"
    assert_eq "$("$XDG_DATA_HOME/kiloaded/libexec/kilo" --version)" "7.8.26"
}

test_update_preserves_remote() {
    setup
    run_k install --no-remote --no-linger
    assert_ok

    FAKE_NPM_VERSION="7.8.28"
    export FAKE_NPM_VERSION
    run_k update
    assert_ok
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=0'
    assert_line_absent "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" '^ExecStartPost'
    assert_not_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"

    # An old config without KILOADED_REMOTE upgrades to remote on.
    printf '%s\n' 'KILOADED_PORT=4096' 'KILOADED_HOSTNAME=127.0.0.1' >"$XDG_CONFIG_HOME/kiloaded/config"
    run_k update
    assert_ok
    assert_contains "$XDG_CONFIG_HOME/kiloaded/config" 'KILOADED_REMOTE=1'
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" '^ExecStartPost'
    assert_exists "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote"
}

test_install_login() {
    setup
    printf 'unused\n' >"$CASE/tty"
    export KILOADED_TTY="$CASE/tty"
    printf 'x\n' >"$CASE/logged-out"
    export FAKE_KILO_LOGGED_OUT_FILE="$CASE/logged-out"
    run_k install --no-linger --no-start
    assert_ok
    assert_contains "$FAKE_KILO_LOG" 'profile'
    assert_contains "$FAKE_KILO_LOG" 'auth login'
    assert_out 'not logged in to Kilo'
    assert_out 'logged in to Kilo'
}

test_install_login_non_interactive() {
    setup
    printf 'x\n' >"$CASE/logged-out"
    export FAKE_KILO_LOGGED_OUT_FILE="$CASE/logged-out"
    KILOADED_TTY=""
    export KILOADED_TTY
    run_k install --no-linger --no-start
    assert_ok
    assert_contains "$FAKE_KILO_LOG" 'profile'
    assert_not_contains "$FAKE_KILO_LOG" 'auth login'
    assert_err 'no interactive terminal for login'
    assert_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
}

test_install_login_fail() {
    setup
    printf 'unused\n' >"$CASE/tty"
    export KILOADED_TTY="$CASE/tty"
    printf 'x\n' >"$CASE/logged-out"
    export FAKE_KILO_LOGGED_OUT_FILE="$CASE/logged-out"
    FAKE_KILO_LOGIN_FAIL=1
    export FAKE_KILO_LOGIN_FAIL
    run_k install --no-linger --no-start
    assert_ok
    assert_contains "$FAKE_KILO_LOG" 'auth login'
    assert_err 'login was not completed'
    assert_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
}

test_login_command() {
    setup
    run_k login
    assert_fail
    assert_err 'kiloaded is not installed'

    run_k install --no-linger --no-start
    assert_ok
    run_k login
    assert_ok
    assert_out 'already logged in to Kilo'
    assert_out 'Name: Test User'

    printf 'unused\n' >"$CASE/tty"
    export KILOADED_TTY="$CASE/tty"
    printf 'x\n' >"$CASE/logged-out"
    export FAKE_KILO_LOGGED_OUT_FILE="$CASE/logged-out"
    run_k login
    assert_ok
    assert_out 'logged in to Kilo'
    assert_contains "$FAKE_KILO_LOG" 'auth login'

    printf 'x\n' >"$CASE/logged-out"
    KILOADED_TTY=""
    export KILOADED_TTY
    run_k login
    assert_fail
    assert_err 'no interactive terminal'

    printf 'x\n' >"$CASE/logged-out"
    export KILOADED_TTY="$CASE/tty"
    FAKE_KILO_LOGIN_FAIL=1
    export FAKE_KILO_LOGIN_FAIL
    run_k login
    assert_fail
    assert_err 'login was not completed'
}

test_install_sh() {
    setup
    export KILOADED_BIN_DIR="$CASE/user-bin"
    make_curl_fake
    run_install_sh --port 5130 --no-linger --no-start
    assert_ok
    assert_exists "$KILOADED_BIN_DIR/kiloaded"
    assert_eq "$(head -n 1 "$KILOADED_BIN_DIR/kiloaded")" '#!/bin/sh'
    assert_symlink "$XDG_DATA_HOME/kiloaded/cli/current" "7.8.27"
    assert_exists "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    assert_out 'installed wrapper'
}

test_install_sh_home_unset() {
    setup
    export KILOADED_BIN_DIR="$CASE/user-bin"
    make_curl_fake
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$CASE/stub-kiloaded"
    chmod 755 "$CASE/stub-kiloaded"
    export KILOADED_TEST_SOURCE="$CASE/stub-kiloaded"
    unset HOME
    run_install_sh --no-linger
    assert_ok
    assert_exists "$KILOADED_BIN_DIR/kiloaded"
    assert_eq "$(head -n 1 "$KILOADED_BIN_DIR/kiloaded")" '#!/bin/sh'

    unset KILOADED_BIN_DIR
    run_install_sh --no-linger
    assert_fail
    assert_err 'HOME is not set'
}

test_install_sh_non_linux() {
    setup
    export KILOADED_BIN_DIR="$CASE/user-bin"
    make_curl_fake
    FAKE_UNAME="Darwin"
    export FAKE_UNAME
    run_install_sh --no-linger
    assert_fail
    assert_err 'only supports Linux'
    assert_not_exists "$KILOADED_BIN_DIR/kiloaded"
    assert_log_absent "$FAKE_NPM_LOG"
}

test_install_sh_bad_ref() {
    setup
    export KILOADED_BIN_DIR="$CASE/user-bin"
    make_curl_fake
    KILOADED_REF="bad ref"
    export KILOADED_REF
    run_install_sh --no-linger
    assert_fail
    assert_err 'KILOADED_REF'
    assert_not_exists "$KILOADED_BIN_DIR/kiloaded"
}

test_unit_verify() {
    setup
    run_k install --no-linger --no-start
    assert_ok
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    fi

    export HOME="$CASE/home with space"
    export XDG_CONFIG_HOME="$CASE/config with space"
    export XDG_DATA_HOME="$CASE/data with space"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
    run_k install --port 5131 --no-linger --no-start
    assert_ok
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    fi

    export HOME="$CASE/home %s"
    export XDG_CONFIG_HOME="$CASE/config-percent"
    export XDG_DATA_HOME="$CASE/data-percent"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
    run_k install --port 5132 --no-linger --no-start
    assert_ok
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" \
        "WorkingDirectory=$CASE/home %%s"
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze verify "$XDG_CONFIG_HOME/systemd/user/kiloaded.service"
    fi
}

test_non_loopback_warning() {
    setup
    run_k install --hostname 0.0.0.0 --no-linger --no-start
    assert_ok
    assert_err 'without authentication'
    assert_out 'url: http://127.0.0.1:4096'
}

test_ipv6_url() {
    setup
    run_k install --hostname ::1 --no-linger --no-start
    assert_ok
    assert_out 'url: http://[::1]:4096'
    run_k status
    assert_ok
    assert_out 'url: http://[::1]:4096'

    # The remote helper bakes in the bracketed IPv6 URL.
    make_test_curl_fake
    KILOADED_REMOTE_TRIES=1 KILOADED_REMOTE_INTERVAL=0 \
        "$XDG_DATA_HOME/kiloaded/libexec/kilo-remote" >/dev/null 2>&1
    assert_contains "$FAKE_CURL_LOG" '-X POST http://[::1]:4096/remote/enable'
}

test_foreign_unit() {
    setup
    mkdir -p "$XDG_CONFIG_HOME/systemd/user"
    printf '%s\n' '[Unit]' 'Description=someone else' >"$XDG_CONFIG_HOME/systemd/user/kiloaded.service"

    run_k install --no-linger --no-start
    assert_fail
    assert_err 'refusing to overwrite'
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" 'someone else'
    assert_not_exists "$XDG_DATA_HOME/kiloaded/cli/current"
    assert_log_absent "$FAKE_NPM_LOG"

    run_k remove
    assert_fail
    assert_err 'refusing to remove'
    assert_contains "$XDG_CONFIG_HOME/systemd/user/kiloaded.service" 'someone else'
}
test_recover_units() {
    setup
    run_k install --no-linger --no-start
    assert_ok
    UNITS="$XDG_CONFIG_HOME/systemd/user"
    RECOVER_UNIT="$UNITS/kiloaded-recover.service"
    RECOVER_TIMER="$UNITS/kiloaded-recover.timer"
    HELPER="$XDG_DATA_HOME/kiloaded/libexec/kilo-recover"

    assert_exists "$HELPER"
    assert_file_mode "$HELPER" 700
    assert_exists "$RECOVER_UNIT"
    assert_exists "$RECOVER_TIMER"
    assert_file_mode "$RECOVER_UNIT" 644
    assert_file_mode "$RECOVER_TIMER" 644
    assert_contains "$RECOVER_UNIT" 'Generated by kiloaded'
    assert_contains "$RECOVER_UNIT" "ExecStart=\"$HELPER\""
    assert_contains "$RECOVER_TIMER" 'OnUnitActiveSec=15s'
    assert_contains "$RECOVER_TIMER" 'Unit=kiloaded-recover.service'
    assert_contains "$RECOVER_TIMER" 'WantedBy=timers.target'
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user enable kiloaded-recover.timer'
    assert_out 'relay recovery: enabled'

    # --no-remote removes the recovery units and helper too.
    run_k install --no-remote --no-linger --no-start
    assert_ok
    assert_not_exists "$RECOVER_UNIT"
    assert_not_exists "$RECOVER_TIMER"
    assert_not_exists "$HELPER"
    assert_contains "$FAKE_SYSTEMCTL_LOG" '--user disable kiloaded-recover.timer'

    # The interval is configurable at install time.
    KILOADED_RECOVER_SECONDS=7
    export KILOADED_RECOVER_SECONDS
    run_k install --remote --no-linger --no-start
    assert_ok
    assert_contains "$RECOVER_TIMER" 'OnUnitActiveSec=7s'
}

test_recover_helper() {
    setup
    run_k install --no-linger --no-start
    assert_ok
    HELPER="$XDG_DATA_HOME/kiloaded/libexec/kilo-recover"
    make_test_curl_fake

    # Connected: probe only, no enable POST.
    printf '{"enabled":true,"connected":true}\n' >"$CASE/status.json"
    FAKE_CURL_STATUS_FILE="$CASE/status.json" export FAKE_CURL_STATUS_FILE
    KILOADED_RECOVER_GRACE=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$FAKE_CURL_LOG" '/remote/status'
    if grep -q 'remote/enable' "$FAKE_CURL_LOG"; then
        printf 'did not expect an enable POST while connected\n'
        return 1
    fi

    # Enabled but disconnected: re-issue enable.
    : >"$FAKE_CURL_LOG"
    printf '{"enabled":true,"connected":false}\n' >"$CASE/status.json"
    KILOADED_RECOVER_GRACE=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$FAKE_CURL_LOG" '-X POST http://127.0.0.1:4096/remote/enable'

    # Disabled (relay never came back): also re-issue enable.
    : >"$FAKE_CURL_LOG"
    printf '{"enabled":false,"connected":false}\n' >"$CASE/status.json"
    KILOADED_RECOVER_GRACE=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$FAKE_CURL_LOG" '-X POST http://127.0.0.1:4096/remote/enable'

    # Server unreachable (mid-outage): do nothing, and never fail the timer.
    : >"$FAKE_CURL_LOG"
    unset FAKE_CURL_STATUS_FILE
    FAKE_CURL_STATUS_RC=7 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    if grep -q 'remote/enable' "$FAKE_CURL_LOG"; then
        printf 'did not expect an enable POST when the server is unreachable\n'
        return 1
    fi
    assert_log_absent "$CASE/herr"

    # Basic auth is taken from the environment at runtime.
    : >"$FAKE_CURL_LOG"
    printf '{"enabled":true,"connected":false}\n' >"$CASE/status.json"
    FAKE_CURL_STATUS_FILE="$CASE/status.json" export FAKE_CURL_STATUS_FILE
    KILO_SERVER_PASSWORD=secret KILOADED_RECOVER_GRACE=0 "$HELPER" >"$CASE/hout" 2>"$CASE/herr"
    assert_status 0
    assert_contains "$FAKE_CURL_LOG" '-u kilo:secret'
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_case() {
    _name="$1"
    _fn="$2"
    _num=$((PASS + FAIL + 1))
    _log="$TEST_ROOT/log.$_num"

    if ( "$_fn" ) >"$_log" 2>&1; then
        PASS=$((PASS + 1))
        printf 'ok %s - %s\n' "$_num" "$_name"
    else
        FAIL=$((FAIL + 1))
        printf 'not ok %s - %s\n' "$_num" "$_name"
        sed 's/^/    /' "$_log"
    fi
    rm -f "$_log"
}

run_case "help and version" test_help_and_version
run_case "fresh install" test_install_fresh
run_case "idempotent install" test_install_idempotent
run_case "pinned install versions" test_install_versions
run_case "install verify failure" test_install_verify_failure
run_case "install repairs broken current" test_install_repairs_broken_current
run_case "corrupt config self-heals" test_corrupt_config
run_case "install --no-remote" test_install_no_remote
run_case "install without curl stays usable" test_install_remote_no_curl
run_case "remote control helper" test_remote_helper
run_case "relay recovery units" test_recover_units
run_case "relay recovery helper" test_recover_helper
run_case "update" test_update
run_case "update rollback" test_update_rollback
run_case "update preserves remote setting" test_update_preserves_remote
run_case "update before install" test_update_not_installed
run_case "install runs login when logged out" test_install_login
run_case "install skips login without a terminal" test_install_login_non_interactive
run_case "install warns when login fails" test_install_login_fail
run_case "login command" test_login_command
run_case "remove" test_remove
run_case "remove best effort" test_remove_best_effort
run_case "remove --keep-cli" test_remove_keep_cli
run_case "non-Linux rejection" test_non_linux
run_case "missing systemd rejection" test_no_systemd
run_case "invalid options" test_invalid_options
run_case "npm failure" test_npm_failure
run_case "systemctl failure" test_systemctl_failure
run_case "linger" test_linger
run_case "status" test_status
run_case "logs" test_logs
run_case "HOME and XDG paths with spaces" test_home_with_spaces
run_case "existing kilo launcher" test_existing_launcher
run_case "install --no-start" test_no_start
run_case "install crash after start" test_install_crash_after_start
run_case "update pinned version" test_update_pinned
run_case "install.sh bootstrap" test_install_sh
run_case "install.sh HOME unset with BIN_DIR" test_install_sh_home_unset
run_case "install.sh non-Linux" test_install_sh_non_linux
run_case "install.sh bad ref" test_install_sh_bad_ref
run_case "systemd unit verifies" test_unit_verify
run_case "non-loopback warning" test_non_loopback_warning
run_case "IPv6 URL formatting" test_ipv6_url
run_case "foreign unit is not overwritten" test_foreign_unit

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
