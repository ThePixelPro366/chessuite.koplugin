#!/bin/sh
# Builds the Maia3 engine (tools/maia3/maia3.c) for the devices in ../bin.
# Needs: gcc, arm-linux-gnueabihf-gcc, aarch64-linux-gnu-gcc
# (Debian/Ubuntu: apt install gcc-arm-linux-gnueabihf gcc-aarch64-linux-gnu)
# The weights (bin/maia3-5m.bin) come from tools/export-maia3.py.
#
# The ARMv7 build uses NEON, which every e-reader chip of the last decade
# has (i.MX6/7, Allwinner, MediaTek). Where it does not run, the bots fall
# back to the Stockfish based move picking.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../bin"
SRC="$HERE/maia3/maia3.c"

build() { # name cc flags...
    name="$1"; cc="$2"; shift 2
    "$cc" -std=c99 -D_DEFAULT_SOURCE -O3 -ffast-math -Wall "$@" "$SRC" -o "$OUT/maia3-$name" -static -s -lm
    chmod 755 "$OUT/maia3-$name"
    echo "built bin/maia3-$name"
}

build armv7   arm-linux-gnueabihf-gcc -march=armv7-a -mfpu=neon -mfloat-abi=hard
build aarch64 aarch64-linux-gnu-gcc   -march=armv8-a
build x86_64  gcc                     -m64 -msse2
