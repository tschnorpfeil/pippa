import Foundation
import SQLite3

/// Thin wrapper around the system SQLite. Not thread-safe: use only from one actor.
final class SQLiteDB: @unchecked Sendable {
    enum Value: Sendable { case text(String), int(Int64), real(Double), null }
    struct DBError: Error, CustomStringConvertible { let description: String }

    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            sqlite3_close(db)
            throw DBError(description: msg)
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec"
            sqlite3_free(err)
            throw DBError(description: msg)
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: String(cString: sqlite3_errmsg(db)) + " — " + sql)
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLiteDB.transient)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): sqlite3_bind_double(stmt, idx, v)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    func run(_ sql: String, _ args: [Value] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(description: String(cString: sqlite3_errmsg(db))) }
    }

    func query(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [[Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError(description: String(cString: sqlite3_errmsg(db))) }
            var row: [Value] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(stmt, c)))
                case SQLITE_NULL: row.append(.null)
                default: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension SQLiteDB.Value {
    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int64? {
        switch self { case .int(let v): v; case .real(let v): Int64(v); default: nil }
    }
    var double: Double? {
        switch self { case .real(let v): v; case .int(let v): Double(v); default: nil }
    }
}
