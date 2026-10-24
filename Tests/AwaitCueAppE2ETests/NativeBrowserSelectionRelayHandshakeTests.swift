import AwaitCueBrowserBridge
import AwaitCueCapture
import AwaitCueCore
import AwaitCueSafariBridge
import Foundation
import Testing
@testable import AwaitCueApp
@testable import AwaitCueSelection

@Suite("Chromium 双向连接用户链路", .serialized)
struct NativeBrowserSelectionRelayHandshakeTests {
    @Test("只有匹配的 pong 返回后才显示扩展已连接")
    func connectedStatusRequiresMatchingPong() async throws {
        let fixture = try await RelayHandshakeFixture()
        defer { fixture.stop() }

        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])

        let ping = try #require(await fixture.nextAppCommand())
        #expect(ping["type"] as? String == "ping")
        let requestID = try #require(ping["requestID"] as? String)
        #expect(ping["extensionInstallationID"] as? String == "installation-1")
        #expect(await fixture.statuses() == [])

        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "company.thebrowser.Browser",
        ])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.statuses() == [])

        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])

        try await fixture.waitForStatus("浏览器扩展已连接")
        #expect(await fixture.statuses() == ["浏览器扩展已连接"])
    }

    @Test("ready 后收不到 pong 会显示双向通信不可用")
    func missingPongDoesNotReportConnected() async throws {
        let fixture = try await RelayHandshakeFixture(handshakeTimeout: .milliseconds(40))
        defer { fixture.stop() }

        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        _ = try #require(await fixture.nextAppCommand())

        try await fixture.waitForStatus("浏览器扩展已启动，但双向通信不可用")
        #expect(await fixture.statuses().contains("浏览器扩展已连接") == false)
    }

    @Test("超时后晚到的匹配 pong 可以自动恢复双向连接")
    func latePongRecoversConnection() async throws {
        let fixture = try await RelayHandshakeFixture(handshakeTimeout: .milliseconds(40))
        defer { fixture.stop() }

        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        let ping = try #require(await fixture.nextAppCommand())
        let requestID = try #require(ping["requestID"] as? String)
        try await fixture.waitForStatus("浏览器扩展已启动，但双向通信不可用")

        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])

        try await fixture.waitForStatus("浏览器扩展已连接")
    }

    @Test("Chrome 冷启动调度超过三秒时仍能完成双向确认")
    func coldChromeSchedulingDelayStillConnects() async throws {
        let fixture = try await RelayHandshakeFixture()
        defer { fixture.stop() }

        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        let ping = try #require(await fixture.nextAppCommand())
        let requestID = try #require(ping["requestID"] as? String)

        // 真实 Chrome 的 MV3 worker 冷启动会超过一秒；不能把正常调度抖动误报成单向连接。
        try await Task.sleep(for: .milliseconds(3_500))
        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])

        try await fixture.waitForStatus("浏览器扩展已连接", timeout: .seconds(2))
        #expect(await fixture.statuses().contains("浏览器扩展已启动，但双向通信不可用") == false)
    }

    @Test("双向连接确认前不会向浏览器发送查询")
    func browserQueriesWaitForVerifiedConnection() async throws {
        let fixture = try await RelayHandshakeFixture()
        defer { fixture.stop() }

        let result = try await fixture.relay.resolveActiveBrowserHost(
            for: "com.google.Chrome"
        )

        #expect(result == .unavailable)
        #expect(await fixture.nextAppCommand(timeout: .milliseconds(80)) == nil)
    }

    @Test("用户在握手进行中框选时等待 pong 后继续原请求")
    func selectionWaitsForInFlightHandshake() async throws {
        let fixture = try await RelayHandshakeFixture(handshakeTimeout: .seconds(1))
        defer { fixture.stop() }
        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        let ping = try #require(await fixture.nextAppCommand())
        let selection = ResolvedWindowSelection(
            window: DiscoveredWindow(
                applicationBundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                windowIdentifier: 42,
                title: "Example",
                frame: CGRect(x: 100, y: 100, width: 1_000, height: 700)
            ),
            screenCaptureRect: CGRect(x: 200, y: 250, width: 300, height: 200),
            normalizedRegion: NormalizedRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        )
        let recorder = BrowserResolutionRecorder()
        Task {
            let result = try? await fixture.relay.resolveBrowserTarget(for: selection)
            await recorder.record(result)
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.value == nil)

        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": try #require(ping["requestID"] as? String),
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        let resolve = try #require(await fixture.nextAppCommand())
        try await fixture.sendBrowserEvent([
            "type": "selectionResolved",
            "requestID": try #require(resolve["requestID"] as? String),
            "matched": false,
            "reason": "window_not_matched",
            "browserBundleIdentifier": "com.google.Chrome",
        ])

        #expect(try await recorder.waitForValue() == .unavailable(.windowNotMatched))
    }

    @Test("无语义页面只产生证据不足文字且绝不产生图片")
    func semanticEvidenceInsufficiencyDoesNotFallBackToImage() async throws {
        let fixture = try await RelayHandshakeFixture()
        defer { fixture.stop() }
        try await fixture.verifyConnection()

        let hookID = HookID(rawValue: UUID())
        let target = BrowserTarget(
            browserBundleIdentifier: "com.google.Chrome",
            nativeWindowIdentifier: 42,
            extensionInstallationID: "installation-1",
            tabIdentifier: 7,
            host: "example.com",
            initialURL: URL(string: "https://example.com/canvas")!,
            initialTitle: "Canvas status",
            normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            observationMode: .dom
        )
        try await fixture.bindAndAcknowledge(hookID: hookID, target: target)

        try await fixture.sendBrowserEvent([
            "type": "evidenceChanged",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
            "evidence": [
                "hookID": hookID.rawValue.uuidString,
                "title": "Canvas status",
                "url": "https://example.com/canvas",
                "text": "",
                "aria": [],
                "availability": "insufficient",
                "insufficiencyReason": "no_semantic_content",
            ],
        ])
        try await Task.sleep(for: .milliseconds(30))

        let evidence = try await fixture.relay.evidence(for: hookID)
        #expect(evidence.image == nil)
        #expect(evidence.domText?.contains("页面内容不足") == true)
    }

    @Test("Safari ready 使用 containing app dispatcher 完成双向确认")
    func safariHandshakeUsesContainingAppDispatcher() async throws {
        let dispatcher = RecordingSafariCommandDispatcher()
        let fixture = try await RelayHandshakeFixture(safariCommandDispatcher: dispatcher)
        defer { fixture.stop() }

        try await fixture.sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "safari-installation-1",
            "browserBundleIdentifier": "com.apple.Safari",
        ])
        let ping = try #require(await dispatcher.nextPayload())
        let command = try #require(
            JSONSerialization.jsonObject(with: ping) as? [String: Any]
        )
        let requestID = try #require(command["requestID"] as? String)
        #expect(command["type"] as? String == "ping")

        try await fixture.sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "safari-installation-1",
            "browserBundleIdentifier": "com.apple.Safari",
        ])

        try await fixture.waitForStatus("浏览器扩展已连接")
    }

    @Test("多个 Safari Profile 同时匹配时等待完整收集并拒绝歧义")
    func safariSelectionCollectsAllProfilesBeforeResolving() async throws {
        let dispatcher = RecordingSafariCommandDispatcher()
        let fixture = try await RelayHandshakeFixture(safariCommandDispatcher: dispatcher)
        defer { fixture.stop() }
        try await fixture.verifySafariConnection(dispatcher: dispatcher)

        let selection = ResolvedWindowSelection(
            window: DiscoveredWindow(
                applicationBundleIdentifier: "com.apple.Safari",
                applicationName: "Safari",
                windowIdentifier: 42,
                title: "Example",
                frame: CGRect(x: 100, y: 100, width: 1_000, height: 700)
            ),
            screenCaptureRect: CGRect(x: 200, y: 250, width: 300, height: 200),
            normalizedRegion: NormalizedRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        )
        let recorder = BrowserResolutionRecorder()
        Task {
            let resolution = try? await fixture.relay.resolveBrowserTarget(for: selection)
            await recorder.record(resolution)
        }
        let commandData = try #require(await dispatcher.nextPayload())
        let command = try #require(
            JSONSerialization.jsonObject(with: commandData) as? [String: Any]
        )
        let requestID = try #require(command["requestID"] as? String)

        try await fixture.sendMatchedSafariSelection(
            requestID: requestID,
            installationID: "safari-profile-1",
            tabID: 11
        )
        try await Task.sleep(for: .milliseconds(80))
        #expect(await recorder.value == nil)

        try await fixture.sendMatchedSafariSelection(
            requestID: requestID,
            installationID: "safari-profile-2",
            tabID: 22
        )
        let resolution = try await recorder.waitForValue()
        #expect(resolution == .unavailable(.ambiguousResponse))
    }

    @Test("Safari bind 只有收到目标已绑定 ACK 后才算成功")
    func safariBindWaitsForTargetBoundAcknowledgement() async throws {
        let dispatcher = RecordingSafariCommandDispatcher()
        let fixture = try await RelayHandshakeFixture(safariCommandDispatcher: dispatcher)
        defer { fixture.stop() }
        try await fixture.verifySafariConnection(dispatcher: dispatcher)

        let hookID = HookID(rawValue: UUID())
        let target = BrowserTarget(
            browserBundleIdentifier: "com.apple.Safari",
            nativeWindowIdentifier: 42,
            extensionInstallationID: "safari-installation-1",
            tabIdentifier: 7,
            host: "example.com",
            initialURL: URL(string: "https://example.com")!,
            initialTitle: "Example",
            normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            observationMode: .dom
        )
        let completion = OperationCompletionRecorder()
        Task {
            let succeeded = (try? await fixture.relay.bind(hookID: hookID, target: target)) != nil
            await completion.record(succeeded)
        }
        let bindData = try #require(await dispatcher.nextPayload())
        let bind = try #require(
            JSONSerialization.jsonObject(with: bindData) as? [String: Any]
        )
        #expect(bind["type"] as? String == "bindTarget")
        let requestID = try #require(bind["requestID"] as? String)

        try await Task.sleep(for: .milliseconds(80))
        #expect(await completion.value == nil)

        try await fixture.sendBrowserEvent([
            "type": "targetBound",
            "requestID": requestID,
            "extensionInstallationID": "safari-installation-1",
            "browserBundleIdentifier": "com.apple.Safari",
            "hookID": hookID.rawValue.uuidString,
            "tabID": 7,
        ])
        #expect(try await completion.waitForValue())
    }

    @Test("Safari 聚焦与解绑只有收到关联 ACK 后才算成功")
    func safariFocusAndUnbindWaitForAcknowledgements() async throws {
        let dispatcher = RecordingSafariCommandDispatcher()
        let fixture = try await RelayHandshakeFixture(safariCommandDispatcher: dispatcher)
        defer { fixture.stop() }
        try await fixture.verifySafariConnection(dispatcher: dispatcher)

        let hookID = HookID(rawValue: UUID())
        let target = BrowserTarget(
            browserBundleIdentifier: "com.apple.Safari",
            nativeWindowIdentifier: 42,
            extensionInstallationID: "safari-installation-1",
            tabIdentifier: 7,
            host: "example.com",
            initialURL: URL(string: "https://example.com")!,
            initialTitle: "Example",
            normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            observationMode: .dom
        )

        let focusCompletion = OperationCompletionRecorder()
        Task {
            let succeeded = (try? await fixture.relay.focus(hookID: hookID, target: target)) != nil
            await focusCompletion.record(succeeded)
        }
        let focusData = try #require(await dispatcher.nextPayload())
        let focus = try #require(
            JSONSerialization.jsonObject(with: focusData) as? [String: Any]
        )
        #expect(focus["type"] as? String == "focusTarget")
        let focusRequestID = try #require(focus["requestID"] as? String)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await focusCompletion.value == nil)

        try await fixture.sendBrowserEvent([
            "type": "targetFocused",
            "requestID": focusRequestID,
            "extensionInstallationID": target.extensionInstallationID,
            "browserBundleIdentifier": target.browserBundleIdentifier,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
        ])
        #expect(try await focusCompletion.waitForValue())

        let unbindCompletion = OperationCompletionRecorder()
        Task {
            let succeeded = (try? await fixture.relay.unbind(hookID: hookID, target: target)) != nil
            await unbindCompletion.record(succeeded)
        }
        let unbindData = try #require(await dispatcher.nextPayload())
        let unbind = try #require(
            JSONSerialization.jsonObject(with: unbindData) as? [String: Any]
        )
        #expect(unbind["type"] as? String == "unbindTarget")
        let unbindRequestID = try #require(unbind["requestID"] as? String)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await unbindCompletion.value == nil)

        try await fixture.sendBrowserEvent([
            "type": "targetUnbound",
            "requestID": unbindRequestID,
            "extensionInstallationID": target.extensionInstallationID,
            "browserBundleIdentifier": target.browserBundleIdentifier,
            "hookID": hookID.rawValue.uuidString,
        ])
        #expect(try await unbindCompletion.waitForValue())
    }

    @Test("AwaitCue 退出前主动停止全部 Safari 页面观察")
    func stoppingRelayStopsAllSafariBindings() async throws {
        let dispatcher = RecordingSafariCommandDispatcher()
        let fixture = try await RelayHandshakeFixture(safariCommandDispatcher: dispatcher)
        defer { fixture.stop() }
        try await fixture.verifySafariConnection(dispatcher: dispatcher)

        await fixture.relay.stop()

        let payload = try #require(await dispatcher.nextPayload())
        let command = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        #expect(command["type"] as? String == "stopAllBindings")
    }
}

private final class RelayHandshakeFixture: @unchecked Sendable {
    let relay: NativeBrowserSelectionRelay

    private let server: NativeBridgeServer
    private let client: NativeBridgeClient
    private let recorder = RelayStatusRecorder()
    private var statusTask: Task<Void, Never>?

    init(
        safariCommandDispatcher: any SafariExtensionCommandDispatching = SafariExtensionCommandDispatcher(),
        handshakeTimeout: Duration = .seconds(10),
        selectionCollectionTimeout: Duration = .seconds(3)
    ) async throws {
        let server = NativeBridgeServer()
        let descriptor = try await server.start()
        let client = NativeBridgeClient(descriptor: descriptor)
        try await client.connect()
        let relay = NativeBrowserSelectionRelay(
            server: server,
            safariCommandDispatcher: safariCommandDispatcher,
            handshakeTimeout: handshakeTimeout,
            selectionCollectionTimeout: selectionCollectionTimeout,
            commandAcknowledgementTimeout: .seconds(1)
        )

        self.server = server
        self.client = client
        self.relay = relay
        await relay.start()
        statusTask = Task { [recorder, statuses = relay.statuses] in
            for await status in statuses {
                await recorder.append(status.message)
            }
        }
    }

    func stop() {
        statusTask?.cancel()
        client.stop()
        server.stop()
        Task { await relay.stop() }
    }

    func sendBrowserEvent(_ object: [String: Any]) async throws {
        try await client.sendPayload(JSONSerialization.data(withJSONObject: object))
    }

    func verifyConnection() async throws {
        try await sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        let ping = try #require(await nextAppCommand())
        let requestID = try #require(ping["requestID"] as? String)
        try await sendBrowserEvent([
            "type": "pong",
            "requestID": requestID,
            "extensionInstallationID": "installation-1",
            "browserBundleIdentifier": "com.google.Chrome",
        ])
        try await waitForStatus("浏览器扩展已连接")
    }

    func bindAndAcknowledge(hookID: HookID, target: BrowserTarget) async throws {
        let completion = OperationCompletionRecorder()
        Task {
            let succeeded = (try? await relay.bind(hookID: hookID, target: target)) != nil
            await completion.record(succeeded)
        }
        let command = try #require(await nextAppCommand())
        try await sendBrowserEvent([
            "type": "targetBound",
            "requestID": try #require(command["requestID"] as? String),
            "extensionInstallationID": target.extensionInstallationID,
            "browserBundleIdentifier": target.browserBundleIdentifier,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
        ])
        #expect(try await completion.waitForValue())
    }

    func verifySafariConnection(
        dispatcher: RecordingSafariCommandDispatcher
    ) async throws {
        try await sendBrowserEvent([
            "type": "ready",
            "extensionInstallationID": "safari-installation-1",
            "browserBundleIdentifier": "com.apple.Safari",
        ])
        let pingData = try #require(await dispatcher.nextPayload())
        let ping = try #require(
            JSONSerialization.jsonObject(with: pingData) as? [String: Any]
        )
        try await sendBrowserEvent([
            "type": "pong",
            "requestID": try #require(ping["requestID"] as? String),
            "extensionInstallationID": "safari-installation-1",
            "browserBundleIdentifier": "com.apple.Safari",
        ])
        try await waitForStatus("浏览器扩展已连接")
    }

    func sendMatchedSafariSelection(
        requestID: String,
        installationID: String,
        tabID: Int
    ) async throws {
        try await sendBrowserEvent([
            "type": "selectionResolved",
            "requestID": requestID,
            "matched": true,
            "browserBundleIdentifier": "com.apple.Safari",
            "target": [
                "extensionInstallationID": installationID,
                "tabID": tabID,
                "host": "example.com",
                "url": "https://example.com",
                "title": "Example",
                "region": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.3],
            ],
        ])
    }

    func nextAppCommand(timeout: Duration = .milliseconds(300)) async -> [String: Any]? {
        let payload = await withTaskGroup(of: Data?.self) { group in
            group.addTask { [client] in
                for await payload in client.incomingMessages {
                    return payload
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let payload else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    func statuses() async -> [String] {
        await recorder.snapshot()
    }

    func waitForStatus(_ expected: String, timeout: Duration = .seconds(1)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await recorder.snapshot().contains(expected) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待状态超时：\(expected)")
    }
}

private actor BrowserResolutionRecorder {
    private(set) var value: BrowserSelectionRelayResolution?

    func record(_ resolution: BrowserSelectionRelayResolution?) {
        value = resolution
    }

    func waitForValue() async throws -> BrowserSelectionRelayResolution {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let value { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

private actor OperationCompletionRecorder {
    private(set) var value: Bool?

    func record(_ result: Bool) {
        value = result
    }

    func waitForValue() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let value { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}

private actor RecordingSafariCommandDispatcher: SafariExtensionCommandDispatching {
    private var payloads: [Data] = []

    func dispatch(_ payload: Data) async throws {
        payloads.append(payload)
    }

    func showPreferences() async throws {}

    func isEnabled() async throws -> Bool {
        true
    }

    func nextPayload(timeout: Duration = .milliseconds(300)) async -> Data? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !payloads.isEmpty {
                return payloads.removeFirst()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

private actor RelayStatusRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}
