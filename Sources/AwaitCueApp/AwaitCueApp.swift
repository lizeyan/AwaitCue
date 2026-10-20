import SwiftUI

@main
struct AwaitCueApp: App {
    @StateObject private var model = AwaitCueApplicationModel()

    var body: some Scene {
        MenuBarExtra("AwaitCue", systemImage: model.menuBarSystemImage) {
            AwaitCueMenuView(model: model)
                .frame(width: 360)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            AwaitCueSettingsView(model: model)
                .frame(width: 560, height: 420)
        }
    }
}
