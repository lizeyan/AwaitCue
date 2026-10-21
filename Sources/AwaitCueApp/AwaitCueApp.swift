import SwiftUI

@main
struct AwaitCueApp: App {
    @StateObject private var model: AwaitCueApplicationModel
    @StateObject private var hookCreationWindowController: HookCreationWindowController
    @StateObject private var settingsWindowController: SettingsWindowController

    init() {
        let model = AwaitCueApplicationModel()
        let hookCreationWindowController = HookCreationWindowController(model: model)
        let settingsWindowController = SettingsWindowController(model: model)
        model.attachHookCreationPresenter(hookCreationWindowController)
        _model = StateObject(wrappedValue: model)
        _hookCreationWindowController = StateObject(wrappedValue: hookCreationWindowController)
        _settingsWindowController = StateObject(wrappedValue: settingsWindowController)
        // MenuBarExtra 内容是懒加载的；进程级服务必须在 App 创建时启动，不能等待用户先打开菜单。
        Task { @MainActor in
            await model.start()
        }
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
}
