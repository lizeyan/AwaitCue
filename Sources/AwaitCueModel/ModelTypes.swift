import Foundation
import AwaitCueCore

/// 仅在内存中传给模型的图片证据。
public struct ModelImage: Equatable, Sendable {
    public let data: Data
    public let mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

/// 一次模型判断所需的当前证据；调用完成后不应由 adapter 持久化。
public struct ModelEvidence: Equatable, Sendable {
    public let text: String?
    public let image: ModelImage?

    public init(text: String? = nil, image: ModelImage? = nil) {
        self.text = text
        self.image = image
    }
}

/// 将用户原始 Condition 整理为可确认表述的类型化输入。
public struct ConditionPreparationRequest: Equatable, Sendable {
    public let originalText: String
    public let evidence: ModelEvidence?

    public init(originalText: String, evidence: ModelEvidence? = nil) {
        self.originalText = originalText
        self.evidence = evidence
    }
}

/// 等待用户确认的 Condition 摘要和后续证据要求。
public struct PreparedCondition: Equatable, Sendable {
    public let confirmedSummary: String
    public let requiredEvidence: EvidenceRequirement

    public init(confirmedSummary: String, requiredEvidence: EvidenceRequirement) {
        self.confirmedSummary = confirmedSummary
        self.requiredEvidence = requiredEvidence
    }
}

/// 对已确认 Condition 进行当前状态判断的类型化输入。
public struct ConditionEvaluationRequest: Equatable, Sendable {
    public let condition: ConditionDefinition
    public let evidence: ModelEvidence

    public init(condition: ConditionDefinition, evidence: ModelEvidence) {
        self.condition = condition
        self.evidence = evidence
    }
}

/// Condition 判断及其置信度。
public struct ConditionEvaluation: Equatable, Sendable {
    public let decision: ConditionDecision
    public let confidence: Double

    public init(decision: ConditionDecision, confidence: Double) {
        self.decision = decision
        self.confidence = confidence
    }
}

/// 判断当前活动是否适合打断的类型化输入。
public struct InterruptibilityEvaluationRequest: Equatable, Sendable {
    public let evidence: ModelEvidence

    public init(evidence: ModelEvidence) {
        self.evidence = evidence
    }
}

/// 是否适合打断的判断及其置信度。
public struct InterruptibilityEvaluation: Equatable, Sendable {
    public let decision: InterruptibilityDecision
    public let confidence: Double

    public init(decision: InterruptibilityDecision, confidence: Double) {
        self.decision = decision
        self.confidence = confidence
    }
}

/// Responses API adapter 对外暴露的稳定错误分类。
public enum OpenAIResponsesClientError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRequest
    case transport(URLError.Code)
    case httpStatus(Int)
    case invalidResponse
    case invalidStructuredOutput
}
