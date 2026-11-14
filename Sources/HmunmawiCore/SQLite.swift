import Foundation
import SQLite3

public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    /// What the owner reads: the common causes in plain words, the raw code only when it is something else.
    public var plain: String {
        switch code & 0xFF {
        case 13: return "Your Mac's disk is full, so Hmunmawi can't save anything. Free some space, then press Retry."
        case 10: return "Hmunmawi couldn't read or write its data. This usually means the disk is full or briefly unavailable. Free some space if it is low, then press Retry."
        case 5, 6: return "Hmunmawi's data is busy for a moment (another copy may be open). Press Retry."
        case 8: return "Hmunmawi's data file is read-only. Check that its folder in Library > Application Support is yours, then press Retry."
        default: return description
        }
    }
    public var description: String { "SQLite error \(code): \(message)" }
}

typealias Row = [String: SQLValue]

extension Dictionary where Key == String, Value == SQLValue {
    func int(_ key: String) -> Int64? {
        if case .integer(let v) = self[key] { return v }
        return nil
    }

    func string(_ key: String) -> String? {
        if case .text(let v) = self[key] { return v }
        return nil
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Not thread-safe; owned and used by exactly one actor.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        // Switching a new file to WAL can fail at once with "locked" while another connection is doing the same
        // (SQLite doesn't wait on the busy timeout for this one); retry briefly, up to ~5 s.
        var tries = 0
        while true {
            do { try execute("PRAGMA journal_mode=WAL"); break }
            catch let e as SQLiteError where (e.code == SQLITE_BUSY || e.code == SQLITE_LOCKED) && tries < 50 {
                tries += 1; usleep(100_000)
            }
        }
        try execute("PRAGMA foreign_keys=ON")
        try? execute("PRAGMA secure_delete=ON")   // deleted rows (old mail text, pruned events) are overwritten, not left on disk
    }

    deinit { sqlite3_close_v2(db) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    @discardableResult
    /// Steps a query and maps each row straight from the statement (columns by position), with no per-row
    /// dictionary. For hot paths such as reading events.
    func map<T>(_ sql: String, _ params: [SQLValue] = [], _ row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch param {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let v): rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            out.append(row(stmt))
        }
        return out
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch param {
            case .null: rc = sqlite3_bind_null(stmt, index)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw lastError() }
        }

        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError() }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: count))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        try query(sql, params)
    }

    func executeScript(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func lastError() -> SQLiteError {
        SQLiteError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}
