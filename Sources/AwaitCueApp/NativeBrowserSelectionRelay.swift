import AwaitCueBrowserBridge
import AwaitCueCore
import AwaitCueModel
import AwaitCueRuntime
import AwaitCueSelection
import Foundation

/// 通过本地 native relay 向具体 Chromium 扩展查询标签页身份和 viewport 区域。
actor NativeBrowserSelectionRelay: BrowserSelectionRelaying, ActiveBrowserHostResolving {
    nonisolated let statuses: AsyncStream<String>
    nonisolated let evidenceUpdates: AsyncStream<HookID>
    nonisolated let targetUnavailableUpdates: AsyncStream<HookID>

    private struct PendingSelection {
        let browserBundleIdentifier: String
        let nativeWindowIdentifier: UInt32
        let continuation: CheckedContinuation<BrowserSelectionRelayResolution, any Error>
        var collector: BrowserSelectionMatchCollector
    }

    private struct PendingActiveHost {
        let continuation: CheckedContinuation<ActiveBrowserHostResolution, any Error>
        var collector: ActiveBrowserHostMatchCollector
    }

    private struct BoundInstallation {
        let extensionInstallationID: String
        let browserBundleIdentifier: String
    }

    private let server: NativeBridgeServer
    private let statusContinuation: AsyncStream<String>.Continuation
    private let evidenceUpdateContinuation: AsyncStream<HookID>.Continuation
    private let targetUnavailableContinuation: AsyncStream<HookID>.Continuation
    private var pending: [String: PendingSelection] = [:]
    private var pendingActiveHosts: [String: PendingActiveHost] = [:]
    private var evidenceByHook: [HookID: ModelEvidence] = [:]
    private var installationByHook: [HookID: BoundInstallation] = [:]
    private var listenTask: Task<Void, Never>?

    init(server: NativeBridgeServer) {
        self.server = server
        // 浏览器页面可以高频变化；只保留有限最新事件，避免主线程暂时阻塞时积累敏感证据通知。
        let stream = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(16))
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

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        for selection in pending.values {
            selection.continuation.resume(returning: .unavailable)
        }
        pending.removeAll()
        for hostQuery in pendingActiveHosts.values {
            hostQuery.continuation.resume(returning: .unavailable)
        }
        pendingActiveHosts.removeAll()
        statusContinuation.finish()
        evidenceUpdateContinuation.finish()
        targetUnavailableContinuation.finish()
    }

    /// 告诉解析出具体 tab 的扩展开始 DOM 观察，并按需要启动像素捕获。
    func bind(hookID: HookID, target: BrowserTarget, requirePixels: Bool) async throws {
        let command: [String: Any] = [
            "type": "bindTarget",
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
            "expectedHost": target.host,
            "expectedURL": target.initialURL.absoluteString,
            "region": Self.jsonRegion(target.normalizedRegion),
            "requirePixels": requirePixels,
        ]
        installationByHook[hookID] = BoundInstallation(
            extensionInstallationID: target.extensionInstallationID,
            browserBundleIdentifier: target.browserBundleIdentifier
        )
        do {
            try await server.broadcastPayload(JSONSerialization.data(withJSONObject: command))
        } catch {
            installationByHook[hookID] = nil
            throw error
        }
    }

    /// 停止指定浏览器 Hook 的 DOM 观察和 tabCapture。
    func unbind(hookID: HookID, extensionInstallationID: String) async throws {
        let command: [String: Any] = [
            "type": "unbindTarget",
            "extensionInstallationID": extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
        ]
        try await server.broadcastPayload(JSONSerialization.data(withJSONObject: command))
        evidenceByHook[hookID] = nil
        installationByHook[hookID] = nil
    }

    /// 激活持久化 Target 原本绑定的标签页；扩展仍会重新验证 tab URL 与 host。
    func focus(hookID: HookID, target: BrowserTarget) async throws {
        let command: [String: Any] = [
            "type": "focusTarget",
            "extensionInstallationID": target.extensionInstallationID,
            "hookID": hookID.rawValue.uuidString,
            "tabID": target.tabIdentifier,
            "expectedHost": target.host,
            "expectedURL": target.initialURL.absoluteString,
        ]
        try await server.broadcastPayload(JSONSerialization.data(withJSONObject: command))
    }

    /// 返回扩展最近一次只驻留内存的 DOM/图片证据。
    func evidence(for hookID: HookID) throws -> ModelEvidence {
        guard let evidence = evidenceByHook[hookID] else {
            throw HookRuntimeEvidenceError.browserExtensionDisconnected
        }
        return evidence
    }

    /// 非浏览器明确降级到 WindowTarget；浏览器必须由扩展返回具体 tab，超时不会猜测。
    func resolveBrowserTarget(
        for selection: ResolvedWindowSelection
    ) async throws -> BrowserSelectionRelayResolution {
        guard Self.chromiumBundleIdentifiers.contains(selection.window.applicationBundleIdentifier) else {
            return .notBrowser
        }
        let requestID = UUID().uuidString
        let command: [String: Any] = [
            "type": "resolveSelection",
            "requestID": requestID,
            "windowFrame": Self.jsonRect(selection.window.frame),
            "selectionRect": Self.jsonRect(selection.screenCaptureRect),
        ]
        let payload = try JSONSerialization.data(withJSONObject: command)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = PendingSelection(
                browserBundleIdentifier: selection.window.applicationBundleIdentifier,
                nativeWindowIdentifier: selection.window.windowIdentifier,
                continuation: continuation,
                collector: BrowserSelectionMatchCollector(
                    browserBundleIdentifier: selection.window.applicationBundleIdentifier
                )
            )
            Task { [weak self, server] in
                do {
                    try await server.broadcastPayload(payload)
                } catch {
                    await self?.finish(requestID: requestID, with: .unavailable)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                await self?.finishSelectionAfterCollection(requestID: requestID)
            }
        }
    }

    /// 查询当前真正处于 focused 状态的浏览器 installation；多 profile 响应会安全拒绝。
    func resolveActiveBrowserHost(
        for browserBundleIdentifier: String
    ) async throws -> ActiveBrowserHostResolution {
        guard Self.chromiumBundleIdentifiers.contains(browserBundleIdentifier) else {
            return .notBrowser
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
            Task { [weak self, server] in
                do {
                    try await server.broadcastPayload(payload)
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
            statusContinuation.yield("扩展消息无效")
            return
        }
        switch type {
        case "ready":
            statusContinuation.yield("Chromium 扩展已连接")
        case "selectionResolved":
            handleSelectionResponse(object)
        case "activeHostResolved":
            handleActiveHostResponse(object)
        case "evidenceChanged":
            handleDOMEvidence(object)
        case "captureFrame":
            handleCaptureFrame(object)
        case "targetUnavailable":
            statusContinuation.yield("浏览器目标不可用")
            handleTargetUnavailable(object)
        case "captureAuthorizationRequired":
            statusContinuation.yield("请点击 AwaitCue 扩展图标允许后台像素观察")
        case "captureAuthorized":
            statusContinuation.yield("浏览器后台像素观察已启用")
        case "error":
            statusContinuation.yield("浏览器扩展报告错误")
        default:
            break
        }
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

    private func handleDOMEvidence(_ object: [String: Any]) {
        guard let evidence = object["evidence"] as? [String: Any],
              let installationID = object["extensionInstallationID"] as? String,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let hookIDString = evidence["hookID"] as? String,
              let uuid = UUID(uuidString: hookIDString),
              let text = evidence["text"] as? String
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
        let previous = evidenceByHook[hookID]
        evidenceByHook[hookID] = ModelEvidence(domText: text, image: previous?.image)
        evidenceUpdateContinuation.yield(hookID)
    }

    private func handleCaptureFrame(_ object: [String: Any]) {
        guard let hookIDString = object["hookID"] as? String,
              let installationID = object["extensionInstallationID"] as? String,
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let uuid = UUID(uuidString: hookIDString),
              let dataURL = object["imageDataURL"] as? String,
              let comma = dataURL.firstIndex(of: ","),
              let imageData = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
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
        let previous = evidenceByHook[hookID]
        evidenceByHook[hookID] = ModelEvidence(
            text: previous?.contextText,
            domText: previous?.domText,
            image: ModelImage(data: imageData, mediaType: "image/jpeg")
        )
        evidenceUpdateContinuation.yield(hookID)
    }

    private func handleSelectionResponse(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              object["matched"] as? Bool == true,
              var pendingSelection = pending[requestID],
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              browserBundleIdentifier == pendingSelection.browserBundleIdentifier,
              let target = object["target"] as? [String: Any],
              let extensionID = target["extensionInstallationID"] as? String,
              let tabID = target["tabID"] as? Int,
              let host = target["host"] as? String,
              let urlString = target["url"] as? String,
              let url = URL(string: urlString),
              let title = target["title"] as? String,
              let regionObject = target["region"] as? [String: Any],
              let region = Self.region(from: regionObject)
        else {
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
            observationMode: .domAndImage
        )
        pendingSelection.collector.record(
            browserBundleIdentifier: browserBundleIdentifier,
            target: browserTarget
        )
        pending[requestID] = pendingSelection
    }

    private func handleActiveHostResponse(_ object: [String: Any]) {
        guard let requestID = object["requestID"] as? String,
              object["matched"] as? Bool == true,
              var pendingHost = pendingActiveHosts[requestID],
              let browserBundleIdentifier = object["browserBundleIdentifier"] as? String,
              let extensionInstallationID = object["extensionInstallationID"] as? String,
              let host = object["host"] as? String
        else {
            return
        }
        pendingHost.collector.record(
            browserBundleIdentifier: browserBundleIdentifier,
            extensionInstallationID: extensionInstallationID,
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

    private static let chromiumBundleIdentifiers: Set<String> = [
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
