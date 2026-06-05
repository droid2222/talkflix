#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ICON="${1:-$ROOT_DIR/assets/images/branding/app_icon_source.png}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -f "$SOURCE_ICON" ]]; then
  echo "Source icon not found: $SOURCE_ICON" >&2
  exit 1
fi

MASTER_RESIZED="$TMP_DIR/icon_resized.png"
MASTER_SQUARE="$TMP_DIR/icon_square_1024.png"
BACKGROUND_COLOR="292929"

sips -Z 1024 "$SOURCE_ICON" --out "$MASTER_RESIZED" >/dev/null
sips -p 1024 1024 --padColor "$BACKGROUND_COLOR" "$MASTER_RESIZED" --out "$MASTER_SQUARE" >/dev/null

generate_png() {
  local size="$1"
  local output="$2"
  mkdir -p "$(dirname "$output")"
  sips -z "$size" "$size" "$MASTER_SQUARE" --out "$output" >/dev/null
}

# iOS app icons
generate_png 40 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@2x.png"
generate_png 60 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@3x.png"
generate_png 29 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@1x.png"
generate_png 58 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@2x.png"
generate_png 87 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-29x29@3x.png"
generate_png 80 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@2x.png"
generate_png 120 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@3x.png"
generate_png 120 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@2x.png"
generate_png 180 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-60x60@3x.png"
generate_png 20 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-20x20@1x.png"
generate_png 40 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-40x40@1x.png"
generate_png 76 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@1x.png"
generate_png 152 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-76x76@2x.png"
generate_png 167 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-83.5x83.5@2x.png"
generate_png 1024 "$ROOT_DIR/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"

# iOS CallKit icon asset
generate_png 60 "$ROOT_DIR/ios/Runner/Assets.xcassets/CallKitLogo.imageset/CallKitLogo.png"
generate_png 120 "$ROOT_DIR/ios/Runner/Assets.xcassets/CallKitLogo.imageset/CallKitLogo@2x.png"
generate_png 180 "$ROOT_DIR/ios/Runner/Assets.xcassets/CallKitLogo.imageset/CallKitLogo@3x.png"

# Android launcher icons
generate_png 48 "$ROOT_DIR/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
generate_png 72 "$ROOT_DIR/android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
generate_png 96 "$ROOT_DIR/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png"
generate_png 144 "$ROOT_DIR/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png"
generate_png 192 "$ROOT_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"
generate_png 48 "$ROOT_DIR/android/app/src/main/res/mipmap-mdpi/ic_launcher_round.png"
generate_png 72 "$ROOT_DIR/android/app/src/main/res/mipmap-hdpi/ic_launcher_round.png"
generate_png 96 "$ROOT_DIR/android/app/src/main/res/mipmap-xhdpi/ic_launcher_round.png"
generate_png 144 "$ROOT_DIR/android/app/src/main/res/mipmap-xxhdpi/ic_launcher_round.png"
generate_png 192 "$ROOT_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png"

# macOS icons
generate_png 16 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_16.png"
generate_png 32 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png"
generate_png 64 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_64.png"
generate_png 128 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png"
generate_png 256 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png"
generate_png 512 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png"
generate_png 1024 "$ROOT_DIR/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"

# Web icons
generate_png 32 "$ROOT_DIR/web/favicon.png"
generate_png 192 "$ROOT_DIR/web/icons/Icon-192.png"
generate_png 512 "$ROOT_DIR/web/icons/Icon-512.png"
generate_png 192 "$ROOT_DIR/web/icons/Icon-maskable-192.png"
generate_png 512 "$ROOT_DIR/web/icons/Icon-maskable-512.png"

echo "Generated app icon assets from $SOURCE_ICON"
