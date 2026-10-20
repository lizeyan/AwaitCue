#!/usr/bin/env bash

set -euo pipefail

readonly threshold="${SWIFT_COVERAGE_THRESHOLD:-90}"
readonly bin_path="$(swift build --show-bin-path)"
readonly test_binary="${bin_path}/AwaitCuePackageTests.xctest/Contents/MacOS/AwaitCuePackageTests"
readonly profile="${bin_path}/codecov/default.profdata"
# AppKit overlay、真实桌面冻结和系统窗口顺序需要 TCC/真实桌面 smoke test；自动覆盖率只统计其可替换的业务 seam。
readonly ignore_regex='(.build|Tests|AwaitCueApp|resource_bundle_accessor|Placeholder|AppKitGlobalSelectionOverlayPresenter|FrozenScreenFrameProvider|CoreGraphicsWindowZOrderProvider)'

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
