import Foundation
import Testing
@testable import AwaitCueCore
@testable import AwaitCuePersistence

@Suite("SQLite Hook 仓库")
struct SQLiteHookRepositoryTests {
    @Test("真实临时数据库支持 Hook 新增、更新、删除和清空")
    func persistsHookRepositoryRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwaitCueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try SQLiteHookRepository(
            databaseURL: directory.appendingPathComponent("hooks.sqlite")
        )
        let first = makeConditionHook(
            id: "00000000-0000-0000-0000-000000000101",
            title: "等待构建",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = makeDelayHook(
            id: "00000000-0000-0000-0000-000000000102",
            title: "稍后查看",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        try await repository.save(first)
        try await repository.save(second)
        #expect(try await repository.loadHooks() == [first, second])

        var updated = first
        updated.title = "等待构建成功"
        updated.blockReason = .modelUnavailable
        updated.lastDecision = LastDecision(
            kind: .condition,
            value: ConditionDecision.uncertain.rawValue,
            confidence: 0.4,
            evaluatedAt: Date(timeIntervalSince1970: 1_100)
        )
        try await repository.save(updated)
        #expect(try await repository.loadHooks() == [updated, second])

        try await repository.delete(id: first.id)
        #expect(try await repository.loadHooks() == [second])

        try await repository.deleteAll()
        #expect(try await repository.loadHooks().isEmpty)
    }

    @Test("另一个数据库连接可以恢复已经提交的 Hook")
    func reopensPersistedHooks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwaitCueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("hooks.sqlite")
        let hook = makeDelayHook(
            id: "00000000-0000-0000-0000-000000000103",
            title: "进程重启后恢复",
            createdAt: Date(timeIntervalSince1970: 3_000)
        )

        let writer = try SQLiteHookRepository(databaseURL: databaseURL)
        try await writer.save(hook)
        let reader = try SQLiteHookRepository(databaseURL: databaseURL)

        #expect(try await reader.loadHooks() == [hook])
    }

    @Test("数据库打开、建表和 Hook 编码失败使用明确错误")
    func classifiesDatabaseAndEncodingFailures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwaitCueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try SQLiteHookRepository(databaseURL: directory)
            Issue.record("目录不应被当作 SQLite 数据库打开")
        } catch SQLiteHookRepositoryError.openDatabase(_) {
            // 预期分类。
        } catch {
            Issue.record("数据库打开失败分类错误：\(error)")
        }

        let invalidDatabase = directory.appendingPathComponent("invalid.sqlite")
        try Data("not-a-sqlite-database".utf8).write(to: invalidDatabase)
        do {
            _ = try SQLiteHookRepository(databaseURL: invalidDatabase)
            Issue.record("损坏文件不应完成建表")
        } catch SQLiteHookRepositoryError.execute(_) {
            // 预期分类。
        } catch {
            Issue.record("数据库建表失败分类错误：\(error)")
        }

        let repository = try SQLiteHookRepository(
            databaseURL: directory.appendingPathComponent("valid.sqlite")
        )
        var unencodable = makeDelayHook(
            id: "00000000-0000-0000-0000-000000000104",
            title: "非法浮点数",
            createdAt: Date(timeIntervalSince1970: 4_000)
        )
        unencodable.target = .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.Editor",
                windowIdentifier: 7,
                initialTitle: "Document",
                normalizedRegion: NormalizedRegion(x: .nan, y: 0, width: 1, height: 1)
            )
        )
        await #expect(throws: SQLiteHookRepositoryError.encodeHook) {
            try await repository.save(unencodable)
        }
    }
}

private func makeConditionHook(id: String, title: String, createdAt: Date) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: title,
        target: .browser(
            BrowserTarget(
                browserBundleIdentifier: "com.google.Chrome",
                nativeWindowIdentifier: 42,
                extensionInstallationID: "installation-id",
                tabIdentifier: 42,
                host: "example.com",
                initialURL: URL(string: "https://example.com/build")!,
                initialTitle: "Build",
                normalizedRegion: NormalizedRegion(x: 0.1, y: 0.2, width: 0.5, height: 0.4),
                observationMode: .domAndImage
            )
        ),
        trigger: .condition(
            ConditionDefinition(
                originalText: "构建完成时提醒我",
                confirmedSummary: "构建已经完成",
                requiredEvidence: .domAndImage
            )
        ),
        state: .observing,
        createdAt: createdAt,
        updatedAt: createdAt,
        conditionProgress: ConditionProgress()
    )
}

private func makeDelayHook(id: String, title: String, createdAt: Date) -> Hook {
    Hook(
        id: HookID(rawValue: UUID(uuidString: id)!),
        title: title,
        target: .window(
            WindowTarget(
                applicationBundleIdentifier: "com.example.Editor",
                windowIdentifier: 7,
                initialTitle: "Document",
                normalizedRegion: NormalizedRegion(x: 0, y: 0, width: 1, height: 1)
            )
        ),
        trigger: .delay(DelayDefinition(minimumDelay: 300)),
        state: .waitingMinimum,
        createdAt: createdAt,
        updatedAt: createdAt,
        earliestAttentionAt: createdAt.addingTimeInterval(300)
    )
}
