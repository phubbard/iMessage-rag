#!/usr/bin/env swift
//
// probe.swift — feasibility probe for an iMessage FTS/RAG app.
//
// Validates the full read path against the live Messages database:
//   • snapshots chat.db (+ WAL/SHM) so we read a consistent point-in-time copy
//   • opens it read-only via the SQLite C API
//   • enumerates group chats with message counts + date ranges
//   • pulls recent messages from the biggest group chat, decoding attributedBody
//   • reports how text is stored (text column vs attributedBody vs neither)
//
// Requires Full Disk Access for whatever runs it (Terminal / iTerm / the swift binary).
// Run:  swift probe.swift
//
import Foundation
import SQLite3

let APPLE_EPOCH: TimeInterval = 978_307_200  // 2001-01-01 → Unix offset
let HOME = FileManager.default.homeDirectoryForCurrentUser
let LIVE_DB = HOME.appendingPathComponent("Library/Messages/chat.db")

// ---- helpers ---------------------------------------------------------------

func appleDate(_ raw: Int64) -> Date {
    // modern macOS stores nanoseconds; very old stored seconds
    let secs = raw > 1_000_000_000_000 ? TimeInterval(raw) / 1e9 : TimeInterval(raw)
    return Date(timeIntervalSince1970: secs + APPLE_EPOCH)
}

let df: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
}()

/// Decode Messages' streamtyped attributedBody blob → plain text.
func decodeAttributedBody(_ data: Data) -> String? {
    if let s = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
        return s.string
    }
    return nil
}

func col(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, i) else { return nil }
    return String(cString: c)
}

// ---- snapshot --------------------------------------------------------------

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-probe-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let snap = tmp.appendingPathComponent("chat.db")

do {
    for suffix in ["", "-wal", "-shm"] {
        let src = URL(fileURLWithPath: LIVE_DB.path + suffix)
        guard FileManager.default.fileExists(atPath: src.path) else { continue }
        let dst = URL(fileURLWithPath: snap.path + suffix)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
    }
} catch {
    print("✗ Could not snapshot chat.db — likely missing Full Disk Access.\n  \(error)")
    exit(1)
}
print("✓ Snapshotted chat.db to \(snap.path)\n")

// ---- open ------------------------------------------------------------------

var db: OpaquePointer?
guard sqlite3_open_v2(snap.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    print("✗ sqlite open failed: \(String(cString: sqlite3_errmsg(db)))"); exit(1)
}
defer { sqlite3_close(db) }

func query(_ sql: String, _ each: (OpaquePointer?) -> Void) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("  ! query failed: \(String(cString: sqlite3_errmsg(db)))"); return
    }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
}

// ---- overview --------------------------------------------------------------

print("=== TOTALS ===")
query("SELECT count(*) FROM message") { print("messages:     \(sqlite3_column_int64($0, 0))") }
query("SELECT count(*) FROM chat")    { print("chats:        \(sqlite3_column_int64($0, 0))") }
query("SELECT count(*) FROM handle")  { print("handles:      \(sqlite3_column_int64($0, 0))") }
query("SELECT count(*) FROM attachment") { print("attachments:  \(sqlite3_column_int64($0, 0))") }

print("\n=== HOW IS TEXT STORED? (sample of 5000 recent) ===")
query("""
    SELECT
      SUM(CASE WHEN text IS NOT NULL AND length(text)>0 THEN 1 ELSE 0 END),
      SUM(CASE WHEN (text IS NULL OR length(text)=0) AND attributedBody IS NOT NULL THEN 1 ELSE 0 END),
      SUM(CASE WHEN (text IS NULL OR length(text)=0) AND attributedBody IS NULL THEN 1 ELSE 0 END),
      COUNT(*)
    FROM (SELECT text, attributedBody FROM message ORDER BY ROWID DESC LIMIT 5000)
""") { s in
    print("  text column populated:    \(sqlite3_column_int64(s,0))")
    print("  only attributedBody:      \(sqlite3_column_int64(s,1))")
    print("  neither (media/tapback):  \(sqlite3_column_int64(s,2))")
    print("  sampled:                  \(sqlite3_column_int64(s,3))")
}

// ---- group chats -----------------------------------------------------------

print("\n=== GROUP CHATS (>=3 participants), by message count ===")
struct ChatRow { let rowid: Int64; let name: String; let count: Int64; let minD: Int64; let maxD: Int64 }
var topChat: ChatRow?
query("""
    SELECT c.ROWID,
           COALESCE(NULLIF(c.display_name,''), c.chat_identifier) AS name,
           COUNT(m.ROWID) AS n,
           MIN(m.date), MAX(m.date),
           (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participants
    FROM chat c
    JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
    JOIN message m ON m.ROWID = cmj.message_id
    GROUP BY c.ROWID
    HAVING participants >= 3
    ORDER BY n DESC
    LIMIT 10
""") { s in
    let row = ChatRow(rowid: sqlite3_column_int64(s,0),
                      name: col(s,1) ?? "(unnamed)",
                      count: sqlite3_column_int64(s,2),
                      minD: sqlite3_column_int64(s,3),
                      maxD: sqlite3_column_int64(s,4))
    if topChat == nil { topChat = row }
    print("  [\(row.rowid)] \(row.name) — \(row.count) msgs, \(df.string(from: appleDate(row.minD)))–\(df.string(from: appleDate(row.maxD)))")
}

// ---- sample messages from the biggest group chat ---------------------------

guard let chat = topChat else { print("\n(no group chats found)"); exit(0) }
print("\n=== 8 RECENT MESSAGES from \"\(chat.name)\" (decoded) ===")
var decoded = 0, total = 0
query("""
    SELECT m.date, m.is_from_me,
           COALESCE(h.id, 'me') AS sender,
           m.text, m.attributedBody
    FROM chat_message_join cmj
    JOIN message m ON m.ROWID = cmj.message_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE cmj.chat_id = \(chat.rowid)
    ORDER BY m.date DESC
    LIMIT 8
""") { s in
    total += 1
    let when = df.string(from: appleDate(sqlite3_column_int64(s,0)))
    let sender = sqlite3_column_int64(s,1) == 1 ? "me" : (col(s,2) ?? "?")
    var body = col(s,3) ?? ""
    if body.isEmpty, sqlite3_column_type(s,4) != SQLITE_NULL,
       let blob = sqlite3_column_blob(s,4) {
        let n = Int(sqlite3_column_bytes(s,4))
        if let txt = decodeAttributedBody(Data(bytes: blob, count: n)) { body = txt; decoded += 1 }
    }
    let preview = body.replacingOccurrences(of: "\n", with: " ").prefix(70)
    print("  \(when)  \(sender.prefix(20).padding(toLength: 20, withPad: " ", startingAt: 0))  \(preview.isEmpty ? "‹non-text›" : String(preview))")
}
print("\n  (attributedBody decoded for \(decoded) of \(total) shown)")
print("\nDone. Snapshot left at \(snap.path) — delete when finished.")
