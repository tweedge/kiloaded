#!/bin/sh
# Install (or refresh) the kiloaded wrapper, then hand off to `kiloaded install`.
#
#   curl -fsSL https://raw.githubusercontent.com/tweedge/kiloaded/main/install.sh | sh
#
# Arguments are passed through to `kiloaded install`. Set KILOADED_BIN_DIR to
# install the wrapper somewhere other than ~/.local/bin, or KILOADED_REF to
# fetch a specific branch/tag instead of main.
set -eu

REPO="tweedge/kiloaded"
REF="${KILOADED_REF:-main}"

say() { printf 'kiloaded install: %s\n' "$*"; }
die() {
    printf 'kiloaded install: %s\n' "$*" >&2
    exit 1
}

BIN_DIR="${KILOADED_BIN_DIR:-}"
if [ -z "$BIN_DIR" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set (or set KILOADED_BIN_DIR)"
    BIN_DIR="$HOME/.local/bin"
fi
DEST="$BIN_DIR/kiloaded"

command -v curl >/dev/null 2>&1 || die "this script needs curl on PATH"

case "$(uname -s 2>/dev/null || printf 'unknown')" in
    Linux) ;;
    *) die "kiloaded only supports Linux" ;;
esac

case "$REF" in
    '' | *[!A-Za-z0-9._/-]*) die "KILOADED_REF contains unsupported characters" ;;
esac

tmpdir=$(mktemp -d) || die "could not create a temporary directory"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup 0
trap 'cleanup; exit 1' 1 2 15

url="https://raw.githubusercontent.com/$REPO/$REF/kiloaded"
say "fetching $url"
curl -fsSL "$url" -o "$tmpdir/kiloaded" || die "download failed"

sh -n "$tmpdir/kiloaded" || die "downloaded wrapper failed a syntax check"

mkdir -p "$BIN_DIR" || die "could not create $BIN_DIR"
chmod 755 "$tmpdir/kiloaded"
mv -f "$tmpdir/kiloaded" "$DEST"

say "installed wrapper to $DEST"
case ":${PATH}:" in
    *":$BIN_DIR:"*) ;;
    *) say "note: $BIN_DIR is not on PATH; add it to use the 'kiloaded' command directly" ;;
esac

exec "$DEST" install "$@"
