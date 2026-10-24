import AwaitCueCapture
import AwaitCueCore
import CoreGraphics
import Foundation
import Testing
@testable import AwaitCueSelection

@Suite("浏览器 relay 目标分类")
struct SelectionTargetResolverTests {
    @Test("唯一扩展一旦响应就完成，多扩展仍保留歧义收集窗口")
    func browserSelectionResponseGateUsesRecipientCount() {
        var earlyResponse = BrowserSelectionResponseGate()
        earlyResponse.recordAcceptedResponse()
        #expect(earlyResponse.isComplete == false)
        earlyResponse.setExpectedResponseCount(1)
        #expect(earlyResponse.isComplete)

        var multipleProfiles = BrowserSelectionResponseGate()
        multipleProfiles.setExpectedResponseCount(2)
        multipleProfiles.recordAcceptedResponse()
        #expect(multipleProfiles.isComplete == false)

        var noExtension = BrowserSelectionResponseGate()
        noExtension.setExpectedResponseCount(0)
        #expect(noExtension.isComplete)
    }

    @Test("浏览器选择只接受同 bundle 的唯一 installation 响应")
    func browserSelectionRejectsCrossBrowserAndAmbiguousResponses() {
        let chromeTarget = fixtureBrowserTarget(
            bundleIdentifier: "com.google.Chrome",
            installationID: "chrome-1",
            tabID: 1
        )
        let secondChromeTarget = fixtureBrowserTarget(
            bundleIdentifier: "com.google.Chrome",
            installationID: "chrome-2",
            tabID: 2
        )
        let arcTarget = fixtureBrowserTarget(
            bundleIdentifier: "company.thebrowser.Browser",
            installationID: "arc-1",
            tabID: 3
        )
        var collector = BrowserSelectionMatchCollector(
            browserBundleIdentifier: "com.google.Chrome"
        )
        collector.record(
            browserBundleIdentifier: "company.thebrowser.Browser",
            target: arcTarget
        )
        collector.record(
            browserBundleIdentifier: "com.google.Chrome",
            target: chromeTarget
        )
        #expect(collector.resolution == .resolved(chromeTarget))

        collector.record(
            browserBundleIdentifier: "com.google.Chrome",
            target: secondChromeTarget
        )
        #expect(collector.resolution == .unavailable(.ambiguousResponse))
    }

    @Test("浏览器选择失败优先返回最具体原因且无响应可区分")
    func browserSelectionPreservesFailureReason() {
        var collector = BrowserSelectionMatchCollector(
            browserBundleIdentifier: "com.google.Chrome"
        )
        #expect(collector.resolution == .unavailable(.noExtensionResponse))

        collector.recordFailure(
            browserBundleIdentifier: "com.google.Chrome",
            reason: .windowNotMatched
        )
        collector.recordFailure(
            browserBundleIdentifier: "com.google.Chrome",
            reason: .selectionOutsideViewport
        )
        #expect(collector.resolution == .unavailable(.selectionOutsideViewport))
    }

    @Test("活动浏览器 host 只接受同 bundle 的唯一 installation")
    func activeBrowserHostRejectsCrossBrowserAndAmbiguousInstallations() {
        var collector = ActiveBrowserHostMatchCollector(
            browserBundleIdentifier: "com.google.Chrome"
        )
        collector.record(
            browserBundleIdentifier: "company.thebrowser.Browser",
            extensionInstallationID: "arc-1",
            tabIdentifier: 1,
            browserWindowIdentifier: 1,
            host: "wrong.example"
        )
        collector.record(
            browserBundleIdentifier: "com.google.Chrome",
            extensionInstallationID: "chrome-1",
            tabIdentifier: 7,
            browserWindowIdentifier: 9,
            host: "build.example"
        )
        // 同一个 installation 的重复响应必须去重。
        collector.record(
            browserBundleIdentifier: "com.google.Chrome",
            extensionInstallationID: "chrome-1",
            tabIdentifier: 7,
            browserWindowIdentifier: 9,
            host: "build.example"
        )

        #expect(
            collector.resolution
                == .resolved(
                    ActiveBrowserContext(
                        extensionInstallationID: "chrome-1",
                        tabIdentifier: 7,
                        browserWindowIdentifier: 9,
                        host: "build.example"
                    )
                )
        )

        collector.record(
            browserBundleIdentifier: "com.google.Chrome",
            extensionInstallationID: "chrome-2",
            tabIdentifier: 8,
            browserWindowIdentifier: 10,
            host: "mail.example"
        )
        #expect(collector.resolution == .unavailable)
    }

    @Test("relay 明确判定为非浏览器后生成普通窗口 Target")
    func nonBrowserSelectionBecomesWindowTarget() async throws {
        let relay = FixtureBrowserSelectionRelay(result: .notBrowser)
        let resolver = fixtureTargetResolver(relay: relay)
        let window = fixtureTargetWindow(bundleIdentifier: "com.example.editor", windowIdentifier: 71)

        let target = try await resolver.resolve(
            appKitSelectionRect: CGRect(x: 120, y: 570, width: 100, height: 80),
            appKitAnchor: CGPoint(x: 130, y: 640),
            windowsFrontToBack: [window]
        )

        #expect(
            target
                == .window(
                    WindowTarget(
                        applicationBundleIdentifier: "com.example.editor",
                        windowIdentifier: 71,
                        initialTitle: "Window 71",
                        normalizedRegion: NormalizedRegion(
                            x: 0.05,
                            y: 0.125,
                            width: 0.25,
                            height: 0.2
                        )
                    )
                )
        )
        #expect(await relay.receivedWindowIdentifiers == [71])
    }

    @Test("relay 返回浏览器 Target 时不创建普通窗口 Target")
    func browserSelectionUsesRelayTarget() async throws {
        let browserTarget = BrowserTarget(
            browserBundleIdentifier: "com.example.browser",
            nativeWindowIdentifier: 70,
            extensionInstallationID: "installation-1",
            tabIdentifier: 9,
            host: "example.com",
            initialURL: URL(string: "https://example.com/build")!,
            initialTitle: "Build",
            normalizedRegion: NormalizedRegion(x: 0.2, y: 0.3, width: 0.4, height: 0.2),
            observationMode: .dom
        )
        let relay = FixtureBrowserSelectionRelay(result: .resolved(browserTarget))
        let resolver = fixtureTargetResolver(relay: relay)

        let target = try await resolver.resolve(
            appKitSelectionRect: CGRect(x: 120, y: 570, width: 100, height: 80),
            appKitAnchor: CGPoint(x: 130, y: 640),
            windowsFrontToBack: [
                fixtureTargetWindow(
                    bundleIdentifier: "com.example.browser",
                    windowIdentifier: 72
                )
            ]
        )

        #expect(target == .browser(browserTarget))
    }

    @Test("浏览器 relay 不可用时禁止降级成窗口 Target")
    func unavailableBrowserRelayDoesNotFallBackToWindowTarget() async {
        let relay = FixtureBrowserSelectionRelay(result: .unavailable(.selectionOutsideViewport))
        let resolver = fixtureTargetResolver(relay: relay)

        await #expect(
            throws: SelectionTargetError.browserRelayUnavailable(.selectionOutsideViewport)
        ) {
            try await resolver.resolve(
                appKitSelectionRect: CGRect(x: 120, y: 570, width: 100, height: 80),
                appKitAnchor: CGPoint(x: 130, y: 640),
                windowsFrontToBack: [
                    fixtureTargetWindow(
                        bundleIdentifier: "com.example.browser",
                        windowIdentifier: 73
                    )
                ]
            )
        }
    }
}

private func fixtureBrowserTarget(
    bundleIdentifier: String,
    installationID: String,
    tabID: Int
) -> BrowserTarget {
    BrowserTarget(
        browserBundleIdentifier: bundleIdentifier,
        nativeWindowIdentifier: 70,
        extensionInstallationID: installationID,
        tabIdentifier: tabID,
        host: "example.com",
        initialURL: URL(string: "https://example.com")!,
        initialTitle: "Example",
        normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
        observationMode: .dom
    )
}

private actor FixtureBrowserSelectionRelay: BrowserSelectionRelaying {
    private let result: BrowserSelectionRelayResolution
    private(set) var receivedWindowIdentifiers: [UInt32] = []

    init(result: BrowserSelectionRelayResolution) {
        self.result = result
    }

    func resolveBrowserTarget(
        for selection: ResolvedWindowSelection
    ) async throws -> BrowserSelectionRelayResolution {
        receivedWindowIdentifiers.append(selection.window.windowIdentifier)
        return result
    }
}

private func fixtureTargetResolver(
    relay: some BrowserSelectionRelaying
) -> SelectionTargetResolver {
    SelectionTargetResolver(
        windowResolver: WindowSelectionResolver(
            coordinateConverter: SelectionCoordinateConverter(
                primaryDisplayFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            )
        ),
        browserRelay: relay
    )
}

private func fixtureTargetWindow(
    bundleIdentifier: String,
    windowIdentifier: UInt32
) -> DiscoveredWindow {
    DiscoveredWindow(
        applicationBundleIdentifier: bundleIdentifier,
        applicationName: bundleIdentifier,
        windowIdentifier: windowIdentifier,
        title: "Window \(windowIdentifier)",
        frame: CGRect(x: 100, y: 100, width: 400, height: 400)
    )
}
