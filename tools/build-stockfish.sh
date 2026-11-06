#!/bin/sh
# Rebuilds the bundled Stockfish binaries in ../bin from the official sources.
# Needs: git, make, g++, arm-linux-gnueabihf-g++, aarch64-linux-gnu-g++
# (Debian/Ubuntu: apt install g++-arm-linux-gnueabihf g++-aarch64-linux-gnu)
#
# Stockfish 11 is used on purpose: it is the last release with the classical
# (hand written) evaluation, so it needs no multi-megabyte NNUE network file,
# the binaries stay around 1 MB and it is still far stronger than any human
# on the slow CPUs found in e-readers.
set -eu

SF_TAG="${SF_TAG:-sf_11}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../bin"
WORK="${WORK:-$(mktemp -d)}"

mkdir -p "$OUT"
if [ ! -d "$WORK/Stockfish" ]; then
    git clone --depth 1 --branch "$SF_TAG" https://github.com/official-stockfish/Stockfish.git "$WORK/Stockfish"
fi
SRC="$WORK/Stockfish/src"

build() { # name cxx flags...
    name="$1"; cxx="$2"; shift 2
    # shellcheck disable=SC2086
    (cd "$SRC" && "$cxx" -std=c++11 -O3 -flto -DNDEBUG -Wall "$@" \
        ./*.cpp syzygy/*.cpp -o "$OUT/stockfish-$name" -static -s -pthread)
    chmod 755 "$OUT/stockfish-$name"
    echo "built bin/stockfish-$name"
}

# Kobo, Kindle (PW and newer), PocketBook, reMarkable ... (32-bit ARMv7, VFP)
build armv7   arm-linux-gnueabihf-g++ -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard
# 64-bit ARM Linux devices
build aarch64 aarch64-linux-gnu-g++   -march=armv8-a -DIS_64BIT
# Desktop Linux / KOReader emulator (any x86-64 CPU)
build x86_64  g++                     -m64 -DIS_64BIT

cp "$WORK/Stockfish/Copying.txt" "$OUT/STOCKFISH-COPYING.txt"
echo "Stockfish $SF_TAG, https://github.com/official-stockfish/Stockfish/tree/$SF_TAG" > "$OUT/STOCKFISH-SOURCE.txt"
