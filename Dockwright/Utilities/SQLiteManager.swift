import Foundation
import SQLite3

/// Thread-safe SQLite wrapper using the C API.
/// All operations are serialized through a DispatchQueue.
final class SQLiteManager: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dockwright.sqlite")

    nonisolated init() {}

    deinit {
        close()
    }

    // MARK: - Open / Close

    func open(path: String) throws {
        try queue.sync {
            // Ensure parent directory exists
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            let status = sqlite3_open_v2(path, &db, flags, nil)
            guard status == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
                throw SQLiteError.openFailed(msg)
            }

            // Enable WAL mode for better concurrent read performance
            sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

            // Set busy timeout to handle locked database (5 seconds)
            sqlite3_busy_timeout(db, 5000)
        }
    }

    /// Attempt to recover a corrupt database by removing and recreating it.
    func recoverIfCorrupt(path: String) throws {
        let fm = FileManager.default
        let backupPath = path + ".corrupt.\(Int(Date().timeIntervalSince1970))"
        try? fm.moveItem(atPath: path, toPath: backupPath)
        // Also remove WAL/SHM files
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
        try open(path: path)
    }

    func close() {
        queue.sync {
            if let db = db {
                sqlite3_close(db)
            }
            db = nil
        }
    }

    // MARK: - Execute (INSERT, UPDATE, DELETE, CREATE)

    func execute(sql: String, params: [String] = []) throws {
        try queue.sync {
            guard let db = db else { throw SQLiteError.notOpen }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.prepareFailed(msg)
            }
            defer { sqlite3_finalize(stmt) }

            for (index, param) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), (param as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            let result = sqlite3_step(stmt)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.executeFailed(msg)
            }
        }
    }

    // MARK: - Query (SELECT)

    func query(sql: String, params: [String] = []) throws -> [[String: String]] {
        try queue.sync {
            guard let db = db else { throw SQLiteError.notOpen }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.prepareFailed(msg)
            }
            defer { sqlite3_finalize(stmt) }

            for (index, param) in params.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), (param as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            var rows: [[String: String]] = []
            let columnCount = sqlite3_column_count(stmt)

            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: String] = [:]
                for i in 0..<columnCount {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    if let text = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: text)
                    }
                }
                rows.append(row)
            }

            return rows
        }
    }
}

enum SQLiteError: LocalizedError {
    case notOpen
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "Database not open"
        case .openFailed(let msg): return "Failed to open database: \(msg)"
        case .prepareFailed(let msg): return "SQL prepare failed: \(msg)"
        case .executeFailed(let msg): return "SQL execute failed: \(msg)"
        }
    }
}
