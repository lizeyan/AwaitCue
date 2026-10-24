#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly app_path="${repository_root}/dist/AwaitCue.app"
readonly app_executable="${app_path}/Contents/MacOS/AwaitCue"
readonly native_host_executable="${app_path}/Contents/MacOS/AwaitCueNativeHost"
readonly safari_extension_path="${app_path}/Contents/PlugIns/AwaitCueSafariExtension.appex"
chromium_window_id=""

cd "${repository_root}"

# CI 安全层：使用真实 AppKit 窗口，不读取或修改用户 TCC 权限数据库。
swift test --filter AwaitCueAppE2ETests

if [[ "${1:-}" != "--live" ]]; then
    echo "macOS AppKit E2E passed. Run with --live for real shortcut and selection smoke."
    exit 0
fi

require_chromium=false
if [[ "${2:-}" == "--require-chromium" ]]; then
    require_chromium=true
elif [[ -n "${2:-}" ]]; then
    echo "Usage: $0 [--live [--require-chromium]]" >&2
    exit 2
fi

# 本机真实层必须由用户主动运行；只检查事件注入权限，绝不重置或伪造 TCC 授权。
# 屏幕录制权限属于 AwaitCue 进程，不能用当前终端的 CGPreflight 结果替代。
if ! swift -e 'import ApplicationServices; exit(AXIsProcessTrusted() ? 0 : 1)'; then
    echo "FAIL: live E2E requires Accessibility permission for the current terminal." >&2
    exit 11
fi

# live Chromium smoke 必须加载当前工作树构建出的扩展，不能让旧 service worker
# 与新 App 偶然完成握手后再把真实产品回归误报成普通超时。
npm --prefix BrowserExtension run build
./Scripts/build-app.sh
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.NativeHost \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue.NativeHost"' \
    --sign - "${native_host_executable}"
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.SafariExtension \
    --entitlements SafariExtension/NativeHandler/AwaitCueSafariExtension.entitlements \
    --sign - "${safari_extension_path}"
# Safari 会自动注册刚签名的 .appex 并锁住 containing app；发布路径签外层前先撤销构建目录注册。
pluginkit -r "${safari_extension_path}" >/dev/null 2>&1 || true
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue"' \
    --entitlements Config/AwaitCue.entitlements \
    --sign - "${app_path}"

if [[ "${require_chromium}" == true ]]; then
    # `--require-chromium` 是显式本机测试模式；受控重启会让 unpacked extension
    # 重新读取 BrowserExtension/dist，避免 Chrome 继续运行内存中的旧 MV3 worker。
    osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
    for _ in {1..100}; do
        LC_ALL=C pgrep -x "Google Chrome" >/dev/null || break
        sleep 0.1
    done
    open -a "Google Chrome"
    for _ in {1..100}; do
        LC_ALL=C pgrep -x "Google Chrome" >/dev/null && break
        sleep 0.1
    done
fi

for executable_path in "${app_executable}" "${native_host_executable}"; do
    while IFS= read -r process_id; do
        [[ -n "${process_id}" ]] && kill "${process_id}"
    done < <(pgrep -f "^${executable_path}( |$)" || true)
done
for _ in {1..50}; do
    if ! pgrep -f "^${app_executable}( |$)" >/dev/null \
        && ! pgrep -f "^${native_host_executable}( |$)" >/dev/null
    then
        break
    fi
    sleep 0.1
done
# Selection/window smoke 不依赖模型密钥；隔离 Keychain 可避免每次 ad-hoc 重签后出现新的 ACL 授权提示。
nohup env \
    AWAITCUE_E2E_SKIP_KEYCHAIN=1 \
    AWAITCUE_E2E_DIAGNOSTICS=1 \
    "${app_executable}" \
    > "${TMPDIR:-/tmp}/awaitcue-macos-e2e.log" 2>&1 &
readonly e2e_app_pid="$!"

cleanup_live_processes() {
    if [[ "${chromium_window_id}" =~ ^[0-9]+$ ]]; then
        osascript -e "tell application \"Google Chrome\" to close window id ${chromium_window_id}" \
            >/dev/null 2>&1 || true
    fi
    kill "${e2e_app_pid}" 2>/dev/null || true
    while IFS= read -r process_id; do
        [[ -n "${process_id}" ]] && kill "${process_id}" 2>/dev/null || true
    done < <(pgrep -f "^${native_host_executable}( |$)" || true)
}
# live E2E 使用隔离 Keychain 的测试进程；任何退出路径都必须清理，不能污染用户随后启动的正常实例。
trap cleanup_live_processes EXIT

sleep 2
if ! kill -0 "${e2e_app_pid}" 2>/dev/null; then
    echo "FAIL: AwaitCue E2E process exited before selection." >&2
    sed -n '1,160p' "${TMPDIR:-/tmp}/awaitcue-macos-e2e.log" >&2 || true
    exit 7
fi

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
import ApplicationServices
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
        echo "FAIL: macOS is waiting for AwaitCue Keychain approval; approve it and rerun --live." >&2
        exit 12
    fi
}
skip_if_security_agent

open_settings_from_menu_bar() {
    osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "AwaitCue"
        click menu bar item 1 of menu bar 2
        delay 0.1
        set menuWindow to first window
        set allElements to entire contents of menuWindow
        repeat with element in allElements
            try
                if role of element is "AXButton" and value of attribute "AXIdentifier" of element is "awaitcue.open-settings" then
                    -- 只计算用户点击设置按钮后的展示耗时；展开菜单和 AX 遍历属于测试驱动开销。
                    set startedAt to current date
                    click element
                    repeat 40 times
                        if exists window "AwaitCue 设置" then
                            return ((current date) - startedAt) as integer
                        end if
                        delay 0.05
                    end repeat
                    error "AwaitCue settings window did not appear"
                end if
            end try
        end repeat
        error "AwaitCue settings button is unavailable"
    end tell
end tell
APPLESCRIPT
}

wait_for_settings_window() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

let startedAt = ContinuousClock.now
for _ in 0 ..< 30 {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    if let window = windows.first(where: {
        ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
            && ($0[kCGWindowName as String] as? String) == "AwaitCue 设置"
    }),
    let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
    let width = bounds["Width"]?.doubleValue,
    let height = bounds["Height"]?.doubleValue,
    width >= 720,
    height >= 520
    {
        let elapsed = startedAt.duration(to: .now)
        guard elapsed < .seconds(2) else { exit(14) }
        print("settings appeared in \(elapsed)")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.05)
}
exit(13)
SWIFT
}

close_settings_window() {
    osascript \
        -e 'tell application id "org.awaitcue.AwaitCue" to activate' \
        -e 'tell application "System Events" to keystroke "w" using command down'
}

echo "E2E stage: real menu settings"
readonly settings_duration="$(open_settings_from_menu_bar)"
if (( settings_duration > 2 )); then
    echo "FAIL: settings took ${settings_duration}s to appear from the real menu action." >&2
    exit 14
fi
echo "settings appeared from the real menu action in ${settings_duration}s"
wait_for_settings_window
close_settings_window

open -a Calculator
sleep 1

activate_fixture_app() {
    open -a Calculator
    swift - <<'SWIFT'
import AppKit
import Foundation

for _ in 0 ..< 30 {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        == "com.apple.calculator"
    {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(8)
SWIFT
}

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
var overlayIsVisible = false
for _ in 0 ..< 5 {
    postShortcut(keyDown: true)
    postShortcut(keyDown: false)
    for _ in 0 ..< 30 {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        overlayIsVisible = windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
                && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 1_000
        }
        if overlayIsVisible { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    if overlayIsVisible { break }
    Thread.sleep(forTimeInterval: 0.3)
}
guard overlayIsVisible else { exit(9) }
Thread.sleep(forTimeInterval: 0.1)

let start = CGPoint(x: x + width * 0.15, y: y + height * 0.20)
let end = CGPoint(x: x + width * 0.85, y: y + height * 0.75)
func overlayVisible() -> Bool {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.contains {
        ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
            && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= 1_000
    }
}

func dragSelection() {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)!
        .post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)!
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
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
        Thread.sleep(forTimeInterval: 0.015)
    }
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)!
        .post(tap: .cghidEventTap)
}

for _ in 0 ..< 3 {
    dragSelection()
    for _ in 0 ..< 20 {
        if !overlayVisible() { exit(0) }
        Thread.sleep(forTimeInterval: 0.1)
    }
}
exit(11)
SWIFT
}

wait_for_creation_window() {
    swift - <<'SWIFT'
import ApplicationServices
import CoreGraphics
import Foundation

// Browser Target 首次解析允许 10 秒冷启动窗口；UI 驱动必须覆盖完整产品超时再下结论。
for _ in 0 ..< 150 {
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
    width >= 520,
    height >= 620
    {
        print(identifier)
        exit(0)
    }
    if let failure = windows.first(where: {
        ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
            && ($0[kCGWindowName as String] as? String) == "无法创建 Hook"
    }) {
        var reason = "unknown reason"
        if let processIdentifier = (failure[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value {
            let application = AXUIElementCreateApplication(processIdentifier)
            var rawWindows: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &rawWindows
            ) == .success,
            let accessibilityWindows = rawWindows as? [AXUIElement]
            {
                for accessibilityWindow in accessibilityWindows {
                    var rawTitle: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(
                        accessibilityWindow,
                        kAXTitleAttribute as CFString,
                        &rawTitle
                    )
                    guard (rawTitle as? String) == "无法创建 Hook" else { continue }
                    var rawDescription: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        accessibilityWindow,
                        kAXDescriptionAttribute as CFString,
                        &rawDescription
                    ) == .success,
                    let description = rawDescription as? String
                    {
                        reason = description
                    }
                }
            }
        }
        FileHandle.standardError.write(
            Data("FAIL: selection displayed a failure window (\(reason)): \(failure)\n".utf8)
        )
        exit(7)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
let remaining = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []
let awaitCueWindows = remaining.filter {
    ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
}
FileHandle.standardError.write(
    Data("FAIL: creation window did not appear; AwaitCue windows: \(awaitCueWindows)\n".utf8)
)
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

wait_for_creation_window_to_close() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

for _ in 0 ..< 50 {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let stillVisible = windows.contains {
        ($0[kCGWindowOwnerName as String] as? String) == "AwaitCue"
            && ($0[kCGWindowName as String] as? String) == "创建 Hook"
    }
    if !stillVisible { exit(0) }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(6)
SWIFT
}

echo "E2E stage: Calculator selection 1"
activate_fixture_app
skip_if_security_agent
perform_frontmost_selection
wait_for_creation_window >/dev/null
close_creation_window
wait_for_creation_window_to_close

echo "E2E stage: Calculator selection 2"
activate_fixture_app
skip_if_security_agent
perform_frontmost_selection
wait_for_creation_window >/dev/null
close_creation_window
wait_for_creation_window_to_close

chromium_status="skipped"
echo "E2E stage: Chromium selection"
chromium_window_id="$(osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "Google Chrome"
    set testWindow to make new window
    set URL of active tab of testWindow to "https://example.com/"
    set index of testWindow to 1
    activate
    return id of testWindow
end tell
APPLESCRIPT
)"
if [[ "${chromium_window_id}" =~ ^[0-9]+$ ]]; then
    for _ in {1..50}; do
        LC_ALL=C pgrep -f "^${native_host_executable}( |$)" >/dev/null && break
        sleep 0.1
    done
fi
if LC_ALL=C pgrep -f "^${native_host_executable}( |$)" >/dev/null; then
    # Native Host 进程出现早于 loopback token 认证和 ping/pong 完成；给双向握手一个有限稳定窗口。
    sleep 1.5
    swift - <<'SWIFT'
import AppKit
import Foundation

for _ in 0 ..< 50 {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" {
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(10)
SWIFT
    perform_frontmost_selection
    wait_for_creation_window >/dev/null
    if [[ -n "${AWAITCUE_E2E_CAPTURE_PATH:-}" ]]; then
        screencapture -x "${AWAITCUE_E2E_CAPTURE_PATH}"
    fi
    close_creation_window
    wait_for_creation_window_to_close
    chromium_status="passed"
else
    if [[ "${require_chromium}" == true ]]; then
        echo "FAIL: Chromium is required, but AwaitCue Native Host is not connected." >&2
        exit 15
    fi
    echo "SKIP live Chromium selection: AwaitCue Native Host is not connected."
fi

if [[ "${require_chromium}" == true && "${chromium_status}" != "passed" ]]; then
    echo "FAIL: required Chromium selection did not pass." >&2
    exit 16
fi

echo "macOS live E2E passed: real settings, Calculator selection and close/reopen; Chromium=${chromium_status}."
