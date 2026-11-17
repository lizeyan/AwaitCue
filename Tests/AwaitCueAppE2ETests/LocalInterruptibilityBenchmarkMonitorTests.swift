import AwaitCueCore
import AwaitCueModel
import AwaitCueRuntime
import CryptoKit
import Foundation
import Testing
@testable import AwaitCueApp

@Suite("本机忙闲 benchmark 采样")
struct LocalInterruptibilityBenchmarkMonitorTests {
    @Test("只有显式开启且输出目录为绝对路径时才创建 24 小时采样配置")
    func configurationRequiresExplicitOptInAndAbsoluteDirectory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("awaitcue-local-benchmark", isDirectory: true)
        let configuration = LocalInterruptibilityBenchmarkConfiguration.from(environment: [
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK": "1",
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DIRECTORY": directory.path,
        ])

        #expect(configuration?.outputDirectory == directory.standardizedFileURL)
        #expect(configuration?.duration == 86_400)
        #expect(configuration?.pollInterval == 60)
        #expect(configuration?.minimumSampleInterval == 300)
        #expect(configuration?.maximumSampleCount == 300)
        #expect(configuration?.activityEvidenceValidFromSampleID == "0001")
        #expect(LocalInterruptibilityBenchmarkConfiguration.from(environment: [
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK": "1",
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DIRECTORY": directory.path,
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_ACTIVITY_VALID_FROM_SAMPLE_ID": "0004",
        ])?.activityEvidenceValidFromSampleID == "0004")
        #expect(LocalInterruptibilityBenchmarkConfiguration.from(environment: [
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DIRECTORY": directory.path,
        ]) == nil)
        #expect(LocalInterruptibilityBenchmarkConfiguration.from(environment: [
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK": "1",
            "AWAITCUE_LOCAL_INTERRUPTIBILITY_BENCHMARK_DIRECTORY": "relative/path",
        ]) == nil)
    }

    @Test("采样器跳过连续重复画面并把模型结果写入仅当前用户可读的本地文件")
    func recorderDeduplicatesEvidenceAndPersistsPrivateSample() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 2
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let recorder = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: "decision-model",
            endpointHost: "model.example"
        )
        let firstEvidence = ModelEvidence(
            text: "前台应用：Xcode\n窗口标题：AwaitCue\n距最近输入约：2 秒",
            image: ModelImage(data: Data([0x01, 0x02]), mediaType: "image/jpeg")
        )

        let first = try await recorder.prepare(firstEvidence, capturedAt: startedAt)
        #expect(first != nil)
        try await recorder.commit(
            first!,
            result: .success(
                InterruptibilityEvaluation(decision: .notInterruptible, confidence: 0.97)
            ),
            latencyMilliseconds: 120
        )

        let repeated = try await recorder.prepare(
            firstEvidence,
            capturedAt: startedAt.addingTimeInterval(600)
        )
        #expect(repeated == nil)

        let changedEvidence = ModelEvidence(
            text: "前台应用：Safari\n窗口标题：文章\n距最近输入约：45 秒",
            image: ModelImage(data: Data([0x03, 0x04]), mediaType: "image/jpeg")
        )
        let second = try await recorder.prepare(
            changedEvidence,
            capturedAt: startedAt.addingTimeInterval(600)
        )
        #expect(second != nil)
        try await recorder.commit(
            second!,
            result: .success(
                InterruptibilityEvaluation(decision: .interruptible, confidence: 0.88)
            ),
            latencyMilliseconds: 90
        )

        let overLimit = try await recorder.prepare(
            ModelEvidence(
                text: "前台应用：Terminal",
                image: ModelImage(data: Data([0x05]), mediaType: "image/jpeg")
            ),
            capturedAt: startedAt.addingTimeInterval(1_200)
        )
        #expect(overLimit == nil)

        let sampleURL = directory.appendingPathComponent("samples/0001.json")
        let imageURL = directory.appendingPathComponent("samples/0001.jpg")
        #expect(FileManager.default.fileExists(atPath: sampleURL.path))
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
        let sample = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkSample.self,
            from: Data(contentsOf: sampleURL)
        )
        #expect(sample.modelDecision == .notInterruptible)
        #expect(sample.imageSHA256 == SHA256.hash(data: Data([0x01, 0x02]))
            .map { String(format: "%02x", $0) }
            .joined())
        #expect(sample.humanDecision == nil)
        #expect(sample.humanRationale == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("进程重启后续写原 run 并保留最初的 24 小时截止时间")
    func recorderResumesExistingRunWithoutOverwritingSamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10,
            activityEvidenceValidFromSampleID: "0004"
        )
        let originalStart = Date(timeIntervalSince1970: 1_000)
        let firstRecorder = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: originalStart,
            modelName: "decision-model",
            endpointHost: "model.example"
        )
        for index in 1 ... 2 {
            let evidence = ModelEvidence(
                text: "样本 \(index)",
                image: ModelImage(data: Data([UInt8(index)]), mediaType: "image/jpeg")
            )
            let pending = try #require(await firstRecorder.prepare(
                evidence,
                capturedAt: originalStart.addingTimeInterval(Double(index) * 300)
            ))
            try await firstRecorder.commit(
                pending,
                result: .success(
                    InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)
                ),
                latencyMilliseconds: 10
            )
        }

        // 模拟修复前已经落盘、尚无可信活动边界字段的真实 run。
        let runURL = directory.appendingPathComponent("run.json")
        var legacyRun = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: runURL))
                as? [String: Any]
        )
        legacyRun.removeValue(forKey: "activityEvidenceValidFromSampleID")
        legacyRun.removeValue(forKey: "interruptibilityPromptSHA256")
        legacyRun.removeValue(forKey: "interruptibilityPromptValidFromSampleID")
        try JSONSerialization.data(withJSONObject: legacyRun).write(to: runURL, options: .atomic)

        let resumedConfiguration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 42,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10,
            activityEvidenceValidFromSampleID: "0004"
        )
        let resumedRecorder = try LocalInterruptibilityBenchmarkRecorder(
            configuration: resumedConfiguration,
            startedAt: originalStart.addingTimeInterval(3_600),
            modelName: "decision-model",
            endpointHost: "model.example",
            interruptibilityPromptSHA256: String(repeating: "b", count: 64)
        )
        let resumedRun = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: runURL)
        )
        #expect(resumedRun.activityEvidenceValidFromSampleID == "0004")
        #expect(resumedRun.interruptibilityPromptSHA256 == String(repeating: "b", count: 64))
        #expect(resumedRun.interruptibilityPromptValidFromSampleID == "0003")
        let third = try #require(await resumedRecorder.prepare(
            ModelEvidence(
                text: "样本 3",
                image: ModelImage(data: Data([0x03]), mediaType: "image/jpeg")
            ),
            capturedAt: originalStart.addingTimeInterval(900)
        ))
        #expect(third.sequence == 3)
        try await resumedRecorder.commit(
            third,
            result: .success(
                InterruptibilityEvaluation(decision: .notInterruptible, confidence: 0.8)
            ),
            latencyMilliseconds: 12
        )

        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("samples/0001.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("samples/0002.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("samples/0003.json").path
        ))
        let run = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: runURL)
        )
        #expect(run.startedAt == originalStart)
        #expect(run.intendedEndAt == originalStart.addingTimeInterval(86_400))
        #expect(run.sampleCount == 3)
        #expect(run.activityEvidenceValidFromSampleID == "0004")
    }

    @Test("同一 run 不能混入不同版本的忙闲 prompt")
    func recorderRejectsPromptChangeAcrossResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: "decision-model",
            endpointHost: "model.example",
            interruptibilityPromptSHA256: String(repeating: "a", count: 64)
        )

        #expect(throws: CocoaError.self) {
            _ = try LocalInterruptibilityBenchmarkRecorder(
                configuration: configuration,
                startedAt: startedAt.addingTimeInterval(60),
                modelName: "decision-model",
                endpointHost: "model.example",
                interruptibilityPromptSHA256: String(repeating: "b", count: 64)
            )
        }
    }

    @Test("prompt SHA 与有效边界只缺一个时拒绝静默修复")
    func recorderRejectsPartialPromptMetadataAcrossResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: "decision-model",
            endpointHost: "model.example"
        )
        let runURL = directory.appendingPathComponent("run.json")
        var damagedRun = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: runURL))
                as? [String: Any]
        )
        damagedRun.removeValue(forKey: "interruptibilityPromptValidFromSampleID")
        try JSONSerialization.data(withJSONObject: damagedRun).write(
            to: runURL,
            options: .atomic
        )

        #expect(throws: CocoaError.self) {
            _ = try LocalInterruptibilityBenchmarkRecorder(
                configuration: configuration,
                startedAt: startedAt.addingTimeInterval(60),
                modelName: "decision-model",
                endpointHost: "model.example"
            )
        }
    }

    @Test("prompt 有效边界超出下一样本时拒绝续跑")
    func recorderRejectsInvalidPromptBoundaryAcrossResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        _ = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: "decision-model",
            endpointHost: "model.example"
        )
        let runURL = directory.appendingPathComponent("run.json")
        var damagedRun = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: runURL))
                as? [String: Any]
        )
        damagedRun["interruptibilityPromptValidFromSampleID"] = "9999"
        try JSONSerialization.data(withJSONObject: damagedRun).write(
            to: runURL,
            options: .atomic
        )

        #expect(throws: CocoaError.self) {
            _ = try LocalInterruptibilityBenchmarkRecorder(
                configuration: configuration,
                startedAt: startedAt.addingTimeInterval(60),
                modelName: "decision-model",
                endpointHost: "model.example"
            )
        }
    }

    @Test("重启发生在原截止时间之后时直接完成而不重新截图")
    func restartedMonitorHonorsOriginalDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 1,
            pollInterval: 0.01,
            minimumSampleInterval: 0.01,
            maximumSampleCount: 10
        )
        // ISO-8601 落盘按秒保存；使用整秒时间避免把序列化精度误当成续跑逻辑失败。
        let originalStart = Date(
            timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) - 10
        )
        _ = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: originalStart,
            modelName: "decision-model",
            endpointHost: "model.example"
        )
        let evidenceProvider = CountingBenchmarkEvidenceProvider()
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: evidenceProvider,
            decisionProvider: UnusedBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example"
        )

        await monitor.run()

        #expect(await evidenceProvider.callCount == 0)
        let run = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
        #expect(run.startedAt == originalStart)
        #expect(run.intendedEndAt == originalStart.addingTimeInterval(1))
        #expect(run.status == "completed")
    }

    @Test("截图失败只落盘稳定分类和时间并在进程重启后保留")
    func captureFailurePersistsSanitizedDiagnosticsAcrossResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let failureAt = startedAt.addingTimeInterval(120)
        let recorder = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt,
            modelName: "decision-model",
            endpointHost: "model.example"
        )

        try await recorder.recordCaptureFailure(
            code: "target_unavailable",
            occurredAt: failureAt
        )
        _ = try LocalInterruptibilityBenchmarkRecorder(
            configuration: configuration,
            startedAt: startedAt.addingTimeInterval(3_600),
            modelName: "decision-model",
            endpointHost: "model.example"
        )

        let run = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
        #expect(run.captureFailureCount == 1)
        #expect(run.lastCaptureFailureCode == "target_unavailable")
        #expect(run.lastCaptureFailureAt == failureAt)
        #expect(LocalInterruptibilityBenchmarkMonitor.stableCaptureFailureCode(
            HookRuntimeEvidenceError.capturePermissionMissing
        ) == "capture_permission_missing")
        #expect(LocalInterruptibilityBenchmarkMonitor.stableCaptureFailureCode(
            BenchmarkFixtureError.unexpectedCall
        ) == "capture_failed")
    }

    @Test("前台没有可捕获窗口时单独计数而不冒充截图故障")
    func unavailableEvidenceUsesDedicatedPollCounter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let unavailableAt = startedAt.addingTimeInterval(120)
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: CountingBenchmarkEvidenceProvider(),
            decisionProvider: UnusedBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt
        )

        await monitor.recordEvidenceFailure(
            HookRuntimeEvidenceError.targetUnavailable,
            occurredAt: unavailableAt
        )

        let run = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
        #expect(run.unavailablePollCount == 1)
        #expect(run.captureFailureCount == 0)
        #expect(run.availabilityClassificationValidFrom == startedAt)
    }

    @Test("本地隐私排除不会生成样本或调用模型")
    func excludedEvidenceIsCountedWithoutSamplingOrModelRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let decisionProvider = CountingBenchmarkDecisionProvider()
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: ExcludedBenchmarkEvidenceProvider(),
            decisionProvider: decisionProvider,
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt,
            isUserSessionUnlocked: { true }
        )

        await monitor.captureOneIfAllowed(at: startedAt)

        let run = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkRun.self,
            from: Data(contentsOf: directory.appendingPathComponent("run.json"))
        )
        #expect(run.excludedPollCount == 1)
        #expect(run.sampleCount == 0)
        #expect(await decisionProvider.interruptibilityCallCount == 0)
        let sampleFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("samples", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(sampleFiles.isEmpty)
    }

    @Test("模型错误只落盘稳定分类而不保存服务端 reason")
    func modelFailurePersistsOnlySanitizedClassification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: SuccessfulCountingBenchmarkEvidenceProvider(),
            decisionProvider: SensitiveReasonBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt,
            isUserSessionUnlocked: { true }
        )

        await monitor.captureOneIfAllowed(at: startedAt)

        let sample = try JSONDecoder.awaitCueBenchmark.decode(
            LocalInterruptibilityBenchmarkSample.self,
            from: Data(contentsOf: directory.appendingPathComponent("samples/0001.json"))
        )
        #expect(sample.modelError == "incomplete_response")
        #expect(sample.modelError?.contains("sensitive-server-reason") == false)
        #expect(sample.modelDecision == nil)
        #expect(sample.modelConfidence == nil)
    }

    @Test("五分钟样本间隔在读取前台截图之前生效")
    func monitorThrottlesBeforeRequestingActiveEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let evidenceProvider = SuccessfulCountingBenchmarkEvidenceProvider()
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: evidenceProvider,
            decisionProvider: SuccessfulBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt,
            isUserSessionUnlocked: { true }
        )

        await monitor.captureOneIfAllowed(at: startedAt)
        // 模拟 LaunchAgent 在不可观察后重启；节流不能因进程边界失效。
        let resumedMonitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: evidenceProvider,
            decisionProvider: UnusedBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt.addingTimeInterval(60),
            isUserSessionUnlocked: { true }
        )
        await resumedMonitor.captureOneIfAllowed(at: startedAt.addingTimeInterval(60))
        #expect(await evidenceProvider.callCount == 1)
        await resumedMonitor.captureOneIfAllowed(at: startedAt.addingTimeInterval(300))
        #expect(await evidenceProvider.callCount == 2)
    }

    @Test("目标持续不可观察时也只按五分钟间隔请求一次屏幕证据")
    func monitorThrottlesUnavailableEvidenceAttempts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = LocalInterruptibilityBenchmarkConfiguration(
            outputDirectory: directory,
            duration: 86_400,
            pollInterval: 60,
            minimumSampleInterval: 300,
            maximumSampleCount: 10
        )
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let evidenceProvider = UnavailableBenchmarkEvidenceProvider()
        let monitor = try LocalInterruptibilityBenchmarkMonitor(
            configuration: configuration,
            evidenceProvider: evidenceProvider,
            decisionProvider: UnusedBenchmarkDecisionProvider(),
            modelName: "decision-model",
            endpointHost: "model.example",
            startedAt: startedAt,
            isUserSessionUnlocked: { true }
        )

        await monitor.captureOneIfAllowed(at: startedAt)
        await monitor.captureOneIfAllowed(at: startedAt.addingTimeInterval(60))
        #expect(await evidenceProvider.callCount == 1)
        await monitor.captureOneIfAllowed(at: startedAt.addingTimeInterval(300))
        #expect(await evidenceProvider.callCount == 2)
    }
}

private actor CountingBenchmarkEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    private(set) var callCount = 0

    func currentEvidence() async throws -> ModelEvidence {
        callCount += 1
        throw BenchmarkFixtureError.unexpectedCall
    }
}

private struct UnusedBenchmarkDecisionProvider: HookRuntimeDecisionProvider {
    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        throw BenchmarkFixtureError.unexpectedCall
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        throw BenchmarkFixtureError.unexpectedCall
    }
}

private actor SuccessfulCountingBenchmarkEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    private(set) var callCount = 0

    func currentEvidence() async throws -> ModelEvidence {
        callCount += 1
        return ModelEvidence(
            text: "前台应用：测试",
            image: ModelImage(data: Data([UInt8(callCount)]), mediaType: "image/jpeg")
        )
    }
}

private actor UnavailableBenchmarkEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    private(set) var callCount = 0

    func currentEvidence() async throws -> ModelEvidence {
        callCount += 1
        throw HookRuntimeEvidenceError.targetUnavailable
    }
}

private struct ExcludedBenchmarkEvidenceProvider: HookRuntimeActiveEvidenceProvider {
    func currentEvidence() async throws -> ModelEvidence {
        throw HookRuntimeEvidenceError.locallyExcluded
    }
}

private actor CountingBenchmarkDecisionProvider: HookRuntimeDecisionProvider {
    private(set) var interruptibilityCallCount = 0

    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        throw BenchmarkFixtureError.unexpectedCall
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        interruptibilityCallCount += 1
        throw BenchmarkFixtureError.unexpectedCall
    }
}

private struct SuccessfulBenchmarkDecisionProvider: HookRuntimeDecisionProvider {
    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        throw BenchmarkFixtureError.unexpectedCall
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        InterruptibilityEvaluation(decision: .interruptible, confidence: 0.9)
    }
}

private struct SensitiveReasonBenchmarkDecisionProvider: HookRuntimeDecisionProvider {
    func evaluateCondition(
        _ request: ConditionEvaluationRequest
    ) async throws -> ConditionEvaluation {
        throw BenchmarkFixtureError.unexpectedCall
    }

    func evaluateInterruptibility(
        _ request: InterruptibilityEvaluationRequest
    ) async throws -> InterruptibilityEvaluation {
        throw OpenAIResponsesClientError.incompleteResponse("sensitive-server-reason")
    }
}

private enum BenchmarkFixtureError: Error {
    case unexpectedCall
}
