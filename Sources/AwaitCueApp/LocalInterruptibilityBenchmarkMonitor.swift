import AwaitCueCore
import AwaitCueModel
import AwaitCueRuntime
import CoreGraphics
import CryptoKit
import Foundation

/// 在系统会话通知丢失时提供低频兜底轮询；只等待解锁，不读取窗口或模型配置。
struct UserSessionUnlockWaiter: Sendable {
    let isUnlocked: @Sendable () async -> Bool
    let sleep: @Sendable () async throws -> Void

    /// 持续等待真实解锁状态；任务取消或 sleep 失败时立即返回。
    func waitUntilUnlocked() async {
        while !Task.isCancelled {
            if await isUnlocked() { return }
            do {
                try await sleep()
            } catch {
                return
            }
        }
    }
}

/// 仅供显式本机评测使用的 24 小时忙闲采样配置。
struct LocalInterruptibilityBenchmarkConfiguration: Equatable, Sendable {
    let outputDirectory: URL
    let duration: TimeInterval
    let pollInterval: TimeInterval
    let minimumSampleInterval: TimeInterval
    let maximumSampleCount: Int
    let activityEvidenceValidFromSampleID: String

    init(
        outputDirectory: URL,
        duration: TimeInterval,
        pollInterval: TimeInterval,
        minimumSampleInterval: TimeInterval,
        maximumSampleCount: Int,
        activityEvidenceValidFromSampleID: String = "0001"
    ) {
        self.outputDirectory = outputDirectory
        self.duration = duration
        self.pollInterval = pollInterval
        self.minimumSampleInterval = minimumSampleInterval
        self.maximumSampleCount = maximumSampleCount
        self.activityEvidenceValidFromSampleID = activityEvidenceValidFromSampleID
    }

    /// 从进程环境读取配置；缺少显式开关或绝对输出路径时完全不启用采样。
    static func from(environment: [String: String]) -> Self? {
        guard environment["AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK"] == "1",
              let outputPath = environment[
                "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DIRECTORY"
              ],
              outputPath.hasPrefix("/"),
              outputPath != "/"
        else {
            return nil
        }
        return Self(
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true)
                .standardizedFileURL,
            duration: positiveTimeInterval(
                environment["AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DURATION_SECONDS"],
                default: 86_400
            ),
            pollInterval: positiveTimeInterval(
                environment["AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_POLL_SECONDS"],
                default: 60
            ),
            minimumSampleInterval: positiveTimeInterval(
                environment["AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_SAMPLE_SECONDS"],
                default: 300
            ),
            maximumSampleCount: positiveInteger(
                environment["AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_MAX_SAMPLES"],
                // 五分钟一次的 24 小时窗口最多约 288 个时间点；300 保留完整覆盖并继续限量。
                default: 300
            ),
            activityEvidenceValidFromSampleID: sampleIdentifier(
                environment[
                    "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_ACTIVITY_VALID_FROM_SAMPLE_ID"
                ],
                default: "0001"
            )
        )
    }

    private static func positiveTimeInterval(
        _ value: String?,
        default defaultValue: TimeInterval
    ) -> TimeInterval {
        guard let value, let parsed = TimeInterval(value), parsed > 0 else {
            return defaultValue
        }
        return parsed
    }

    private static func positiveInteger(_ value: String?, default defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value), parsed > 0 else { return defaultValue }
        return parsed
    }

    private static func sampleIdentifier(_ value: String?, default defaultValue: String) -> String {
        guard let value,
              value.count == 4,
              value.allSatisfy(\.isNumber),
              value != "0000"
        else {
            return defaultValue
        }
        return value
    }
}

/// 一张待人工复核的本机样本；人工字段在采集阶段必须保持为空。
struct LocalInterruptibilityBenchmarkSample: Codable, Equatable, Sendable {
    let id: String
    let capturedAt: Date
    let contextText: String?
    let imageFile: String
    /// nil 兼容早期样本；新样本记录模型实际接收 JPEG 的 SHA-256，供复核前验证未被替换。
    let imageSHA256: String?
    let modelDecision: InterruptibilityDecision?
    let modelConfidence: Double?
    let modelLatencyMilliseconds: Int
    let modelError: String?
    let humanDecision: InterruptibilityDecision?
    let humanRationale: String?
}

/// 采样运行的非敏感概要；endpoint 只记录 hostname，绝不记录 API key 或完整 URL。
struct LocalInterruptibilityBenchmarkRun: Codable, Sendable {
    let startedAt: Date
    let intendedEndAt: Date
    let completedAt: Date?
    let status: String
    let modelName: String
    let endpointHost: String
    /// nil 兼容未记录生产 prompt 版本的旧 run。
    let interruptibilityPromptSHA256: String?
    /// 旧 run 升级后只能从后续样本起声明 prompt 摘要已经固定。
    let interruptibilityPromptValidFromSampleID: String?
    let sampleCount: Int
    /// 最近一次真正请求屏幕证据的时间；用于跨进程重启保持采样节流。
    let lastEvidenceAttemptAt: Date?
    let lockedPollCount: Int
    let excludedPollCount: Int
    /// nil 兼容分类修复前的 run；新 run 会写入从语义边界起累计的不可观察轮询次数。
    let unavailablePollCount: Int?
    let captureFailureCount: Int
    let modelFailureCount: Int
    /// 可选字段用于兼容修复前的 run；只保存脱敏稳定分类，不落盘底层错误描述。
    let lastCaptureFailureCode: String?
    let lastCaptureFailureAt: Date?
    /// nil 表示旧 run 的 captureFailureCount 可能包含“当前无可捕获窗口”等预期不可用状态。
    let availabilityClassificationValidFrom: Date?
    /// nil 仅用于兼容修复前已经落盘的 run；新 run 一律写入四位样本编号。
    let activityEvidenceValidFromSampleID: String?
}

extension JSONEncoder {
    /// benchmark 文件统一使用可读、稳定的 ISO-8601 JSON，方便人工复核和后续脚本读取。
    static var awaitCueBenchmark: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    /// 与本机 benchmark encoder 对应的日期解码器。
    static var awaitCueBenchmark: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// 在模型调用前完成节流与连续画面去重，并以私有权限持久化待复核样本。
actor LocalInterruptibilityBenchmarkRecorder {
    struct PendingSample: Sendable {
        let sequence: Int
        let capturedAt: Date
        let evidence: ModelEvidence
        let fingerprint: String
    }

    enum EvaluationResult: Sendable {
        case success(InterruptibilityEvaluation)
        case failure(String)
    }

    private let configuration: LocalInterruptibilityBenchmarkConfiguration
    private let startedAt: Date
    private let originalIntendedEndAt: Date
    private let modelName: String
    private let endpointHost: String
    private let interruptibilityPromptSHA256: String
    private let interruptibilityPromptValidFromSampleID: String
    private let activityEvidenceValidFromSampleID: String
    private let fileManager: FileManager
    private var committedSampleCount = 0
    private var lastPreparedAt: Date?
    private var lastEvidenceAttemptAt: Date?
    private var lastFingerprint: String?
    private var lockedPollCount = 0
    private var excludedPollCount = 0
    private var unavailablePollCount = 0
    private var captureFailureCount = 0
    private var modelFailureCount = 0
    private var lastCaptureFailureCode: String?
    private var lastCaptureFailureAt: Date?
    private let availabilityClassificationValidFrom: Date

    init(
        configuration: LocalInterruptibilityBenchmarkConfiguration,
        startedAt: Date,
        modelName: String,
        endpointHost: String,
        interruptibilityPromptSHA256: String = OpenAIResponsesClient
            .interruptibilityPromptSHA256,
        fileManager: FileManager = .default
    ) throws {
        self.configuration = configuration
        self.modelName = modelName
        self.endpointHost = endpointHost
        self.fileManager = fileManager
        try Self.createPrivateDirectory(configuration.outputDirectory, fileManager: fileManager)
        let samplesDirectory = configuration.outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
        try Self.createPrivateDirectory(samplesDirectory, fileManager: fileManager)
        let runURL = configuration.outputDirectory.appendingPathComponent("run.json")
        if fileManager.fileExists(atPath: runURL.path) {
            let run = try JSONDecoder.awaitCueBenchmark.decode(
                LocalInterruptibilityBenchmarkRun.self,
                from: Data(contentsOf: runURL)
            )
            guard run.status == "running",
                  run.modelName == modelName,
                  run.endpointHost == endpointHost,
                  (run.interruptibilityPromptSHA256 == nil)
                    == (run.interruptibilityPromptValidFromSampleID == nil),
                  Self.isValidPromptBoundary(
                    run.interruptibilityPromptValidFromSampleID,
                    sampleCount: run.sampleCount
                  ),
                  run.interruptibilityPromptSHA256 == nil
                    || run.interruptibilityPromptSHA256 == interruptibilityPromptSHA256
            else {
                throw CocoaError(.fileWriteFileExists)
            }
            self.startedAt = run.startedAt
            originalIntendedEndAt = run.intendedEndAt
            activityEvidenceValidFromSampleID = run.activityEvidenceValidFromSampleID
                ?? configuration.activityEvidenceValidFromSampleID
            committedSampleCount = run.sampleCount
            self.interruptibilityPromptSHA256 = run.interruptibilityPromptSHA256
                ?? interruptibilityPromptSHA256
            interruptibilityPromptValidFromSampleID = run
                .interruptibilityPromptValidFromSampleID
                ?? (run.interruptibilityPromptSHA256 == nil
                    ? String(format: "%04d", run.sampleCount + 1)
                    : "0001")
            lastEvidenceAttemptAt = run.lastEvidenceAttemptAt
            lockedPollCount = run.lockedPollCount
            excludedPollCount = run.excludedPollCount
            unavailablePollCount = run.unavailablePollCount ?? 0
            captureFailureCount = run.captureFailureCount
            modelFailureCount = run.modelFailureCount
            lastCaptureFailureCode = run.lastCaptureFailureCode
            lastCaptureFailureAt = run.lastCaptureFailureAt
            availabilityClassificationValidFrom = run.availabilityClassificationValidFrom
                ?? startedAt
            if run.sampleCount > 0 {
                let identifier = String(format: "%04d", run.sampleCount)
                let sampleURL = samplesDirectory.appendingPathComponent("\(identifier).json")
                let imageURL = samplesDirectory.appendingPathComponent("\(identifier).jpg")
                let sample = try JSONDecoder.awaitCueBenchmark.decode(
                    LocalInterruptibilityBenchmarkSample.self,
                    from: Data(contentsOf: sampleURL)
                )
                let imageData = try Data(contentsOf: imageURL)
                lastPreparedAt = sample.capturedAt
                // 旧 run 没有尝试时间时，以最后一张真实样本作为保守迁移边界。
                if lastEvidenceAttemptAt == nil {
                    lastEvidenceAttemptAt = sample.capturedAt
                }
                lastFingerprint = SHA256.hash(data: imageData)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
            let normalizedRun = LocalInterruptibilityBenchmarkRun(
                startedAt: run.startedAt,
                intendedEndAt: run.intendedEndAt,
                completedAt: run.completedAt,
                status: run.status,
                modelName: run.modelName,
                endpointHost: run.endpointHost,
                interruptibilityPromptSHA256: self.interruptibilityPromptSHA256,
                interruptibilityPromptValidFromSampleID:
                    interruptibilityPromptValidFromSampleID,
                sampleCount: run.sampleCount,
                lastEvidenceAttemptAt: lastEvidenceAttemptAt,
                lockedPollCount: run.lockedPollCount,
                excludedPollCount: run.excludedPollCount,
                unavailablePollCount: unavailablePollCount,
                captureFailureCount: run.captureFailureCount,
                modelFailureCount: run.modelFailureCount,
                lastCaptureFailureCode: run.lastCaptureFailureCode,
                lastCaptureFailureAt: run.lastCaptureFailureAt,
                availabilityClassificationValidFrom: availabilityClassificationValidFrom,
                activityEvidenceValidFromSampleID: activityEvidenceValidFromSampleID
            )
            // 兼容旧 run 时立即补齐元数据；不能依赖后续一定还会采到新画面。
            try Self.writePrivate(
                JSONEncoder.awaitCueBenchmark.encode(normalizedRun),
                to: runURL,
                fileManager: fileManager
            )
            return
        }
        self.startedAt = startedAt
        originalIntendedEndAt = startedAt.addingTimeInterval(configuration.duration)
        self.interruptibilityPromptSHA256 = interruptibilityPromptSHA256
        interruptibilityPromptValidFromSampleID = "0001"
        activityEvidenceValidFromSampleID = configuration.activityEvidenceValidFromSampleID
        availabilityClassificationValidFrom = startedAt
        let run = LocalInterruptibilityBenchmarkRun(
            startedAt: startedAt,
            intendedEndAt: originalIntendedEndAt,
            completedAt: nil,
            status: "running",
            modelName: modelName,
            endpointHost: endpointHost,
            interruptibilityPromptSHA256: interruptibilityPromptSHA256,
            interruptibilityPromptValidFromSampleID: interruptibilityPromptValidFromSampleID,
            sampleCount: 0,
            lastEvidenceAttemptAt: nil,
            lockedPollCount: 0,
            excludedPollCount: 0,
            unavailablePollCount: 0,
            captureFailureCount: 0,
            modelFailureCount: 0,
            lastCaptureFailureCode: nil,
            lastCaptureFailureAt: nil,
            availabilityClassificationValidFrom: availabilityClassificationValidFrom,
            activityEvidenceValidFromSampleID: activityEvidenceValidFromSampleID
        )
        try Self.writePrivate(
            JSONEncoder.awaitCueBenchmark.encode(run),
            to: runURL,
            fileManager: fileManager
        )
    }

    /// 返回首次启动时确定的截止时间；进程重启不能重新获得一段新的 24 小时窗口。
    func intendedEndAt() -> Date {
        originalIntendedEndAt
    }

    /// 原子占用本次屏幕证据采样时隙；失败和不可观察也必须等待完整采样间隔后再试。
    func beginEvidenceAttempt(at capturedAt: Date) throws -> Bool {
        guard committedSampleCount < configuration.maximumSampleCount else { return false }
        if let lastEvidenceAttemptAt,
           capturedAt.timeIntervalSince(lastEvidenceAttemptAt)
               < configuration.minimumSampleInterval
        {
            return false
        }
        // 先落盘再调用 ScreenCaptureKit，避免采集过程崩溃或进程重启后立即重复读取屏幕。
        lastEvidenceAttemptAt = capturedAt
        try writeRun(status: "running", completedAt: nil)
        return true
    }

    /// 返回需要调用模型的新样本；过密、连续相同或达到上限时返回 nil。
    func prepare(_ evidence: ModelEvidence, capturedAt: Date) throws -> PendingSample? {
        guard committedSampleCount < configuration.maximumSampleCount,
              let image = evidence.image,
              !image.data.isEmpty
        else {
            return nil
        }
        if let lastPreparedAt,
           capturedAt.timeIntervalSince(lastPreparedAt) < configuration.minimumSampleInterval
        {
            return nil
        }
        let fingerprint = SHA256.hash(data: image.data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard fingerprint != lastFingerprint else { return nil }
        let pending = PendingSample(
            sequence: committedSampleCount + 1,
            capturedAt: capturedAt,
            evidence: evidence,
            fingerprint: fingerprint
        )
        // 在模型调用前保留节流状态；即使 API 失败，也不能对同一敏感画面形成紧密重试风暴。
        lastPreparedAt = capturedAt
        lastFingerprint = fingerprint
        return pending
    }

    /// 将模型判断与原始本地图像成对落盘，人工标签明确留空等待 24 小时后的复核。
    func commit(
        _ pending: PendingSample,
        result: EvaluationResult,
        latencyMilliseconds: Int
    ) throws {
        guard pending.sequence == committedSampleCount + 1,
              let image = pending.evidence.image
        else {
            return
        }
        let identifier = String(format: "%04d", pending.sequence)
        let imageName = "\(identifier).jpg"
        let imageURL = configuration.outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent(imageName)
        try Self.writePrivate(image.data, to: imageURL, fileManager: fileManager)

        let decision: InterruptibilityDecision?
        let confidence: Double?
        let modelError: String?
        switch result {
        case let .success(evaluation):
            decision = evaluation.decision
            confidence = evaluation.confidence
            modelError = nil
        case let .failure(message):
            decision = nil
            confidence = nil
            modelError = message
            modelFailureCount += 1
        }
        let sample = LocalInterruptibilityBenchmarkSample(
            id: identifier,
            capturedAt: pending.capturedAt,
            contextText: pending.evidence.contextText,
            imageFile: "samples/\(imageName)",
            imageSHA256: pending.fingerprint,
            modelDecision: decision,
            modelConfidence: confidence,
            modelLatencyMilliseconds: latencyMilliseconds,
            modelError: modelError,
            humanDecision: nil,
            humanRationale: nil
        )
        let sampleURL = configuration.outputDirectory
            .appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent("\(identifier).json")
        try Self.writePrivate(
            JSONEncoder.awaitCueBenchmark.encode(sample),
            to: sampleURL,
            fileManager: fileManager
        )
        committedSampleCount += 1
        try writeRun(status: "running", completedAt: nil)
    }

    func recordLockedPoll() throws {
        lockedPollCount += 1
        try writeRun(status: "running", completedAt: nil)
    }

    func recordExcludedPoll() throws {
        excludedPollCount += 1
        try writeRun(status: "running", completedAt: nil)
    }

    /// 当前没有普通可捕获窗口属于缺少可评测证据，不等同于截图系统发生故障。
    func recordUnavailablePoll() throws {
        unavailablePollCount += 1
        try writeRun(status: "running", completedAt: nil)
    }

    /// 记录可用于长时间运行诊断的脱敏失败分类；原始错误文本可能包含系统细节，不得落盘。
    func recordCaptureFailure(code: String, occurredAt: Date) throws {
        captureFailureCount += 1
        lastCaptureFailureCode = code
        lastCaptureFailureAt = occurredAt
        try writeRun(status: "running", completedAt: nil)
    }

    func finish(at completedAt: Date, cancelled: Bool) throws {
        try writeRun(status: cancelled ? "cancelled" : "completed", completedAt: completedAt)
    }

    private func writeRun(status: String, completedAt: Date?) throws {
        let run = LocalInterruptibilityBenchmarkRun(
            startedAt: startedAt,
            intendedEndAt: originalIntendedEndAt,
            completedAt: completedAt,
            status: status,
            modelName: modelName,
            endpointHost: endpointHost,
            interruptibilityPromptSHA256: interruptibilityPromptSHA256,
            interruptibilityPromptValidFromSampleID: interruptibilityPromptValidFromSampleID,
            sampleCount: committedSampleCount,
            lastEvidenceAttemptAt: lastEvidenceAttemptAt,
            lockedPollCount: lockedPollCount,
            excludedPollCount: excludedPollCount,
            unavailablePollCount: unavailablePollCount,
            captureFailureCount: captureFailureCount,
            modelFailureCount: modelFailureCount,
            lastCaptureFailureCode: lastCaptureFailureCode,
            lastCaptureFailureAt: lastCaptureFailureAt,
            availabilityClassificationValidFrom: availabilityClassificationValidFrom,
            activityEvidenceValidFromSampleID: activityEvidenceValidFromSampleID
        )
        try Self.writePrivate(
            JSONEncoder.awaitCueBenchmark.encode(run),
            to: configuration.outputDirectory.appendingPathComponent("run.json"),
            fileManager: fileManager
        )
    }

    private static func createPrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// prompt 边界最多指向下一张尚未产生的样本；更远的编号无法证明任何真实范围。
    private static func isValidPromptBoundary(_ value: String?, sampleCount: Int) -> Bool {
        guard let value else { return true }
        guard value.count == 4,
              let identifier = Int(value),
              identifier > 0
        else {
            return false
        }
        return identifier <= sampleCount + 1
    }

    private static func writePrivate(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 使用生产截图、隐私排除规则和模型客户端执行长时间本机采样。
actor LocalInterruptibilityBenchmarkMonitor {
    private let configuration: LocalInterruptibilityBenchmarkConfiguration
    private let evidenceProvider: any HookRuntimeActiveEvidenceProvider
    private let decisionProvider: any HookRuntimeDecisionProvider
    private let recorder: LocalInterruptibilityBenchmarkRecorder
    private let userSessionIsUnlocked: @Sendable () -> Bool

    init(
        configuration: LocalInterruptibilityBenchmarkConfiguration,
        evidenceProvider: any HookRuntimeActiveEvidenceProvider,
        decisionProvider: any HookRuntimeDecisionProvider,
        modelName: String,
        endpointHost: String,
        interruptibilityPromptSHA256: String = OpenAIResponsesClient
            .interruptibilityPromptSHA256,
        startedAt: Date = .now,
        isUserSessionUnlocked: @escaping @Sendable () -> Bool =
            LocalInterruptibilityBenchmarkMonitor.isUserSessionUnlocked
    ) throws {
        self.configuration = configuration
        self.evidenceProvider = evidenceProvider
        self.decisionProvider = decisionProvider
        userSessionIsUnlocked = isUserSessionUnlocked
        recorder = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: modelName,
            endpointHost: endpointHost,
            interruptibilityPromptSHA256: interruptibilityPromptSHA256
        )
    }

    /// 以墙上时间运行到截止点；睡眠期间不补采，解锁后的后续轮询会自然恢复。
    func run() async {
        let deadline = await recorder.intendedEndAt()
        while !Task.isCancelled, Date.now < deadline {
            await captureOneIfAllowed(at: .now)
            do {
                try await Task.sleep(for: .seconds(configuration.pollInterval))
            } catch {
                break
            }
        }
        try? await recorder.finish(at: .now, cancelled: Task.isCancelled)
    }

    func captureOneIfAllowed(at capturedAt: Date) async {
        guard userSessionIsUnlocked() else {
            try? await recorder.recordLockedPoll()
            return
        }
        guard (try? await recorder.beginEvidenceAttempt(at: capturedAt)) == true else { return }
        do {
            let evidence = try await evidenceProvider.currentEvidence()
            guard let pending = try await recorder.prepare(evidence, capturedAt: capturedAt) else {
                return
            }
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let result = try await decisionProvider.evaluateInterruptibility(
                    InterruptibilityEvaluationRequest(evidence: evidence)
                )
                let elapsed = started.duration(to: clock.now)
                try await recorder.commit(
                    pending,
                    result: .success(result),
                    latencyMilliseconds: Self.milliseconds(elapsed)
                )
            } catch {
                let elapsed = started.duration(to: clock.now)
                try? await recorder.commit(
                    pending,
                    result: .failure(Self.stableErrorName(error)),
                    latencyMilliseconds: Self.milliseconds(elapsed)
                )
            }
        } catch {
            await recordEvidenceFailure(error, occurredAt: .now)
        }
    }

    /// 把缺少可评测证据、隐私排除和真实采集故障分别落盘，避免可靠性报告混淆三类状态。
    func recordEvidenceFailure(_ error: Error, occurredAt: Date) async {
        guard let evidenceError = error as? HookRuntimeEvidenceError else {
            try? await recorder.recordCaptureFailure(
                code: Self.stableCaptureFailureCode(error),
                occurredAt: occurredAt
            )
            return
        }
        switch evidenceError {
        case .targetUnavailable, .targetMinimized, .evidenceIncomplete:
            try? await recorder.recordUnavailablePoll()
        case .locallyExcluded:
            try? await recorder.recordExcludedPoll()
        case .browserExtensionDisconnected, .capturePermissionMissing:
            try? await recorder.recordCaptureFailure(
                code: Self.stableCaptureFailureCode(error),
                occurredAt: occurredAt
            )
        }
    }

    /// 将采集错误压缩成稳定、无页面内容的分类，供 24 小时结束后的可靠性报告使用。
    nonisolated static func stableCaptureFailureCode(_ error: Error) -> String {
        guard let evidenceError = error as? HookRuntimeEvidenceError else {
            return "capture_failed"
        }
        switch evidenceError {
        case .targetUnavailable:
            return "target_unavailable"
        case .targetMinimized:
            return "target_minimized"
        case .browserExtensionDisconnected:
            return "browser_extension_disconnected"
        case .capturePermissionMissing:
            return "capture_permission_missing"
        case .evidenceIncomplete:
            return "evidence_incomplete"
        case .locallyExcluded:
            return "locally_excluded"
        }
    }

    /// 锁屏时完全不进入截图 provider，避免把登录窗口或系统维护唤醒误当成用户状态。
    nonisolated static func isUserSessionUnlocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: milliseconds)
    }

    /// 只保存稳定错误类型，防止底层错误文本意外包含 URL、请求体或页面内容。
    nonisolated private static func stableErrorName(_ error: any Error) -> String {
        if let modelError = error as? OpenAIResponsesClientError {
            // 带关联值的错误可能包含服务端 reason、状态码或网络细节；benchmark 只需要稳定类别。
            switch modelError {
            case .invalidConfiguration:
                return "invalid_configuration"
            case .invalidRequest:
                return "invalid_request"
            case .transport:
                return "transport"
            case .httpStatus:
                return "http_status"
            case .invalidResponse:
                return "invalid_response"
            case .invalidStructuredOutput:
                return "invalid_structured_output"
            case .incompleteResponse:
                return "incomplete_response"
            }
        }
        return "model_failed"
    }
}
