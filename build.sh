#!/usr/bin/env bash
#
# Builds MyCallRec.app and packages it as a TrollStore-installable .tipa.
# Runs on macOS with Xcode command line tools. Used by CI and locally.
#
set -euo pipefail

APP_NAME="MyCallRec"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/Payload/$APP_NAME.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK_PATH"

echo "Compiling Swift sources..."
xcrun -sdk iphoneos swiftc \
  -target "arm64-apple-ios$DEPLOYMENT_TARGET" \
  -sdk "$SDK_PATH" \
  -O -swift-version 5 \
  -module-name "$APP_NAME" \
  -framework Foundation -framework UIKit -framework SwiftUI \
  -framework AudioToolbox -framework AVFAudio -framework AVFoundation \
  -framework MediaPlayer -framework CoreFoundation -framework CoreAudio \
  -o "$APP_DIR/$APP_NAME" \
  Sources/*.swift

cp Resources/Info.plist "$APP_DIR/Info.plist"
printf 'APPL????' > "$APP_DIR/PkgInfo"
chmod 755 "$APP_DIR/$APP_NAME"

echo "Signing with entitlements..."
if command -v ldid >/dev/null 2>&1; then
  ldid -S"$PWD/entitlements.plist" "$APP_DIR/$APP_NAME"
  echo "signed with ldid"
else
  # Fallback: ad-hoc signature carrying the same entitlements.
  # TrollStore re-signs on install, so the embedded entitlements are what matter.
  codesign --force --sign - --timestamp=none \
    --entitlements entitlements.plist "$APP_DIR/$APP_NAME"
  echo "signed with codesign (ad-hoc)"
fi

echo "Packaging tipa..."
(cd "$BUILD_DIR" && zip -qry "$APP_NAME.tipa" Payload)

echo "Done: $BUILD_DIR/$APP_NAME.tipa"
ls -la "$BUILD_DIR/$APP_NAME.tipa"
