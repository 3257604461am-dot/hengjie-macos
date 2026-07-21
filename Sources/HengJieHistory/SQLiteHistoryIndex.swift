import Foundation
import SQLite3

public struct SQLiteHistoryRow: Sendable {
    public let id: String
    public let sortValue: Double
    public let kind: String
    public let isPinned: Bool
    public let byteCount: Int64
    public let searchText: String?
    public let metadata: Data

    public init(id: String, sortValue: Double, kind: String, isPinned: Bool, byteCount: Int64, searchText: String?, metadata: Data) {
        self.id = id; self.sortValue = sortValue; self.kind = kind; self.isPinned = isPinned
        self.byteCount = byteCount; self.searchText = searchText; self.metadata = metadata
    }
}

public enum SQLiteHistoryIndexError: LocalizedError {
    case open(String)
    case statement(String)
    case transaction(String)
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case let .open(message): "无法打开历史索引：\(message)"
        case let .statement(message): "历史索引操作失败：\(message)"
        case let .transaction(message): "历史索引事务失败：\(message)"
        case .invalidMetadata: "历史索引元数据损坏。"
        }
    }
}

/// A small SQLite metadata index. Large images, thumbnails and projects remain
/// separate files, so the database stays fast and crash recovery can remove
/// orphaned payload directories safely.
public actor SQLiteHistoryIndex {
    private let database: OpaquePointer

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let handle { sqlite3_close(handle) }
            throw SQLiteHistoryIndexError.open(message)
        }
        database = handle
        do {
            try Self.execute(database: handle, sql: "PRAGMA journal_mode=WAL;")
            try Self.execute(database: handle, sql: "PRAGMA synchronous=NORMAL;")
            try Self.execute(database: handle, sql: "PRAGMA foreign_keys=ON;")
            try Self.execute(database: handle, sql: "PRAGMA busy_timeout=2500;")
            try Self.execute(database: handle, sql: """
                CREATE TABLE IF NOT EXISTS items (
                    id TEXT PRIMARY KEY NOT NULL,
                    sort_value REAL NOT NULL,
                    kind TEXT NOT NULL,
                    is_pinned INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL DEFAULT 0,
                    search_text TEXT,
                    metadata TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS items_sort_idx ON items(sort_value DESC);
                CREATE INDEX IF NOT EXISTS items_kind_idx ON items(kind);
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func load() throws -> [SQLiteHistoryRow] {
        let statement = try prepare("SELECT id, sort_value, kind, is_pinned, byte_count, search_text, metadata FROM items ORDER BY sort_value DESC")
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteHistoryRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw statementError() }
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let kindPointer = sqlite3_column_text(statement, 2),
                  let metadataPointer = sqlite3_column_text(statement, 6),
                  let metadata = String(cString: metadataPointer).data(using: .utf8) else {
                throw SQLiteHistoryIndexError.invalidMetadata
            }
            let searchText = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            rows.append(SQLiteHistoryRow(
                id: String(cString: idPointer),
                sortValue: sqlite3_column_double(statement, 1),
                kind: String(cString: kindPointer),
                isPinned: sqlite3_column_int(statement, 3) != 0,
                byteCount: sqlite3_column_int64(statement, 4),
                searchText: searchText,
                metadata: metadata
            ))
        }
        return rows
    }

    public func replace(_ rows: [SQLiteHistoryRow]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM items;")
            for row in rows {
                let statement = try prepare("INSERT INTO items (id, sort_value, kind, is_pinned, byte_count, search_text, metadata) VALUES (?, ?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                try bind(row.id, to: statement, index: 1)
                sqlite3_bind_double(statement, 2, row.sortValue)
                try bind(row.kind, to: statement, index: 3)
                sqlite3_bind_int(statement, 4, row.isPinned ? 1 : 0)
                sqlite3_bind_int64(statement, 5, row.byteCount)
                if let searchText = row.searchText { try bind(searchText, to: statement, index: 6) }
                else { sqlite3_bind_null(statement, 6) }
                guard let metadata = String(data: row.metadata, encoding: .utf8) else { throw SQLiteHistoryIndexError.invalidMetadata }
                try bind(metadata, to: statement, index: 7)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
            }
            guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw transactionError() }
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    public func deleteAll() throws { try execute("DELETE FROM items;") }

    private func execute(_ sql: String) throws {
        try Self.execute(database: database, sql: sql)
    }

    private static func execute(database: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteHistoryIndexError.statement(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw statementError()
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw statementError() }
    }

    private func statementError() -> SQLiteHistoryIndexError {
        .statement(String(cString: sqlite3_errmsg(database)))
    }

    private func transactionError() -> SQLiteHistoryIndexError {
        .transaction(String(cString: sqlite3_errmsg(database)))
    }
}
