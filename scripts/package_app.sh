#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-DriveDrop}"
PRODUCT_NAME="DriveDrop"
BUNDLE_ID="${BUNDLE_ID:-com.local.drivedrop}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"

cd "$ROOT_DIR"

if [[ ! -f "$ICON_FILE" && -f "$ROOT_DIR/scripts/generate_app_icon.swift" ]]; then
  echo "Generating app icon..."
  swift "$ROOT_DIR/scripts/generate_app_icon.swift"
fi

echo "Building release binary..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path | tail -n 1)"
BIN_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Release binary not found: $BIN_PATH" >&2
  exit 1
fi

echo "Creating app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

install -m 755 "$BIN_PATH" "$MACOS_DIR/$PRODUCT_NAME"
if command -v strip >/dev/null 2>&1; then
  strip -S -x "$MACOS_DIR/$PRODUCT_NAME"
fi
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <true/>
  <key>NSSupportsSuddenTermination</key>
  <true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>DriveDrop 需要访问你拖入的桌面文件，以便迁移到移动硬盘。</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>DriveDrop 需要访问你拖入的文稿文件，以便迁移到移动硬盘。</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>DriveDrop 需要访问你拖入的下载文件，以便迁移到移动硬盘。</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>DriveDrop 需要写入移动硬盘来完成文件迁移。</string>
</dict>
</plist>
PLIST

if [[ -f "$ROOT_DIR/README.md" ]]; then
  cp "$ROOT_DIR/README.md" "$RESOURCES_DIR/README.md"
fi

if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_PATH" >/dev/null
codesign --verify --deep --strict "$APP_PATH"

echo "Creating zip archive..."
rm -f "$DIST_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/$APP_NAME.zip"

echo "Packaged:"
echo "  $APP_PATH"
echo "  $DIST_DIR/$APP_NAME.zip"
