import Foundation

/// Hook 创建参数不满足已确认的产品不变量。
public enum HookFactoryError: Error, Equatable {
    case emptyCondition
    case invalidMinimumDelay
    case invalidTargetRegion
}

/// 将用户确认过的输入转换为具有合法初始状态的 Hook。
public enum HookFactory {
    /// 创建从“观察中”开始的条件 Hook。
    public static func makeCondition(
        id: HookID = HookID(rawValue: UUID()),
        title: String,
        target: HookTarget,
        condition: ConditionDefinition,
        now: Date
    ) throws -> Hook {
        guard target.normalizedRegion.isValid else {
            throw HookFactoryError.invalidTargetRegion
        }
        guard !condition.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !condition.confirmedSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HookFactoryError.emptyCondition
        }

        return Hook(
            id: id,
            title: title,
            target: target,
            trigger: .condition(condition),
            state: .observing,
            createdAt: now,
            updatedAt: now,
            conditionProgress: ConditionProgress()
        )
    }

    /// 创建从“最短等待中”开始的延迟 Hook。
    public static func makeDelay(
        id: HookID = HookID(rawValue: UUID()),
        title: String,
        target: HookTarget,
        minimumDelay: TimeInterval,
        now: Date
    ) throws -> Hook {
        guard target.normalizedRegion.isValid else {
            throw HookFactoryError.invalidTargetRegion
        }
        guard minimumDelay > 0 else {
            throw HookFactoryError.invalidMinimumDelay
        }

        return Hook(
            id: id,
            title: title,
            target: target,
            trigger: .delay(DelayDefinition(minimumDelay: minimumDelay)),
            state: .waitingMinimum,
            createdAt: now,
            updatedAt: now,
            earliestAttentionAt: now.addingTimeInterval(minimumDelay)
        )
    }
}

public extension HookTarget {
    /// 读取不同 Target adapter 共享的框选区域。
    var normalizedRegion: NormalizedRegion {
        switch self {
        case let .window(target):
            target.normalizedRegion
        case let .browser(target):
            target.normalizedRegion
        }
    }
}
