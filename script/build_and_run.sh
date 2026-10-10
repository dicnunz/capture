#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME="Capture"
CAPTURE_CONFIGURATION="${CAPTURE_CONFIGURATION:-debug}"
BUNDLE="$ROOT_DIR/outputs/Capture.app"
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "Capture is running. Quit Capture from its menu bar before rebuilding; active recordings will finish and save." >&2
  exit 1
fi
swift build -c "$CAPTURE_CONFIGURATION"
BUILD_BINARY="$(swift build -c "$CAPTURE_CONFIGURATION" --show-bin-path)/$APP_NAME"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Capture</string>
<key>CFBundleIdentifier</key><string>local.nic.Capture</string>
<key>CFBundleName</key><string>Capture</string>
<key>CFBundleDisplayName</key><string>Capture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Capture screenshots and recordings of the screen, with audio from your chosen app.</string>
<key>NSMicrophoneUsageDescription</key><string>Record microphone audio when you choose Microphone as the audio source.</string>
<key>CFBundleIconFile</key><string>Capture</string>
</dict></plist>
PLIST
cp "$ROOT_DIR/Resources/Capture.icns" "$BUNDLE/Contents/Resources/Capture.icns"
# Stable local identity keeps macOS privacy permission attached to the bundle.
codesign --force --sign - --identifier local.nic.Capture -r='designated => identifier "local.nic.Capture"' "$BUNDLE" >/dev/null
case "$MODE" in
  run) /usr/bin/open -n "$BUNDLE" ;;
  --verify) /usr/bin/open -n "$BUNDLE"; sleep 1; pgrep -x Capture ;;
  --debug) lldb -- "$BUNDLE/Contents/MacOS/Capture" ;;
  --logs) /usr/bin/open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Capture"' ;;
  --telemetry) /usr/bin/open -n "$BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.nic.Capture"' ;;
  --build-only) : ;;
  *) echo "usage: $0 [run|--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2 ;;
esac
