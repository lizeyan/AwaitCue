import AppKit
import AwaitCueSelection
import SwiftUI

/// 用独立普通窗口承载创建表单，使全局快捷键完成框选后无需先打开 MenuBarExtra。
@MainActor
final class HookCreationWindowController: NSObject, ObservableObject, HookCreationPresenting, NSWindowDelegate {
    private let rootView: () -> AnyView
    private let onUserClose: () -> Void
    private var windowController: NSWindowController?
    private var failureWindowController: NSWindowController?
    private var isDismissingProgrammatically = false

    init(model: AwaitCueApplicationModel) {
        rootView = { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(HookCreationView(model: model))
        }
        onUserClose = { [weak model] in
            model?.dismissPendingTarget()
        }
    }

    /// 注入真实 SwiftUI 内容但隔离进程级依赖，供窗口服务器端到端测试使用。
    init(
        rootView: @escaping () -> AnyView,
        onUserClose: @escaping () -> Void
    ) {
        self.rootView = rootView
        self.onUserClose = onUserClose
    }

    /// 首次创建新 hosting root；同一 pending target 再次请求时只把现有窗口带到前台。
    func present() {
        dismissFailure()
        if let window = windowController?.window {
            activate(window)
            return
        }
        let hostingController = NSHostingController(
            rootView: rootView()
                .frame(minWidth: 520, minHeight: 620)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "创建 Hook"
        window.contentViewController = hostingController
        // 安装 hosting controller 会按 SwiftUI 固有尺寸压缩窗口；挂载后必须重申默认尺寸。
        window.setContentSize(NSSize(width: 560, height: 640))
        window.contentMinSize = NSSize(width: 520, height: 620)
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

    /// 框选无法建立可靠 Target 时展示独立非模态窗口，避免错误只藏在菜单栏内容里。
    func presentFailure(message: String) {
        dismissFailure()
        let hostingController = NSHostingController(
            rootView: HookCreationFailureView(
                message: message,
                dismiss: { [weak self] in self?.dismissFailure() }
            )
            .frame(minWidth: 420, minHeight: 180)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "无法创建 Hook"
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 480, height: 220))
        window.contentMinSize = NSSize(width: 420, height: 180)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.setAccessibilityLabel("无法创建 Hook：\(message)")
        window.center()

        let controller = NSWindowController(window: window)
        failureWindowController = controller
        controller.showWindow(nil)
        activate(window)
    }

    private func dismissFailure() {
        failureWindowController?.close()
        failureWindowController = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        if closingWindow === failureWindowController?.window {
            failureWindowController = nil
            return
        }
        guard closingWindow === windowController?.window else { return }
        let shouldClearTarget = !isDismissingProgrammatically
        windowController = nil
        if shouldClearTarget {
            onUserClose()
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

private struct HookCreationFailureView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("无法创建 Hook", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("知道了", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
    }
}
