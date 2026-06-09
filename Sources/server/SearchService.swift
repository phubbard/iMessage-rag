import Foundation
import IndexerCore

// Wire models shared with the web UI.

public struct SearchHit: Codable, Sendable {
    public let id: Int64
    public let ts: Double
    public let sender: String
    public let senderName: String?
    public let isFromMe: Bool
    public let snippet: String   // bm25 snippet with <mark> highlights
    public let body: String
    public let links: [LinkPreview]
    public let images: [ImageInfo]
}

public struct ContextMessage: Codable, Sendable {
    public let id: Int64
    public let ts: Double
    public let sender: String
    public let senderName: String?
    public let isFromMe: Bool
    public let body: String?
    public let hasMedia: Bool
    public let isHit: Bool
    public let links: [LinkPreview]
    public let images: [ImageInfo]
}

public struct SearchResponse: Codable, Sendable {
    public let query: String
    public let count: Int
    public let hits: [SearchHit]
}

public struct ContextResponse: Codable, Sendable {
    public let centerID: Int64
    public let messages: [ContextMessage]
}

public struct SenderInfo: Codable, Sendable {
    public let sender: String
    public let name: String?
    public let count: Int64
}

public struct SendersResponse: Codable, Sendable {
    public let senders: [SenderInfo]
}

public struct StatsResponse: Codable, Sendable {
    public let messages: Int64
    public let chunks: Int64
    public let taggedImages: Int64
    public let linkPreviews: Int64
    public let lastIndexedAt: Double?     // unix seconds of last indexer run
    public let latestMessageTs: Double?   // unix seconds of newest message
    public let latestMessageID: Int64     // ROWID of newest message (live-update cursor)
}

/// A conversational chunk retrieved for RAG, with its fused relevance score.
public struct RetrievedChunk: Codable, Sendable {
    public let id: Int64
    public let startID: Int64
    public let endID: Int64
    public let tsStart: Double
    public let tsEnd: Double
    public let text: String
    public let score: Double
}

/// Serializes access to a SQLite read connection over index.db. One connection,
/// actor-isolated — plenty for a family-scale app and avoids SQLite threading hazards.
public actor SearchService {
    let db: Database
    let chatID: Int
    let embedder: EmbeddingClient

    public init(config: Config) throws {
        // Open read/write (only SELECTs are issued) to avoid WAL read-only shm pitfalls;
        // enableVec so vector queries work on the same connection.
        self.db = try Database(path: config.indexDBPath, readOnly: false, enableVec: true)
        self.chatID = config.targetChatID
        self.embedder = EmbeddingClient(baseURL: config.lmStudioBaseURL, model: config.embedModel)
    }

    /// Turn free text into a safe FTS5 MATCH expression: bareword tokens AND-ed
    /// together, with a prefix match on the final token for search-as-you-type.
    static func ftsQuery(_ raw: String) -> String? {
        let specials = CharacterSet(charactersIn: "\"*()+-:^")
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.components(separatedBy: specials).joined() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var parts = tokens.map { "\"\($0)\"" }
        // Prefix-match the last token (helps incremental typing).
        if let last = tokens.last, last.count >= 2 {
            parts[parts.count - 1] = "\"\(last)\"*"
        }
        return parts.joined(separator: " AND ")
    }

    public func search(query: String, from: Double?, to: Double?, sender: String?, limit: Int) throws -> SearchResponse {
        guard let match = Self.ftsQuery(query) else {
            return SearchResponse(query: query, count: 0, hits: [])
        }
        var sql = """
            SELECT m.id, m.ts_unix, m.sender, m.sender_name, m.is_from_me,
                   snippet(messages_fts, 0, '<mark>', '</mark>', '…', 14) AS snip,
                   m.body
            FROM messages_fts f
            JOIN messages m ON m.id = f.rowid
            WHERE messages_fts MATCH ?
            """
        if from != nil   { sql += " AND m.ts_unix >= ?" }
        if to != nil     { sql += " AND m.ts_unix <= ?" }
        if sender != nil { sql += " AND m.sender = ?" }
        sql += " ORDER BY bm25(messages_fts) LIMIT ?"

        let s = try db.prepare(sql)
        defer { s.finalize() }
        var i: Int32 = 1
        s.bind(i, match); i += 1
        if let from   { s.bind(i, from); i += 1 }
        if let to     { s.bind(i, to); i += 1 }
        if let sender { s.bind(i, sender); i += 1 }
        s.bind(i, Int64(limit))

        struct Row { let id: Int64; let ts: Double; let sender: String; let senderName: String?
                     let isFromMe: Bool; let snippet: String; let body: String }
        var rows: [Row] = []
        while try s.step() {
            rows.append(Row(
                id: s.int(0), ts: s.double(1), sender: s.text(2) ?? "?",
                senderName: s.text(3), isFromMe: s.int(4) == 1,
                snippet: s.text(5) ?? "", body: s.text(6) ?? ""))
        }
        let previews = try linkPreviews(forBodies: rows.map { $0.body })
        let imagesByMsg = try imagesForMessages(rows.map { $0.id })
        let hits = rows.map { r in
            SearchHit(id: r.id, ts: r.ts, sender: r.sender, senderName: r.senderName,
                      isFromMe: r.isFromMe, snippet: r.snippet, body: r.body,
                      links: links(in: r.body, from: previews),
                      images: imagesByMsg[r.id] ?? [])
        }
        return SearchResponse(query: query, count: hits.count, hits: hits)
    }

    /// Distinct senders in the target chat, by message volume — populates the filter.
    public func senders() throws -> SendersResponse {
        let s = try db.prepare("""
            SELECT sender, MAX(sender_name), COUNT(*) AS n
            FROM messages WHERE chat_id=?
            GROUP BY sender ORDER BY n DESC
            """)
        defer { s.finalize() }
        s.bind(1, Int64(chatID))
        var out: [SenderInfo] = []
        while try s.step() {
            out.append(SenderInfo(sender: s.text(0) ?? "?", name: s.text(1), count: s.int(2)))
        }
        return SendersResponse(senders: out)
    }

    // MARK: - Hybrid retrieval for RAG (vector kNN + FTS bm25, fused with RRF)

    /// Retrieve the top-`k` chunks for a query by fusing semantic (vector) and
    /// lexical (FTS) rankings with Reciprocal Rank Fusion. Hybrid beats either
    /// alone for chat (PLAN §8).
    public func retrieveChunks(query: String, k: Int = 8, candidates: Int = 40,
                               from: Double? = nil, to: Double? = nil) async throws -> [RetrievedChunk] {
        let rrfK = 60.0
        var score: [Int64: Double] = [:]

        // --- vector arm ---
        if let vec = try await embedder.embed([query]).first {
            let s = try db.prepare("SELECT chunk_id FROM vec_chunks WHERE embedding MATCH ? AND k = ? ORDER BY distance")
            defer { s.finalize() }
            s.bind(1, vecJSON(vec)).bind(2, Int64(candidates))
            var rank = 0
            while try s.step() {
                score[s.int(0), default: 0] += 1.0 / (rrfK + Double(rank))
                rank += 1
            }
        }

        // --- lexical arm: top messages → their containing chunk ---
        if let match = Self.ftsQuery(query) {
            let s = try db.prepare("""
                SELECT m.id FROM messages_fts f JOIN messages m ON m.id=f.rowid
                WHERE messages_fts MATCH ? ORDER BY bm25(messages_fts) LIMIT ?
                """)
            defer { s.finalize() }
            s.bind(1, match).bind(2, Int64(candidates))
            var msgIDs: [Int64] = []
            while try s.step() { msgIDs.append(s.int(0)) }

            let findChunk = try db.prepare("""
                SELECT id FROM chunks WHERE chat_id=? AND start_id<=? AND end_id>=?
                ORDER BY (end_id - start_id) ASC LIMIT 1
                """)
            defer { findChunk.finalize() }
            var rank = 0
            for mid in msgIDs {
                findChunk.reset().bind(1, Int64(chatID)).bind(2, mid).bind(3, mid)
                if try findChunk.step() {
                    score[findChunk.int(0), default: 0] += 1.0 / (rrfK + Double(rank))
                }
                rank += 1
            }
        }

        guard !score.isEmpty else { return [] }
        let topIDs = score.sorted { $0.value > $1.value }.prefix(k).map { $0.key }

        // Fetch chunk rows for the winners, honoring optional date filters.
        var out: [RetrievedChunk] = []
        let fetch = try db.prepare("SELECT id, start_id, end_id, ts_start, ts_end, text FROM chunks WHERE id=?")
        defer { fetch.finalize() }
        for id in topIDs {
            fetch.reset().bind(1, id)
            if try fetch.step() {
                let tsStart = fetch.double(3), tsEnd = fetch.double(4)
                if let from, tsEnd < from { continue }
                if let to, tsStart > to { continue }
                out.append(RetrievedChunk(
                    id: fetch.int(0), startID: fetch.int(1), endID: fetch.int(2),
                    tsStart: tsStart, tsEnd: tsEnd, text: fetch.text(5) ?? "",
                    score: score[id] ?? 0))
            }
        }
        return out
    }

    private typealias MsgRow = (id: Int64, ts: Double, sender: String, senderName: String?,
                                isFromMe: Bool, body: String?, hasMedia: Bool)
    private static let msgCols = "id, ts_unix, sender, sender_name, is_from_me, body, has_media"

    private func readRows(_ stmt: Statement) throws -> [MsgRow] {
        defer { stmt.finalize() }
        var out: [MsgRow] = []
        while try stmt.step() {
            out.append((id: stmt.int(0), ts: stmt.double(1), sender: stmt.text(2) ?? "?",
                        senderName: stmt.text(3), isFromMe: stmt.int(4) == 1,
                        body: stmt.text(5), hasMedia: stmt.int(6) == 1))
        }
        return out
    }

    /// Turn rows into ContextMessages with link previews + image info attached.
    private func assemble(_ rows: [MsgRow], hitID: Int64?) throws -> [ContextMessage] {
        let previews = try linkPreviews(forBodies: rows.compactMap { $0.body })
        let imagesByMsg = try imagesForMessages(rows.map { $0.id })
        return rows.map { r in
            ContextMessage(id: r.id, ts: r.ts, sender: r.sender, senderName: r.senderName,
                           isFromMe: r.isFromMe, body: r.body, hasMedia: r.hasMedia,
                           isHit: hitID != nil && r.id == hitID,
                           links: links(in: r.body ?? "", from: previews),
                           images: imagesByMsg[r.id] ?? [])
        }
    }

    public func context(id: Int64, window: Int) throws -> ContextResponse {
        let before = try readRows(db.prepare(
            "SELECT \(Self.msgCols) FROM messages WHERE chat_id=? AND id <= ? ORDER BY id DESC LIMIT ?")
            .bind(1, Int64(chatID)).bind(2, id).bind(3, Int64(window + 1))).reversed()
        let after = try readRows(db.prepare(
            "SELECT \(Self.msgCols) FROM messages WHERE chat_id=? AND id > ? ORDER BY id ASC LIMIT ?")
            .bind(1, Int64(chatID)).bind(2, id).bind(3, Int64(window)))
        return ContextResponse(centerID: id, messages: try assemble(Array(before) + after, hitID: id))
    }

    /// A page of the thread for browsing, in ascending id order:
    /// - `after`  → messages with id > after (for live-appending new messages)
    /// - `before` → messages with id < before (for loading older history)
    /// - neither  → the latest page.
    public func thread(before: Int64?, after: Int64?, limit: Int) throws -> ContextResponse {
        let cap = Int64(min(max(limit, 1), 200))
        let rows: [MsgRow]
        if let after {
            // Already ascending — no reverse needed.
            rows = try readRows(db.prepare(
                "SELECT \(Self.msgCols) FROM messages WHERE chat_id=? AND id > ? ORDER BY id ASC LIMIT ?")
                .bind(1, Int64(chatID)).bind(2, after).bind(3, cap))
        } else {
            let stmt: Statement
            if let before {
                stmt = try db.prepare("SELECT \(Self.msgCols) FROM messages WHERE chat_id=? AND id < ? ORDER BY id DESC LIMIT ?")
                    .bind(1, Int64(chatID)).bind(2, before).bind(3, cap)
            } else {
                stmt = try db.prepare("SELECT \(Self.msgCols) FROM messages WHERE chat_id=? ORDER BY id DESC LIMIT ?")
                    .bind(1, Int64(chatID)).bind(2, cap)
            }
            rows = Array(try readRows(stmt).reversed())
        }
        return ContextResponse(centerID: 0, messages: try assemble(rows, hitID: nil))
    }

    public func stats() throws -> StatsResponse {
        func count(_ sql: String) -> Int64 { (try? db.scalarInt(sql)) ?? 0 }
        func scalarDouble(_ sql: String) -> Double? {
            guard let s = try? db.prepare(sql) else { return nil }
            defer { s.finalize() }
            return ((try? s.step()) == true && !s.isNull(0)) ? s.double(0) : nil
        }
        return StatsResponse(
            messages: count("SELECT COUNT(*) FROM messages WHERE chat_id=\(chatID)"),
            chunks: count("SELECT COUNT(*) FROM chunks"),
            taggedImages: count("SELECT COUNT(*) FROM image_meta WHERE status='ok'"),
            linkPreviews: count("SELECT COUNT(*) FROM link_previews WHERE status='ok' AND (title IS NOT NULL OR description IS NOT NULL)"),
            lastIndexedAt: try? getMetaDouble("last_indexed_at"),
            latestMessageTs: scalarDouble("SELECT MAX(ts_unix) FROM messages WHERE chat_id=\(chatID)"),
            latestMessageID: count("SELECT COALESCE(MAX(id),0) FROM messages WHERE chat_id=\(chatID)"))
    }

    private func getMetaDouble(_ key: String) throws -> Double? {
        let s = try db.prepare("SELECT value FROM meta WHERE key=?")
        defer { s.finalize() }
        s.bind(1, key)
        return try s.step() ? s.text(0).flatMap(Double.init) : nil
    }

    // MARK: - Link preview attachment

    /// Batch-load previews for every URL appearing in the given bodies.
    private func linkPreviews(forBodies bodies: [String]) throws -> [String: LinkPreview] {
        var urls = Set<String>()
        for b in bodies where b.contains("http") { for u in URLExtractor.extract(b) { urls.insert(u) } }
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
                    url: s.text(0) ?? u, status: "ok", title: s.text(2), description: s.text(3),
                    imageURL: s.text(4), siteName: s.text(5), fetchedAt: s.double(6))
            }
        }
        return out
    }

    /// Image display info (tags, availability) per message id.
    private func imagesForMessages(_ ids: [Int64]) throws -> [Int64: [ImageInfo]] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: [ImageInfo]] = [:]
        let s = try db.prepare("SELECT attachment_id, tags, status FROM image_meta WHERE message_id=? ORDER BY attachment_id")
        defer { s.finalize() }
        for id in ids {
            s.reset().bind(1, id)
            while try s.step() {
                let tags = (s.text(1)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }) ?? []
                out[id, default: []].append(
                    ImageInfo(attachmentID: s.int(0), tags: tags, hasFile: s.text(2) == "ok"))
            }
        }
        return out
    }

    /// On-disk path + status for an attachment (for the thumbnail endpoint).
    public func imagePath(attachmentID: Int64) throws -> (path: String, status: String)? {
        let s = try db.prepare("SELECT path, status FROM image_meta WHERE attachment_id=?")
        defer { s.finalize() }
        s.bind(1, attachmentID)
        guard try s.step() else { return nil }
        return (s.text(0) ?? "", s.text(1) ?? "")
    }

    /// Resolve the previews for one body, preserving URL order. URLs without a
    /// fetched preview (e.g. sites that 403 our bot, like nytimes.com/alltrails.com)
    /// still get a card synthesized from the URL itself, so every link renders.
    private func links(in body: String, from map: [String: LinkPreview]) -> [LinkPreview] {
        guard body.contains("http") else { return [] }
        var seen = Set<String>()
        return URLExtractor.extract(body).compactMap { url in
            guard seen.insert(url).inserted else { return nil }
            return map[url] ?? Self.fallbackPreview(url)
        }
    }

    /// Build a minimal preview from a URL alone: humanized last path segment as
    /// the title, host (sans www) as the site. No image.
    static func fallbackPreview(_ url: String) -> LinkPreview? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // Last meaningful path segment → words.
        let segs = u.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var title: String? = nil
        if let last = segs.last {
            let stem = last
                .replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: ".php", with: "")
            let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            // Skip pure-id slugs (all digits / very short).
            let meaningful = words.filter { $0.count > 1 && !$0.allSatisfy(\.isNumber) }
            if meaningful.count >= 1 {
                title = meaningful.joined(separator: " ").capitalized
            }
        }
        return LinkPreview(url: url, status: "ok", title: title, description: nil,
                           imageURL: nil, siteName: site, fetchedAt: 0)
    }
}
