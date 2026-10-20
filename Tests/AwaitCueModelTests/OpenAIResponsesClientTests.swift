import Foundation
import Testing
@testable import AwaitCueCore
@testable import AwaitCueModel

@Suite("Responses API 客户端", .serialized)
struct OpenAIResponsesClientTests {
    @Test("Condition 准备返回供用户确认的摘要和证据要求")
    func preparesConditionForConfirmation() async throws {
        let recorder = RequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)
            return try stubbedResponse(
                for: request,
                statusCode: 200,
                body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"confirmedSummary\":\"构建状态显示成功\",\"requiredEvidence\":\"domAndImage\",\"currentDecision\":\"notMatched\",\"confidence\":0.82}"}]}]}"#
            )
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: session
        )

        let result = try await client.prepareCondition(
            ConditionPreparationRequest(
                originalText: "等构建成功",
                evidence: ModelEvidence(text: "Build status card")
            )
        )

        #expect(
            result == PreparedCondition(
                confirmedSummary: "构建状态显示成功",
                requiredEvidence: .domAndImage,
                currentDecision: .notMatched,
                confidence: 0.82
            )
        )
        let bodyData = try #require(recorder.request?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "low")
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["name"] as? String == "condition_preparation")
        #expect(format["strict"] as? Bool == true)
    }

    @Test("条件判断发送图片、关闭服务端存储并使用严格 JSON Schema")
    func evaluatesConditionWithPrivateStructuredRequest() async throws {
        let recorder = RequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)
            return try stubbedResponse(
                for: request,
                statusCode: 200,
                body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"matched\",\"confidence\":0.91}"}]}]}"#
            )
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1/")!,
            apiKey: "test-key",
            model: "vision-model",
            session: session
        )
        let request = ConditionEvaluationRequest(
            condition: ConditionDefinition(
                originalText: "构建完成时提醒我",
                confirmedSummary: "构建已经完成",
                requiredEvidence: .domAndImage
            ),
            evidence: ModelEvidence(
                text: "Build complete",
                image: ModelImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mediaType: "image/png")
            )
        )

        let result = try await client.evaluateCondition(request)

        #expect(result == ConditionEvaluation(decision: .matched, confidence: 0.91))
        let captured = try #require(recorder.request)
        #expect(captured.url == URL(string: "https://model.example/v1/responses"))
        #expect(captured.httpMethod == "POST")
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let bodyData = try #require(captured.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(body["model"] as? String == "vision-model")
        #expect(body["store"] as? Bool == false)
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")

        let input = try #require(body["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "input_image" })
        #expect(
            image["image_url"] as? String
                == "data:image/png;base64,iVBORw=="
        )

        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["decision", "confidence"])
    }

    @Test("是否适合打断使用独立三态判断契约")
    func evaluatesInterruptibility() async throws {
        let recorder = RequestRecorder()
        let session = makeStubbedSession { request in
            recorder.record(request)
            return try stubbedResponse(
                for: request,
                statusCode: 200,
                body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"notInterruptible\",\"confidence\":0.87}"}]}]}"#
            )
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: session
        )

        let result = try await client.evaluateInterruptibility(
            InterruptibilityEvaluationRequest(
                evidence: ModelEvidence(
                    image: ModelImage(data: Data([0x01, 0x02]), mediaType: "image/jpeg")
                )
            )
        )

        #expect(
            result == InterruptibilityEvaluation(
                decision: .notInterruptible,
                confidence: 0.87
            )
        )
        let bodyData = try #require(recorder.request?.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let reasoning = try #require(body["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none")
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["name"] as? String == "interruptibility_evaluation")
        let schema = try #require(format["schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let decision = try #require(properties["decision"] as? [String: Any])
        #expect(
            decision["enum"] as? [String]
                == ["interruptible", "notInterruptible", "uncertain"]
        )
    }

    @Test("解析时跳过没有文字内容的 reasoning 输出")
    func skipsReasoningItemsBeforeStructuredMessage() async throws {
        let session = makeStubbedSession { request in
            try stubbedResponse(
                for: request,
                statusCode: 200,
                body: #"{"output":[{"type":"reasoning","id":"reasoning-1"},{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"uncertain\",\"confidence\":0.3}"}]}]}"#
            )
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: session
        )

        let result = try await client.evaluateCondition(
            ConditionEvaluationRequest(
                condition: ConditionDefinition(
                    originalText: "构建完成时提醒我",
                    confirmedSummary: "构建已经完成",
                    requiredEvidence: .dom
                ),
                evidence: ModelEvidence(text: "状态未知")
            )
        )

        #expect(result == ConditionEvaluation(decision: .uncertain, confidence: 0.3))
    }

    @Test("配置、传输、HTTP、协议和结构化输出错误保持可区分")
    func classifiesFailures() async {
        let configurationClient = OpenAIResponsesClient(
            baseURL: URL(string: "file:///tmp/model")!,
            apiKey: "",
            model: "",
            session: makeStubbedSession { _ in throw URLError(.unknown) }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidConfiguration) {
            try await configurationClient.evaluateCondition(fixtureConditionRequest())
        }

        let transportClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { _ in throw URLError(.timedOut) }
        )
        await #expect(throws: OpenAIResponsesClientError.transport(.timedOut)) {
            try await transportClient.evaluateCondition(fixtureConditionRequest())
        }

        let httpClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(for: request, statusCode: 429, body: #"{"error":{}}"#)
            }
        )
        await #expect(throws: OpenAIResponsesClientError.httpStatus(429)) {
            try await httpClient.evaluateCondition(fixtureConditionRequest())
        }

        let protocolClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(for: request, statusCode: 200, body: #"{"output":[]}"#)
            }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidResponse) {
            try await protocolClient.evaluateCondition(fixtureConditionRequest())
        }

        let outputClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"not-json"}]}]}"#
                )
            }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidStructuredOutput) {
            try await outputClient.evaluateCondition(fixtureConditionRequest())
        }
    }

    @Test("空 Condition、空证据和无效图片在联网前被拒绝")
    func rejectsInvalidInputsBeforeTransport() async {
        let session = makeStubbedSession { _ in
            throw URLError(.cannotConnectToHost)
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: session
        )

        await #expect(throws: OpenAIResponsesClientError.invalidRequest) {
            try await client.prepareCondition(
                ConditionPreparationRequest(originalText: "  \n")
            )
        }
        await #expect(throws: OpenAIResponsesClientError.invalidRequest) {
            try await client.evaluateCondition(
                ConditionEvaluationRequest(
                    condition: fixtureConditionRequest().condition,
                    evidence: ModelEvidence(text: " \n")
                )
            )
        }
        await #expect(throws: OpenAIResponsesClientError.invalidRequest) {
            try await client.evaluateInterruptibility(
                InterruptibilityEvaluationRequest(evidence: ModelEvidence())
            )
        }
        await #expect(throws: OpenAIResponsesClientError.invalidRequest) {
            try await client.evaluateCondition(
                ConditionEvaluationRequest(
                    condition: fixtureConditionRequest().condition,
                    evidence: ModelEvidence(
                        image: ModelImage(data: Data(), mediaType: "text/plain")
                    )
                )
            )
        }
    }

    @Test("严格输出之外的空摘要和越界置信度被拒绝")
    func rejectsSemanticallyInvalidStructuredOutput() async {
        let emptySummaryClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"confirmedSummary\":\"  \",\"requiredEvidence\":\"dom\",\"currentDecision\":\"uncertain\",\"confidence\":0.2}"}]}]}"#
                )
            }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidStructuredOutput) {
            try await emptySummaryClient.prepareCondition(
                ConditionPreparationRequest(originalText: "构建完成")
            )
        }

        let conditionClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"matched\",\"confidence\":1.2}"}]}]}"#
                )
            }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidStructuredOutput) {
            try await conditionClient.evaluateCondition(fixtureConditionRequest())
        }

        let interruptibilityClient = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"interruptible\",\"confidence\":-0.1}"}]}]}"#
                )
            }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidStructuredOutput) {
            try await interruptibilityClient.evaluateInterruptibility(
                InterruptibilityEvaluationRequest(evidence: ModelEvidence(text: "桌面"))
            )
        }
    }

    @Test("无法解析的 Responses envelope 属于协议错误")
    func rejectsMalformedResponseEnvelope() async {
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(for: request, statusCode: 200, body: "not-json")
            }
        )

        await #expect(throws: OpenAIResponsesClientError.invalidResponse) {
            try await client.evaluateCondition(fixtureConditionRequest())
        }
    }

    @Test("远端模型必须使用 HTTPS，只有 loopback 开发端点允许 HTTP")
    func rejectsRemotePlaintextHTTP() async throws {
        let insecure = OpenAIResponsesClient(
            baseURL: URL(string: "http://model.example/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { _ in throw URLError(.unknown) }
        )
        await #expect(throws: OpenAIResponsesClientError.invalidConfiguration) {
            try await insecure.evaluateCondition(fixtureConditionRequest())
        }

        let loopback = OpenAIResponsesClient(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            apiKey: "test-key",
            model: "vision-model",
            session: makeStubbedSession { request in
                try stubbedResponse(
                    for: request,
                    statusCode: 200,
                    body: #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"decision\":\"matched\",\"confidence\":1}"}]}]}"#
                )
            }
        )
        #expect(try await loopback.evaluateCondition(fixtureConditionRequest()).decision == .matched)
    }
}

private func fixtureConditionRequest() -> ConditionEvaluationRequest {
    ConditionEvaluationRequest(
        condition: ConditionDefinition(
            originalText: "构建完成时提醒我",
            confirmedSummary: "构建已经完成",
            requiredEvidence: .dom
        ),
        evidence: ModelEvidence(text: "Build complete")
    )
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func record(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        lock.withLock {
            storedRequest = captured
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?

    static func install(handler: @escaping Handler) {
        lock.withLock {
            storedHandler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.storedHandler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeStubbedSession(
    handler: @escaping StubURLProtocol.Handler
) -> URLSession {
    StubURLProtocol.install(handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func stubbedResponse(
    for request: URLRequest,
    statusCode: Int,
    body: String
) throws -> (HTTPURLResponse, Data) {
    let url = try #require(request.url)
    let response = try #require(
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    )
    return (response, Data(body.utf8))
}
