#!/bin/sh
# HACKHACK this file downloads gcrypt and gpgerror because netatalk needs them to build
# TODO add these as actual submodules so this script doesnt have to just fetch the tarball

set -eu

GPGERROR_VERSION=1.61
GPGERROR_SHA256=7a85413f2bc354f4f8aa832b718af122e48965e9e0eb9012ee659c13c6385c93
GCRYPT_VERSION=1.12.4
GCRYPT_SHA256=d77f68f48879510e79a2f65977ccc68981781ea0923e5bdffac2a193ea3d660e
MIN_MACOS=27.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor"
PREFIX="$VENDOR/build"
SRC="$VENDOR/src"
STAMP="$PREFIX/.stamp"
WANT="gpg-error-$GPGERROR_VERSION gcrypt-$GCRYPT_VERSION macos-$MIN_MACOS"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ]; then
    exit 0
fi

# xcode build phases export a lot of toolchain variables that confuse configure
unset LD CC CXX CPP CFLAGS LDFLAGS SDKROOT ARCHS MACOSX_DEPLOYMENT_TARGET

SDK=$(xcrun --sdk macosx --show-sdk-path)
CFLAGS="-arch arm64 -mmacosx-version-min=$MIN_MACOS -isysroot $SDK -O2"
export SDKROOT="$SDK" CC="$(xcrun --find clang)" CFLAGS LDFLAGS="$CFLAGS"
JOBS=$(sysctl -n hw.ncpu)

fetch() {
    # $1 project, $2 version, $3 sha256
    tarball="$SRC/$1-$2.tar.bz2"
    if [ ! -f "$tarball" ]; then
        mkdir -p "$SRC"
        curl -fL --retry 3 -o "$tarball.part" "https://gnupg.org/ftp/gcrypt/$1/$1-$2.tar.bz2"
        mv "$tarball.part" "$tarball"
    fi
    echo "$3  $tarball" | shasum -a 256 -c - >/dev/null
    rm -rf "$SRC/$1-$2"
    tar -xjf "$tarball" -C "$SRC"
}

rm -rf "$PREFIX"
mkdir -p "$PREFIX"

fetch libgpg-error "$GPGERROR_VERSION" "$GPGERROR_SHA256"
(
    cd "$SRC/libgpg-error-$GPGERROR_VERSION"
    ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-nls --disable-doc \
        --disable-tests --disable-languages --enable-install-gpg-error-config
    make -j"$JOBS"
    make install
)

fetch libgcrypt "$GCRYPT_VERSION" "$GCRYPT_SHA256"
(
    cd "$SRC/libgcrypt-$GCRYPT_VERSION"
    ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --disable-doc \
        --with-libgpg-error-prefix="$PREFIX" \
        --disable-asm
    make -j"$JOBS"
    make install
)

echo "$WANT" > "$STAMP"
