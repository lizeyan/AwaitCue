#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults_domain="${AWAITCUE_DEFAULTS_DOMAIN:-org.awaitcue.AwaitCue}"
benchmark_directory="${AWAITCUE_BENCHMARK_OUTPUT_DIR:-${repository_root}/.local/benchmarks}"
report_path="${benchmark_directory}/interruptibility-$(date +%Y%m%d-%H%M%S).json"

# 密钥只进入当前 Node 进程的环境，不打印、不写入报告，也不出现在命令行参数中。
AWAITCUE_BASE_URL="$(defaults read "${defaults_domain}" modelBaseURL)"
AWAITCUE_MODEL="$(defaults read "${defaults_domain}" modelName)"
AWAITCUE_API_KEY="$(security find-generic-password \
  -s org.awaitcue.model \
  -a default-responses-api-key \
  -w)"
export AWAITCUE_BASE_URL AWAITCUE_MODEL AWAITCUE_API_KEY

mkdir -p "${benchmark_directory}"
printf 'AwaitCue interruptibility report: %s\n' "${report_path}" >&2

exec node "${repository_root}/Scripts/run-decision-benchmark.mjs" \
  --kind interruptibility \
  --output "${report_path}" \
  "$@"
