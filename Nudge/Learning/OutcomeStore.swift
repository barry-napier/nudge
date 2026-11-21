import Foundation
import SQLite3

/// What the writer did with one rewrite.
struct Outcome: Identifiable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Kept exactly as Nudge wrote it.
        case accepted
        /// Kept, then changed by the writer.
        case edited
        /// Undone, or deleted, or put back to the original.
        case undone
        /// Run again straight away with a different action.
        case rerun
    }

    var id: Int64 = 0
    var created = Date()
    var bundleID: String
    var appName: String
    var site: String?
    var action: String
    var voice: String?
    var kind: Kind
    /// Short snippets only. Text from password fields is never seen.
    var original: String
    var rewrite: String
    var final: String?
    var rerunTo: String?
}

/// A small SQLite database of outcomes in Application Support. Local only.
@MainActor
final class OutcomeStore {
    static let shared = OutcomeStore()

    /// Longest snippet kept for any one text.
    static let snippetLimit = 300

    private var db: OpaquePointer?
    let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Nudge/learning.sqlite")

    private init() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK else {
            Log.shared.add("Could not open the learning database.")
            db = nil
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created REAL NOT NULL,
                bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                site TEXT,
                action TEXT NOT NULL,
                voice TEXT,
                kind TEXT NOT NULL,
                original TEXT NOT NULL,
                rewrite TEXT NOT NULL,
                final TEXT,
                rerun_to TEXT,
                processed INTEGER NOT NULL DEFAULT 0
            )
            """)
    }

    func insert(_ outcome: Outcome) {
        let sql = """
            INSERT INTO outcomes (created, bundle_id, app_name, site, action, voice, kind, original, rewrite, final, rerun_to)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        withStatement(sql) { statement in
            sqlite3_bind_double(statement, 1, outcome.created.timeIntervalSince1970)
            bind(statement, 2, outcome.bundleID)
            bind(statement, 3, outcome.appName)
            bind(statement, 4, outcome.site)
            bind(statement, 5, outcome.action)
            bind(statement, 6, outcome.voice)
            bind(statement, 7, outcome.kind.rawValue)
            bind(statement, 8, Self.snippet(outcome.original))
            bind(statement, 9, Self.snippet(outcome.rewrite))
            bind(statement, 10, outcome.final.map(Self.snippet))
            bind(statement, 11, outcome.rerunTo)
            sqlite3_step(statement)
        }
    }

    func recent(limit: Int, unprocessedOnly: Bool = false) -> [Outcome] {
        let filter = unprocessedOnly ? "WHERE processed = 0" : ""
        let sql = """
            SELECT id, created, bundle_id, app_name, site, action, voice, kind, original, rewrite, final, rerun_to
            FROM outcomes \(filter) ORDER BY id DESC LIMIT ?
            """
        var rows: [Outcome] = []
        withStatement(sql) { statement in
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(Outcome(
                    id: sqlite3_column_int64(statement, 0),
                    created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    bundleID: text(statement, 2) ?? "",
                    appName: text(statement, 3) ?? "",
                    site: text(statement, 4),
                    action: text(statement, 5) ?? "",
                    voice: text(statement, 6),
                    kind: Outcome.Kind(rawValue: text(statement, 7) ?? "") ?? .accepted,
                    original: text(statement, 8) ?? "",
                    rewrite: text(statement, 9) ?? "",
                    final: text(statement, 10),
                    rerunTo: text(statement, 11)))
            }
        }
        return rows
    }

    func count(unprocessedOnly: Bool = false) -> Int {
        var result = 0
        withStatement("SELECT COUNT(*) FROM outcomes" + (unprocessedOnly ? " WHERE processed = 0" : "")) { statement in
            if sqlite3_step(statement) == SQLITE_ROW { result = Int(sqlite3_column_int(statement, 0)) }
        }
        return result
    }

    func countsByKind() -> [Outcome.Kind: Int] {
        var result: [Outcome.Kind: Int] = [:]
        withStatement("SELECT kind, COUNT(*) FROM outcomes GROUP BY kind") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if let kind = text(statement, 0).flatMap(Outcome.Kind.init(rawValue:)) {
                    result[kind] = Int(sqlite3_column_int(statement, 1))
                }
            }
        }
        return result
    }

    /// The newest outcome's id, or 0 when there are none.
    func latestID() -> Int64 {
        var result: Int64 = 0
        withStatement("SELECT COALESCE(MAX(id), 0) FROM outcomes") { statement in
            if sqlite3_step(statement) == SQLITE_ROW { result = sqlite3_column_int64(statement, 0) }
        }
        return result
    }

    /// Deletes outcomes newer than `id`. Used to clean up after the self-test.
    func delete(after id: Int64) {
        withStatement("DELETE FROM outcomes WHERE id > ?") { statement in
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_step(statement)
        }
    }

    func markAllProcessed() {
        exec("UPDATE outcomes SET processed = 1 WHERE processed = 0")
    }

    func deleteAll() {
        exec("DELETE FROM outcomes")
    }

    /// Removes everything recorded from one app, for example after excluding it.
    func delete(bundleID: String) {
        withStatement("DELETE FROM outcomes WHERE bundle_id = ?") { statement in
            bind(statement, 1, bundleID)
            sqlite3_step(statement)
        }
    }

    // MARK: - SQLite helpers

    static func snippet(_ text: String) -> String {
        text.count > snippetLimit ? String(text.prefix(snippetLimit)) + "…" : text
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.shared.add("Learning database error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.shared.add("Learning database error: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(statement) }
        body(statement)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        // SQLITE_TRANSIENT: SQLite copies the string.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}
