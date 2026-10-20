import Foundation

/// 把操作系统提供的父进程 bundle 或 executable path 收敛为受支持的 Chromium 产品身份。
public enum BrowserParentIdentity {
    /// Chrome helper 的 bundle ID 带额外后缀；按最长主 bundle 前缀归一化，避免 Beta 被稳定版吞掉。
    public static func canonicalBundleIdentifier(_ bundleIdentifier: String) -> String? {
        supportedBrowserBundleIdentifiers.first { candidate in
            bundleIdentifier == candidate || bundleIdentifier.hasPrefix(candidate + ".")
        }
    }

    /// `NSRunningApplication` 无法识别父进程时，从 executable path 向上寻找真实 `.app` 的 Info.plist。
    public static func bundleIdentifier(containingExecutableAt executableURL: URL) -> String? {
        var candidate = executableURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                let infoURL = candidate
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Info.plist")
                guard let data = try? Data(contentsOf: infoURL),
                      let object = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                      ),
                      let info = object as? [String: Any],
                      let bundleIdentifier = info["CFBundleIdentifier"] as? String
                else {
                    return nil
                }
                return canonicalBundleIdentifier(bundleIdentifier)
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    private static let supportedBrowserBundleIdentifiers = [
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome",
        "com.microsoft.edgemac.Canary",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]
}
