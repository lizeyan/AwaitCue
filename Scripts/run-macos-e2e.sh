#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "$0")/.." && pwd)"
readonly app_path="${repository_root}/dist/AwaitCue.app"
readonly app_executable="${app_path}/Contents/MacOS/AwaitCue"
readonly native_host_executable="${app_path}/Contents/MacOS/AwaitCueNativeHost"
readonly safari_extension_path="${app_path}/Contents/PlugIns/AwaitCueSafariExtension.appex"
chromium_window_id=""
e2e_app_pid=""
fixture_server_pid=""
e2e_data_directory=""
fixture_port=""
model_request_log=""
chromium_extension_id=""

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

# 锁屏时 SecurityAgent 会隐藏菜单栏和窗口的辅助功能树；继续执行只会把系统状态
# 误报成 AwaitCue 设置或框选失败，因此在触碰任何用户界面前给出准确的恢复动作。
if ! swift - <<'SWIFT'
import CoreGraphics
import Foundation

let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
let isLocked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
exit(isLocked ? 1 : 0)
SWIFT
then
    echo "FAIL: live E2E requires the Mac to be unlocked." >&2
    exit 12
fi

# 本机真实层必须由用户主动运行；只检查事件注入权限，绝不重置或伪造 TCC 授权。
# 屏幕录制权限属于 AwaitCue 进程，不能用当前终端的 CGPreflight 结果替代。
if ! swift -e 'import ApplicationServices; exit(AXIsProcessTrusted() ? 0 : 1)'; then
    echo "FAIL: live E2E requires Accessibility permission for the current terminal." >&2
    exit 11
fi

# live Chromium smoke 必须加载当前工作树构建出的扩展，不能让旧 service worker
# 与新 App 偶然完成握手后再把真实产品回归误报成普通超时。
# Chrome 留在后台时会在旧 Host 被终止后立即重连；必须先退出浏览器，避免它在
# build-app 覆盖 bundle 的中途重新执行 Native Host 并锁住 Info.plist 或签名目标。
if [[ "${require_chromium}" == true ]]; then
    osascript -e 'tell application "Google Chrome" to quit' >/dev/null 2>&1 || true
    for _ in {1..100}; do
        LC_ALL=C pgrep -x "Google Chrome" >/dev/null || break
        sleep 0.1
    done
fi
# 上一轮 App 或 Safari appex 仍在运行/注册时，macOS 会拒绝覆盖 bundle；必须先释放构建目标。
for executable_path in "${app_executable}" "${native_host_executable}"; do
    while IFS= read -r process_id; do
        [[ -n "${process_id}" ]] && kill "${process_id}" 2>/dev/null || true
    done < <(LC_ALL=C pgrep -f "^${executable_path}( |$)" || true)
done
if [[ -d "${safari_extension_path}" ]]; then
    pluginkit -r "${safari_extension_path}" >/dev/null 2>&1 || true
fi
npm --prefix BrowserExtension run build
AWAITCUE_SKIP_SAFARI_EXTENSION=1 ./Scripts/build-app.sh
test -x "${app_executable}"
test -x "${native_host_executable}"
test ! -e "${safari_extension_path}"
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue.NativeHost \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue.NativeHost"' \
    --sign - "${native_host_executable}"
codesign --force --options runtime \
    --identifier org.awaitcue.AwaitCue \
    --requirements '=designated => identifier "org.awaitcue.AwaitCue"' \
    --entitlements Config/AwaitCue.entitlements \
    --sign - "${app_path}"

if [[ "${require_chromium}" == true ]]; then
    # `--require-chromium` 是显式本机测试模式；受控重启会让 unpacked extension
    # 重新读取 BrowserExtension/dist，避免 Chrome 继续运行内存中的旧 MV3 worker。
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

# 真实 Hook 创建会写 SQLite；每次 live E2E 使用独立临时目录，绝不能读取或污染用户 Hook。
e2e_data_directory="$(mktemp -d "${TMPDIR:-/tmp}/awaitcue-live-e2e.XXXXXX")"
model_request_log="${e2e_data_directory}/model-requests.jsonl"

cleanup_live_processes() {
    if [[ "${chromium_window_id}" =~ ^[0-9]+$ ]]; then
        osascript -e "tell application \"Google Chrome\" to close window id ${chromium_window_id}" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "${e2e_app_pid}" ]]; then
        kill "${e2e_app_pid}" 2>/dev/null || true
        wait "${e2e_app_pid}" 2>/dev/null || true
    fi
    if [[ -n "${fixture_server_pid}" ]]; then
        kill "${fixture_server_pid}" 2>/dev/null || true
        wait "${fixture_server_pid}" 2>/dev/null || true
    fi
    while IFS= read -r process_id; do
        [[ -n "${process_id}" ]] && kill "${process_id}" 2>/dev/null || true
    done < <(pgrep -f "^${native_host_executable}( |$)" || true)
    if [[ -n "${e2e_data_directory}" && -d "${e2e_data_directory}" ]]; then
        rm -rf "${e2e_data_directory}"
    fi
}
# fixture、隔离数据库、测试 App 与 Native Host 必须覆盖任何提前退出路径。
trap cleanup_live_processes EXIT

start_chromium_fixture_server() {
    fixture_port="$(/usr/bin/python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
    /usr/bin/python3 "${repository_root}/Tests/Fixtures/ChromeE2E/server.py" \
        --port "${fixture_port}" \
        --directory "${repository_root}/Tests/Fixtures/ChromeE2E" \
        --request-log "${model_request_log}" \
        > "${TMPDIR:-/tmp}/awaitcue-chrome-fixture.log" 2>&1 &
    fixture_server_pid="$!"
    for _ in {1..50}; do
        if curl --fail --silent "http://127.0.0.1:${fixture_port}/health" >/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: local Chrome fixture and Responses server did not become ready." >&2
    sed -n '1,120p' "${TMPDIR:-/tmp}/awaitcue-chrome-fixture.log" >&2 || true
    return 1
}

start_chromium_fixture_server

launch_e2e_app() {
    # 条件链路只连接本机 fixture model；隔离 Keychain 可避免 ad-hoc 重签触发 ACL 提示。
    nohup env \
        AWAITCUE_E2E=1 \
        AWAITCUE_E2E_DATA_DIRECTORY="${e2e_data_directory}" \
        AWAITCUE_E2E_SKIP_KEYCHAIN=1 \
        AWAITCUE_E2E_MODEL_BASE_URL="http://127.0.0.1:${fixture_port}/v1" \
        AWAITCUE_E2E_MODEL_API_KEY="awaitcue-e2e-key" \
        AWAITCUE_E2E_MODEL="awaitcue-e2e-decision" \
        AWAITCUE_E2E_DIAGNOSTICS=1 \
        "${app_executable}" \
        > "${TMPDIR:-/tmp}/awaitcue-macos-e2e.log" 2>&1 &
    e2e_app_pid="$!"
}

set_awaitcue_menu_visibility() {
    local expected_visibility="$1"
    swift - "${e2e_app_pid}" "${expected_visibility}" <<'SWIFT'
import ApplicationServices
import Darwin
import Foundation

let processID = pid_t(CommandLine.arguments[1])!
let shouldBeVisible = CommandLine.arguments[2] == "visible"
let application = AXUIElementCreateApplication(processID)

func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

func text(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

for _ in 0 ..< 600 {
    guard kill(processID, 0) == 0 else { exit(2) }
    let isVisible = !elements(application, attribute: kAXWindowsAttribute as CFString).isEmpty
    if isVisible == shouldBeVisible { exit(0) }
    let menuBars = elements(application, attribute: kAXChildrenAttribute as CFString)
        .filter { text($0, attribute: kAXRoleAttribute as CFString) == kAXMenuBarRole as String }
    let statusItem = menuBars.compactMap { menuBar -> AXUIElement? in
        let items = elements(menuBar, attribute: kAXChildrenAttribute as CFString)
            .filter { text($0, attribute: kAXRoleAttribute as CFString) == kAXMenuBarItemRole as String }
        // MenuBarExtra 的状态栏独占一条 AXMenuBar；主应用菜单包含多个普通菜单项。
        return items.count == 1 ? items[0] : nil
    }.first
    if let statusItem,
       AXUIElementPerformAction(statusItem, kAXPressAction as CFString) == .success
    {
        for _ in 0 ..< 50 {
            let updatedVisibility = !elements(
                application,
                attribute: kAXWindowsAttribute as CFString
            ).isEmpty
            if updatedVisibility == shouldBeVisible { exit(0) }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
FileHandle.standardError.write(Data("AwaitCue status item did not reach the requested visibility\n".utf8))
exit(1)
SWIFT
}

open_awaitcue_menu() {
    set_awaitcue_menu_visibility visible
}

close_awaitcue_menu() {
    set_awaitcue_menu_visibility hidden
}

wait_for_e2e_app_ready() {
    local log_path="${TMPDIR:-/tmp}/awaitcue-macos-e2e.log"
    if ! open_awaitcue_menu; then
        echo "FAIL: AwaitCue menu-bar item did not become operable within 60 seconds." >&2
        sed -n '1,160p' "${log_path}" >&2 || true
        return 1
    fi
    close_awaitcue_menu
}

launch_e2e_app

wait_for_e2e_app_ready

reload_current_chromium_extension() {
    local native_manifest="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts/org.awaitcue.native.json"
    if [[ ! -f "${native_manifest}" ]]; then
        echo "FAIL: Chrome Native Messaging manifest is missing: ${native_manifest}" >&2
        return 1
    fi
    chromium_extension_id="$(/usr/bin/python3 - "${native_manifest}" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)
origins = manifest.get("allowed_origins", [])
match = re.fullmatch(r"chrome-extension://([a-p]{32})/", origins[0] if origins else "")
if match:
    print(match.group(1))
PY
)"
    if [[ ! "${chromium_extension_id}" =~ ^[a-p]{32}$ ]]; then
        echo "FAIL: Chrome Native Messaging manifest has no valid AwaitCue extension ID." >&2
        return 1
    fi

    local secure_preferences="${HOME}/Library/Application Support/Google/Chrome/Default/Secure Preferences"
    local loaded_extension_path
    loaded_extension_path="$(/usr/bin/python3 - "${secure_preferences}" "${chromium_extension_id}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as preferences_file:
    settings = json.load(preferences_file).get("extensions", {}).get("settings", {})
path = settings.get(sys.argv[2], {}).get("path", "")
if path:
    print(os.path.realpath(path))
PY
)"
    local expected_extension_path
    expected_extension_path="$(cd "${repository_root}/BrowserExtension/dist" && pwd -P)"
    if [[ "${loaded_extension_path}" != "${expected_extension_path}" ]]; then
        echo "FAIL: Chrome extension ${chromium_extension_id} is loaded from '${loaded_extension_path}', expected '${expected_extension_path}'." >&2
        return 1
    fi

    local native_manifest_directory
    native_manifest_directory="$(dirname "${native_manifest}")"
    AWAITCUE_NATIVE_MESSAGING_DIRS="${native_manifest_directory}" \
    AWAITCUE_EXTENSION_ID="${chromium_extension_id}" \
        ./Scripts/install-native-host.sh "${app_path}" >/dev/null
    local installed_host_path
    installed_host_path="$(/usr/bin/python3 - "${native_manifest}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as manifest_file:
    print(json.load(manifest_file).get("path", ""))
PY
)"
    if [[ "${installed_host_path}" != "${native_host_executable}" ]]; then
        echo "FAIL: Native Messaging manifest points to stale host: ${installed_host_path}" >&2
        return 1
    fi
    if [[ "$(stat -f '%Lp' "${native_manifest}")" != "600" ]]; then
        echo "FAIL: Native Messaging manifest must be mode 0600." >&2
        return 1
    fi

    local reload_result
    reload_result="$(osascript - "${chromium_extension_id}" <<'APPLESCRIPT'
on run argv
    set extensionID to item 1 of argv
    tell application "Google Chrome"
        set extensionWindow to make new window
        set URL of active tab of extensionWindow to "chrome://extensions/?id=" & extensionID
        activate
        set reloadResult to "missing"
        repeat 50 times
            set reloadResult to execute active tab of extensionWindow javascript "(() => { const manager=document.querySelector('extensions-manager'); const detail=manager?.shadowRoot?.querySelector('extensions-detail-view'); const button=detail?.shadowRoot?.querySelector('#dev-reload-button'); if(!button) return 'missing'; button.click(); return 'reloaded'; })()"
            if reloadResult is "reloaded" then exit repeat
            delay 0.1
        end repeat
        delay 0.5
        close extensionWindow
        return reloadResult
    end tell
end run
APPLESCRIPT
)"
    if [[ "${reload_result}" != "reloaded" ]]; then
        echo "FAIL: current unpacked AwaitCue extension could not be reloaded (result=${reload_result})." >&2
        return 1
    fi
}

if [[ "${require_chromium}" == true ]]; then
    if [[ "${AWAITCUE_E2E_SKIP_CHROMIUM_REPAIR:-0}" == "1" ]]; then
        native_manifest="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts/org.awaitcue.native.json"
        if [[ ! -f "${native_manifest}" ]]; then
            echo "FAIL: no-repair E2E requires an existing Native Messaging manifest." >&2
            exit 19
        fi
        installed_host_path="$(jq -r '.path // ""' "${native_manifest}")"
        if [[ "${installed_host_path}" != "${native_host_executable}" ]]; then
            echo "FAIL: no-repair E2E found stale Native Host path: ${installed_host_path}" >&2
            exit 19
        fi
        echo "E2E stage: using existing Chromium installation without manifest repair or extension reload"
    elif [[ "${AWAITCUE_E2E_SKIP_EXTENSION_RELOAD:-0}" == "1" ]]; then
        # 本轮已经在构建扩展后完整退出并重启 Chrome；再次点 reload 会制造无意义的第二次断连，
        # 真实生命周期测试可以直接使用冷启动加载的当前 dist，同时继续执行全部 Hook 场景。
        echo "E2E stage: using Chrome cold-started current extension without a second reload"
    else
        reload_current_chromium_extension
    fi
fi

open_settings_from_menu_bar() {
    open_awaitcue_menu
    osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "AwaitCue"
        repeat 50 times
            if exists window 1 then
                set menuWindow to first window
                set allElements to entire contents of menuWindow
                repeat with element in allElements
                    try
                        if role of element is "AXButton" and value of attribute "AXIdentifier" of element is "awaitcue.open-settings" then
                            -- 激活 App 会关闭 MenuBarExtra；保持现有弹窗并直接执行按钮动作。
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
            end if
            delay 0.1
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

verify_real_model_settings() {
    osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "AwaitCue"
        set settingsWindow to window "AwaitCue 设置"
        set allElements to entire contents of settingsWindow
        set expectedIdentifiers to {¬
            "awaitcue.settings.model-base-url", ¬
            "awaitcue.settings.api-key", ¬
            "awaitcue.settings.model-name", ¬
            "awaitcue.settings.confirm-hostname", ¬
            "awaitcue.settings.delete-model", ¬
            "awaitcue.settings.test-model"¬
        }
        repeat with expectedIdentifier in expectedIdentifiers
            set expectedIdentifierText to expectedIdentifier as text
            set matched to false
            repeat with element in allElements
                try
                    if value of attribute "AXIdentifier" of element is expectedIdentifierText then
                        set matched to true
                        exit repeat
                    end if
                end try
            end repeat
            if not matched then error "missing model setting control: " & expectedIdentifierText
        end repeat
    end tell
end tell
APPLESCRIPT
}

close_settings_window() {
    osascript \
        -e 'tell application id "org.awaitcue.AwaitCue" to activate' \
        -e 'tell application "System Events" to keystroke "w" using command down'
}

if [[ "${AWAITCUE_E2E_CHROME_ONLY:-0}" != "1" ]]; then
    echo "E2E stage: real menu settings"
    settings_duration="$(open_settings_from_menu_bar)" || {
        echo "FAIL: settings could not be opened from the real menu action." >&2
        exit 13
    }
    readonly settings_duration
    if (( settings_duration > 2 )); then
        echo "FAIL: settings took ${settings_duration}s to appear from the real menu action." >&2
        exit 14
    fi
    echo "settings appeared from the real menu action in ${settings_duration}s"
    wait_for_settings_window
    verify_real_model_settings
    close_settings_window
else
    echo "E2E stage: skip already-validated settings and Calculator stages"
fi

open -a Calculator
sleep 1

activate_fixture_app() {
    open -a Calculator
    swift - <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

guard let calculator = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.calculator"
).first else {
    exit(8)
}
calculator.activate()

let application = AXUIElementCreateApplication(calculator.processIdentifier)
var rawWindows: CFTypeRef?
for _ in 0 ..< 30 {
    if AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &rawWindows
    ) == .success,
    let window = (rawWindows as? [AXUIElement])?.first
    {
        let display = CGDisplayBounds(CGMainDisplayID())
        // 用户可能把 Calculator 留在跨显示器位置；真实框选测试先把 fixture
        // 放进主显示器安全区域，不能把个人窗口布局冒充产品失败。
        var position = CGPoint(x: display.minX + 100, y: display.minY + 100)
        var size = CGSize(
            width: min(420, display.width - 200),
            height: min(560, display.height - 200)
        )
        if let positionValue = AXValueCreate(.cgPoint, &position),
           let sizeValue = AXValueCreate(.cgSize, &size)
        {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                sizeValue
            )
        }
        break
    }
    Thread.sleep(forTimeInterval: 0.1)
}

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
    local top_fraction="${1:-0.20}"
    local left_fraction="${2:-0.15}"
    local right_fraction="${3:-0.85}"
    swift - "${top_fraction}" "${left_fraction}" "${right_fraction}" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

guard let topFraction = Double(CommandLine.arguments[1]),
      let leftFraction = Double(CommandLine.arguments[2]),
      let rightFraction = Double(CommandLine.arguments[3])
else { exit(12) }
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

let start = CGPoint(x: x + width * leftFraction, y: y + height * topFraction)
let end = CGPoint(x: x + width * rightFraction, y: y + height * 0.75)
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

verify_real_creation_form() {
    osascript - "${AWAITCUE_E2E_REQUIRE_EXPANDED_SELECTION:-0}" <<'APPLESCRIPT'
on run argv
set requireExpandedSelection to (item 1 of argv is "1")
tell application "System Events"
    tell process "AwaitCue"
        set frontmost to true
        set formWindow to window "创建 Hook"
        perform action "AXRaise" of formWindow
        set allElements to entire contents of formWindow
        set seenIdentifiers to {}
        repeat with element in allElements
            try
                set identifier to value of attribute "AXIdentifier" of element
                if identifier is not missing value and identifier is not "" then set end of seenIdentifiers to identifier
            end try
        end repeat
        set expectedIdentifiers to {¬
            "awaitcue.hook.target-summary", ¬
            "awaitcue.hook.target-title", ¬
            "awaitcue.hook.kind", ¬
            "awaitcue.hook.kind.delay", ¬
            "awaitcue.hook.title", ¬
            "awaitcue.hook.condition", ¬
            "awaitcue.hook.analyze", ¬
            "awaitcue.hook.cancel"¬
        }
        if requireExpandedSelection then set end of expectedIdentifiers to "awaitcue.hook.expanded-selection-warning"
        repeat with expectedIdentifier in expectedIdentifiers
            set expectedIdentifierText to expectedIdentifier as text
            set matched to false
            repeat with element in allElements
                try
                    if value of attribute "AXIdentifier" of element is expectedIdentifierText then
                        set matched to true
                        exit repeat
                    end if
                end try
            end repeat
            if not matched then error "missing creation control: " & expectedIdentifierText & "; seen=" & seenIdentifiers
        end repeat

        set targetTitle to missing value
        repeat with element in allElements
            try
                if value of attribute "AXIdentifier" of element is "awaitcue.hook.target-title" then
                    set targetTitle to value of element
                    exit repeat
                end if
            end try
        end repeat
        if targetTitle does not contain "AwaitCue Chrome E2E Target" then
            error "unexpected browser target title: " & targetTitle
        end if
    end tell
end tell
end run
APPLESCRIPT
}

create_delay_hook_from_form() {
    osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "AwaitCue"
        set frontmost to true
        set formWindow to window "创建 Hook"
        perform action "AXRaise" of formWindow
        set allElements to entire contents of formWindow
        repeat with element in allElements
            try
                if value of attribute "AXIdentifier" of element is "awaitcue.hook.kind.delay" then
                    click element
                    exit repeat
                end if
            end try
        end repeat
        delay 0.2
        set allElements to entire contents of formWindow
        repeat with element in allElements
            try
                if value of attribute "AXIdentifier" of element is "awaitcue.hook.create" then
                    click element
                    return
                end if
            end try
        end repeat
        error "delay Hook create button is unavailable"
    end tell
end tell
APPLESCRIPT
}

set_condition_text_through_accessibility() {
    local accessibility_diagnostic
    if ! accessibility_diagnostic="$(swift - "${e2e_app_pid}" 2>&1 <<'SWIFT'
import ApplicationServices
import Foundation

let application = AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!)
let condition = "AWAITCUE_E2E_STATUS_COMPLETE"

func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return []
    }
    return value as? [AXUIElement] ?? []
}

func text(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value as? String
}

func descendant(identifier: String) -> AXUIElement? {
    var queue = elements(application, attribute: kAXChildrenAttribute as CFString)
    var visited = 0
    while !queue.isEmpty, visited < 2_000 {
        let element = queue.removeFirst()
        visited += 1
        if text(element, attribute: kAXIdentifierAttribute as CFString) == identifier {
            return element
        }
        queue.append(contentsOf: elements(element, attribute: kAXChildrenAttribute as CFString))
    }
    return nil
}

guard let identifiedField = descendant(identifier: "awaitcue.hook.condition") else {
    FileHandle.standardError.write(Data("Condition AX element is missing\n".utf8))
    exit(3)
}
var fieldCandidates = [identifiedField]
var candidateIndex = 0
while candidateIndex < fieldCandidates.count, fieldCandidates.count < 100 {
    fieldCandidates.append(contentsOf: elements(
        fieldCandidates[candidateIndex],
        attribute: kAXChildrenAttribute as CFString
    ))
    candidateIndex += 1
}
let field = fieldCandidates.first { candidate in
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
        candidate,
        kAXValueAttribute as CFString,
        &settable
    ) == .success && settable.boolValue
}
guard let field else {
    let role = text(identifiedField, attribute: kAXRoleAttribute as CFString) ?? "unknown"
    FileHandle.standardError.write(Data("Condition AXValue is not settable; role=\(role)\n".utf8))
    exit(4)
}
_ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
let setResult = AXUIElementSetAttributeValue(
    field,
    kAXValueAttribute as CFString,
    condition as CFString
)
guard setResult == .success else {
    FileHandle.standardError.write(Data("Condition AXValue write failed: \(setResult.rawValue)\n".utf8))
    exit(5)
}

for _ in 0 ..< 50 {
    if text(field, attribute: kAXValueAttribute as CFString) == condition,
       let analyze = descendant(identifier: "awaitcue.hook.analyze")
    {
        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            analyze,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success,
        (enabledValue as? NSNumber)?.boolValue == true
        {
            exit(0)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}
let actualValue = text(field, attribute: kAXValueAttribute as CFString) ?? "missing"
let analyzeExists = descendant(identifier: "awaitcue.hook.analyze") != nil
FileHandle.standardError.write(
    Data("Condition did not enable analysis; value=\(actualValue), analyzeExists=\(analyzeExists)\n".utf8)
)
exit(6)
SWIFT
    )"
    then
        echo "FAIL: Condition accessibility input failed: ${accessibility_diagnostic}" >&2
        return 1
    fi
}

create_condition_hook_from_form() {
    set_condition_text_through_accessibility
    osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "AwaitCue"
        set formWindow to window "创建 Hook"
        set allElements to entire contents of formWindow
        set conditionField to missing value
        set analyzeButton to missing value
        repeat with element in allElements
            try
                set identifier to value of attribute "AXIdentifier" of element
                if identifier is "awaitcue.hook.condition" then set conditionField to element
                if identifier is "awaitcue.hook.analyze" then set analyzeButton to element
            end try
        end repeat
        if conditionField is missing value or analyzeButton is missing value then
            error "Condition controls are unavailable"
        end if
        set analysisStarted to false
        repeat 50 times
            set allElements to entire contents of formWindow
            repeat with element in allElements
                try
                    if value of attribute "AXIdentifier" of element is "awaitcue.hook.analyze" and enabled of element then
                        click element
                        set analysisStarted to true
                        exit repeat
                    end if
                end try
            end repeat
            if analysisStarted then exit repeat
            delay 0.1
        end repeat
        if not analysisStarted then error "Condition text did not enable analysis"
        repeat 200 times
            set allElements to entire contents of formWindow
            set createButton to missing value
            set summaryElement to missing value
            set decisionElement to missing value
            set confidenceElement to missing value
            set explanationElement to missing value
            repeat with element in allElements
                try
                    set identifier to value of attribute "AXIdentifier" of element
                    if identifier is "awaitcue.hook.create" then set createButton to element
                    if identifier is "awaitcue.hook.condition-summary" then set summaryElement to element
                    if identifier is "awaitcue.hook.current-decision" then set decisionElement to element
                    if identifier is "awaitcue.hook.decision-confidence" then set confidenceElement to element
                    if identifier is "awaitcue.hook.decision-explanation" then set explanationElement to element
                end try
            end repeat
            if createButton is not missing value and summaryElement is not missing value and decisionElement is not missing value and confidenceElement is not missing value and explanationElement is not missing value then
                set summaryText to value of summaryElement as text
                set decisionText to value of decisionElement as text
                set confidenceText to value of confidenceElement as text
                set explanationText to value of explanationElement as text
                if summaryText does not contain "当 CN 全流量部署状态显示完成时" then error "unexpected reminder condition: " & summaryText
                if decisionText does not contain "当前未满足" then error "unexpected current decision: " & decisionText
                if confidenceText does not contain "判断置信度 99%" then error "unexpected decision confidence: " & confidenceText
                if explanationText does not contain "尚未满足" then error "unexpected decision explanation: " & explanationText
                click createButton
                return
            end if
            delay 0.1
        end repeat
        error "Condition analysis did not expose the reminder condition and current decision before creating"
    end tell
end tell
APPLESCRIPT
}

model_request_count() {
    local name="$1"
    local marker="${2:-}"
    /usr/bin/python3 - "${model_request_log}" "${name}" "${marker}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
name = sys.argv[2]
marker = sys.argv[3]
count = 0
if path.exists():
    for line in path.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if record.get("name") == name and marker in record.get("input_text", ""):
            count += 1
print(count)
PY
}

wait_for_model_requests() {
    local name="$1"
    local marker="$2"
    local minimum_count="$3"
    for _ in {1..200}; do
        if (( $(model_request_count "${name}" "${marker}") >= minimum_count )); then
            return 0
        fi
        sleep 0.1
    done
    echo "FAIL: expected at least ${minimum_count} ${name} requests containing '${marker}'." >&2
    if [[ -f "${model_request_log}" ]]; then
        sed -n '1,200p' "${model_request_log}" >&2
    fi
    return 1
}

mark_chromium_fixture_complete() {
    osascript - "${chromium_window_id}" <<'APPLESCRIPT'
on run argv
    set targetWindowID to item 1 of argv as integer
    tell application "Google Chrome"
        set result to execute active tab of window id targetWindowID javascript "(() => { const status=document.querySelector('#deployment-status'); const text=document.querySelector('#status-text'); if(!status || !text) return 'missing'; status.dataset.state='complete'; status.dataset.status='success'; status.setAttribute('aria-label','部署状态：完成'); text.textContent='AWAITCUE_E2E_STATUS_COMPLETE'; return text.textContent; })()"
        if result is not "AWAITCUE_E2E_STATUS_COMPLETE" then error "fixture mutation failed: " & result
    end tell
end run
APPLESCRIPT
}

verify_menu_hook() {
    local expected_count="$1"
    local expected_title="${2:-}"
    open_awaitcue_menu
    osascript - "${expected_count}" "${expected_title}" <<'APPLESCRIPT'
on run argv
    set expectedCount to item 1 of argv
    set expectedTitle to item 2 of argv
    tell application "System Events"
        tell process "AwaitCue"
            set countValue to missing value
            repeat 50 times
                if exists window 1 then
                    set allElements to entire contents of first window
                    set countValue to missing value
                    set titleFound to false
                    repeat with element in allElements
                        try
                            set identifier to value of attribute "AXIdentifier" of element
                            if identifier is "awaitcue.menu.hook-count" then set countValue to value of element
                            if identifier is "awaitcue.menu.hook-title" and value of element is expectedTitle then set titleFound to true
                        end try
                    end repeat
                    if countValue is not missing value then
                        if (countValue as text) is expectedCount and (expectedTitle is "" or titleFound) then
                            key code 53
                            repeat 30 times
                                if not (exists first window) then exit repeat
                                delay 0.1
                            end repeat
                            return
                        end if
                    end if
                end if
                delay 0.1
            end repeat
            error "unexpected Hook menu state: count=" & countValue & ", title=" & expectedTitle
        end tell
    end tell
end run
APPLESCRIPT
}

click_menu_action() {
    local identifier="$1"
    open_awaitcue_menu
    osascript - "${identifier}" <<'APPLESCRIPT'
on run argv
    set expectedIdentifier to item 1 of argv
    tell application "System Events"
        tell process "AwaitCue"
            repeat 50 times
                if exists window 1 then
                    set allElements to entire contents of first window
                    repeat with element in allElements
                        try
                            if value of attribute "AXIdentifier" of element is expectedIdentifier then
                                click element
                                delay 0.1
                                try
                                    key code 53
                                end try
                                return
                            end if
                        end try
                    end repeat
                end if
                delay 0.1
            end repeat
            error "menu action is unavailable: " & expectedIdentifier
        end tell
    end tell
end run
APPLESCRIPT
}

restart_e2e_app() {
    click_menu_action "awaitcue.menu.quit"
    for _ in {1..100}; do
        kill -0 "${e2e_app_pid}" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "${e2e_app_pid}" 2>/dev/null; then
        echo "FAIL: AwaitCue did not exit after the real menu action." >&2
        return 1
    fi
    wait "${e2e_app_pid}" 2>/dev/null || true
    launch_e2e_app
    wait_for_e2e_app_ready
}

if [[ "${AWAITCUE_E2E_CHROME_ONLY:-0}" != "1" ]]; then
    echo "E2E stage: Calculator selection 1"
    activate_fixture_app
    perform_frontmost_selection
    wait_for_creation_window >/dev/null
    close_creation_window
    wait_for_creation_window_to_close

    echo "E2E stage: Calculator selection 2"
    activate_fixture_app
    perform_frontmost_selection
    wait_for_creation_window >/dev/null
    close_creation_window
    wait_for_creation_window_to_close
fi

chromium_status="skipped"
echo "E2E stage: Chromium selection and Hook lifecycle"
readonly chromium_fixture_url="http://127.0.0.1:${fixture_port}/index.html"
readonly chromium_window_left="$((80 + fixture_port % 7 * 23))"
readonly chromium_window_top="$((80 + fixture_port % 5 * 19))"
readonly chromium_window_width="$((1000 + fixture_port % 4 * 37))"
readonly chromium_window_height="$((800 + fixture_port % 3 * 29))"
readonly chromium_window_right="$((chromium_window_left + chromium_window_width))"
readonly chromium_window_bottom="$((chromium_window_top + chromium_window_height))"
chromium_window_id="$(osascript - \
    "${chromium_fixture_url}" \
    "${chromium_window_left}" \
    "${chromium_window_top}" \
    "${chromium_window_right}" \
    "${chromium_window_bottom}" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
    tell application "Google Chrome"
        set testWindow to make new window
        -- 每轮使用不同但安全的主屏 bounds，避免与用户窗口或异常退出的旧测试窗口身份冲突。
        set bounds of testWindow to {¬
            item 2 of argv as integer, ¬
            item 3 of argv as integer, ¬
            item 4 of argv as integer, ¬
            item 5 of argv as integer¬
        }
        set URL of active tab of testWindow to item 1 of argv
        set index of testWindow to 1
        activate
        return id of testWindow
    end tell
end run
APPLESCRIPT
)"
if [[ "${chromium_window_id}" =~ ^[0-9]+$ ]]; then
    if ! osascript - "${chromium_window_id}" <<'APPLESCRIPT' >/dev/null; then
on run argv
    set targetWindowID to item 1 of argv as integer
    tell application "Google Chrome"
        repeat 100 times
            try
                if title of active tab of window id targetWindowID is "AwaitCue Chrome E2E Target" then return
            end try
            delay 0.1
        end repeat
        error "local fixture page did not finish loading"
    end tell
end run
APPLESCRIPT
        echo "FAIL: Chrome did not load the local fixture page." >&2
        exit 17
    fi
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
    # 中间选区在垂直标签栏或双侧栏布局下无法唯一反推出 viewport 左边缘；
    # 真实 E2E 必须证明产品会打开创建窗口，而不是只覆盖贴右边缘的容易路径。
    perform_frontmost_selection 0.20 0.25 0.75
    wait_for_creation_window >/dev/null
    verify_real_creation_form
    if [[ -n "${AWAITCUE_E2E_CAPTURE_PATH:-}" ]]; then
        screencapture -x "${AWAITCUE_E2E_CAPTURE_PATH}"
    fi
    if [[ "${AWAITCUE_E2E_SKIP_CHROMIUM_REPAIR:-0}" == "1" ]]; then
        echo "E2E stage: existing Chrome installation connected without repair"
        close_creation_window
        wait_for_creation_window_to_close
    else
        echo "E2E stage: create observing Chrome Condition Hook"
        create_condition_hook_from_form
        wait_for_creation_window_to_close
        wait_for_model_requests \
            "condition_evaluation" \
            "atom-pipeline-icon-queuing-circle-fill" \
            1
        verify_menu_hook "1" "AwaitCue Chrome E2E Target"

        echo "E2E stage: restart while Condition is still observing"
        pending_before_restart="$(model_request_count \
            "condition_evaluation" \
            "atom-pipeline-icon-queuing-circle-fill")"
        restart_e2e_app
        wait_for_model_requests \
            "condition_evaluation" \
            "atom-pipeline-icon-queuing-circle-fill" \
            "$((pending_before_restart + 1))"

        echo "E2E stage: mutate DOM and wait for two stable matched decisions"
        osascript -e 'tell application "Google Chrome" to activate'
        mark_chromium_fixture_complete
        wait_for_model_requests \
            "condition_evaluation" \
            "data-status=\"success\"" \
            2
        verify_menu_hook "1" "AwaitCue Chrome E2E Target"
        echo "E2E stage: cancel completed Condition observation"
        click_menu_action "awaitcue.menu.cancel-hook"
        sleep 0.3
        verify_menu_hook "0" ""

        echo "E2E stage: create Delay Hook on the same exact Chrome tab"
        osascript -e 'tell application "Google Chrome" to activate'
        perform_frontmost_selection 0.20 0.25 0.75
        wait_for_creation_window >/dev/null
        verify_real_creation_form
        create_delay_hook_from_form
        wait_for_creation_window_to_close
        verify_menu_hook "1" "AwaitCue Chrome E2E Target"

        echo "E2E stage: restart and restore Delay Hook"
        restart_e2e_app
        verify_menu_hook "1" "AwaitCue Chrome E2E Target"
        click_menu_action "awaitcue.menu.cancel-hook"
        sleep 0.3
        verify_menu_hook "0" ""
    fi
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

if [[ "${AWAITCUE_E2E_SKIP_CHROMIUM_REPAIR:-0}" == "1" ]]; then
    echo "macOS live E2E passed: existing Chrome installation connected and opened the real Hook form without repair; Chromium=${chromium_status}."
else
    echo "macOS live E2E passed: settings, Calculator selection, Chrome Condition DOM/restart/stability, and Delay create/restart/cancel; Chromium=${chromium_status}."
fi
