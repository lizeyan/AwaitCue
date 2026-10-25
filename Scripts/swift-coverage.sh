#!/usr/bin/env bash

set -euo pipefail

readonly threshold="${SWIFT_COVERAGE_THRESHOLD:-90}"
readonly bin_path="$(swift build --show-bin-path)"
readonly test_binary="${bin_path}/AwaitCuePackageTests.xctest/Contents/MacOS/AwaitCuePackageTests"
readonly profile="${bin_path}/codecov/default.profdata"
# App E2E target 会链接完整 AwaitCueApp；该 target 通过真实 AppKit 行为测试独立门禁，不把 TCC、
# NSWorkspace、UserNotifications 等不可替换系统适配代码混入可替换业务 seam 的 90% 覆盖率。
readonly ignore_regex='(.build|Tests|resource_bundle_accessor|Placeholder|Sources/AwaitCueApp|AppKitGlobalSelectionOverlayPresenter|FrozenScreenFrameProvider|CoreGraphicsWindowZOrderProvider)'
readonly full_ignore_regex='(.build|Tests|resource_bundle_accessor|Placeholder)'

swift test --enable-code-coverage

mkdir -p coverage
xcrun llvm-cov export "${test_binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex="${ignore_regex}" \
  -format=lcov > coverage/swift.lcov

# 同时导出不隐藏 AwaitCueApp/SwiftUI/system adapter 的全量清单。它不冒充 90% 业务 gate，
# 但让 App 层覆盖缺口在 CI artifact 中持续可见，后续只能通过新增行为测试缩小。
xcrun llvm-cov export "${test_binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex="${full_ignore_regex}" \
  -format=lcov > coverage/swift-all.lcov

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

full_report="$(xcrun llvm-cov report "${test_binary}" \
  -instr-profile="${profile}" \
  -ignore-filename-regex="${full_ignore_regex}" | awk '/^TOTAL/ { print }')"

echo "Swift core coverage gate passed: region=${region}% function=${function}% line=${line}%"
echo "Full Swift coverage inventory (includes App/UI/system adapters): ${full_report}"
