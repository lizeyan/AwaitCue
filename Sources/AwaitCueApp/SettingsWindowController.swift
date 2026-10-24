import AppKit
import SwiftUI

/// 自主管理设置窗口，确保菜单栏 agent 每次请求都能激活并置前，而不是只创建隐藏的 Settings scene。
@MainActor
final class SettingsWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let rootView: () -> AnyView
    private var windowController: NSWindowController?

    init(model: AwaitCueApplicationModel) {
        rootView = { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(AwaitCueSettingsView(model: model))
        }
    }

    /// 注入真实 SwiftUI 内容但隔离进程级依赖，供窗口服务器端到端测试使用。
    init(rootView: @escaping () -> AnyView) {
        self.rootView = rootView
    }

    /// 同一时间只保留一个设置窗口；已存在时恢复最小化状态并带到前台。
    func present() {
        if let window = windowController?.window {
            activate(window)
            return
        }
        let hostingController = NSHostingController(
            rootView: rootView()
                .frame(minWidth: 720, minHeight: 520)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AwaitCue 设置"
        window.contentViewController = hostingController
        // 设置 contentViewController 可能按 SwiftUI 固有尺寸收缩窗口；必须在挂载后重申默认大小。
        window.setContentSize(NSSize(width: 760, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
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
