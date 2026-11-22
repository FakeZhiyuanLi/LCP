#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--build-only]\n' "$(basename "$0")"
}

build_only=false
case "${1:-}" in
    "") ;;
    --build-only) build_only=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
client_directory="$(cd -- "$script_directory/.." && pwd)"
app_directory="$client_directory/.build/manual/LCPRecorderTest.app"
executable_directory="$app_directory/Contents/MacOS"
architecture="$(uname -m)"

case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

mkdir -p "$executable_directory"

cat > "$app_directory/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.lcp.RecorderTest</string>
    <key>CFBundleName</key>
    <string>LCP Recorder Test</string>
    <key>CFBundleDisplayName</key>
    <string>LCP Recorder Test</string>
    <key>CFBundleExecutable</key>
    <string>LCPRecorderTest</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Record a short lecture audio sample to verify LCP recording.</string>
</dict>
</plist>
PLIST

xcrun swiftc \
    -swift-version 5 \
    -target "${architecture}-apple-macosx14.0" \
    -parse-as-library \
    "$client_directory/Sources/Audio/AudioConfig.swift" \
    "$client_directory/Sources/Storage/IngestManager.swift" \
    "$client_directory/Sources/Storage/RecordingManifest.swift" \
    "$client_directory/Sources/Audio/AudioRecorder.swift" \
    "$client_directory/Sources/Audio/MicrophoneCapture.swift" \
    "$client_directory/Tests/Manual/RecorderTestApp.swift" \
    -o "$executable_directory/LCPRecorderTest"

/usr/bin/plutil -lint "$app_directory/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_directory"
/usr/bin/codesign --verify --strict "$app_directory"
printf 'Built %s\n' "$app_directory"

if [[ "$build_only" == false ]]; then
    /usr/bin/open "$app_directory"
    printf 'Open the LCP Test microphone item in the menu bar to record.\n'
fi
