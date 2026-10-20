import Foundation
import Testing
@testable import AwaitCueBrowserBridge

@Suite("浏览器父进程身份")
struct BrowserParentIdentityTests {
    @Test("Chrome 主进程和 helper bundle 都归一化到受支持浏览器")
    func canonicalizesSupportedBrowserBundles() {
        #expect(BrowserParentIdentity.canonicalBundleIdentifier("com.google.Chrome") == "com.google.Chrome")
        #expect(
            BrowserParentIdentity.canonicalBundleIdentifier(
                "com.google.Chrome.helper.renderer"
            ) == "com.google.Chrome"
        )
        #expect(BrowserParentIdentity.canonicalBundleIdentifier("com.example.Untrusted") == nil)
    }

    @Test("从父进程 executable path 向上读取 app bundle 身份")
    func resolvesBundleFromExecutablePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("Chrome.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Google Chrome")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.google.Chrome",
            "CFBundleExecutable": "Google Chrome",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            BrowserParentIdentity.bundleIdentifier(
                containingExecutableAt: executable
            ) == "com.google.Chrome"
        )
    }

    @Test("缺失或损坏的 app 元数据不会被信任")
    func rejectsMissingAndInvalidBundleMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = root
            .appendingPathComponent("Broken.app/Contents/MacOS/Browser")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            BrowserParentIdentity.bundleIdentifier(
                containingExecutableAt: executable
            ) == nil
        )
        #expect(
            BrowserParentIdentity.bundleIdentifier(
                containingExecutableAt: URL(fileURLWithPath: "/usr/bin/false")
            ) == nil
        )
    }
}
