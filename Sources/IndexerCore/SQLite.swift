import Foundation
import SQLite3
import CSQLiteVec

/// SQLite's SQLITE_TRANSIENT sentinel (tells SQLite to copy bound bytes).
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// Thin wrapper over the SQLite C API. Not thread-safe; use one instance per
/// thread/connection (the server opens its own read connection).
public final class Database {
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false, enableVec: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(code: rc, message: msg)
        }
        self.handle = db
        sqlite3_busy_timeout(db, 5000)
        if enableVec {
            var err: UnsafeMutablePointer<CChar>?
            if csv_register_vec(db, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "vec init failed"
                sqlite3_free(err)
                sqlite3_close(db)
                throw SQLiteError(code: -1, message: "sqlite-vec: \(msg)")
            }
        }
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: sqlite3_errcode(handle), message: msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(code: sqlite3_errcode(handle),
                              message: String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(stmt: stmt, db: handle)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Convenience: run a query returning a single integer (first row, first column).
    public func scalarInt(_ sql: String) throws -> Int64? {
        let s = try prepare(sql)
        defer { s.finalize() }
        return try s.step() ? s.int(0) : nil
    }

    public func scalarText(_ sql: String) throws -> String? {
        let s = try prepare(sql)
        defer { s.finalize() }
        return try s.step() ? s.text(0) : nil
    }
}

/// A prepared statement. Bind (1-indexed), step, read columns (0-indexed).
public final class Statement {
    let stmt: OpaquePointer
    let db: OpaquePointer
    init(stmt: OpaquePointer, db: OpaquePointer) { self.stmt = stmt; self.db = db }

    public func finalize() { sqlite3_finalize(stmt) }

    @discardableResult
    public func reset() -> Statement { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt); return self }

    // --- binding (1-indexed) ---
    @discardableResult public func bind(_ i: Int32, _ v: Int64) -> Statement { sqlite3_bind_int64(stmt, i, v); return self }
    @discardableResult public func bind(_ i: Int32, _ v: Int) -> Statement { sqlite3_bind_int64(stmt, i, Int64(v)); return self }
    @discardableResult public func bind(_ i: Int32, _ v: Double) -> Statement { sqlite3_bind_double(stmt, i, v); return self }
    @discardableResult public func bind(_ i: Int32, _ v: String?) -> Statement {
        if let v { sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, i) }
        return self
    }
    @discardableResult public func bind(_ i: Int32, _ v: Data) -> Statement {
        v.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
        return self
    }
    @discardableResult public func bindNull(_ i: Int32) -> Statement { sqlite3_bind_null(stmt, i); return self }

    /// Step. Returns true if a row is available, false when done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    /// Execute a statement expected to return no rows.
    public func run() throws { _ = try step() }

    // --- column reads (0-indexed) ---
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }
    public func blob(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let p = sqlite3_column_blob(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}
