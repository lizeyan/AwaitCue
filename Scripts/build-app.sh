#!/usr/bin/env bash

set -euo pipefail

readonly version="${VERSION:-0.1.0}"
readonly build_number="${BUILD_NUMBER:-1}"
readonly configuration="${CONFIGURATION:-release}"
readonly bin_path="$(swift build -c "${configuration}" --show-bin-path)"
readonly app_path="dist/AwaitCue.app"

swift build -c "${configuration}"

rm -rf "${app_path}"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Resources"
cp "${bin_path}/AwaitCue" "${app_path}/Contents/MacOS/AwaitCue"
cp "${bin_path}/AwaitCueNativeHost" "${app_path}/Contents/MacOS/AwaitCueNativeHost"
cp Config/Info.plist "${app_path}/Contents/Info.plist"

if [[ -d "${bin_path}/AwaitCue_AwaitCueApp.bundle" ]]; then
  cp -R "${bin_path}/AwaitCue_AwaitCueApp.bundle" "${app_path}/Contents/Resources/"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_path}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${app_path}/Contents/Info.plist"

echo "Built ${app_path}"
