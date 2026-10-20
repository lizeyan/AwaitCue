#!/usr/bin/env bash

set -euo pipefail

readonly version="${VERSION:-0.1.0}"
readonly identity="${CODESIGN_IDENTITY:--}"
readonly app_path="dist/AwaitCue.app"
readonly dmg_path="dist/AwaitCue-${version}.dmg"
readonly staging_path="dist/dmg-root"

./Scripts/build-app.sh

codesign --force --deep --options runtime \
  --entitlements Config/AwaitCue.entitlements \
  --sign "${identity}" "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"

rm -rf "${staging_path}" "${dmg_path}"
mkdir -p "${staging_path}"
cp -R "${app_path}" "${staging_path}/AwaitCue.app"
ln -s /Applications "${staging_path}/Applications"

hdiutil create \
  -volname "AwaitCue" \
  -srcfolder "${staging_path}" \
  -ov \
  -format UDZO \
  "${dmg_path}"

rm -rf "${staging_path}"
echo "Packaged ${dmg_path}"
