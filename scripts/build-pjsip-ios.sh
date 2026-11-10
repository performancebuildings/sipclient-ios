#!/bin/bash
# Builds Vendor/PJSIP.xcframework (static, ios-arm64 + ios-arm64-simulator).
#
# Source is upstream pjproject pinned to $SHA plus pjsip-patches/, not ../../pjsip:
# that tree is configured for Android, and in-tree configure would overwrite it.
# Each slice gets its own export, because device and simulator share a target name.
set -euo pipefail

SHA=d0cbf57aca90f4722194c4e0d94ef0b236bb2489
MIN_IOS_VERSION=16.0

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PATCHES=$PROJECT_DIR/pjsip-patches
VENDOR=$PROJECT_DIR/Vendor
ROOT=$VENDOR/.pjsip-build
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

mkdir -p "$ROOT"
if ! git -C "$ROOT/pjproject" cat-file -e "$SHA^{commit}" 2>/dev/null; then
  rm -rf "$ROOT/pjproject"
  git init -q "$ROOT/pjproject"
  git -C "$ROOT/pjproject" fetch -q --depth 1 https://github.com/pjsip/pjproject.git "$SHA"
fi

write_config_site() {
  cat > "$1" <<'CONFIG'
#define PJ_CONFIG_IPHONE                1
#define PJMEDIA_HAS_VIDEO               1
/* configure leaves VideoToolbox out, so it must be enabled here. */
#define PJMEDIA_HAS_VID_TOOLBOX_CODEC   1

/* Parity with the Android panels. Without this, pj_assert aborts,
 * because configure-iphone does not define NDEBUG. */
#define PJ_DEBUG                        0

/* No SRTP: the app doesn't use it, and leaving libsrtp out keeps the app
 * to Apple's own encryption, which is exempt from export documentation
 * (ITSAppUsesNonExemptEncryption is false in Info.plist). */
#define PJMEDIA_HAS_SRTP                0

/* Empty RTP every 5 s holds the NAT pinhole for receive-only video. */
#define PJMEDIA_STREAM_ENABLE_KA        PJMEDIA_STREAM_KA_EMPTY_RTP

#include <pj/config_site_sample.h>
CONFIG
}

for SLICE in device simulator; do
  case $SLICE in
    device)    PLAT=iPhoneOS;        MINFLAG=-miphoneos-version-min=$MIN_IOS_VERSION ;;
    simulator) PLAT=iPhoneSimulator; MINFLAG=-mios-simulator-version-min=$MIN_IOS_VERSION ;;
  esac
  SRC=$ROOT/src-$SLICE
  OUT=$ROOT/out-$SLICE
  rm -rf "$SRC" "$OUT"
  mkdir -p "$SRC"
  git -C "$ROOT/pjproject" archive "$SHA" | tar -x -C "$SRC"
  (
    cd "$SRC"
    for PATCH in "$PATCHES"/*.patch; do
      patch -p1 --forward < "$PATCH"
    done
    write_config_site pjlib/include/pj/config_site.h
    DEVPATH=$DEVELOPER_DIR/Platforms/$PLAT.platform/Developer \
    ARCH="-arch arm64" MIN_IOS="$MINFLAG" \
    CFLAGS="-O2 -g -Wno-unused-label" LDFLAGS="-O2" \
      ./configure-iphone --prefix="$OUT" --disable-darwin-ssl --disable-libsrtp \
        --enable-speex-resample
    # Speex (BSD) instead of the default libresample: libresample is LGPL,
    # which a statically linked, closed-source App Store build can't meet.
    make dep
    make -j"$(sysctl -n hw.ncpu)"
    make install
    libtool -static -o "$OUT/libpjproject.a" "$OUT"/lib/*.a 2>/dev/null
  )
done

rm -rf "$VENDOR/PJSIP.xcframework"
xcodebuild -create-xcframework \
  -library "$ROOT/out-device/libpjproject.a"    -headers "$ROOT/out-device/include" \
  -library "$ROOT/out-simulator/libpjproject.a" -headers "$ROOT/out-simulator/include" \
  -output "$VENDOR/PJSIP.xcframework"
