import Foundation

/// Runs Apple Vision over image attachments in the target chat: content tags +
/// OCR → image_meta, and the denormalized messages.media_text used by FTS + RAG.
///
/// Availability: most attachments are offloaded to iCloud. We process whatever
/// is present on disk and record offloaded ones as `missing`; each run re-checks
/// `missing`/`error` rows (and skips `ok`), so coverage grows as files download.
public final class ImageIndexer {
    public let config: Config

    public init(config: Config) { self.config = config }

    public struct Result: Sendable {
        public let processed: Int
        public let ok: Int
        public let missing: Int
        public let okTotal: Int64
    }

    public func run(
        full: Bool,
        concurrency: Int = 4,
        throttleMs: Int = 0,
        log: ((String) -> Void)? = nil
    ) async throws -> Result {
        let store = try IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
        let reader = try ChatDBReader(chatDBPath: config.chatDBPath)
        let tagger = VisionTagger()

        // All image attachments (small set); skip already-ok unless full.
        let all = try reader.imageAttachments(chatID: config.targetChatID)
        let okSet = full ? [] : try store.okImageAttachmentIDs()
        let todo = all.filter { !okSet.contains($0.attachmentID) }
        log?("\(all.count) image attachments; \(todo.count) to (re)process\(full ? " (full)" : "")")

        guard !todo.isEmpty else {
            return Result(processed: 0, ok: 0, missing: 0, okTotal: store.imageOKCount)
        }

        var processed = 0, okCount = 0, missingCount = 0
        var affectedMessages = Set<Int64>()

        for wave in stride(from: 0, to: todo.count, by: concurrency) {
            let batch = Array(todo[wave..<min(wave + concurrency, todo.count)])
            let now = Date().timeIntervalSince1970

            let records = await withTaskGroup(of: ImageRecord.self) { group -> [ImageRecord] in
                for att in batch {
                    group.addTask {
                        guard FileManager.default.fileExists(atPath: att.path) else {
                            return ImageRecord(attachmentID: att.attachmentID, messageID: att.messageID,
                                               path: att.path, mime: att.mime, status: "missing",
                                               tags: nil, ocr: nil, processedAt: now)
                        }
                        guard let a = tagger.analyze(url: URL(fileURLWithPath: att.path)) else {
                            return ImageRecord(attachmentID: att.attachmentID, messageID: att.messageID,
                                               path: att.path, mime: att.mime, status: "error",
                                               tags: nil, ocr: nil, processedAt: now)
                        }
                        let tags = a.tags.map { $0.label }.joined(separator: ", ")
                        return ImageRecord(attachmentID: att.attachmentID, messageID: att.messageID,
                                           path: att.path, mime: att.mime, status: "ok",
                                           tags: tags.isEmpty ? nil : tags,
                                           ocr: a.ocr.isEmpty ? nil : a.ocr, processedAt: now)
                    }
                }
                var out: [ImageRecord] = []
                for await r in group { out.append(r) }
                return out
            }

            try store.upsertImageMeta(records)
            for r in records {
                processed += 1
                switch r.status {
                case "ok": okCount += 1; affectedMessages.insert(r.messageID)
                case "missing": missingCount += 1
                default: break
                }
            }
            log?("  \(processed)/\(todo.count) processed (\(okCount) ok, \(missingCount) offloaded)")
            if throttleMs > 0 { try await Task.sleep(nanoseconds: UInt64(throttleMs) * 1_000_000) }
        }

        // Refresh media_text for every message whose images changed (fires FTS triggers).
        for mid in affectedMessages { try store.rebuildMediaText(messageID: mid) }
        if let maxID = todo.map({ $0.attachmentID }).max() {
            try store.setLastImagedAttachmentID(max(maxID, store.lastImagedAttachmentID))
        }

        return Result(processed: processed, ok: okCount, missing: missingCount, okTotal: store.imageOKCount)
    }
}
