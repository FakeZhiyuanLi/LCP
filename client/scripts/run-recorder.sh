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
app_directory="$client_directory/.build/manual/LCPRecorder.app"
contents_directory="$app_directory/Contents"
executable_directory="$contents_directory/MacOS"
architecture="$(uname -m)"

case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac

mkdir -p "$executable_directory"
cp "$client_directory/App/Info.plist" "$contents_directory/Info.plist"

xcrun swiftc \
    -swift-version 5 \
    -target "${architecture}-apple-macosx14.0" \
    -parse-as-library \
    "$client_directory/Sources/Audio/AudioConfig.swift" \
    "$client_directory/Sources/Storage/IngestManager.swift" \
    "$client_directory/Sources/Storage/ClassManifest.swift" \
    "$client_directory/Sources/Storage/RecordingManifest.swift" \
    "$client_directory/Sources/Audio/AudioRecorder.swift" \
    "$client_directory/Sources/Audio/MicrophoneCapture.swift" \
    "$client_directory/Sources/Audio/AudioLevelMeter.swift" \
    "$client_directory/Sources/Capture/CaptureLease.swift" \
    "$client_directory/Sources/Capture/CaptureCompatibility.swift" \
    "$client_directory/Sources/Capture/CaptureCoordinator.swift" \
    "$client_directory/App/LCPRecorderApp.swift" \
    -o "$executable_directory/LCPRecorder"

/usr/bin/plutil -lint "$contents_directory/Info.plist"
/usr/bin/codesign --force --sign - "$app_directory"
/usr/bin/codesign --verify --strict "$app_directory"
printf 'Built %s\n' "$app_directory"

if [[ "$build_only" == false ]]; then
    /usr/bin/open "$app_directory"
    printf 'Opened LCP Recorder in the menu bar.\n'
fi
