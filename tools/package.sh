#!/bin/sh
# Builds the release zip: chessuite.koplugin-<version>.zip, holding one folder
# named chessuite.koplugin with what the plugin needs on the device (no tests,
# build tools or companion app sources; the companion APK is kept because the
# e-reader serves it to the phone).
# Usage, from the plugin folder: sh tools/package.sh
set -e
cd "$(dirname "$0")/.."
version=$(sed -n 's/^ *version *= *"\(.*\)".*/\1/p' _meta.lua)
[ -n "$version" ] || { echo "no version in _meta.lua" >&2; exit 1; }
out="$PWD/chessuite.koplugin-$version.zip"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dest="$tmp/chessuite.koplugin"
mkdir -p "$dest/companion"
cp -R _meta.lua main.lua LICENSE README.md bin chessuite icons "$dest/"
cp companion/chessuite-companion.apk companion/README.md "$dest/companion/"
chmod +x "$dest"/bin/stockfish-* "$dest"/bin/maia3-armv7 "$dest"/bin/maia3-aarch64 "$dest"/bin/maia3-x86_64
rm -f "$out"
(cd "$tmp" && zip -qr -X "$out" chessuite.koplugin)
echo "$out"
