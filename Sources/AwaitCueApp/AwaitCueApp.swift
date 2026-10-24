import SwiftUI

@main
struct AwaitCueApp: App {
    @StateObject private var model: AwaitCueApplicationModel
    @StateObject private var hookCreationWindowController: HookCreationWindowController
    @StateObject private var settingsWindowController: SettingsWindowController

    init() {
        Self.writeE2EDiagnostic("app init started")
        let model = AwaitCueApplicationModel()
        Self.writeE2EDiagnostic("application model initialized")
        let hookCreationWindowController = HookCreationWindowController(model: model)
        Self.writeE2EDiagnostic("hook creation controller initialized")
        let settingsWindowController = SettingsWindowController(model: model)
        Self.writeE2EDiagnostic("window controllers initialized")
        model.attachHookCreationPresenter(hookCreationWindowController)
        _model = StateObject(wrappedValue: model)
        _hookCreationWindowController = StateObject(wrappedValue: hookCreationWindowController)
        _settingsWindowController = StateObject(wrappedValue: settingsWindowController)
        // MenuBarExtra 内容是懒加载的；进程级服务必须在 App 创建时启动，不能等待用户先打开菜单。
        Task { @MainActor in
            await model.start()
        }
        Self.writeE2EDiagnostic("app init completed")
    }

    var body: some Scene {
        MenuBarExtra("AwaitCue", systemImage: model.menuBarSystemImage) {
            AwaitCueMenuView(
                model: model,
                openSettings: settingsWindowController.present
            )
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)
    }

    /// live E2E 只记录启动阶段，不包含 Hook、窗口标题、URL 或用户内容。
    private static func writeE2EDiagnostic(_ message: String) {
        guard ProcessInfo.processInfo.environment["AWAITCUE_E2E_DIAGNOSTICS"] == "1" else {
            return
        }
        try? FileHandle.standardError.write(
            contentsOf: Data("AwaitCueApp \(message)\n".utf8)
        )
    }
}
