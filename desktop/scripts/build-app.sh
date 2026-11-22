#!/bin/bash
# Build only. This script never installs, launches, quits or records with an app.
set -euo pipefail

desktop_root=$(cd "$(dirname "$0")/.." && pwd)
configuration=Release
output_directory=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --configuration) configuration=${2:?Missing Debug or Release}; shift 2 ;;
    --output-directory) output_directory=${2:?Missing staging directory}; shift 2 ;;
    --help|-h)
      printf '%s\n' 'Usage: build-app.sh [--configuration Debug|Release] [--output-directory STAGING_DIRECTORY]' 'Builds arm64 LCP Desktop and bundled stdio helper. Never installs or launches.'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
output_directory=${output_directory:-"$desktop_root/build/$configuration"}
case "$configuration" in Debug|Release) ;; *) printf '%s\n' 'Configuration must be Debug or Release.' >&2; exit 2 ;; esac
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'Run this script on the target Mac.' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { printf '%s\n' 'This release builds for the Apple Silicon Mac (arm64).' >&2; exit 1; }

output_directory=$(python3 - "$output_directory" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]).expanduser().resolve()
for forbidden in [Path('/Applications'), Path.home()/'Applications', Path.home()/'Library'/'Application Support']:
    if p == forbidden or forbidden in p.parents:
        raise SystemExit('Choose a staging directory outside Applications and Application Support.')
print(p)
PY
)
mkdir -p "$output_directory"
app_destination="$output_directory/LCP Desktop.app"
if [ -e "$app_destination/Contents/MacOS/LCPDesktop" ] && /usr/sbin/lsof -t "$app_destination/Contents/MacOS/LCPDesktop" >/dev/null 2>&1; then
  printf '%s\n' 'The app at the staging destination is in use. Choose a different staging directory.' >&2
  exit 1
fi
build_directory="$desktop_root/.build/xcode-packaging-$configuration"
receipt=$(mktemp -t lcp-build-receipt)
staging_directory=$(mktemp -d "$output_directory/.lcp-build.XXXXXX")
trap 'rm -f "$receipt"; rm -rf "$staging_directory"' EXIT

# Capture exact source bytes before compilation; refuse a misleading receipt if
# another source writer changes them during the build.
python3 - "$desktop_root" "$receipt" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path(sys.argv[1]); repo=root.parent
files=[]
for base in [root/'Sources',root/'Resources',root/'scripts',root/'LCPDesktop.xcodeproj',repo/'client'/'Sources']:
    if not base.exists():continue
    for p in base.rglob('*'):
        if p.is_file() and not p.is_symlink() and not any(x in {'xcuserdata','.build','project.xcworkspace','__pycache__','.DS_Store'} for x in p.parts):files.append(p)
for p in [root/'Package.swift',repo/'client'/'Package.swift']:
    if p.exists():files.append(p)
record={'schema_version':1,'bundle_id':'org.lcp.Desktop','architecture':'arm64','source_files':{str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(files))}}
try:
    record['git_head']=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
    record['git_dirty']=bool(subprocess.check_output(['git','-C',str(repo),'status','--porcelain'],text=True))
except subprocess.CalledProcessError:
    record['git_head']=None;record['git_dirty']=None
Path(sys.argv[2]).write_text(json.dumps(record,indent=2)+'\n')
PY
xcodebuild -quiet -jobs 2 -project "$desktop_root/LCPDesktop.xcodeproj" \
  -scheme LCPDesktop -configuration "$configuration" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$build_directory" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_ALLOWED=YES \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build
built_app="$build_directory/Build/Products/$configuration/LCP Desktop.app"
[ -d "$built_app" ] || { printf '%s\n' 'Xcode did not produce the expected application bundle.' >&2; exit 1; }
/usr/bin/ditto "$built_app" "$staging_directory/LCP Desktop.app"
mkdir -p "$staging_directory/LCP Desktop.app/Contents/Resources"
python3 - "$desktop_root" "$receipt" "$configuration" <<'PY'
from pathlib import Path
import datetime,hashlib,json,subprocess,sys
root=Path(sys.argv[1]);record=json.loads(Path(sys.argv[2]).read_text())
current_files=[]
for base in [root/'Sources',root/'Resources',root/'scripts',root/'LCPDesktop.xcodeproj',root.parent/'client'/'Sources']:
    if not base.exists():continue
    for p in base.rglob('*'):
        if p.is_file() and not p.is_symlink() and not any(x in {'xcuserdata','.build','project.xcworkspace','__pycache__','.DS_Store'} for x in p.parts):current_files.append(p)
for p in [root/'Package.swift',root.parent/'client'/'Package.swift']:
    if p.exists():current_files.append(p)
if {str(p.relative_to(root.parent)) for p in current_files} != set(record['source_files']):
    raise SystemExit('Source files were added or removed during build. Rebuild after source writers finish.')
for rel,digest in record['source_files'].items():
    p=root.parent/rel
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
        raise SystemExit('Source changed during build: '+rel+'. Rebuild after source writers finish.')
record['built_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
record['configuration']=sys.argv[3]
record['macos']=subprocess.check_output(['/usr/bin/sw_vers','-productVersion'],text=True).strip()
record['xcode']=subprocess.check_output(['xcodebuild','-version'],text=True).strip()
record['swift']=subprocess.check_output(['xcrun','swift','--version'],text=True).strip()
record['signing']='ad-hoc local development; not notarized'
record['validation']='Build receipt only. Test and manual verification are reported separately.'
Path(sys.argv[2]).write_text(json.dumps(record,indent=2)+'\n')
PY
cp "$receipt" "$staging_directory/LCP Desktop.app/Contents/Resources/BuildReceipt.json"
if [ "$configuration" = Release ]; then
  # Mach-O debug-map records contain the full paths to the builder's object files.
  # The separate build products retain their symbols for local debugging.
  /usr/bin/strip -S "$staging_directory/LCP Desktop.app/Contents/MacOS/LCPDesktop"
  bridge="$staging_directory/LCP Desktop.app/Contents/Helpers/LCPAgentBridge"
  /usr/bin/strip -S "$bridge"
  # SwiftPM also embeds its specific toolchain directory. The distributed
  # helper uses the Swift libraries supplied by macOS.
  python3 - "$bridge" <<'PY'
import subprocess, sys
binary = sys.argv[1]
for line in subprocess.check_output(['/usr/bin/otool', '-l', binary], text=True).splitlines():
    entry = line.strip()
    if entry.startswith('path ') and '.xctoolchain/usr/lib/swift' in entry:
        path = entry[5:].rsplit(' (offset ', 1)[0]
        subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', path, binary], check=True)
PY
fi
/usr/bin/codesign --force --sign - --timestamp=none "$staging_directory/LCP Desktop.app/Contents/Helpers/LCPAgentBridge"
/usr/bin/codesign --force --sign - --timestamp=none "$staging_directory/LCP Desktop.app"
"$desktop_root/scripts/verify-release.sh" --app "$staging_directory/LCP Desktop.app"
# Only the caller-selected staging copy is replaced. The installed recorder is
# never read, replaced, stopped or launched by packaging.
if [ -e "$app_destination" ]; then
  if /usr/sbin/lsof -t "$app_destination/Contents/MacOS/LCPDesktop" >/dev/null 2>&1; then
    printf '%s\n' 'Staging application became active; preserving it. Choose another directory.' >&2
    exit 1
  fi
  retired_destination="$output_directory/LCP Desktop.previous.$(date -u +%Y%m%dT%H%M%SZ).app"
  [ ! -e "$retired_destination" ] || { printf '%s\n' 'Previous staging backup already exists.' >&2; exit 1; }
  mv "$app_destination" "$retired_destination"
fi
mv "$staging_directory/LCP Desktop.app" "$app_destination"
printf 'Built app: %s\n' "$app_destination"
printf 'Receipt: %s\n' "$app_destination/Contents/Resources/BuildReceipt.json"
