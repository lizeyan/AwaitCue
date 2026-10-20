import Foundation

/// 在采集当前活动窗口之前即可本地判断的隐私排除规则。
public struct PrivacyExclusionRules: Equatable, Sendable {
    public let applicationBundleIdentifiers: Set<String>
    public let browserHosts: Set<String>

    /// 创建经过空白、大小写和尾随点规范化的规则集合。
    public init(
        applicationBundleIdentifiers: some Sequence<String>,
        browserHosts: some Sequence<String>
    ) {
        self.applicationBundleIdentifiers = Set(
            applicationBundleIdentifiers.compactMap(Self.normalizedBundleIdentifier)
        )
        self.browserHosts = Set(browserHosts.compactMap(Self.normalizedHost))
    }

    /// bundle ID 使用精确匹配，避免无意排除同一厂商的其他应用。
    public func excludes(applicationBundleIdentifier: String) -> Bool {
        guard let normalized = Self.normalizedBundleIdentifier(applicationBundleIdentifier) else {
            return false
        }
        return applicationBundleIdentifiers.contains(normalized)
    }

    /// host 规则同时覆盖自身和子域，但不会把相似字符串后缀当成同一域。
    public func excludes(browserHost: String) -> Bool {
        guard let normalized = Self.normalizedHost(browserHost) else {
            return false
        }
        return browserHosts.contains { excludedHost in
            normalized == excludedHost || normalized.hasSuffix(".\(excludedHost)")
        }
    }

    private static func normalizedBundleIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedHost(_ value: String) -> String? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? nil : normalized
    }
}
