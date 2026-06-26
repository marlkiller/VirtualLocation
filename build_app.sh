#!/bin/bash
set -euo pipefail

APP_NAME="VirtualLocation"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"

# Parse architecture argument: arm | intel | u2b
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
    arm|arm64|aarch64)   SWIFT_ARCH="arm64"  ;;
    intel|x86_64|amd64)  SWIFT_ARCH="x86_64" ;;
    u2b|universal)       SWIFT_ARCH="universal" ;;
    *) echo "Unknown arch: $ARCH (use arm, intel, or u2b)"; exit 1 ;;
esac

echo "🔨 Building $APP_NAME (arch: $SWIFT_ARCH) ..."

if [ "$SWIFT_ARCH" = "universal" ]; then
    swift build -c release --product "$APP_NAME" --arch arm64
    swift build -c release --product "$APP_NAME" --arch x86_64
    mkdir -p "$BUILD_DIR/release"
    lipo -create \
        "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" \
        "$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME" \
        -output "$BUILD_DIR/release/$APP_NAME"
else
    swift build -c release --product "$APP_NAME" --arch "$SWIFT_ARCH"
fi

RELEASE_BIN="$BUILD_DIR/release/$APP_NAME"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Creating $APP_NAME.app bundle ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$RELEASE_BIN" "$MACOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh</string>
        <string>en</string>
    </array>
</dict>
</plist>
EOF

echo "✅ Done: $APP_BUNDLE"
