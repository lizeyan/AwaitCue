import AwaitCueCore
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("App 全局快捷键用户链路", .serialized)
struct ApplicationModelShortcutTests {
    @MainActor
    @Test("新快捷键注册成功后更新界面和本地设置")
    func successfulShortcutChangePersistsSelection() throws {
        let recorder = HotKeyFactoryRecorder()
        let fixture = try IsolatedApplicationModelFixture(
            globalHotKeyFactory: recorder.make
        )
        defer { fixture.cleanup() }

        fixture.model.updateGlobalShortcut(.optionShiftSpace)

        #expect(fixture.model.globalShortcutPreset == .optionShiftSpace)
        #expect(fixture.model.globalShortcutError == nil)
        #expect(
            fixture.defaults.string(forKey: "globalShortcutPreset")
                == GlobalShortcutPreset.optionShiftSpace.rawValue
        )
        #expect(recorder.attemptedPresets == [.optionShiftSpace])
    }

    @MainActor
    @Test("快捷键冲突时恢复旧组合并显示错误")
    func shortcutConflictRestoresPreviousRegistration() throws {
        let recorder = HotKeyFactoryRecorder(failingPreset: .optionShiftSpace)
        let fixture = try IsolatedApplicationModelFixture(
            globalHotKeyFactory: recorder.make
        )
        defer { fixture.cleanup() }

        fixture.model.updateGlobalShortcut(.optionShiftSpace)

        #expect(fixture.model.globalShortcutPreset == .default)
        #expect(fixture.model.globalShortcutError?.contains("已恢复") == true)
        #expect(fixture.defaults.string(forKey: "globalShortcutPreset") == nil)
        #expect(recorder.attemptedPresets == [.optionShiftSpace, .default])
    }
}

@MainActor
private final class HotKeyFactoryRecorder {
    private let failingPreset: GlobalShortcutPreset?
    private(set) var attemptedPresets: [GlobalShortcutPreset] = []

    init(failingPreset: GlobalShortcutPreset? = nil) {
        self.failingPreset = failingPreset
    }

    func make(
        preset: GlobalShortcutPreset,
        action: @escaping @MainActor () -> Void
    ) throws -> any GlobalHotKeyControlling {
        attemptedPresets.append(preset)
        if preset == failingPreset {
            throw HotKeyFixtureError.conflict
        }
        return RecordingHotKeyController()
    }
}

@MainActor
private final class RecordingHotKeyController: GlobalHotKeyControlling {
    func stop() {}
}

private enum HotKeyFixtureError: Error {
    case conflict
}
