#!/usr/bin/env bash

set -euo pipefail

readonly requested_app_path="${1:-/Applications/AwaitCue.app}"
# Chrome Native Messaging 明确要求绝对 executable path；调用者从仓库根目录传入
# dist/AwaitCue.app 时也必须在落盘前规范化，不能把 shell 当前目录泄漏进 manifest。
readonly app_path="$(/usr/bin/python3 - "${requested_app_path}" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
readonly host_path="${app_path}/Contents/MacOS/AwaitCueNativeHost"
readonly host_name="org.awaitcue.native"

if [[ ! -x "${host_path}" ]]; then
  echo "Native host executable is missing: ${host_path}" >&2
  exit 1
fi

install_manifest() {
  local directory="$1"
  local extension_id="$2"
  local manifest
  local temporary
  if [[ ! "${extension_id}" =~ ^[a-p]{32}$ ]]; then
    echo "Invalid Chromium extension ID: ${extension_id}" >&2
    return 1
  fi
  mkdir -p "${directory}"
  manifest="${directory}/${host_name}.json"
  temporary="$(mktemp "${directory}/.${host_name}.XXXXXX")"
  chmod 600 "${temporary}"
  # 路径来自本机安装位置，可能包含空格、引号或反斜杠；必须由 JSON encoder
  # 负责转义，不能用字符串拼接生成 Native Messaging manifest。
  jq -n \
    --arg name "${host_name}" \
    --arg path "${host_path}" \
    --arg origin "chrome-extension://${extension_id}/" \
    '{
      name: $name,
      description: "AwaitCue local browser relay",
      path: $path,
      type: "stdio",
      allowed_origins: [$origin]
    }' > "${temporary}"
  mv "${temporary}" "${manifest}"
  echo "Installed ${manifest}"
}

installed=0
if [[ -n "${AWAITCUE_NATIVE_MESSAGING_DIRS:-}" ]]; then
  : "${AWAITCUE_EXTENSION_ID:?Set AWAITCUE_EXTENSION_ID when using custom test directories}"
  IFS=':' read -r -a custom_directories <<<"${AWAITCUE_NATIVE_MESSAGING_DIRS}"
  for directory in "${custom_directories[@]}"; do
    install_manifest "${directory}" "${AWAITCUE_EXTENSION_ID}"
    installed=1
  done
else
  if [[ -n "${AWAITCUE_CHROME_EXTENSION_ID:-}" ]]; then
    install_manifest "${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts" "${AWAITCUE_CHROME_EXTENSION_ID}"
    installed=1
  fi
  if [[ -n "${AWAITCUE_EDGE_EXTENSION_ID:-}" ]]; then
    install_manifest "${HOME}/Library/Application Support/Microsoft Edge/NativeMessagingHosts" "${AWAITCUE_EDGE_EXTENSION_ID}"
    installed=1
  fi
  if [[ -n "${AWAITCUE_CHROMIUM_EXTENSION_ID:-}" ]]; then
    install_manifest "${HOME}/Library/Application Support/Chromium/NativeMessagingHosts" "${AWAITCUE_CHROMIUM_EXTENSION_ID}"
    installed=1
  fi
  if [[ -n "${AWAITCUE_ARC_EXTENSION_ID:-}" ]]; then
    install_manifest "${HOME}/Library/Application Support/Arc/User Data/NativeMessagingHosts" "${AWAITCUE_ARC_EXTENSION_ID}"
    installed=1
  fi
fi

if [[ "${installed}" -ne 1 ]]; then
  echo "Set at least one browser-specific extension ID (CHROME, EDGE, CHROMIUM, or ARC)." >&2
  exit 1
fi
