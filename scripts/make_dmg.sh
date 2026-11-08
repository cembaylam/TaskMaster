#!/bin/zsh
# Packages build/TaskMaster.app into build/TaskMaster.dmg (drag-to-Applications layout)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d build/TaskMaster.app ]] || ./scripts/build_app.sh
STAGE=build/dmg_stage
rm -rf "$STAGE" build/TaskMaster.dmg
mkdir -p "$STAGE"
cp -R build/TaskMaster.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TaskMaster" -srcfolder "$STAGE" -fs APFS -format UDZO -ov build/TaskMaster.dmg >/dev/null
rm -rf "$STAGE"
echo "Created build/TaskMaster.dmg"
