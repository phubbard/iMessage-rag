import Foundation

/// Orchestrates a message-index pass: snapshot chat.db → stream target chat →
/// decode/normalize → write messages + FTS into index.db, advancing the ROWID
/// watermark. Embeddings/chunks are handled separately (Phase 3).
public final class Indexer {
    public let config: Config

    public init(config: Config) { self.config = config }

    public struct Result: Sendable {
        public let added: Int
        public let watermark: Int64
        public let total: Int64
    }

    /// Run a message index pass. `full: true` re-reads from ROWID 0 (idempotent
    /// upsert); otherwise resumes from the stored watermark.
    @discardableResult
    public func indexMessages(full: Bool, log: ((String) -> Void)? = nil) throws -> Result {
        let store = try IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
        try store.setMeta("target_chat_id", String(config.targetChatID))
        try store.setMeta("embed_model", config.embedModel)

        let reader = try ChatDBReader(chatDBPath: config.chatDBPath)
        let startWatermark = full ? 0 : store.lastIndexedRowID
        log?("indexing chat \(config.targetChatID) from ROWID > \(startWatermark)\(full ? " (full)" : "")")

        var added = 0
        var maxSeen = startWatermark
        try reader.streamMessages(
            chatID: config.targetChatID,
            afterRowID: startWatermark,
            handles: config.handles
        ) { batch in
            try store.upsert(batch)
            added += batch.count
            if let last = batch.last?.id { maxSeen = max(maxSeen, last) }
            log?("  +\(batch.count) (watermark \(maxSeen))")
        }

        if maxSeen > store.lastIndexedRowID { try store.setLastIndexedRowID(maxSeen) }
        return Result(added: added, watermark: maxSeen, total: store.messageCount)
    }
}
