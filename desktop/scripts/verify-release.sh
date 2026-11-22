#!/bin/bash
# Static bundle verification only: never opens an app or the microphone.
set -euo pipefail
desktop_root=$(cd "$(dirname "$0")/.." && pwd)
app_path="$desktop_root/build/Release/LCP Desktop.app"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app_path=${2:?Missing app path}; shift 2 ;;
    --help|-h) printf '%s\n' 'Usage: verify-release.sh [--app /path/to/LCP Desktop.app]' 'Checks arm64 binaries, local signature and product metadata without launching.'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -d "$app_path" ] || { printf 'Missing app: %s\n' "$app_path" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app_path"
for binary in "$app_path/Contents/MacOS/LCPDesktop" "$app_path/Contents/Helpers/LCPAgentBridge"; do
  [ -x "$binary" ] || { printf 'Missing executable: %s\n' "$binary" >&2; exit 1; }
  [ "$(/usr/bin/lipo -archs "$binary")" = arm64 ] || { printf 'Unexpected architecture: %s\n' "$binary" >&2; exit 1; }
done
python3 - "$app_path" <<'PY'
from pathlib import Path
import hashlib,json,plistlib,subprocess,sys,tempfile
app=Path(sys.argv[1]);info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info.get('CFBundleIdentifier')=='org.lcp.Desktop','Unexpected bundle identifier'
assert info.get('CFBundleExecutable')=='LCPDesktop','Unexpected executable name'
assert info.get('CFBundlePackageType')=='APPL','Expected native app bundle'
assert not info.get('LSUIElement',False),'Desktop must have a Dock and normal windows'
assert info.get('NSMicrophoneUsageDescription'),'Missing microphone usage explanation'
assert 'lcp' in [s for entry in info.get('CFBundleURLTypes',[]) for s in entry.get('CFBundleURLSchemes',[])],'Missing lcp citation URL scheme'
assert float('.'.join(str(info.get('LSMinimumSystemVersion','0')).split('.')[:2]))>=14,'Expected macOS14 minimum'
receipt=app/'Contents/Resources/BuildReceipt.json'
if receipt.exists():
    data=json.loads(receipt.read_text());assert data['bundle_id']=='org.lcp.Desktop';assert data['architecture']=='arm64';assert data.get('source_files')
if 'CFBundleIconFile' in info or int(info['CFBundleVersion']) >= 12:
    assert info.get('CFBundleIconFile') == 'LCP.icns', 'Missing app icon registration'
    icon = app / 'Contents/Resources/LCP.icns'
    if receipt.exists():
        expected = data['source_files'].get('desktop/Resources/LCP.icns')
        assert hashlib.sha256(icon.read_bytes()).hexdigest() == expected, 'Bundled icon differs from the build receipt'
    with tempfile.TemporaryDirectory() as scratch:
        iconset = Path(scratch) / 'LCP.iconset'
        subprocess.run(['/usr/bin/iconutil', '--convert', 'iconset', '--output', iconset, icon], check=True)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = '@2x' if scale == 2 else ''
                image = (iconset / f'icon_{size}x{size}{suffix}.png').read_bytes()
                assert image.startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid app icon representation'
                width = int.from_bytes(image[16:20], 'big')
                height = int.from_bytes(image[20:24], 'big')
                assert width == height == size * scale, 'Incorrect app icon dimensions'
print('Verified native arm64 bundle, helper, signature, Dock presence and citation registration.')
PY
