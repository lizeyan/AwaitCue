#!/usr/bin/env bash

set -euo pipefail

readonly version="${VERSION:-0.1.0}"
readonly build_number="${BUILD_NUMBER:-1}"
readonly configuration="${CONFIGURATION:-release}"
readonly bin_path="$(swift build -c "${configuration}" --show-bin-path)"
readonly app_path="dist/AwaitCue.app"

swift build -c "${configuration}"
if [[ "${AWAITCUE_SKIP_SAFARI_EXTENSION:-0}" != "1" ]]; then
  CONFIGURATION="${configuration}" \
  VERSION="${version}" \
  BUILD_NUMBER="${build_number}" \
  ./Scripts/build-safari-extension.sh
fi

rm -rf "${app_path}"
mkdir -p \
  "${app_path}/Contents/MacOS" \
  "${app_path}/Contents/Resources"
cp "${bin_path}/AwaitCue" "${app_path}/Contents/MacOS/AwaitCue"
cp "${bin_path}/AwaitCueNativeHost" "${app_path}/Contents/MacOS/AwaitCueNativeHost"
cp Config/Info.plist "${app_path}/Contents/Info.plist"

if [[ -d "${bin_path}/AwaitCue_AwaitCueApp.bundle" ]]; then
  # Xcode/SwiftPM 产物可能带有 com.apple.provenance。它属于本机执行状态，复制进
  # 正在重建的 App bundle 时 macOS 可能拒绝写入；发布物也不应该携带该扩展属性。
  cp -R -X "${bin_path}/AwaitCue_AwaitCueApp.bundle" "${app_path}/Contents/Resources/"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" "${app_path}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build_number}" "${app_path}/Contents/Info.plist"

# Chrome-only live E2E 不验证 Safari，显式开关可以避开 LaunchServices 对开发 appex 的锁；
# 默认发布与 CI 路径仍必须构建并嵌入 Safari extension。
if [[ "${AWAITCUE_SKIP_SAFARI_EXTENSION:-0}" != "1" ]]; then
  # 最后嵌入 .appex，避免 LaunchServices 在主 App plist 尚未完成时扫描半成品 bundle。
  mkdir -p "${app_path}/Contents/PlugIns"
  cp -R -X "dist/AwaitCueSafariExtension.appex" "${app_path}/Contents/PlugIns/"
fi

echo "Built ${app_path}"
