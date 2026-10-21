/// AwaitCue 支持的全局框选快捷键预设；raw value 用于本地设置持久化。
public enum GlobalShortcutPreset: String, CaseIterable, Codable, Sendable {
    case controlShiftSpace
    case optionShiftSpace
    case commandShiftSpace

    /// 默认避开 1Password 常用的 Command-Shift-Space。
    public static let `default`: Self = .controlShiftSpace

    public var displayName: String {
        switch self {
        case .controlShiftSpace: "⌃⇧Space"
        case .optionShiftSpace: "⌥⇧Space"
        case .commandShiftSpace: "⌘⇧Space"
        }
    }
}
