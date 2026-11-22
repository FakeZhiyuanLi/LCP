#!/bin/bash
# Build-only manual hardware checkpoint. Never launches, installs or records.
set -euo pipefail
script_directory=$(cd "$(dirname "$0")" && pwd)
client_directory=$(cd "$script_directory/.." && pwd)
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(/usr/bin/uuidgen | cut -c1-8)"
if [ "$#" -gt 0 ]; then
  case "$1" in
    --run-id) run_id=${2:?Missing new run identifier}; shift 2 ;;
    --help|-h) printf '%s\n' 'Usage: build-capture-acceptance.sh [--run-id NEW_ID]' 'Builds two signed manual hosts and an isolated fixture. Never launches or accesses microphone.'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
fi
[ "$#" -eq 0 ] || { printf '%s\n' 'Unexpected arguments.' >&2; exit 2; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { printf '%s\n' 'Build on the target Apple Silicon Mac.' >&2; exit 1; }

fixture_root=$(python3 - "$run_id" <<'PY'
import datetime,json,os,re,sys,uuid
from pathlib import Path
run=sys.argv[1]
if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',run):raise SystemExit('Use 1–64 letters, numbers, underscores or hyphens for a new run ID.')
parent=Path.home()/'Library/Application Support/LCP Capture/Acceptance'
if parent.resolve()!=parent:raise SystemExit('Acceptance parent must not use symlinks.')
parent.mkdir(parents=True,mode=0o700,exist_ok=True)
parent.chmod(0o700)
root=parent/run
root.mkdir(mode=0o700) # Existing fixture must never be overwritten.
for name in ['Incoming','Events']: (root/name).mkdir(mode=0o700)
entries=[{'host':h,'attempt':n,'courseCode':f'LCPACCEPT_{h}_{n}','folderID':f'lcp_acceptance_{run}_{h}_{n}','classID':str(uuid.uuid4())} for h in ['A','B'] for n in range(1,9)]
fixture={'schemaVersion':1,'fictional':True,'runID':run,'entries':entries}
catalog={'version':1,'source':'google_drive','generated_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'root_folder_id':'synthetic_acceptance_only','classes':[{'name':e['courseCode'],'courseCode':e['courseCode'],'drive_folder_id':e['folderID']} for e in entries]}
for name,content in [('fixture.json',fixture),('classes.json',catalog)]:
 p=root/name;p.write_text(json.dumps(content,indent=2)+'\n');p.chmod(0o600)
print(root)
PY
)
build_root="$client_directory/.build/capture-acceptance/$run_id"
[ ! -e "$build_root" ] || { printf '%s\n' 'Build directory already exists; choose a new run.' >&2; exit 1; }
mkdir -p "$build_root"
chmod 700 "$build_root"
source_files=()
while IFS= read -r file; do source_files+=("$file"); done < <(python3 - "$client_directory" <<'PY'
from pathlib import Path
import sys
for p in sorted((Path(sys.argv[1])/'Sources').rglob('*.swift')):
 if p.is_file() and not p.is_symlink():print(p)
PY
)
python3 - "$client_directory" "$build_root/SourceHashes.before.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
source=Path(sys.argv[1]);files=sorted((source/'Sources').rglob('*.swift'))+[source/'Acceptance/CaptureAcceptanceApp.swift',source/'scripts/build-capture-acceptance.sh']
Path(sys.argv[2]).write_text(json.dumps({str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},sort_keys=True))
PY
xcrun swiftc -swift-version 5 -strict-concurrency=complete -target arm64-apple-macosx14.0 -parse-as-library \
  "${source_files[@]}" "$client_directory/Acceptance/CaptureAcceptanceApp.swift" -o "$build_root/LCPRecorder"

for host in A B; do
  app="$build_root/LCP Capture Acceptance $host.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$build_root/LCPRecorder" "$app/Contents/MacOS/LCPRecorder"
  python3 - "$app/Contents/Info.plist" "$host" "$run_id" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);host=sys.argv[2];run=sys.argv[3]
value={'CFBundleName':f'LCP Capture Acceptance {host}','CFBundleDisplayName':f'LCP Capture Acceptance {host}','CFBundleExecutable':'LCPRecorder','CFBundleIdentifier':f'dev.lcp.CaptureAcceptance{host}','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'Record a short manual LCP acceptance fixture only when you press Start. Audio remains in an isolated local folder.','LCPCaptureProtocolVersion':1,'LCPCaptureLeaseIdentifier':'org.lcp.capture.v1','LCPCaptureAcceptanceHost':host,'LCPCaptureAcceptanceRunID':run}
p.write_bytes(plistlib.dumps(value))
PY
  /usr/bin/plutil -lint "$app/Contents/Info.plist"
  /usr/bin/codesign --force --sign - --timestamp=none "$app"
  /usr/bin/codesign --verify --strict "$app"
done

python3 - "$client_directory" "$build_root" "$fixture_root" <<'PY'
import datetime,hashlib,json,plistlib,subprocess,sys
from pathlib import Path
source=Path(sys.argv[1]);build=Path(sys.argv[2]);fixture=Path(sys.argv[3])
files=sorted((source/'Sources').rglob('*.swift'))+[source/'Acceptance/CaptureAcceptanceApp.swift',source/'scripts/build-capture-acceptance.sh']
source_hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
assert source_hashes==json.loads((build/'SourceHashes.before.json').read_text()),'Source changed during compilation; preserve this attempt and rebuild under a new run ID.'
apps={}
for host in ['A','B']:
 app=build/f'LCP Capture Acceptance {host}.app';info=plistlib.loads((app/'Contents/Info.plist').read_bytes());exe=app/'Contents/MacOS/LCPRecorder'
 assert info['LCPCaptureProtocolVersion']==1 and info['LCPCaptureLeaseIdentifier']=='org.lcp.capture.v1'
 arch=subprocess.check_output(['/usr/bin/lipo','-archs',str(exe)],text=True).strip();assert arch=='arm64'
 apps[host]={'path':str(app),'bundleIdentifier':info['CFBundleIdentifier'],'architecture':arch,'executableSha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'signatureVerified':True}
receipt={'schemaVersion':1,'builtAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'machine':'Mac arm64','fixtureRoot':str(fixture),'sharedLease':str(Path.home()/'Library/Application Support/LCP Capture/capture.lock'),'captureAPI':'CaptureCoordinator','sourceHashes':source_hashes,'sourceUnchangedDuringBuild':True,'apps':apps,'launched':False,'microphoneRequested':False,'recordingsCreated':False,'distribution':'private ad-hoc signed manual acceptance build; not notarized'}
(build/'BuildReceipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Fixture: '+str(fixture))
print('Receipt: '+str(build/'BuildReceipt.json'))
for entry in apps.values():print('Mac Terminal: open '+__import__('shlex').quote(entry['path']))
PY
