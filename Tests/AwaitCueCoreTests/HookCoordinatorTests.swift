import Foundation
import Testing
@testable import AwaitCueCore

@Suite("Hook 协调")
struct HookCoordinatorTests {
    @Test("协调器在每次生命周期变化后原子保存新 Hook")
    func persistsLifecycleTransition() async throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let hook = try HookFactory.makeDelay(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!),
            title: "稍后查看",
            target: fixtureTarget,
            minimumDelay: 60,
            now: now
        )
        let repository = RecordingHookRepository(initialHooks: [hook])
        let coordinator = HookCoordinator(repository: repository)

        let transition = try await coordinator.apply(
            .timeAdvanced(to: now.addingTimeInterval(60)),
            to: hook.id
        )

        #expect(transition.hook.state == .waitingInterruptible)
        #expect(await repository.savedHooks.last?.state == .waitingInterruptible)
    }

    @Test("恢复时只返回仍需运行的 Hook")
    func restoresOnlyActiveHooks() async throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let active = try HookFactory.makeDelay(
            title: "活动",
            target: fixtureTarget,
            minimumDelay: 60,
            now: now
        )
        var completed = try HookFactory.makeDelay(
            id: HookID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!),
            title: "已完成",
            target: fixtureTarget,
            minimumDelay: 60,
            now: now.addingTimeInterval(1)
        )
        completed.state = .completed

        let repository = RecordingHookRepository(initialHooks: [active, completed])
        let coordinator = HookCoordinator(repository: repository)

        let restored = try await coordinator.restoreActiveHooks()

        #expect(restored == [active])
    }

    @Test("协调器支持新增、删除和清空")
    func addDeleteAndDeleteAll() async throws {
        let now = Date(timeIntervalSince1970: 41_000)
        let hook = try HookFactory.makeDelay(
            title: "新增",
            target: fixtureTarget,
            minimumDelay: 60,
            now: now
        )
        let repository = RecordingHookRepository(initialHooks: [])
        let coordinator = HookCoordinator(repository: repository)

        try await coordinator.add(hook)
        #expect(await repository.currentHooks == [hook])

        try await coordinator.delete(id: hook.id)
        #expect(await repository.currentHooks.isEmpty)

        try await coordinator.add(hook)
        try await coordinator.deleteAll()
        #expect(await repository.currentHooks.isEmpty)
    }

    @Test("不存在的 Hook 返回明确错误")
    func missingHookFailsExplicitly() async {
        let missing = HookID(rawValue: UUID())
        let coordinator = HookCoordinator(repository: RecordingHookRepository(initialHooks: []))

        await #expect(throws: HookCoordinatorError.hookNotFound(missing)) {
            try await coordinator.apply(.timeAdvanced(to: .now), to: missing)
        }
    }

    @Test("并发生命周期事件不会在 repository await 之间丢失更新")
    func serializesConcurrentLifecycleMutations() async throws {
        let now = Date(timeIntervalSince1970: 42_000)
        var hook = try HookFactory.makeDelay(
            title: "并发更新",
            target: fixtureTarget,
            minimumDelay: 60,
            now: now.addingTimeInterval(-60)
        )
        hook.state = .waitingInterruptible
        let hookID = hook.id
        let repository = SuspendingHookRepository(initialHook: hook)
        let coordinator = HookCoordinator(repository: repository)

        let first = Task {
            try await coordinator.apply(.blocked(.modelUnavailable, at: now), to: hookID)
        }
        try await waitUntil { await repository.loadCount == 1 }
        let second = Task {
            try await coordinator.apply(
                .interruptibilityEvaluated(.notInterruptible, at: now.addingTimeInterval(1)),
                to: hookID
            )
        }
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(await repository.loadCount == 1)
        await repository.releaseFirstLoad()
        _ = try await first.value
        _ = try await second.value

        let stored = try #require(await repository.currentHook)
        #expect(stored.blockReason == .modelUnavailable)
        #expect(stored.lastDecision?.value == InterruptibilityDecision.notInterruptible.rawValue)
    }

    private var fixtureTarget: HookTarget {
        .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.App",
                windowIdentifier: 30,
                initialTitle: "Target",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        )
    }
}

private actor SuspendingHookRepository: HookRepository {
    private var hook: Hook?
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private(set) var loadCount = 0

    init(initialHook: Hook) {
        hook = initialHook
    }

    var currentHook: Hook? { hook }

    func loadHooks() async throws -> [Hook] {
        loadCount += 1
        if loadCount == 1 {
            await withCheckedContinuation { continuation in
                firstLoadContinuation = continuation
            }
        }
        return hook.map { [$0] } ?? []
    }

    func save(_ hook: Hook) async throws {
        self.hook = hook
    }

    func delete(id: HookID) async throws {
        if hook?.id == id { hook = nil }
    }

    func deleteAll() async throws {
        hook = nil
    }

    func releaseFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0 ..< 100 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("异步条件未在预期时间内成立")
}

private actor RecordingHookRepository: HookRepository {
    private var hooks: [HookID: Hook]
    private(set) var savedHooks: [Hook] = []

    init(initialHooks: [Hook]) {
        hooks = Dictionary(uniqueKeysWithValues: initialHooks.map { ($0.id, $0) })
    }

    var currentHooks: [Hook] {
        hooks.values.sorted { $0.createdAt < $1.createdAt }
    }

    func loadHooks() async throws -> [Hook] {
        Array(hooks.values)
    }

    func save(_ hook: Hook) async throws {
        hooks[hook.id] = hook
        savedHooks.append(hook)
    }

    func delete(id: HookID) async throws {
        hooks[id] = nil
    }

    func deleteAll() async throws {
        hooks.removeAll()
    }
}
