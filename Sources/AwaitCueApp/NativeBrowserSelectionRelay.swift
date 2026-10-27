import AwaitCueBrowserBridge
import AwaitCueCore
import AwaitCueModel
import AwaitCueRuntime
import AwaitCueSafariBridge
import AwaitCueSelection
import Foundation
import OSLog

private enum BrowserTargetCommandError: Error {
    case targetUnavailable
}

struct BrowserBridgeStatusUpdate: Sendable {
    let browserBundleIdentifier: String?
    let message: String
}

/// 通过浏览器各自的 transport 查询具体标签页身份和 DOM-only 页面证据。
actor NativeBrowserSelectionRelay: BrowserSelectionRelaying, ActiveBrowserHostResolving {
    private static let chromiumProtocolVersion = 1
    private static let versionMismatchMessage = "浏览器扩展版本不匹配，请更新或重新加载"
    private static let logger = Logger(
        subsystem: "org.awaitcue.AwaitCue",
        category: "BrowserSelectionRelay"
    )
    private static let e2eDiagnosticsEnabled = ProcessInfo.processInfo.environment[
        "AWAITCUE_E2E_DIAGNOSTICS"
    ] == "1"
    nonisolated let statuses: AsyncStream<BrowserBridgeStatusUpdate>
    nonisolated let evidenceUpdates: AsyncStream<HookID>
    nonisolated let targetUnavailableUpdates: AsyncStream<HookID>

    private struct PendingSelection {
        let browserBundleIdentifier: String
        let nativeWindowIdentifier: UInt32
        let continuation: CheckedContinuation<BrowserSelectionRelayResolution, any Error>
        var collector: BrowserSelectionMatchCollector
        var responseGate: BrowserSelectionResponseGate
    }

    private struct PendingActiveHost {
        let continuation: CheckedContinuation<ActiveBrowserHostResolution, any Error>
        var collector: ActiveBrowserHostMatchCollector
    }

    private struct BoundInstallation {
        let extensionInstallationID: String
        let browserBundleIdentifier: String
        let selectionRegionExpanded: Bool
    }

    private struct BrowserInstallationIdentity: Hashable {
        let extensionInstallationID: String
        let browserBundleIdentifier: String
        let protocolVersion: Int?
        let extensionVersion: String?
    }

    private struct PendingBinding {
        let hookID: HookID
        let extensionInstallationID: String
        let browserBundleIdentifier: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingTargetCommand {
        let hookID: HookID
        let extensionInstallationID: String
        let browserBundleIdentifier: String
        let expectedAcknowledgement: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let server: NativeBridgeServer
    private let safariCommandDispatcher: any SafariExtensionCommandDispatching
    private let handshakeTimeout: Duration
    private let selectionCollectionTimeout: Duration
    private let commandAcknowledgementTimeout: Duration
    private let statusContinuation: AsyncStream<BrowserBridgeStatusUpdate>.Continuation
    private let evidenceUpdateContinuation: AsyncStream<HookID>.Continuation
    private let targetUnavailableContinuation: AsyncStream<HookID>.Continuation
    private var pending: [String: PendingSelection] = [:]
    private var pendingActiveHosts: [String: PendingActiveHost] = [:]
    private var evidenceByHook: [HookID: ModelEvidence] = [:]
    private var installationByHook: [HookID: BoundInstallation] = [:]
    private var previewDOMByTarget: [String: String] = [:]
    private var pendingHandshakes: [String: BrowserInstallationIdentity] = [:]
    private var timedOutHandshakeRequestIDs: Set<String> = []
    private var pendingBindings: [String: PendingBinding] = [:]
    private var pendingTargetCommands: [String: PendingTargetCommand] = [:]
    private var verifiedInstallations: Set<BrowserInstallationIdentity> = []
    private var listenTask: Task<Void, Never>?

    init(
        server: NativeBridgeServer,
        safariCommandDispatcher: any SafariExtensionCommandDispatching = SafariExtensionCommandDispatcher(),
        handshakeTimeout: Duration = .seconds(10),
        selectionCollectionTimeout: Duration = .seconds(10),
        commandAcknowledgementTimeout: Duration = .seconds(10)
    ) {
        self.server = server
        self.safariCommandDispatcher = safariCommandDispatcher
        self.handshakeTimeout = handshakeTimeout
        self.selectionCollectionTimeout = selectionCollectionTimeout
        self.commandAcknowledgementTimeout = commandAcknowledgementTimeout
        // 浏览器页面可以高频变化；只保留有限最新事件，避免主线程暂时阻塞时积累敏感证据通知。
        let stream = AsyncStream<BrowserBridgeStatusUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        statuses = stream.stream
        statusContinuation = stream.continuation
        let evidenceStream = AsyncStream<HookID>.makeStream(bufferingPolicy: .bufferingNewest(64))
        evidenceUpdates = evidenceStream.stream
        evidenceUpdateContinuation = evidenceStream.continuation
        let unavailableStream = AsyncStream<HookID>.makeStream(bufferingPolicy: .bufferingNewest(64))
        targetUnavailableUpdates = unavailableStream.stream
        targetUnavailableContinuation = unavailableStream.continuation
    }

    /// 开始独占消费 server 消息，并将状态与 request-response 分开路由。
    func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self, server] in
            for await payload in server.incomingMessages {
                await self?.handle(payload)
            }
        }
    }

    func stop() async {
        guard let activeListenTask = listenTask else { return }
        if hasVerifiedInstallation(
            for: SafariBridgeMessageCodec.browserBundleIdentifier
        ), let payload = try? JSONSerialization.data(withJSONObject: [
            "type": "stopAllBindings",
        ]) {
            // Safari native extension 与菜单栏 App 生命周期独立；退出前必须显式停止页面观察。
            try? await safariCommandDispatcher.dispatch(payload)
        }
        activeListenTask.cancel()
        listenTask = nil
        for selection in pending.values {
            selection.continuation.resume(returning: .unavailable(.noExtensionResponse))
        }
        pending.removeAll()
        for hostQuery in pendingActiveHosts.values {
            hostQuery.continuation.resume(returning: .unavailable)
        }
        pendingActiveHosts.removeAll()
        previewDOMByTarget.removeAll()
        pendingHandshakes.removeAll()
        timedOutHandshakeRequestIDs.removeAll()
        for binding in pendingBindings.values {
            binding.continuation.resume(throwing: NativeBridgeError.disconnected)
        }
        pendingBindings.removeAll()
        for command in pendingTargetCommands.values {
            command.continuation.resume(throwing: NativeBridgeError.disconnected)
        }
        pendingTargetCommands.removeAll()
        verifiedInstallations.removeAll()
        statusContinuation.finish()
        evidenceUpdateContinuation.finish()
        targetUnavailableContinuation.finish()
    }

    /// 告诉解析出具体 tab 的扩展开始 DOM、ARIA 和状态属性观察。
    func bind(hookID: HookID, target: BrowserTarget) async throws {
        let requestID = UUID().uuidString
        let command: [String: Any] = [
            "type": "bindTarget",
            "requestID": requestID,
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
            "expectedHost": target.host,
            "expectedURL": target.initialURL.absoluteString,
            "region": Self.jsonRegion(target.normalizedRegion),
            "selectionRegionExpanded": target.selectionRegionExpanded,
        ]
        installationByHook[hookID] = BoundInstallation(
            extensionInstallationID: target.extensionInstallationID,
            browserBundleIdentifier: target.browserBundleIdentifier,
            selectionRegionExpanded: target.selectionRegionExpanded
        )
        let payload = try JSONSerialization.data(withJSONObject: command)
        let commandTimeout = commandAcknowledgementTimeout
        try await withCheckedThrowingContinuation { continuation in
            pendingBindings[requestID] = PendingBinding(
                hookID: hookID,
                extensionInstallationID: target.extensionInstallationID,
                browserBundleIdentifier: target.browserBundleIdentifier,
                continuation: continuation
            )
            Task { [weak self] in
                do {
                    guard let self else { return }
                    _ = try await self.sendPayload(payload, to: target.browserBundleIdentifier)
                } catch {
                    await self?.finishBinding(requestID: requestID, error: error)
                    return
                }
                try? await Task.sleep(for: commandTimeout)
                await self?.finishBinding(
                    requestID: requestID,
                    error: NativeBridgeError.disconnected
                )
            }
        }
    }

    /// 停止指定浏览器 Hook 的页面内容观察。
    func unbind(hookID: HookID, target: BrowserTarget) async throws {
        var command: [String: Any] = [
            "type": "unbindTarget",
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
        ]
        let requestID = UUID().uuidString
        command["requestID"] = requestID
        try await sendCommandAwaitingAcknowledgement(
            command,
            requestID: requestID,
            expectedAcknowledgement: "targetUnbound",
            hookID: hookID,
            target: target
        )
        evidenceByHook[hookID] = nil
        installationByHook[hookID] = nil
    }

    /// 激活持久化 Target 原本绑定的标签页；扩展仍会重新验证 tab URL 与 host。
    func focus(hookID: HookID, target: BrowserTarget) async throws {
        var command: [String: Any] = [
            "type": "focusTarget",
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
            "expectedHost": target.host,
            "expectedURL": target.initialURL.absoluteString,
        ]
        let requestID = UUID().uuidString
        command["requestID"] = requestID
        try await sendCommandAwaitingAcknowledgement(
            command,
            requestID: requestID,
            expectedAcknowledgement: "targetFocused",
            hookID: hookID,
            target: target
        )
    }

    /// 验证 Delay 或已满足 Hook 原先绑定的 tab 仍是同一 Target，不产生聚焦或 DOM 观察副作用。
    func targetIsAvailable(hookID: HookID, target: BrowserTarget) async throws -> Bool {
        let requestID = UUID().uuidString
        let command: [String: Any] = [
            "type": "validateTarget",
            "requestID": requestID,
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
            "expectedHost": target.host,
            "expectedURL": target.initialURL.absoluteString,
        ]
        do {
            try await sendCommandAwaitingAcknowledgement(
                command,
                requestID: requestID,
                expectedAcknowledgement: "targetValidated",
                hookID: hookID,
                target: target
            )
            return true
        } catch BrowserTargetCommandError.targetUnavailable {
            return false
        }
    }

    /// 返回扩展最近一次只驻留内存的页面内容证据。
    func evidence(for hookID: HookID) throws -> ModelEvidence {
        guard let evidence = evidenceByHook[hookID] else {
            throw HookRuntimeEvidenceError.browserExtensionDisconnected
        }
        return evidence
    }

    /// 取出框选响应携带的初始 DOM；读取后立即删除，避免页面内容在内存中长期滞留。
    func previewDOMText(for target: BrowserTarget) async -> String? {
        previewDOMByTarget.removeValue(forKey: Self.previewKey(for: target))
    }

    /// 非浏览器明确降级到 WindowTarget；浏览器必须由扩展返回具体 tab，超时不会猜测。
    func resolveBrowserTarget(
        for selection: ResolvedWindowSelection
    ) async throws -> BrowserSelectionRelayResolution {
        guard Self.browserBundleIdentifiers.contains(selection.window.applicationBundleIdentifier) else {
            return .notBrowser
        }
        guard await waitForVerifiedInstallation(
            for: selection.window.applicationBundleIdentifier
        ) else {
            Self.writeE2EDiagnostic("resolveSelection blocked: browser is not duplex-verified")
            return .unavailable(.noExtensionResponse)
        }
        let requestID = UUID().uuidString
        let command: [String: Any] = [
            "type": "resolveSelection",
            "requestID": requestID,
            "windowFrame": Self.jsonRect(selection.window.frame),
            "selectionRect": Self.jsonRect(selection.screenCaptureRect),
        ]
        let payload = try JSONSerialization.data(withJSONObject: command)
        let collectionTimeout = selectionCollectionTimeout

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingSelection(
                browserBundleIdentifier: selection.window.applicationBundleIdentifier,
                nativeWindowIdentifier: selection.window.windowIdentifier,
                continuation: continuation,
                collector: BrowserSelectionMatchCollector(
                    browserBundleIdentifier: selection.window.applicationBundleIdentifier
                ),
                responseGate: BrowserSelectionResponseGate()
            )
            Task { [weak self] in
                do {
                    guard let self else { return }
                    let recipientCount = try await self.sendPayload(
                        payload,
                        to: selection.window.applicationBundleIdentifier
                    )
                    Self.logger.info("resolveSelection broadcast recipients=\(recipientCount)")
                    Self.writeE2EDiagnostic(
                        "resolveSelection broadcast recipients=\(recipientCount)"
                    )
                    // Safari dispatch 可能抵达多个 Profile，completion 次数不等于 installation 数量；
                    // 必须收满窗口，才能识别两个匹配或先失败后成功，避免绑定错误 Profile。
                    if selection.window.applicationBundleIdentifier
                        != SafariBridgeMessageCodec.browserBundleIdentifier
                    {
                        await self.setExpectedSelectionResponseCount(
                            recipientCount,
                            requestID: requestID
                        )
                    }
                } catch {
                    await self?.finish(
                        requestID: requestID,
                        with: .unavailable(.noExtensionResponse)
                    )
                    return
                }
                try? await Task.sleep(for: collectionTimeout)
                await self?.finishSelectionAfterCollection(requestID: requestID)
            }
        }
    }

    /// 查询当前真正处于 focused 状态的浏览器 installation；多 profile 响应会安全拒绝。
    func resolveActiveBrowserHost(
        for browserBundleIdentifier: String
    ) async throws -> ActiveBrowserHostResolution {
        guard Self.browserBundleIdentifiers.contains(browserBundleIdentifier) else {
            return .notBrowser
        }
        guard hasVerifiedInstallation(for: browserBundleIdentifier) else {
            return .unavailable
        }
        let requestID = UUID().uuidString
        let payload = try JSONSerialization.data(withJSONObject: [
            "type": "resolveActiveHost",
            "requestID": requestID,
        ])

        return try await withCheckedThrowingContinuation { continuation in
            pendingActiveHosts[requestID] = PendingActiveHost(
                continuation: continuation,
                collector: ActiveBrowserHostMatchCollector(
                    browserBundleIdentifier: browserBundleIdentifier
                )
            )
            Task { [weak self] in
                do {
                    guard let self else { return }
                    _ = try await self.sendPayload(payload, to: browserBundleIdentifier)
                } catch {
                    await self?.finishActiveHost(
                        requestID: requestID,
                        with: .unavailable
                    )
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
                await self?.finishActiveHostCollection(requestID: requestID)
            }
        }
    }

    private func handle(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = object["type"] as? String
        else {
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(browserBundleIdentifier: nil, message: "扩展消息无效")
            )
            return
        }
        Self.logger.info("received browser event type=\(type, privacy: .public)")
        Self.writeE2EDiagnostic("received browser event type=\(type)")
        switch type {
        case "ready":
            beginHandshake(object)
        case "pong":
            finishHandshake(object)
        case "selectionResolved":
            handleSelectionResponse(object)
        case "activeHostResolved":
            handleActiveHostResponse(object)
        case "evidenceChanged":
            handleDOMEvidence(object)
        case "targetBound":
            handleTargetBound(object)
        case "targetFocused", "targetUnbound", "targetValidated":
            handleTargetCommandAcknowledgement(type: type, object: object)
        case "targetUnavailable":
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(
                    browserBundleIdentifier: object["browserBundleIdentifier"] as? String,
                    message: "浏览器目标不可用"
                )
            )
            handleTargetUnavailable(object)
        case "error":
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(
                    browserBundleIdentifier: object["browserBundleIdentifier"] as? String,
                    message: "浏览器扩展报告错误"
                )
            )
            handleTargetCommandError(object)
        default:
            break
        }
    }

    /// ready 只证明浏览器可以向应用发消息；必须用关联的 ping/pong 再确认反向链路。
    private func beginHandshake(_ object: [String: Any]) {
        guard let extensionInstallationID = object["extensionInstallationID"] as? String,
              !extensionInstallationID.isEmpty,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              Self.browserBundleIdentifiers.contains(browserBundleIdentifier)
        else {
            return
        }
        // 同一 installation 的旧 worker 或旧协议不能继续沿用先前的验证状态。
        verifiedInstallations = verifiedInstallations.filter {
            $0.extensionInstallationID != extensionInstallationID
                || $0.browserBundleIdentifier != browserBundleIdentifier
        }
        let supersededRequestIDs = pendingHandshakes.compactMap { requestID, value in
            value.extensionInstallationID == extensionInstallationID
                && value.browserBundleIdentifier == browserBundleIdentifier
                ? requestID
                : nil
        }
        for requestID in supersededRequestIDs {
            pendingHandshakes[requestID] = nil
            timedOutHandshakeRequestIDs.remove(requestID)
        }

        let isSafari = browserBundleIdentifier
            == SafariBridgeMessageCodec.browserBundleIdentifier
        let protocolVersion = object["protocolVersion"] as? Int
        let extensionVersion = object["extensionVersion"] as? String
        if !isSafari,
           protocolVersion != Self.chromiumProtocolVersion
            || extensionVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(
                    browserBundleIdentifier: browserBundleIdentifier,
                    message: Self.versionMismatchMessage
                )
            )
            return
        }
        let identity = BrowserInstallationIdentity(
            extensionInstallationID: extensionInstallationID,
            browserBundleIdentifier: browserBundleIdentifier,
            protocolVersion: isSafari ? nil : protocolVersion,
            extensionVersion: isSafari ? nil : extensionVersion
        )
        // 同一 service worker 再次 ready 时，旧验证不能替新端口背书；旧 timeout 也必须失效。
        let requestID = UUID().uuidString
        pendingHandshakes[requestID] = identity
        let timeout = handshakeTimeout
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: [
                "type": "ping",
                "requestID": requestID,
                "extensionInstallationID": extensionInstallationID,
            ])
        } catch {
            pendingHandshakes[requestID] = nil
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(
                    browserBundleIdentifier: browserBundleIdentifier,
                    message: "浏览器扩展已启动，但双向通信不可用"
                )
            )
            return
        }

        Task { [weak self] in
            do {
                guard let self else { return }
                let recipientCount = try await self.sendPayload(
                    payload,
                    to: browserBundleIdentifier
                )
                Self.writeE2EDiagnostic("handshake ping broadcast recipients=\(recipientCount)")
                guard recipientCount > 0 else {
                    await self.failHandshake(requestID: requestID)
                    return
                }
            } catch {
                await self?.failHandshake(requestID: requestID)
                return
            }
            try? await Task.sleep(for: timeout)
            await self?.failHandshake(requestID: requestID)
        }
    }

    /// 只有 request、installation 和操作系统验证过的 browser bundle 全部一致才确认连接。
    private func finishHandshake(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              let expectedIdentity = pendingHandshakes[requestID],
              let extensionInstallationID = object["extensionInstallationID"] as? String,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              expectedIdentity.extensionInstallationID == extensionInstallationID,
              expectedIdentity.browserBundleIdentifier == browserBundleIdentifier
        else {
            return
        }
        if expectedIdentity.browserBundleIdentifier
            != SafariBridgeMessageCodec.browserBundleIdentifier,
           object["protocolVersion"] as? Int != expectedIdentity.protocolVersion
            || object["extensionVersion"] as? String != expectedIdentity.extensionVersion
        {
            pendingHandshakes[requestID] = nil
            timedOutHandshakeRequestIDs.remove(requestID)
            statusContinuation.yield(
                BrowserBridgeStatusUpdate(
                    browserBundleIdentifier: expectedIdentity.browserBundleIdentifier,
                    message: Self.versionMismatchMessage
                )
            )
            return
        }
        pendingHandshakes = pendingHandshakes.filter { $0.value != expectedIdentity }
        timedOutHandshakeRequestIDs.remove(requestID)
        verifiedInstallations.insert(expectedIdentity)
        Self.writeE2EDiagnostic("handshake verified")
        statusContinuation.yield(
            BrowserBridgeStatusUpdate(
                browserBundleIdentifier: expectedIdentity.browserBundleIdentifier,
                message: "浏览器扩展已连接"
            )
        )
    }

    private func failHandshake(requestID: String) {
        guard let identity = pendingHandshakes[requestID],
              timedOutHandshakeRequestIDs.insert(requestID).inserted
        else {
            return
        }
        Self.writeE2EDiagnostic("handshake timed out")
        statusContinuation.yield(
            BrowserBridgeStatusUpdate(
                browserBundleIdentifier: identity.browserBundleIdentifier,
                message: "浏览器扩展已启动，但双向通信不可用"
            )
        )
    }

    private func hasVerifiedInstallation(for browserBundleIdentifier: String) -> Bool {
        verifiedInstallations.contains {
            $0.browserBundleIdentifier == browserBundleIdentifier
        }
    }

    /// 用户可能在 ready→pong 期间立即框选；等待当前握手比要求用户重新操作更可靠。
    private func waitForVerifiedInstallation(
        for browserBundleIdentifier: String
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: handshakeTimeout)
        while ContinuousClock.now < deadline {
            if hasVerifiedInstallation(for: browserBundleIdentifier) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return hasVerifiedInstallation(for: browserBundleIdentifier)
    }

    /// Chromium 通过 loopback relay 广播；Safari 由 containing app 直接 dispatch 到嵌入式扩展。
    private func sendPayload(
        _ payload: Data,
        to browserBundleIdentifier: String
    ) async throws -> Int {
        if browserBundleIdentifier == SafariBridgeMessageCodec.browserBundleIdentifier {
            try await safariCommandDispatcher.dispatch(payload)
            return 1
        }
        return try await server.broadcastPayload(payload)
    }

    /// transport 接受消息不代表扩展已经完成操作；聚焦和解绑统一等待关联 ACK。
    private func sendCommandAwaitingAcknowledgement(
        _ command: [String: Any],
        requestID: String,
        expectedAcknowledgement: String,
        hookID: HookID,
        target: BrowserTarget
    ) async throws {
        let payload = try JSONSerialization.data(withJSONObject: command)
        let commandTimeout = commandAcknowledgementTimeout
        try await withCheckedThrowingContinuation { continuation in
            pendingTargetCommands[requestID] = PendingTargetCommand(
                hookID: hookID,
                extensionInstallationID: target.extensionInstallationID,
                browserBundleIdentifier: target.browserBundleIdentifier,
                expectedAcknowledgement: expectedAcknowledgement,
                continuation: continuation
            )
            Task { [weak self] in
                do {
                    guard let self else { return }
                    _ = try await self.sendPayload(payload, to: target.browserBundleIdentifier)
                } catch {
                    await self?.finishTargetCommand(requestID: requestID, error: error)
                    return
                }
                try? await Task.sleep(for: commandTimeout)
                await self?.finishTargetCommand(
                    requestID: requestID,
                    error: NativeBridgeError.disconnected
                )
            }
        }
    }

    /// live E2E 只输出协议阶段和连接数量，不记录 URL、DOM、截图、installation ID 或 request ID。
    private nonisolated static func writeE2EDiagnostic(_ message: String) {
        guard e2eDiagnosticsEnabled else { return }
        let timestampMilliseconds = Int(Date().timeIntervalSince1970 * 1_000)
        try? FileHandle.standardError.write(
            contentsOf: Data(
                "AwaitCueBrowserRelay t=\(timestampMilliseconds) \(message)\n".utf8
            )
        )
    }

    private func handleTargetUnavailable(_ object: [String: Any]) {
        guard let hookIDString = object["hookID"] as? String,
              let installationID = object["extensionInstallationID"] as? String,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let uuid = UUID(uuidString: hookIDString)
        else {
            return
        }
        let hookID = HookID(rawValue: uuid)
        if let requestID = object["requestID"] as? String,
           let pendingBinding = pendingBindings[requestID],
           pendingBinding.hookID == hookID,
           pendingBinding.extensionInstallationID == installationID,
           pendingBinding.browserBundleIdentifier == browserBundleIdentifier
        {
            finishBinding(requestID: requestID, error: NativeBridgeError.disconnected)
            return
        }
        if let requestID = object["requestID"] as? String,
           let pendingCommand = pendingTargetCommands[requestID],
           pendingCommand.hookID == hookID,
           pendingCommand.extensionInstallationID == installationID,
           pendingCommand.browserBundleIdentifier == browserBundleIdentifier
        {
            let error: any Error = pendingCommand.expectedAcknowledgement == "targetValidated"
                ? BrowserTargetCommandError.targetUnavailable
                : NativeBridgeError.disconnected
            finishTargetCommand(requestID: requestID, error: error)
        }
        guard let binding = installationByHook[hookID],
              binding.extensionInstallationID == installationID,
              binding.browserBundleIdentifier == browserBundleIdentifier
        else {
            return
        }
        evidenceByHook[hookID] = nil
        installationByHook[hookID] = nil
        targetUnavailableContinuation.yield(hookID)
    }

    private func handleTargetBound(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              let pendingBinding = pendingBindings[requestID],
              let hookIDString = object["hookID"] as? String,
              UUID(uuidString: hookIDString) == pendingBinding.hookID.rawValue,
              object["extensionInstallationID"] as? String
                == pendingBinding.extensionInstallationID,
              object["browserBundleIdentifier"] as? String
                == pendingBinding.browserBundleIdentifier
        else {
            return
        }
        pendingBindings.removeValue(forKey: requestID)?.continuation.resume(returning: ())
    }

    private func handleTargetCommandAcknowledgement(
        type: String,
        object: [String: Any]
    ) {
        guard let requestID = object["requestID"] as? String,
              let pendingCommand = pendingTargetCommands[requestID],
              pendingCommand.expectedAcknowledgement == type,
              let hookIDString = object["hookID"] as? String,
              UUID(uuidString: hookIDString) == pendingCommand.hookID.rawValue,
              object["extensionInstallationID"] as? String
                == pendingCommand.extensionInstallationID,
              object["browserBundleIdentifier"] as? String
                == pendingCommand.browserBundleIdentifier
        else {
            return
        }
        pendingTargetCommands.removeValue(forKey: requestID)?.continuation.resume(returning: ())
    }

    private func handleTargetCommandError(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              let pendingCommand = pendingTargetCommands[requestID],
              let hookIDString = object["hookID"] as? String,
              UUID(uuidString: hookIDString) == pendingCommand.hookID.rawValue,
              object["extensionInstallationID"] as? String
                == pendingCommand.extensionInstallationID,
              object["browserBundleIdentifier"] as? String
                == pendingCommand.browserBundleIdentifier
        else {
            return
        }
        finishTargetCommand(requestID: requestID, error: NativeBridgeError.disconnected)
    }

    private func finishBinding(requestID: String, error: any Error) {
        guard let binding = pendingBindings.removeValue(forKey: requestID) else { return }
        installationByHook[binding.hookID] = nil
        binding.continuation.resume(throwing: error)
    }

    private func finishTargetCommand(requestID: String, error: any Error) {
        guard let command = pendingTargetCommands.removeValue(forKey: requestID) else { return }
        command.continuation.resume(throwing: error)
    }

    private func handleDOMEvidence(_ object: [String: Any]) {
        guard var evidence = object["evidence"] as? [String: Any],
              let installationID = object["extensionInstallationID"] as? String,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let hookIDString = evidence["hookID"] as? String,
              let uuid = UUID(uuidString: hookIDString)
        else {
            return
        }
        let hookID = HookID(rawValue: uuid)
        guard let binding = installationByHook[hookID],
              binding.extensionInstallationID == installationID,
              binding.browserBundleIdentifier == browserBundleIdentifier
        else {
            return
        }
        // 持久化的 Target 是读取范围语义的权威来源；即使旧扩展漏传可选字段，
        // 也不能让模型在 App 重启或扩展回退后把扩大范围误认为精确框选。
        if binding.selectionRegionExpanded {
            evidence["selectionRegionExpanded"] = true
        }
        guard let domText = Self.domText(from: evidence) else { return }
        evidenceByHook[hookID] = ModelEvidence(domText: domText)
        evidenceUpdateContinuation.yield(hookID)
    }

    private func handleSelectionResponse(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              var pendingSelection = pending[requestID],
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              browserBundleIdentifier == pendingSelection.browserBundleIdentifier
        else {
            return
        }
        guard object["matched"] as? Bool == true else {
            let reason = (object["reason"] as? String)
                .flatMap(BrowserSelectionFailureReason.init(rawValue:))
                ?? .invalidPageResponse
            pendingSelection.collector.recordFailure(
                browserBundleIdentifier: browserBundleIdentifier,
                reason: reason
            )
            pendingSelection.responseGate.recordAcceptedResponse()
            pending[requestID] = pendingSelection
            finishSelectionIfComplete(requestID: requestID)
            return
        }
        guard let target = object["target"] as? [String: Any],
              let extensionID = target["extensionInstallationID"] as? String,
              let tabID = target["tabID"] as? Int,
              let host = target["host"] as? String,
              let urlString = target["url"] as? String,
              let url = URL(string: urlString),
              let title = target["title"] as? String,
              let regionObject = target["region"] as? [String: Any],
              let region = Self.region(from: regionObject)
        else {
            pendingSelection.collector.recordFailure(
                browserBundleIdentifier: browserBundleIdentifier,
                reason: .invalidPageResponse
            )
            pendingSelection.responseGate.recordAcceptedResponse()
            pending[requestID] = pendingSelection
            finishSelectionIfComplete(requestID: requestID)
            return
        }
        let browserTarget = BrowserTarget(
            browserBundleIdentifier: pendingSelection.browserBundleIdentifier,
            nativeWindowIdentifier: pendingSelection.nativeWindowIdentifier,
            extensionInstallationID: extensionID,
            tabIdentifier: tabID,
            host: host,
            initialURL: url,
            initialTitle: title,
            normalizedRegion: region,
            observationMode: .dom,
            selectionRegionExpanded: target["selectionRegionExpanded"] as? Bool ?? false
        )
        if var evidence = target["evidence"] as? [String: Any]
        {
            // 框选响应的首份证据可能只在 target 层携带标记；统一补进 evidence，确保预览与后续判断语义一致。
            if browserTarget.selectionRegionExpanded {
                evidence["selectionRegionExpanded"] = true
            }
            if let domText = Self.domText(from: evidence) {
                previewDOMByTarget[Self.previewKey(for: browserTarget)] = domText
            }
        }
        pendingSelection.collector.record(
            browserBundleIdentifier: browserBundleIdentifier,
            target: browserTarget
        )
        pendingSelection.responseGate.recordAcceptedResponse()
        pending[requestID] = pendingSelection
        finishSelectionIfComplete(requestID: requestID)
    }

    /// 把扩展的标题、URL、区域文字和语义属性整理成模型可读但不持久化的网页证据。
    private static func domText(from evidence: [String: Any]) -> String? {
        let title = (evidence["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = (evidence["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let html = (evidence["html"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (evidence["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let semantics = (evidence["aria"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let insufficiency: String? = if evidence["availability"] as? String == "insufficient" {
            switch evidence["insufficiencyReason"] as? String {
            case "no_semantic_content":
                "页面内容不足：框选区域没有可供判断的正文或 HTML 属性；不得使用截图推测。"
            default:
                "页面内容不足：浏览器扩展无法读取足够的 HTML 证据；不得使用截图推测。"
            }
        } else {
            nil
        }
        let selectionRegionExpanded = evidence["selectionRegionExpanded"] as? Bool == true
        let expandedRegionGuidance: String? = if selectionRegionExpanded {
            """
            读取范围提示：浏览器侧栏导致读取范围横向扩大，以下证据可能包含用户原框选区域左右相邻的页面内容。只有目标状态能够唯一对应，或读取范围内相关证据一致时，才可判断 matched；证据冲突时必须判断 uncertain。
            """
        } else {
            nil
        }
        var parts = [
            expandedRegionGuidance,
            title.map { "页面标题：\($0)" },
            url.map { "页面 URL：\($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if let html, !html.isEmpty {
            let coordinateNote = selectionRegionExpanded
                ? "data-awaitcue-rect 坐标相对于扩大后的读取范围左上角，并非用户原始选区坐标"
                : "data-awaitcue-rect 坐标相对于框选区域左上角"
            parts.append(
                "框选区域精简 HTML（保留层级、class、ARIA 和 data-* 属性；\(coordinateNote)）：\n\(html)"
            )
        } else {
            // 旧扩展没有 HTML 字段时继续读取原有扁平证据，避免升级期间已有 Hook 中断。
            let textHeading = selectionRegionExpanded
                ? "扩大后读取范围内容（坐标相对于扩大后的读取范围左上角，单位为 CSS 像素，并非用户原始选区坐标）"
                : "框选内容（坐标相对于选区左上角，单位为 CSS 像素）"
            if let text, !text.isEmpty { parts.append("\(textHeading)：\n\(text)") }
            if let semantics, !semantics.isEmpty { parts.append("语义属性：\n\(semantics)") }
        }
        if let insufficiency { parts.append(insufficiency) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func previewKey(for target: BrowserTarget) -> String {
        "\(target.extensionInstallationID)|\(target.tabIdentifier)|\(target.initialURL.absoluteString)"
    }

    private func handleActiveHostResponse(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              object["matched"] as? Bool == true,
              var pendingHost = pendingActiveHosts[requestID],
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let extensionInstallationID = object["extensionInstallationID"] as? String,
              let tabID = object["tabID"] as? Int,
              let browserWindowID = object["browserWindowID"] as? Int,
              let host = object["host"] as? String
        else {
            return
        }
        pendingHost.collector.record(
            browserBundleIdentifier: browserBundleIdentifier,
            extensionInstallationID: extensionInstallationID,
            tabIdentifier: tabID,
            browserWindowIdentifier: browserWindowID,
            host: host
        )
        pendingActiveHosts[requestID] = pendingHost
    }

    private func finish(requestID: String, with result: BrowserSelectionRelayResolution) {
        guard let selection = pending.removeValue(forKey: requestID) else { return }
        selection.continuation.resume(returning: result)
    }

    private func finishSelectionAfterCollection(requestID: String) {
        guard let selection = pending[requestID] else { return }
        finish(requestID: requestID, with: selection.collector.resolution)
    }

    private func setExpectedSelectionResponseCount(_ count: Int, requestID: String) {
        guard var selection = pending[requestID] else { return }
        selection.responseGate.setExpectedResponseCount(count)
        pending[requestID] = selection
        finishSelectionIfComplete(requestID: requestID)
    }

    private func finishSelectionIfComplete(requestID: String) {
        guard let selection = pending[requestID], selection.responseGate.isComplete else { return }
        finish(requestID: requestID, with: selection.collector.resolution)
    }

    private func finishActiveHost(
        requestID: String,
        with result: ActiveBrowserHostResolution
    ) {
        guard let query = pendingActiveHosts.removeValue(forKey: requestID) else { return }
        query.continuation.resume(returning: result)
    }

    private func finishActiveHostCollection(requestID: String) {
        guard let query = pendingActiveHosts[requestID] else { return }
        finishActiveHost(requestID: requestID, with: query.collector.resolution)
    }

    private static func jsonRect(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    private static func jsonRegion(_ region: NormalizedRegion) -> [String: Double] {
        ["x": region.x, "y": region.y, "width": region.width, "height": region.height]
    }

    private static func region(from object: [String: Any]) -> NormalizedRegion? {
        guard let x = object["x"] as? Double,
              let y = object["y"] as? Double,
              let width = object["width"] as? Double,
              let height = object["height"] as? Double
        else {
            return nil
        }
        let region = NormalizedRegion(x: x, y: y, width: width, height: height)
        return region.isValid ? region : nil
    }

    private static let browserBundleIdentifiers: Set<String> = [
        SafariBridgeMessageCodec.browserBundleIdentifier,
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]
}
