import Foundation
import SQLite3

/// A read-only SQLite connection. Opened with `SQLITE_OPEN_READONLY` and never
/// anything else. Callers hand it a copy of a database, never a database still inside
/// a Photos library — that rule is enforced by `ReadOnlyLibrary` being the only type
/// that can produce bytes from a bundle.
public final class SQLiteRead {

    public enum Failure: Error, LocalizedError {
        case cannotOpen(String)
        case badQuery(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let m): return "Could not open the photo database: \(m)"
            case .badQuery(let m): return "Database query failed: \(m)"
            }
        }
    }

    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        // READONLY is the whole point. No SQLITE_OPEN_CREATE, no READWRITE.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw Failure.cannotOpen(msg)
        }
        self.db = handle
    }

    deinit { sqlite3_close_v2(db) }

    /// Column values we care about, kept deliberately narrow.
    public enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case null

        public var intValue: Int64? {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int64(v)
            case .text(let s): return Int64(s)
            case .null: return nil
            }
        }
        public var doubleValue: Double? {
            switch self {
            case .int(let v): return Double(v)
            case .double(let v): return v
            case .text(let s): return Double(s)
            case .null: return nil
            }
        }
        public var textValue: String? {
            switch self {
            case .text(let s): return s.isEmpty ? nil : s
            case .int(let v): return String(v)
            case .double(let v): return String(v)
            case .null: return nil
            }
        }
    }

    public struct Row {
        let values: [String: Value]
        public subscript(_ column: String) -> Value { values[column] ?? .null }
    }

    /// Runs a query, calling `onRow` for each result. Streams; never materialises
    /// 13,000 rows of dictionaries at once when the caller does not need them all.
    public func query(_ sql: String, onRow: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_finalize(stmt)
            throw Failure.badQuery(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let columnCount = sqlite3_column_count(stmt)
        var names: [String] = []
        names.reserveCapacity(Int(columnCount))
        for i in 0..<columnCount {
            names.append(String(cString: sqlite3_column_name(stmt, i)))
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String: Value] = [:]
            values.reserveCapacity(names.count)
            for i in 0..<columnCount {
                let v: Value
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:   v = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    if let c = sqlite3_column_text(stmt, i) {
                        v = .text(String(cString: c))
                    } else { v = .null }
                default: v = .null
                }
                values[names[Int(i)]] = v
            }
            try onRow(Row(values: values))
        }
    }

    public func scalar(_ sql: String) -> Value? {
        var out: Value?
        try? query(sql) { row in
            if out == nil, let first = row.values.values.first { out = first }
        }
        return out
    }

    /// Table names present in this database. Used to tell the schemas apart.
    public func tableNames() -> Set<String> {
        var names = Set<String>()
        try? query("SELECT name FROM sqlite_master WHERE type='table'") { row in
            if let n = row["name"].textValue { names.insert(n) }
        }
        return names
    }

    /// Column names on a table, so a reader can adapt to schema drift between
    /// macOS versions instead of crashing on a renamed column.
    public func columnNames(of table: String) -> Set<String> {
        var names = Set<String>()
        try? query("SELECT name FROM pragma_table_info('\(table)')") { row in
            if let n = row["name"].textValue { names.insert(n) }
        }
        return names
    }
}
