#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT/Dashboard"
npm ci --no-fund --no-audit
npm run build
cd "$TASK_ROOT"
swift build -c release   -Xswiftc -file-prefix-map -Xswiftc "$TASK_ROOT=/AgentBarBar"   -Xswiftc -debug-prefix-map -Xswiftc "$TASK_ROOT=/AgentBarBar"   -Xcc "-ffile-prefix-map=$TASK_ROOT=/AgentBarBar"

swift scripts/generate_icons.swift "$TASK_ROOT"
iconutil -c icns assets/AgentBarBar.iconset -o assets/AgentBarBar.icns
mkdir -p "$TASK_ROOT/build"
TASK_STAGE="$(mktemp -d "$TASK_ROOT/build/.release-XXXXXX")"
trap 'rm -rf "$TASK_STAGE"' EXIT
TASK_APP="$TASK_STAGE/AgentBarBar.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources/Dashboard"
cp .build/release/AgentBarBar "$TASK_APP/Contents/MacOS/AgentBarBar"
strip -S "$TASK_APP/Contents/MacOS/AgentBarBar"
rsync -a --delete Dashboard/dist/ "$TASK_APP/Contents/Resources/Dashboard/"
TASK_ICON="AgentBarBar.icns"
cp assets/AgentBarBar.icns "$TASK_APP/Contents/Resources/$TASK_ICON"
cp assets/THIRD_PARTY_NOTICES.txt "$TASK_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
mkdir -p "$TASK_APP/Contents/Resources/Licenses"
cp ThirdParty/zstd/LICENSE "$TASK_APP/Contents/Resources/Licenses/zstd-BSD.txt"
cp -R assets/MenuBar "$TASK_APP/Contents/Resources/"
TASK_VERSION="$(cat VERSION)" TASK_BUILD="$(cat BUILD_NUMBER)" TASK_APP="$TASK_APP" python3 - <<'PY'
import os,plistlib,pathlib
info={'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hans'],'CFBundleName':'AgentBarBar','CFBundleDisplayName':'AgentBarBar','CFBundleIdentifier':'app.agentbarbar.mac','CFBundleExecutable':'AgentBarBar','CFBundlePackageType':'APPL','CFBundleShortVersionString':os.environ['TASK_VERSION'],'CFBundleVersion':os.environ['TASK_BUILD'],'CFBundleIconFile':'AgentBarBar.icns','CFBundleInfoDictionaryVersion':'6.0','CFBundleSupportedPlatforms':['MacOSX'],'LSUIElement':True,'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication','NSHumanReadableCopyright':'Copyright © 2026 AgentBarBar contributors.','NSSupportsAutomaticTermination':False}
pathlib.Path(os.environ['TASK_APP'],'Contents','Info.plist').write_bytes(plistlib.dumps(info))
PY
xattr -cr "$TASK_APP"
if [[ -n "${AGENTBARBAR_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$AGENTBARBAR_SIGNING_IDENTITY" "$TASK_APP"
else
  codesign --force --sign - "$TASK_APP"
fi
codesign --verify --deep --strict "$TASK_APP"
python3 "$TASK_ROOT/scripts/audit_release.py" "$TASK_APP"
TASK_DEST="$TASK_ROOT/build/AgentBarBar.app"
if [[ -e "$TASK_DEST" ]]; then
  mkdir -p "$TASK_ROOT/build/build-backups"
  mv "$TASK_DEST" "$TASK_ROOT/build/build-backups/AgentBarBar-$(date +%Y%m%d%H%M%S)-$RANDOM.app"
fi
mv "$TASK_APP" "$TASK_DEST"
echo "Built $TASK_DEST"
