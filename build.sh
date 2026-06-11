#!/bin/bash
# Baut LANScan als installierbare .app und packt sie in ein DMG.
set -e
cd "$(dirname "$0")"

APP_NAME="LANScan"
BUNDLE_ID="ch.kalyro.lanscan"
VERSION="1.1"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"

echo "▸ Release-Build…"
swift build -c release

echo "▸ App-Bundle zusammenstellen…"
rm -rf "dist"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# Hersteller-Datenbank einbetten.
cp "Resources/oui.tsv" "${APP_DIR}/Contents/Resources/oui.tsv"

# Icon erzeugen (best effort).
echo "▸ Icon erzeugen…"
ICONSET="dist/AppIcon.iconset"
if swift makeicon.swift "$ICONSET" >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>LANScan durchsucht dein lokales Netzwerk nach verbundenen Geräten.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_services._dns-sd._udp</string>
        <string>_http._tcp</string>
        <string>_https._tcp</string>
        <string>_ssh._tcp</string>
        <string>_smb._tcp</string>
        <string>_ipp._tcp</string>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
        <string>_hap._tcp</string>
        <string>_googlecast._tcp</string>
        <string>_spotify-connect._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signieren…"
codesign --force --deep --sign - "${APP_DIR}" 2>/dev/null || true

echo "▸ DMG bauen…"
rm -f "${DMG_PATH}"
STAGING="dist/dmg"
mkdir -p "$STAGING"
cp -R "${APP_DIR}" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGING" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "$STAGING"

echo ""
echo "✓ Fertig:"
echo "  App: ${APP_DIR}"
echo "  DMG: ${DMG_PATH}"
