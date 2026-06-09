import Foundation

/// Our own SQLite store (index.db): normalized messages + FTS5 + sqlite-vec
/// chunks + bookkeeping. Decoupled from chat.db. See PLAN §7.
public final class IndexStore {
    public let db: Database
    public let embedDim: Int

    public static let schemaVersion = 2

    /// 2-column external-content FTS (body + media_text) plus its sync triggers.
    /// media_text holds image tags/OCR so photos are searchable. Reused by
    /// createSchema (fresh DB) and migrateToV2 (existing DB).
    private static let ftsDDL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      body, media_text,
      content='messages', content_rowid='id',
      tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, body, media_text) VALUES (new.id, new.body, new.media_text);
    END;
    CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, body, media_text) VALUES('delete', old.id, old.body, old.media_text);
    END;
    CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, body, media_text) VALUES('delete', old.id, old.body, old.media_text);
      INSERT INTO messages_fts(rowid, body, media_text) VALUES (new.id, new.body, new.media_text);
    END;
    """

    public init(path: String, embedDim: Int) throws {
        // Ensure parent directory exists.
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        self.db = try Database(path: path, readOnly: false, enableVec: true)
        self.embedDim = embedDim
        try configure()
        try createSchema()
    }

    private func configure() throws {
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("PRAGMA synchronous=NORMAL;")
        try db.exec("PRAGMA foreign_keys=ON;")
    }

    private func createSchema() throws {
        let messagesExisted = try tableExists("messages")

        try db.exec("""
        CREATE TABLE IF NOT EXISTS messages (
          id           INTEGER PRIMARY KEY,
          chat_id      INTEGER NOT NULL,
          ts_unix      REAL    NOT NULL,
          sender       TEXT    NOT NULL,
          sender_name  TEXT,
          is_from_me   INTEGER NOT NULL,
          body         TEXT,
          has_media    INTEGER NOT NULL DEFAULT 0,
          reply_to     INTEGER,
          media_text   TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts_unix);
        CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id);

        CREATE TABLE IF NOT EXISTS chunks (
          id        INTEGER PRIMARY KEY,
          chat_id   INTEGER NOT NULL,
          start_id  INTEGER NOT NULL,
          end_id    INTEGER NOT NULL,
          ts_start  REAL NOT NULL,
          ts_end    REAL NOT NULL,
          text      TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

        -- Cached previews for URLs shared in the chat (OpenGraph/title metadata).
        CREATE TABLE IF NOT EXISTS link_previews (
          url         TEXT PRIMARY KEY,
          status      TEXT NOT NULL,
          title       TEXT,
          description TEXT,
          image_url   TEXT,
          site_name   TEXT,
          fetched_at  REAL NOT NULL
        );

        -- Vision results per image attachment (tags + OCR). media_text on messages
        -- is the denormalized, searchable concatenation across a message's images.
        CREATE TABLE IF NOT EXISTS image_meta (
          attachment_id INTEGER PRIMARY KEY,
          message_id    INTEGER NOT NULL,
          path          TEXT NOT NULL,
          mime          TEXT,
          status        TEXT NOT NULL,   -- ok | missing | error | skipped
          tags          TEXT,
          ocr_text      TEXT,
          processed_at  REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_image_meta_msg ON image_meta(message_id);
        """)

        // Migrate a pre-images (v1) database in place before creating the FTS,
        // so the FTS is always the 2-column shape.
        let hasMediaCol = messagesExisted ? try columnExists("messages", "media_text") : true
        if messagesExisted && !hasMediaCol {
            try db.exec("ALTER TABLE messages ADD COLUMN media_text TEXT;")
        }
        let ftsCols = messagesExisted ? try ftsColumnCount() : 0
        if ftsCols == 1 {
            try migrateFTSToTwoColumns()
        } else {
            try db.exec(Self.ftsDDL)
        }

        // vec_chunks dimension is fixed at creation time → format it in.
        try db.exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
          chunk_id INTEGER PRIMARY KEY,
          embedding FLOAT[\(embedDim)]
        );
        """)

        try setMeta("schema_version", String(Self.schemaVersion))
        try setMetaIfAbsent("embed_dim", String(embedDim))
    }

    // MARK: - Schema helpers / migration

    private func tableExists(_ name: String) throws -> Bool {
        let s = try db.prepare("SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=?")
        defer { s.finalize() }
        s.bind(1, name)
        return try s.step()
    }

    private func columnExists(_ table: String, _ column: String) throws -> Bool {
        let s = try db.prepare("SELECT 1 FROM pragma_table_info(?) WHERE name=?")
        defer { s.finalize() }
        s.bind(1, table).bind(2, column)
        return try s.step()
    }

    /// Number of user columns in messages_fts (1 = old body-only, 2 = body+media_text).
    private func ftsColumnCount() throws -> Int {
        guard try tableExists("messages_fts") else { return 0 }
        let s = try db.prepare("SELECT COUNT(*) FROM pragma_table_info('messages_fts')")
        defer { s.finalize() }
        return try s.step() ? Int(s.int(0)) : 0
    }

    /// Rebuild a 1-column FTS as the 2-column (body, media_text) shape and repopulate.
    private func migrateFTSToTwoColumns() throws {
        try db.exec("""
        DROP TRIGGER IF EXISTS messages_ai;
        DROP TRIGGER IF EXISTS messages_ad;
        DROP TRIGGER IF EXISTS messages_au;
        DROP TABLE IF EXISTS messages_fts;
        """)
        try db.exec(Self.ftsDDL)
        try db.exec("INSERT INTO messages_fts(rowid, body, media_text) SELECT id, body, media_text FROM messages;")
    }

    // MARK: - Meta

    public func getMeta(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT value FROM meta WHERE key=?")
        defer { s.finalize() }
        s.bind(1, key)
        return try s.step() ? s.text(0) : nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        let s = try db.prepare("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { s.finalize() }
        s.bind(1, key).bind(2, value)
        try s.run()
    }

    private func setMetaIfAbsent(_ key: String, _ value: String) throws {
        if try getMeta(key) == nil { try setMeta(key, value) }
    }

    public var lastIndexedRowID: Int64 {
        (try? getMeta("last_indexed_rowid")).flatMap { $0 }.flatMap { Int64($0) } ?? 0
    }

    public func setLastIndexedRowID(_ id: Int64) throws {
        try setMeta("last_indexed_rowid", String(id))
    }

    // MARK: - Message writes

    /// Insert/update a batch of messages in one transaction. FTS is maintained
    /// automatically by triggers, so re-running over the same range is idempotent.
    public func upsert(_ batch: [IndexedMessage]) throws {
        guard !batch.isEmpty else { return }
        try db.transaction {
            let ins = try db.prepare("""
                INSERT INTO messages(id, chat_id, ts_unix, sender, sender_name, is_from_me, body, has_media, reply_to)
                VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  body=excluded.body, has_media=excluded.has_media, sender_name=excluded.sender_name
                """)
            defer { ins.finalize() }
            for m in batch {
                ins.reset()
                ins.bind(1, m.id).bind(2, Int64(m.chatID)).bind(3, m.tsUnix)
                   .bind(4, m.sender).bind(5, m.senderName)
                   .bind(6, m.isFromMe ? 1 : 0).bind(7, m.body)
                   .bind(8, m.hasMedia ? 1 : 0)
                if let r = m.replyTo { ins.bind(9, r) } else { ins.bindNull(9) }
                try ins.run()
            }
        }
    }

    public var messageCount: Int64 {
        (try? db.scalarInt("SELECT COUNT(*) FROM messages")) ?? 0
    }

    // MARK: - Chunks + vectors (RAG)

    public var lastEmbeddedRowID: Int64 {
        (try? getMeta("last_embedded_rowid")).flatMap { $0 }.flatMap { Int64($0) } ?? 0
    }
    public func setLastEmbeddedRowID(_ id: Int64) throws {
        try setMeta("last_embedded_rowid", String(id))
    }

    public var chunkCount: Int64 {
        (try? db.scalarInt("SELECT COUNT(*) FROM chunks")) ?? 0
    }

    public func clearChunks() throws {
        try db.exec("DELETE FROM chunks; DELETE FROM vec_chunks;")
        try setLastEmbeddedRowID(0)
    }

    /// Text-bearing messages for chunking, in id order, with id > afterID.
    /// Includes image-only messages that have media_text (tags/OCR) so photos
    /// participate in RAG.
    public func textMessages(chatID: Int, afterID: Int64) throws -> [IndexedMessage] {
        let s = try db.prepare("""
            SELECT id, ts_unix, sender, sender_name, is_from_me, body, has_media, reply_to, media_text
            FROM messages
            WHERE chat_id=? AND id > ?
              AND ((body IS NOT NULL AND body <> '') OR (media_text IS NOT NULL AND media_text <> ''))
            ORDER BY id ASC
            """)
        defer { s.finalize() }
        s.bind(1, Int64(chatID)).bind(2, afterID)
        var out: [IndexedMessage] = []
        while try s.step() {
            out.append(IndexedMessage(
                id: s.int(0), chatID: chatID, tsUnix: s.double(1),
                sender: s.text(2) ?? "?", senderName: s.text(3), isFromMe: s.int(4) == 1,
                body: s.text(5), hasMedia: s.int(6) == 1,
                replyTo: s.isNull(7) ? nil : s.int(7), mediaText: s.text(8)))
        }
        return out
    }

    // MARK: - Link previews

    /// URLs already fetched (any status) — so incremental runs skip them.
    public func knownPreviewURLs() throws -> Set<String> {
        let s = try db.prepare("SELECT url FROM link_previews")
        defer { s.finalize() }
        var out = Set<String>()
        while try s.step() { if let u = s.text(0) { out.insert(u) } }
        return out
    }

    /// URLs that already have a useful preview (ok + title/description) — used to
    /// decide what to (re)try when Firecrawl is enabled.
    public func successfulPreviewURLs() throws -> Set<String> {
        let s = try db.prepare("SELECT url FROM link_previews WHERE status='ok' AND (title IS NOT NULL OR description IS NOT NULL)")
        defer { s.finalize() }
        var out = Set<String>()
        while try s.step() { if let u = s.text(0) { out.insert(u) } }
        return out
    }

    public func upsertPreviews(_ previews: [LinkPreview]) throws {
        guard !previews.isEmpty else { return }
        try db.transaction {
            let s = try db.prepare("""
                INSERT INTO link_previews(url, status, title, description, image_url, site_name, fetched_at)
                VALUES(?,?,?,?,?,?,?)
                ON CONFLICT(url) DO UPDATE SET
                  status=excluded.status, title=excluded.title, description=excluded.description,
                  image_url=excluded.image_url, site_name=excluded.site_name, fetched_at=excluded.fetched_at
                """)
            defer { s.finalize() }
            for p in previews {
                s.reset()
                s.bind(1, p.url).bind(2, p.status).bind(3, p.title).bind(4, p.description)
                 .bind(5, p.imageURL).bind(6, p.siteName).bind(7, p.fetchedAt)
                try s.run()
            }
        }
    }

    /// Look up successful previews for a set of URLs (keyed by url).
    public func previews(forURLs urls: [String]) throws -> [String: LinkPreview] {
        guard !urls.isEmpty else { return [:] }
        var out: [String: LinkPreview] = [:]
        let s = try db.prepare("""
            SELECT url, status, title, description, image_url, site_name, fetched_at
            FROM link_previews WHERE url = ?
            """)
        defer { s.finalize() }
        for u in urls {
            s.reset().bind(1, u)
            if try s.step(), s.text(1) == "ok" {
                out[u] = LinkPreview(
                    url: s.text(0) ?? u, status: s.text(1) ?? "ok",
                    title: s.text(2), description: s.text(3), imageURL: s.text(4),
                    siteName: s.text(5), fetchedAt: s.double(6))
            }
        }
        return out
    }

    public var previewCount: Int64 {
        (try? db.scalarInt("SELECT COUNT(*) FROM link_previews WHERE status='ok'")) ?? 0
    }

    /// Bodies of text messages that contain a URL, for extraction.
    public func bodiesWithLinks(chatID: Int) throws -> [String] {
        let s = try db.prepare("""
            SELECT body FROM messages
            WHERE chat_id=? AND body LIKE '%http%'
            """)
        defer { s.finalize() }
        s.bind(1, Int64(chatID))
        var out: [String] = []
        while try s.step() { if let b = s.text(0) { out.append(b) } }
        return out
    }

    // MARK: - Image metadata (Vision tags + OCR)

    public var lastImagedAttachmentID: Int64 {
        (try? getMeta("last_imaged_attachment_id")).flatMap { $0 }.flatMap { Int64($0) } ?? 0
    }
    public func setLastImagedAttachmentID(_ id: Int64) throws {
        try setMeta("last_imaged_attachment_id", String(id))
    }

    /// Attachment ids already processed successfully — skipped on incremental runs.
    public func okImageAttachmentIDs() throws -> Set<Int64> {
        let s = try db.prepare("SELECT attachment_id FROM image_meta WHERE status='ok'")
        defer { s.finalize() }
        var out = Set<Int64>()
        while try s.step() { out.insert(s.int(0)) }
        return out
    }

    public func upsertImageMeta(_ rows: [ImageRecord]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction {
            let s = try db.prepare("""
                INSERT INTO image_meta(attachment_id, message_id, path, mime, status, tags, ocr_text, processed_at)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(attachment_id) DO UPDATE SET
                  status=excluded.status, tags=excluded.tags, ocr_text=excluded.ocr_text,
                  processed_at=excluded.processed_at, path=excluded.path, mime=excluded.mime
                """)
            defer { s.finalize() }
            for r in rows {
                s.reset()
                s.bind(1, r.attachmentID).bind(2, r.messageID).bind(3, r.path).bind(4, r.mime)
                 .bind(5, r.status).bind(6, r.tags).bind(7, r.ocr).bind(8, r.processedAt)
                try s.run()
            }
        }
    }

    /// Recompute messages.media_text for a message from its ok image rows. The
    /// resulting UPDATE fires the FTS trigger, so search picks up tags/OCR.
    public func rebuildMediaText(messageID: Int64) throws {
        let q = try db.prepare("SELECT tags, ocr_text FROM image_meta WHERE message_id=? AND status='ok'")
        defer { q.finalize() }
        q.bind(1, messageID)
        var parts: [String] = []
        while try q.step() {
            if let t = q.text(0), !t.isEmpty { parts.append(t) }
            if let o = q.text(1), !o.isEmpty { parts.append(o) }
        }
        let text = parts.isEmpty ? nil : "📷 " + parts.joined(separator: " ")
        let u = try db.prepare("UPDATE messages SET media_text=? WHERE id=?")
        defer { u.finalize() }
        u.bind(1, text).bind(2, messageID)
        try u.run()
    }

    public var imageOKCount: Int64 {
        (try? db.scalarInt("SELECT COUNT(*) FROM image_meta WHERE status='ok'")) ?? 0
    }
    public var imageMissingCount: Int64 {
        (try? db.scalarInt("SELECT COUNT(*) FROM image_meta WHERE status='missing'")) ?? 0
    }

    /// Image display info per message id (for the server to attach to results).
    public func imagesForMessages(_ ids: [Int64]) throws -> [Int64: [ImageInfo]] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: [ImageInfo]] = [:]
        let s = try db.prepare("SELECT attachment_id, tags, status FROM image_meta WHERE message_id=? ORDER BY attachment_id")
        defer { s.finalize() }
        for id in ids {
            s.reset().bind(1, id)
            while try s.step() {
                let tags = (s.text(1)?.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }) ?? []
                let info = ImageInfo(attachmentID: s.int(0), tags: tags, hasFile: (s.text(2) == "ok"))
                out[id, default: []].append(info)
            }
        }
        return out
    }

    /// Resolve an attachment's on-disk path + status (for the thumbnail endpoint).
    public func imagePath(attachmentID: Int64) throws -> (path: String, status: String)? {
        let s = try db.prepare("SELECT path, status FROM image_meta WHERE attachment_id=?")
        defer { s.finalize() }
        s.bind(1, attachmentID)
        guard try s.step() else { return nil }
        return (s.text(0) ?? "", s.text(1) ?? "")
    }

    /// Insert chunks + their embedding vectors in one transaction.
    public func addChunks(_ items: [(chunk: Chunk, embeddingJSON: String)], chatID: Int) throws {
        guard !items.isEmpty else { return }
        try db.transaction {
            let insChunk = try db.prepare("""
                INSERT INTO chunks(chat_id, start_id, end_id, ts_start, ts_end, text)
                VALUES(?,?,?,?,?,?)
                """)
            defer { insChunk.finalize() }
            let insVec = try db.prepare("INSERT INTO vec_chunks(chunk_id, embedding) VALUES(?, ?)")
            defer { insVec.finalize() }
            for (c, json) in items {
                insChunk.reset()
                insChunk.bind(1, Int64(chatID)).bind(2, c.startID).bind(3, c.endID)
                        .bind(4, c.tsStart).bind(5, c.tsEnd).bind(6, c.text)
                try insChunk.run()
                let chunkID = db.lastInsertRowID
                insVec.reset().bind(1, chunkID).bind(2, json)
                try insVec.run()
            }
        }
    }
}
