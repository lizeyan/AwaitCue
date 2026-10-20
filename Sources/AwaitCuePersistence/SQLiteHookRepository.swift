import Foundation
import SQLite3
import AwaitCueCore

/// SQLite Hook 仓库无法完成操作的稳定错误分类。
public enum SQLiteHookRepositoryError: Error, Equatable, Sendable {
    case openDatabase(Int32)
    case execute(Int32)
    case encodeHook
    case decodeHook
}

/// 使用本地 SQLite 数据库实现 `HookRepository`，并通过 actor 串行化同一连接上的操作。
public actor SQLiteHookRepository: HookRepository {
    // OpaquePointer 本身未声明 Sendable；连接仅在 actor 隔离方法和析构中使用，因此这里安全地放宽静态检查。
    nonisolated(unsafe) private let database: OpaquePointer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 打开或创建数据库，并确保 Hook 表已经存在。
    public init(databaseURL: URL) throws {
        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil)
        guard openResult == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw SQLiteHookRepositoryError.openDatabase(openResult)
        }

        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS hooks (
            id TEXT PRIMARY KEY NOT NULL,
            created_at REAL NOT NULL,
            payload BLOB NOT NULL
        ) WITHOUT ROWID;
        """
        let createResult = sqlite3_exec(openedDatabase, createTableSQL, nil, nil, nil)
        guard createResult == SQLITE_OK else {
            sqlite3_close(openedDatabase)
            throw SQLiteHookRepositoryError.execute(createResult)
        }
        database = openedDatabase
    }

    deinit {
        sqlite3_close(database)
    }

    /// 读取全部 Hook；排序只用于让恢复和测试获得稳定结果，不承载生命周期语义。
    public func loadHooks() async throws -> [Hook] {
        let statement = try prepare(
            "SELECT payload FROM hooks ORDER BY created_at ASC, id ASC;"
        )
        defer { sqlite3_finalize(statement) }

        var hooks: [Hook] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE {
                return hooks
            }
            guard stepResult == SQLITE_ROW else {
                throw SQLiteHookRepositoryError.execute(stepResult)
            }

            let byteCount = Int(sqlite3_column_bytes(statement, 0))
            guard byteCount > 0, let bytes = sqlite3_column_blob(statement, 0) else {
                throw SQLiteHookRepositoryError.decodeHook
            }
            let data = Data(bytes: bytes, count: byteCount)
            do {
                hooks.append(try decoder.decode(Hook.self, from: data))
            } catch {
                throw SQLiteHookRepositoryError.decodeHook
            }
        }
    }

    /// 新增或覆盖一个 Hook 的完整有限状态。
    public func save(_ hook: Hook) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(hook)
        } catch {
            throw SQLiteHookRepositoryError.encodeHook
        }

        let statement = try prepare(
            """
            INSERT INTO hooks (id, created_at, payload) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                created_at = excluded.created_at,
                payload = excluded.payload;
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(hook.id.rawValue.uuidString, at: 1, to: statement)
        guard sqlite3_bind_double(statement, 2, hook.createdAt.timeIntervalSince1970) == SQLITE_OK else {
            throw SQLiteHookRepositoryError.execute(sqlite3_errcode(database))
        }
        let bindPayloadResult = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                3,
                bytes.baseAddress,
                Int32(bytes.count),
                sqliteTransient
            )
        }
        guard bindPayloadResult == SQLITE_OK else {
            throw SQLiteHookRepositoryError.execute(sqlite3_errcode(database))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHookRepositoryError.execute(sqlite3_errcode(database))
        }

        // payload 只编码 Core.Hook；截图、DOM 和模型请求不属于该类型，因此不会进入数据库。
    }

    /// 按稳定身份永久删除一个 Hook。
    public func delete(id: HookID) async throws {
        let statement = try prepare("DELETE FROM hooks WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bind(id.rawValue.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHookRepositoryError.execute(sqlite3_errcode(database))
        }
    }

    /// 删除全部本地 Hook 数据。
    public func deleteAll() async throws {
        let result = sqlite3_exec(database, "DELETE FROM hooks;", nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteHookRepositoryError.execute(result)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteHookRepositoryError.execute(result)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString { characters in
            sqlite3_bind_text(statement, index, characters, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw SQLiteHookRepositoryError.execute(sqlite3_errcode(database))
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
