import Foundation

/// Hook 持久化 adapter 必须满足的最小接口。
public protocol HookRepository: Sendable {
    func loadHooks() async throws -> [Hook]
    func save(_ hook: Hook) async throws
    func delete(id: HookID) async throws
    func deleteAll() async throws
}

/// Hook 协调器无法完成请求的原因。
public enum HookCoordinatorError: Error, Equatable {
    case hookNotFound(HookID)
}

/// 串行协调生命周期与持久化，防止同一个 Hook 的并发事件覆盖彼此。
public actor HookCoordinator {
    private let repository: any HookRepository

    public init(repository: any HookRepository) {
        self.repository = repository
    }

    /// 恢复仍需要运行或等待用户处理的 Hook。
    public func restoreActiveHooks() async throws -> [Hook] {
        try await repository.loadHooks()
            .filter { $0.state != .completed && $0.state != .cancelled }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 保存一个新建 Hook。
    public func add(_ hook: Hook) async throws {
        try await repository.save(hook)
    }

    /// 应用生命周期事实并在返回前持久化完整新状态。
    public func apply(_ event: HookEvent, to id: HookID) async throws -> HookTransition {
        guard let hook = try await repository.loadHooks().first(where: { $0.id == id }) else {
            throw HookCoordinatorError.hookNotFound(id)
        }
        let transition = try HookLifecycle.apply(event, to: hook)
        try await repository.save(transition.hook)
        return transition
    }

    /// 永久删除一个 Hook 及其运行状态。
    public func delete(id: HookID) async throws {
        try await repository.delete(id: id)
    }

    /// 删除全部本地 Hook 数据。
    public func deleteAll() async throws {
        try await repository.deleteAll()
    }
}
