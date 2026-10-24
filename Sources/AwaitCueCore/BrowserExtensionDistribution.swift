import Foundation

/// AwaitCue 可主动引导安装或管理扩展的 Chromium 浏览器。
public enum BrowserExtensionFamily: String, CaseIterable, Sendable {
    case chrome
    case edge
    case arc
    case chromium

    public var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .arc: "Arc"
        case .chromium: "Chromium"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .arc: "company.thebrowser.Browser"
        case .chromium: "org.chromium.Chromium"
        }
    }

    /// 浏览器自身的扩展管理页；调用方必须指定对应浏览器打开自定义 scheme。
    public var managementURL: URL {
        switch self {
        case .edge:
            URL(string: "edge://extensions/")!
        case .chrome, .arc, .chromium:
            URL(string: "chrome://extensions/")!
        }
    }
}

/// 尚未发布商店版本时，扩展的唯一正式下载来源。
public enum BrowserExtensionDistribution {
    public static let releaseDownloadURL = URL(
        string: "https://github.com/lizeyan/AwaitCue/releases/latest"
    )!
}

/// AwaitCue 可以直接打开的 macOS 系统设置权限页。
public enum SystemSettingsDestination: Sendable {
    case screenRecording
    case notifications

    public var url: URL {
        switch self {
        case .screenRecording:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
        case .notifications:
            URL(
                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
            )!
        }
    }
}
