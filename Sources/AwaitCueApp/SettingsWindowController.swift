import AppKit
import SwiftUI

/// 自主管理设置窗口，确保菜单栏 agent 每次请求都能激活并置前，而不是只创建隐藏的 Settings scene。
@MainActor
final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private weak var model: AwaitCueApplicationModel?
    private var windowController: NSWindowController?

    init(model: AwaitCueApplicationModel) {
        self.model = model
    }

    /// 同一时间只保留一个设置窗口；已存在时恢复最小化状态并带到前台。
    func present() {
        if let window = windowController?.window {
            activate(window)
            return
        }
        guard let model else { return }

        let hostingController = NSHostingController(rootView: AwaitCueSettingsView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AwaitCue 设置"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        activate(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === windowController?.window
        else {
            return
        }
        windowController = nil
    }

    private func activate(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
