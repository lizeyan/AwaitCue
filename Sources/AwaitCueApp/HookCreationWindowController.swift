import AppKit
import AwaitCueSelection
import SwiftUI

/// 用独立普通窗口承载创建表单，使全局快捷键完成框选后无需先打开 MenuBarExtra。
@MainActor
final class HookCreationWindowController: NSObject, ObservableObject, HookCreationPresenting, NSWindowDelegate {
    private weak var model: AwaitCueApplicationModel?
    private var windowController: NSWindowController?
    private var isDismissingProgrammatically = false

    init(model: AwaitCueApplicationModel) {
        self.model = model
    }

    /// 首次创建新 hosting root；同一 pending target 再次请求时只把现有窗口带到前台。
    func present() {
        if let window = windowController?.window {
            activate(window)
            return
        }
        guard let model else { return }

        let hostingController = NSHostingController(rootView: HookCreationView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "创建 Hook"
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 520, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        activate(window)
    }

    /// 清除 target 后关闭并释放整棵 SwiftUI 表单，下一轮不会继承旧的 @State 输入。
    func dismiss() {
        guard let controller = windowController else { return }
        isDismissingProgrammatically = true
        controller.close()
        isDismissingProgrammatically = false
        if windowController === controller {
            windowController = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === windowController?.window
        else {
            return
        }
        let shouldClearTarget = !isDismissingProgrammatically
        windowController = nil
        if shouldClearTarget {
            model?.dismissPendingTarget()
        }
    }

    /// overlay 已经关闭后再激活普通窗口，避免与 screenSaver 级框选窗口争夺焦点。
    private func activate(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
