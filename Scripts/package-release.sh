#!/usr/bin/env bash

set -euo pipefail

readonly version="${VERSION:-0.1.0}"
readonly identity="${CODESIGN_IDENTITY:--}"
readonly app_path="dist/AwaitCue.app"
readonly dmg_path="dist/AwaitCue-${version}.dmg"
readonly staging_path="dist/dmg-root"

./Scripts/build-app.sh

if [[ "${identity}" == "-" ]]; then
  # 纯 ad-hoc 签名默认以 cdhash 作为 designated requirement，每次构建都会让 TCC 授权失效。
  # 开发构建固定 identifier requirement；正式 Developer ID 流程仍使用证书提供的 requirement。
  codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.NativeHost \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue.NativeHost"' \
    --sign - "${app_path}/Contents/MacOS/AwaitCueNativeHost"
  codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue"' \
    --entitlements Config/AwaitCue.entitlements \
    --sign - "${app_path}"
else
  codesign --force --deep --options runtime \
    --entitlements Config/AwaitCue.entitlements \
    --sign "${identity}" "${app_path}"
fi
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
