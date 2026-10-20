#!/usr/bin/env bash

set -euo pipefail

readonly threshold="${SWIFT_COVERAGE_THRESHOLD:-90}"
readonly bin_path="$(swift build --show-bin-path)"
readonly test_binary="${bin_path}/AwaitCuePackageTests.xctest/Contents/MacOS/AwaitCuePackageTests"
readonly profile="${bin_path}/codecov/default.profdata"
# 只排除必须依赖真实 TCC/桌面会话的薄系统适配文件；所有可替换的 Swift 业务 seam 都计入 90% 门禁。
# SwiftPM 测试二进制不会链接 AwaitCueApp/AwaitCueNativeHost executable，它们由 warnings-as-errors build 与人工 smoke 单独验证。
readonly ignore_regex='(.build|Tests|resource_bundle_accessor|Placeholder|AppKitGlobalSelectionOverlayPresenter|FrozenScreenFrameProvider|CoreGraphicsWindowZOrderProvider)'

swift test --enable-code-coverage

mkdir -p coverage
xcrun llvm-cov export "${test_binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex="${ignore_regex}" \
  -format=lcov > coverage/swift.lcov

report="$(xcrun llvm-cov report "${test_binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex="${ignore_regex}")"
printf '%s\n' "${report}"

read -r region function line < <(
  awk '/^TOTAL/ {
    gsub("%", "", $4);
    gsub("%", "", $7);
    gsub("%", "", $10);
    print $4, $7, $10;
  }' <<<"${report}"
)

for entry in "region:${region}" "function:${function}" "line:${line}"; do
  name="${entry%%:*}"
  value="${entry#*:}"
  if ! awk -v value="${value}" -v threshold="${threshold}" 'BEGIN { exit !(value + 0 >= threshold + 0) }'; then
    echo "Swift ${name} coverage ${value}% is below ${threshold}%" >&2
    exit 1
  fi
done

echo "Swift coverage gate passed: region=${region}% function=${function}% line=${line}%"
