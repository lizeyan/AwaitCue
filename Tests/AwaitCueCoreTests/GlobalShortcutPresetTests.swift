import Testing
@testable import AwaitCueCore

@Suite("全局快捷键预设")
struct GlobalShortcutPresetTests {
    @Test("默认快捷键避开 1Password 的 Command-Shift-Space")
    func defaultAvoidsOnePasswordShortcut() {
        #expect(GlobalShortcutPreset.default == .controlShiftSpace)
        #expect(GlobalShortcutPreset.default.displayName == "⌃⇧Space")
    }

    @Test("预设可以通过稳定 raw value 保存并恢复")
    func presetsRoundTripThroughRawValues() {
        for preset in GlobalShortcutPreset.allCases {
            #expect(GlobalShortcutPreset(rawValue: preset.rawValue) == preset)
            #expect(!preset.displayName.isEmpty)
        }
    }
}
