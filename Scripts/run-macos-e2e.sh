#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly app_path="${repository_root}/dist/AwaitCue.app"
readonly app_executable="${app_path}/Contents/MacOS/AwaitCue"
readonly native_host_executable="${app_path}/Contents/MacOS/AwaitCueNativeHost"

cd "${repository_root}"

# CI 安全层：使用真实 AppKit 窗口，不读取或修改用户 TCC 权限数据库。
swift test --filter AwaitCueAppE2ETests

if [[ "${1:-}" != "--live" ]]; then
    echo "macOS AppKit E2E passed. Run with --live for real shortcut and selection smoke."
    exit 0
fi

# 本机真实层必须由用户主动运行；只检查事件注入权限，绝不重置或伪造 TCC 授权。
# 屏幕录制权限属于 AwaitCue 进程，不能用当前终端的 CGPreflight 结果替代。
if ! swift -e 'import ApplicationServices; exit(AXIsProcessTrusted() ? 0 : 1)'; then
    echo "SKIP live selection: the current terminal does not have Accessibility permission."
    exit 0
fi

./Scripts/build-app.sh
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.NativeHost \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue.NativeHost"' \
    --sign - "${native_host_executable}"
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue"' \
    --entitlements Config/AwaitCue.entitlements \
    --sign - "${app_path}"

while IFS= read -r process_id; do
    [[ -n "${process_id}" ]] && kill "${process_id}"
done < <(pgrep -f "^${app_executable}( |$)" || true)
open "${app_path}"
sleep 2

skip_if_security_agent() {
    local frontmost_name=""
    local attempt
    # 应用切换期间 System Events 可能短暂无 frontmost 进程；有限重试，不能把竞态伪装成产品失败。
    for attempt in {1..20}; do
        frontmost_name="$(
            osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' \
                2>/dev/null || true
        )"
        [[ -n "${frontmost_name}" ]] && break
        sleep 0.1
    done
    local security_window_visible
    security_window_visible="$(swift - <<'SWIFT'
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []
let visible = windows.contains {
    ($0[kCGWindowOwnerName as String] as? String) == "SecurityAgent"
}
print(visible ? "yes" : "no")
SWIFT
)"
    if [[ "${frontmost_name}" == "SecurityAgent" || "${security_window_visible}" == "yes" ]]; then
        echo "SKIP live selection: macOS is waiting for the user to approve AwaitCue Keychain access. Approve it and rerun --live."
        exit 0
    fi
}
skip_if_security_agent

readonly fixture_path="$(mktemp -t awaitcue-macos-e2e)"
printf '%s\n' 'AwaitCue E2E fixture' 'Task finished. Waiting for user input.' > "${fixture_path}"
open -a TextEdit "${fixture_path}"
sleep 1

perform_frontmost_selection() {
    swift - <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

var entry: [String: Any]?
for _ in 0 ..< 50 {
    if let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        entry = windows.first(where: {
            (($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier)
                && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0)
        })
    }
    if entry != nil { break }
    Thread.sleep(forTimeInterval: 0.1)
}
guard let entry,
let bounds = entry[kCGWindowBounds as String] as? [String: NSNumber],
let x = bounds["X"]?.doubleValue,
let y = bounds["Y"]?.doubleValue,
let width = bounds["Width"]?.doubleValue,
let height = bounds["Height"]?.doubleValue
else {
    exit(3)
}

func postShortcut(keyDown: Bool) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: keyDown)!
    event.flags = [.maskControl, .maskShift]
    event.post(tap: .cghidEventTap)
}
postShortcut(keyDown: true)
postShortcut(keyDown: false)
Thread.sleep(forTimeInterval: 0.8)

let start = CGPoint(x: x + width * 0.15, y: y + height * 0.20)
let end = CGPoint(x: x + width * 0.85, y: y + height * 0.75)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)!
    .post(tap: .cghidEventTap)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)!
    .post(tap: .cghidEventTap)
for step in 1 ... 20 {
    let progress = CGFloat(step) / 20
    let point = CGPoint(
        x: start.x + (end.x - start.x) * progress,
        y: start.y + (end.y - start.y) * progress
    )
    CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDragged,
        mouseCursorPosition: point,
        mouseButton: .left
    )!.post(tap: .cghidEventTap)
}
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)!
    .post(tap: .cghidEventTap)
SWIFT
}

wait_for_creation_window() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

for _ in 0 ..< 50 {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    if let window = windows.first(where: {
        ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
            && ($0[kCGWindowName as String] as? String) == "创建 Hook"
    }),
    let identifier = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
    let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
    let width = bounds["Width"]?.doubleValue,
    let height = bounds["Height"]?.doubleValue,
    width >= 560,
    height >= 640
    {
        print(identifier)
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(4)
SWIFT
}

close_creation_window() {
    skip_if_security_agent
    osascript \
        -e 'tell application id "org.awaitcue.AwaitCue" to activate' \
        -e 'tell application "System Events" to keystroke "w" using command down'
    sleep 1
}

osascript -e 'tell application "TextEdit" to activate'
skip_if_security_agent
perform_frontmost_selection
readonly first_window_id="$(wait_for_creation_window)"
close_creation_window

osascript -e 'tell application "TextEdit" to activate'
skip_if_security_agent
perform_frontmost_selection
readonly second_window_id="$(wait_for_creation_window)"
if [[ "${first_window_id}" == "${second_window_id}" ]]; then
    echo "FAIL: user close did not create a fresh Hook window on the next selection."
    exit 5
fi
close_creation_window

if pgrep -f "^${native_host_executable}( |$)" >/dev/null; then
    open -a "Google Chrome" "https://example.com/"
    sleep 2
    osascript -e 'tell application "Google Chrome" to activate'
    perform_frontmost_selection
    wait_for_creation_window >/dev/null
    close_creation_window
else
    echo "SKIP live Chromium selection: AwaitCue Native Host is not connected."
fi

echo "macOS live E2E passed: TextEdit selection, close/reopen, and available Chromium selection."
