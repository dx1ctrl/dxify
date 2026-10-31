#!/usr/bin/env bash
# Build the pinned, non-premium SponsorBlock part of EeveeSpotifyReincarnated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
PIN="ca363e63efd4730811a241ec48a5c0e4ef838112"
REPO="https://github.com/SideloadLabs/EeveeSpotifyReincarnated.git"
SWIFTPROTOBUF_VERSION="1.29.0"
IPAPATCH_VERSION="2.1.3"
OUT="$ROOT/out/eevee"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1 -> $2" >&2; exit 1; }; }
need git "install Git"
need gmake "brew install make"
need dpkg-deb "brew install dpkg"
need ldid "brew install ldid"
need python3 "install Python 3"
need curl "install curl"
need xcrun "select Xcode 26 or newer"
[ -d "$THEOS" ] || { echo "Theos is missing at $THEOS" >&2; exit 1; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
[ -d "$SDK" ] || { echo "no iPhoneOS SDK selected" >&2; exit 1; }
mkdir -p "$ROOT/out"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxify-eevee.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
SOURCE="$BUILD_DIR/source"

echo "==> fetching EeveeSpotifyReincarnated $PIN"
git init -q "$SOURCE"
git -C "$SOURCE" remote add origin "$REPO"
git -C "$SOURCE" fetch --quiet --depth=1 origin "$PIN"
git -C "$SOURCE" checkout --quiet --detach FETCH_HEAD
git -C "$SOURCE" submodule update --init --recursive --depth=1

python3 "$ROOT/integrations/eevee/prepare_eevee.py" "$SOURCE"

export THEOS
export THEOS_PACKAGE_SCHEME=rootless
export SWIFTPROTOBUF_VERSION
export SRC_DIR="$BUILD_DIR/swift-protobuf"

echo "==> building EeveeSwiftProtobuf"
bash "$SOURCE/Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh"

echo "==> building SponsorBlock tweak"
(cd "$SOURCE" && env -u MAKELEVEL gmake clean package FINALPACKAGE=1 REPO_SLUG=dx1ctrl/dxify BRANCH_NAME=main)

echo "==> building keychain and CloudKit sideload shim"
(cd "$SOURCE" && bash Tools/build-zxpi.sh)

PACKAGE_COUNT="$(find "$SOURCE/packages" -maxdepth 1 -type f -name 'com.eevee.spotify_*.deb' -print | wc -l | tr -d ' ')"
[ "$PACKAGE_COUNT" -eq 1 ] || { echo "expected one Eevee package; found $PACKAGE_COUNT" >&2; exit 1; }
PACKAGE="$(find "$SOURCE/packages" -maxdepth 1 -type f -name 'com.eevee.spotify_*.deb' -print -quit)"
ZX_SHIM="$SOURCE/packages/zxPluginsInject.dylib"
[ -f "$ZX_SHIM" ] || { echo "missing zxPluginsInject.dylib" >&2; exit 1; }

PKG_ROOT="$BUILD_DIR/package"
dpkg-deb -R "$PACKAGE" "$PKG_ROOT"
EEVEE_DYLIB="$(find "$PKG_ROOT" -type f -name EeveeSpotify.dylib -print -quit)"
PROTOBUF_FRAMEWORK="$(find "$PKG_ROOT" -type d -name EeveeSwiftProtobuf.framework -print -quit)"
EEVEE_BUNDLE="$(find "$PKG_ROOT" -type d -name EeveeSpotify.bundle -print -quit)"
[ -n "$EEVEE_DYLIB" ] && [ -n "$PROTOBUF_FRAMEWORK" ] && [ -n "$EEVEE_BUNDLE" ] \
  || { echo "Eevee package is missing its dylib, framework, or resource bundle" >&2; exit 1; }

case "$OUT" in "$ROOT/out/eevee") ;; *) echo "refusing unexpected output path: $OUT" >&2; exit 1 ;; esac
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$EEVEE_DYLIB" "$OUT/EeveeSpotify.dylib"
cp -R "$PROTOBUF_FRAMEWORK" "$OUT/"
cp -R "$EEVEE_BUNDLE" "$OUT/"
cp "$ZX_SHIM" "$OUT/zxPluginsInject.dylib"
cp "$PACKAGE" "$OUT/"
cp "$SOURCE/LICENSE" "$OUT/EeveeSpotifyReincarnated-LICENSE.txt"
tar --exclude=.git --exclude=.theos --exclude=packages --exclude=extra_dylibs \
  -czf "$OUT/EeveeSpotifyReincarnated-source.tar.gz" -C "$SOURCE" .

case "$(uname -m)" in
  arm64|aarch64) IPAPATCH_ARCH=macos-arm64 ;;
  x86_64|amd64) IPAPATCH_ARCH=macos-amd64 ;;
  *) echo "unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
esac
curl -fsSL "https://github.com/asdfzxcvbn/ipapatch/releases/download/v${IPAPATCH_VERSION}/ipapatch.${IPAPATCH_ARCH}" \
  -o "$OUT/ipapatch"
chmod +x "$OUT/ipapatch"
"$OUT/ipapatch" --help >/dev/null

printf 'EeveeSpotifyReincarnated commit: %s\nProfile: SponsorBlock only\nPremium and ad-block hooks: disabled\nLyrics, UI, and App Group hooks: dxify-owned\n' "$PIN" \
  > "$OUT/BUILD-INFO.txt"
echo "    Integration payload ready in $OUT"
