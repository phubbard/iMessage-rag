import Foundation

/// Builds conversational chunks from indexed messages, embeds them via LM Studio,
/// and stores them in `chunks` + `vec_chunks`. The initial full pass is throttled
/// so it doesn't starve interactive LLM use (PLAN §8/§12).
public final class EmbeddingIndexer {
    public let config: Config

    public init(config: Config) { self.config = config }

    public struct Result: Sendable {
        public let chunksAdded: Int
        public let totalChunks: Int64
    }

    public func run(
        full: Bool,
        batchSize: Int = 32,
        throttleMs: Int = 50,
        log: ((String) -> Void)? = nil
    ) async throws -> Result {
        let store = try IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
        let client = EmbeddingClient(baseURL: config.lmStudioBaseURL, model: config.embedModel)

        if full { try store.clearChunks(); log?("cleared existing chunks") }

        let watermark = store.lastEmbeddedRowID
        let messages = try store.textMessages(chatID: config.targetChatID, afterID: watermark)
        guard !messages.isEmpty else {
            log?("no new messages to embed")
            return Result(chunksAdded: 0, totalChunks: store.chunkCount)
        }

        let chunks = Chunker().chunk(messages)
        log?("chunked \(messages.count) messages → \(chunks.count) chunks; embedding…")

        var added = 0
        var maxEndID = watermark
        var batch: [Chunk] = []
        batch.reserveCapacity(batchSize)

        func flush() async throws {
            guard !batch.isEmpty else { return }
            let vectors = try await client.embed(batch.map { $0.text })
            let items = zip(batch, vectors).map { ($0, vecJSON($1)) }
            try store.addChunks(items, chatID: config.targetChatID)
            added += batch.count
            maxEndID = max(maxEndID, batch.map { $0.endID }.max() ?? maxEndID)
            log?("  embedded \(added)/\(chunks.count) chunks")
            batch.removeAll(keepingCapacity: true)
            if throttleMs > 0 { try await Task.sleep(nanoseconds: UInt64(throttleMs) * 1_000_000) }
        }

        for c in chunks {
            batch.append(c)
            if batch.count >= batchSize { try await flush() }
        }
        try await flush()

        if maxEndID > store.lastEmbeddedRowID { try store.setLastEmbeddedRowID(maxEndID) }
        return Result(chunksAdded: added, totalChunks: store.chunkCount)
    }
}
