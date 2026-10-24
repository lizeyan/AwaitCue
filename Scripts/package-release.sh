#!/usr/bin/env bash

set -euo pipefail

readonly version="${VERSION:-0.1.0}"
readonly identity="${CODESIGN_IDENTITY:--}"
readonly app_path="dist/AwaitCue.app"
readonly safari_extension_path="${app_path}/Contents/PlugIns/AwaitCueSafariExtension.appex"
readonly dmg_path="dist/AwaitCue-${version}.dmg"
readonly staging_path="dist/dmg-root"
readonly app_group_identifier="group.org.awaitcue.shared"
readonly app_provisioning_profile="${APP_PROVISIONING_PROFILE:-}"
readonly safari_extension_provisioning_profile="${SAFARI_EXTENSION_PROVISIONING_PROFILE:-}"
readonly profile_validation_directory="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-profiles.XXXXXX")"

cleanup_profile_validation() {
  rm -rf "${profile_validation_directory}"
}
trap cleanup_profile_validation EXIT

validate_provisioning_profile() {
  local profile_path="$1"
  local bundle_identifier="$2"
  local label="$3"
  local decoded_path="${profile_validation_directory}/${label}.plist"
  local application_identifier

  if [[ ! -f "${profile_path}" ]]; then
    echo "${label} provisioning profile is missing: ${profile_path}" >&2
    return 1
  fi
  security cms -D -i "${profile_path}" > "${decoded_path}"
  application_identifier="$(
    plutil -extract Entitlements.application-identifier raw -o - "${decoded_path}"
  )"
  if [[ "${application_identifier}" != *."${bundle_identifier}" ]]; then
    echo "${label} provisioning profile does not match ${bundle_identifier}." >&2
    return 1
  fi
  if ! plutil -convert json -o - "${decoded_path}" \
      | jq -e --arg expected "${app_group_identifier}" \
          '.Entitlements["com.apple.security.application-groups"] | index($expected) != null' \
      >/dev/null
  then
    echo "${label} provisioning profile does not authorize ${app_group_identifier}." >&2
    return 1
  fi
}

validate_signed_app_group() {
  local bundle_path="$1"
  local label="$2"
  local entitlements_path="${profile_validation_directory}/${label}-signed-entitlements.plist"

  codesign -d --entitlements :- "${bundle_path}" > "${entitlements_path}" 2>/dev/null
  if ! plutil -convert json -o - "${entitlements_path}" \
      | jq -e --arg expected "${app_group_identifier}" \
          '.["com.apple.security.application-groups"] | index($expected) != null' \
      >/dev/null
  then
    echo "Signed ${label} does not contain ${app_group_identifier}." >&2
    return 1
  fi
}

./Scripts/build-app.sh

if [[ "${identity}" == "-" ]]; then
  # 纯 ad-hoc 签名默认以 cdhash 作为 designated requirement，每次构建都会让 TCC 授权失效。
  # 开发构建固定 identifier requirement；正式 Developer ID 流程仍使用证书提供的 requirement。
  codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.NativeHost \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue.NativeHost"' \
    --sign - "${app_path}/Contents/MacOS/AwaitCueNativeHost"
  codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.SafariExtension \
    --entitlements SafariExtension/NativeHandler/AwaitCueSafariExtension.entitlements \
    --sign - "${safari_extension_path}"
  pluginkit -r "${safari_extension_path}" >/dev/null 2>&1 || true
  codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue"' \
    --entitlements Config/AwaitCue.entitlements \
    --sign - "${app_path}"
else
  if [[ -z "${app_provisioning_profile}" || -z "${safari_extension_provisioning_profile}" ]]; then
    echo "Developer ID releases require APP_PROVISIONING_PROFILE and SAFARI_EXTENSION_PROVISIONING_PROFILE." >&2
    exit 1
  fi
  validate_provisioning_profile \
    "${app_provisioning_profile}" \
    "org.awaitcue.AwaitCue" \
    "AwaitCue"
  validate_provisioning_profile \
    "${safari_extension_provisioning_profile}" \
    "org.awaitcue.AwaitCue.SafariExtension" \
    "AwaitCueSafariExtension"
  # App Group entitlement 只有在对应 Developer ID profile 嵌入后才会被系统认可。
  cp -X "${app_provisioning_profile}" "${app_path}/Contents/embedded.provisionprofile"
  cp -X \
    "${safari_extension_provisioning_profile}" \
    "${safari_extension_path}/Contents/embedded.provisionprofile"
  codesign --force --options runtime \
    --sign "${identity}" "${app_path}/Contents/MacOS/AwaitCueNativeHost"
  codesign --force --options runtime \
    --entitlements SafariExtension/NativeHandler/AwaitCueSafariExtension.entitlements \
    --sign "${identity}" "${safari_extension_path}"
  pluginkit -r "${safari_extension_path}" >/dev/null 2>&1 || true
  codesign --force --options runtime \
    --entitlements Config/AwaitCue.entitlements \
    --sign "${identity}" "${app_path}"
fi
codesign --verify --deep --strict --verbose=2 "${app_path}"
validate_signed_app_group "${app_path}" "AwaitCue"
validate_signed_app_group "${safari_extension_path}" "AwaitCueSafariExtension"

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
