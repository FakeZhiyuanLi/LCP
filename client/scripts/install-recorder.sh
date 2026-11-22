#!/bin/bash
set -euo pipefail

usage() {
    printf 'Usage: %s [--build-only]\n' "$(basename "$0")"
    printf '\nBuilds LCP Recorder and installs it at ~/Applications/LCP Recorder.app.\n'
    printf 'Requires all LCP recorder and desktop hosts to be fully closed.\n'
    printf -- '--build-only installs without opening; run-recorder.sh --build-only only builds.\n'
    printf 'Use macOS System Settings > General > Login Items to launch it at login.\n'
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
source_app="$client_directory/.build/manual/LCPRecorder.app"
install_directory="$HOME/Applications"
install_app="$install_directory/LCP Recorder.app"
temporary_app="$install_directory/.LCP Recorder.app.tmp.$$"

require_closed_hosts() {
    if /usr/bin/pgrep -x LCPRecorder >/dev/null || /usr/bin/pgrep -x LCPDesktop >/dev/null; then
        printf 'Installation blocked: an LCP Recorder or Desktop process is running.\n' >&2
        printf 'Leave active recordings running. Follow docs/capture-migration.md after finalization.\n' >&2
        exit 1
    fi
}

require_closed_hosts
"$client_directory/scripts/run-recorder.sh" --build-only
mkdir -p "$install_directory"
rm -rf "$temporary_app"
trap 'rm -rf "$temporary_app"' EXIT

/usr/bin/ditto "$source_app" "$temporary_app"
/usr/bin/codesign --verify --strict "$temporary_app"
require_closed_hosts
rm -rf "$install_app"
mv "$temporary_app" "$install_app"
trap - EXIT

printf 'Installed %s\n' "$install_app"
printf 'Add it to Login Items in System Settings if it should start automatically.\n'
if [[ "$build_only" == false ]]; then
    /usr/bin/open "$install_app"
    printf 'Opened LCP Recorder in the menu bar.\n'
fi
