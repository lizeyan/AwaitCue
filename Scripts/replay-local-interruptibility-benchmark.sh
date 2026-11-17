#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults_domain="${AWAITCUE_DEFAULTS_DOMAIN:-org.awaitcue.AwaitCue}"

# 与 App 和固定 live benchmark 共用配置；密钥只进入当前 Node 进程，不写入参数或报告。
AWAITCUE_BASE_URL="$(defaults read "${defaults_domain}" modelBaseURL)"
AWAITCUE_MODEL="$(defaults read "${defaults_domain}" modelName)"
AWAITCUE_API_KEY="$(security find-generic-password \
  -s org.awaitcue.model \
  -a default-responses-api-key \
  -w)"
export AWAITCUE_API_KEY

exec node "${repository_root}/Scripts/review-local-interruptibility-benchmark.mjs" \
  replay \
  --base-url "${AWAITCUE_BASE_URL}" \
  --model "${AWAITCUE_MODEL}" \
  "$@"
