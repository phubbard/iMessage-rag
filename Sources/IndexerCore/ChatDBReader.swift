import Foundation

/// Reads messages out of Apple's chat.db. Always operates on a *snapshot*
/// (db + -wal + -shm) so we read a consistent point-in-time even while Messages
/// is writing. Requires Full Disk Access for the running process. See PLAN §5/§6.
public final class ChatDBReader {
    public struct GroupChat: Sendable {
        public let rowid: Int64
        public let name: String
        public let count: Int64
        public let minDate: Int64
        public let maxDate: Int64
    }

    let snapshotDir: URL
    let snapshotDB: URL
    let db: Database

    /// Snapshot `chatDBPath` into a temp dir and open it read-only.
    public init(chatDBPath: String) throws {
        let src = URL(fileURLWithPath: (chatDBPath as NSString).expandingTildeInPath)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("imsg-rag-snap-\(getpid())-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let snap = tmp.appendingPathComponent("chat.db")
        for suffix in ["", "-wal", "-shm"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            guard FileManager.default.fileExists(atPath: s.path) else { continue }
            let d = URL(fileURLWithPath: snap.path + suffix)
            try? FileManager.default.removeItem(at: d)
            try FileManager.default.copyItem(at: s, to: d)
        }
        self.snapshotDir = tmp
        self.snapshotDB = snap
        self.db = try Database(path: snap.path, readOnly: true)
    }

    deinit { try? FileManager.default.removeItem(at: snapshotDir) }

    /// Enumerate group chats (>=3 participants) by message count — useful for
    /// identifying / confirming the target chat id.
    public func groupChats(limit: Int = 10) throws -> [GroupChat] {
        let s = try db.prepare("""
            SELECT c.ROWID,
                   COALESCE(NULLIF(c.display_name,''), c.chat_identifier) AS name,
                   COUNT(m.ROWID) AS n, MIN(m.date), MAX(m.date),
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            HAVING participants >= 3
            ORDER BY n DESC
            LIMIT ?
            """)
        defer { s.finalize() }
        s.bind(1, limit)
        var rows: [GroupChat] = []
        while try s.step() {
            rows.append(GroupChat(rowid: s.int(0), name: s.text(1) ?? "(unnamed)",
                                  count: s.int(2), minDate: s.int(3), maxDate: s.int(4)))
        }
        return rows
    }

    public struct ImageAttachment: Sendable {
        public let attachmentID: Int64
        public let messageID: Int64
        public let path: String      // tilde-expanded absolute path
        public let mime: String?
    }

    /// Image attachments for `chatID` with attachment ROWID > `afterID`, ordered
    /// ascending. Excludes SVG (vector; Vision can't rasterize it). The file may
    /// or may not be present on disk (iCloud offload) — the caller checks.
    public func imageAttachments(chatID: Int, afterID: Int64 = 0) throws -> [ImageAttachment] {
        let s = try db.prepare("""
            SELECT a.ROWID, cmj.message_id, a.filename, a.mime_type
            FROM chat_message_join cmj
            JOIN message_attachment_join maj ON maj.message_id = cmj.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE cmj.chat_id = ? AND a.ROWID > ?
              AND a.mime_type LIKE 'image/%' AND a.mime_type <> 'image/svg+xml'
            ORDER BY a.ROWID ASC
            """)
        defer { s.finalize() }
        s.bind(1, chatID).bind(2, afterID)
        var out: [ImageAttachment] = []
        while try s.step() {
            guard let raw = s.text(2) else { continue }
            out.append(ImageAttachment(
                attachmentID: s.int(0), messageID: s.int(1),
                path: (raw as NSString).expandingTildeInPath, mime: s.text(3)))
        }
        return out
    }

    public func maxRowID(chatID: Int) throws -> Int64 {
        let s = try db.prepare("""
            SELECT COALESCE(MAX(m.ROWID),0)
            FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
            """)
        defer { s.finalize() }
        s.bind(1, chatID)
        return try s.step() ? s.int(0) : 0
    }

    /// Stream messages for `chatID` with ROWID > `afterRowID`, in ascending ROWID
    /// order, decoding text. Tapbacks/reactions (associated_message_type != 0) are
    /// skipped. `handles` maps handle.id → friendly name. The handler is invoked
    /// per batch so callers can write incrementally.
    public func streamMessages(
        chatID: Int,
        afterRowID: Int64 = 0,
        handles: [String: String] = [:],
        batchSize: Int = 500,
        _ handler: ([IndexedMessage]) throws -> Void
    ) throws {
        let s = try db.prepare("""
            SELECT m.ROWID, m.date, m.is_from_me,
                   COALESCE(h.id,'me') AS sender,
                   m.text, m.attributedBody, m.cache_has_attachments,
                   m.associated_message_type,
                   (SELECT m2.ROWID FROM message m2 WHERE m2.guid = m.thread_originator_guid) AS reply_to
            FROM chat_message_join cmj
            JOIN message m ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id = ? AND m.ROWID > ?
            ORDER BY m.ROWID ASC
            """)
        defer { s.finalize() }
        s.bind(1, chatID).bind(2, afterRowID)

        var batch: [IndexedMessage] = []
        batch.reserveCapacity(batchSize)
        while try s.step() {
            // Skip tapbacks/reactions entirely.
            if s.int(7) != 0 { continue }

            let rowid = s.int(0)
            let tsUnix = AppleDate.toUnix(s.int(1))
            let isFromMe = s.int(2) == 1
            let sender = isFromMe ? "me" : (s.text(3) ?? "?")
            let hasMedia = s.int(6) != 0

            // Resolve body: text column first, else decode attributedBody.
            var body: String? = nil
            if let t = s.text(4), !t.isEmpty {
                body = t
            } else if let blob = s.blob(5), let decoded = AttributedBodyDecoder.decode(blob), !decoded.isEmpty {
                body = decoded
            }

            let replyTo: Int64? = s.isNull(8) ? nil : s.int(8)
            let senderName = handles[sender] ?? (isFromMe ? handles["me"] : nil)

            batch.append(IndexedMessage(
                id: rowid, chatID: chatID, tsUnix: tsUnix,
                sender: sender, senderName: senderName, isFromMe: isFromMe,
                body: body, hasMedia: hasMedia, replyTo: replyTo))

            if batch.count >= batchSize {
                try handler(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try handler(batch) }
    }
}
