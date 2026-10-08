#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TypstEdit"
APP_DESTINATION="${APP_OUTPUT:-.build/TypstEdit.app}"
APP_ARCH="${APP_ARCH:-$(uname -m)}"
if [ -n "${BUNDLE_EXECUTABLE:-}" ]; then
    EXECUTABLE="$BUNDLE_EXECUTABLE"
else
    echo "Building optimized $APP_ARCH application..."
    swift build -c release --arch "$APP_ARCH" "$@"
    BUILD_DIR="$(swift build -c release --arch "$APP_ARCH" --show-bin-path "$@")"
    EXECUTABLE="$BUILD_DIR/$APP_NAME"
fi
case "$APP_ARCH" in
    arm64) TYPST_BINARY="typst-aarch64-apple-darwin/typst" ;;
    x86_64) TYPST_BINARY="typst-x86_64-apple-darwin/typst" ;;
    universal) TYPST_BINARY="typst-universal" ;;
    *) echo "Unsupported architecture: $APP_ARCH" >&2; exit 1 ;;
esac
# Validate inputs before replacing a prior generated bundle.
test -x "$EXECUTABLE"
test -x "$TYPST_BINARY"
# Build/sign outside Finder-managed or iCloud folders, which may reattach metadata
# between xattr cleanup and codesign. Publish only the completed bundle.
BUNDLE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/typstedit-bundle.XXXXXX")"
trap 'rm -rf "$BUNDLE_STAGE"' EXIT
APP_BUNDLE="$BUNDLE_STAGE/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/bin"
cp -X "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -X "$TYPST_BINARY" "$APP_BUNDLE/Contents/Resources/bin/typst"
chmod +x "$APP_BUNDLE/Contents/Resources/bin/typst"

# Icon Handling
# Priority: Use existing AppIcon.icns if available, otherwise generate from icon.png
if [ -f "AppIcon.icns" ]; then
    echo "Using custom AppIcon.icns..."
    cp -X "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
elif [ -f "icon.png" ]; then
    echo "Generating App Icon from icon.png..."
    ICONSET="AppIcon.iconset"
    mkdir -p "$ICONSET"
    
    # Ensure source is PNG
    sips -s format png "icon.png" --out "icon_source.png" > /dev/null
    
    # Generate sizes
    sips -z 16 16     "icon_source.png" --out "$ICONSET/icon_16x16.png" > /dev/null
    sips -z 32 32     "icon_source.png" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "icon_source.png" --out "$ICONSET/icon_32x32.png" > /dev/null
    sips -z 64 64     "icon_source.png" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "icon_source.png" --out "$ICONSET/icon_128x128.png" > /dev/null
    sips -z 256 256   "icon_source.png" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "icon_source.png" --out "$ICONSET/icon_256x256.png" > /dev/null
    sips -z 512 512   "icon_source.png" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "icon_source.png" --out "$ICONSET/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "icon_source.png" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
    
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    rm -f "icon_source.png"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.supermegafort.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>Typst document</string>
        <key>CFBundleTypeExtensions</key><array><string>typ</string></array>
        <key>CFBundleTypeRole</key><string>Editor</string>
    </dict></array>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Finder metadata and resource forks are not signable bundle resources.
xattr -dr com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - "$APP_BUNDLE"
mkdir -p "$(dirname "$APP_DESTINATION")"
ditto --norsrc "$APP_BUNDLE" "$APP_DESTINATION"
echo "Done! App is located at $APP_DESTINATION"
