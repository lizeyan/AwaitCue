#!/usr/bin/env bash

set -euo pipefail

readonly prompt_path="dist/AwaitCue.app/Contents/Resources/AwaitCue_AwaitCueModel.bundle/interruptibility.txt"

# 签名 App 必须携带与 benchmark 共用的生产 prompt；开发目录里存在资源不能替代发布包验证。
if [[ ! -f "${prompt_path}" ]]; then
  echo "AwaitCue.app is missing the interruptibility prompt resource: ${prompt_path}" >&2
  exit 1
fi

echo "AwaitCue.app includes the interruptibility prompt resource."
