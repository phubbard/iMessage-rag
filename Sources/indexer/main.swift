import Foundation
import IndexerCore

// indexer — build/update index.db from chat.db.
//
//   indexer --full            full (re)index of messages + FTS
//   indexer --watch [secs]    incremental loop (default 60s)
//   indexer                   one incremental pass
//   indexer --chats           list group chats (to find/confirm target chat id)
//   indexer --embed [--full]  build chunks + embeddings for RAG
//   indexer --previews [--full]  fetch link previews for URLs in messages
//   indexer --images [--full]    Vision tags + OCR for image attachments
//   --config <path>           config file (default ./config.json)

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    let v = a[i + 1]
    return v.hasPrefix("--") ? nil : v
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

let configPath = arg("--config")
let config: Config
do { config = try Config.resolveAndLoad(configPath) }
catch { FileHandle.standardError.write(Data("config error: \(error)\n".utf8)); exit(1) }

func stamp(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

do {
    if flag("--chats") {
        let reader = try ChatDBReader(chatDBPath: config.chatDBPath)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        print("Group chats (>=3 participants), by message count:")
        for c in try reader.groupChats(limit: 15) {
            let lo = df.string(from: Date(timeIntervalSince1970: AppleDate.toUnix(c.minDate)))
            let hi = df.string(from: Date(timeIntervalSince1970: AppleDate.toUnix(c.maxDate)))
            print("  [\(c.rowid)] \(c.name) — \(c.count) msgs, \(lo)…\(hi)")
        }
        exit(0)
    }

    // Standalone embed pass (not combined with --watch).
    if flag("--embed") && !flag("--watch") {
        let emb = EmbeddingIndexer(config: config)
        let r = try await emb.run(full: flag("--full"), log: stamp)
        stamp("embeddings done: +\(r.chunksAdded) chunks (total \(r.totalChunks))")
        exit(0)
    }

    // Standalone link-preview pass (not combined with --watch).
    if flag("--previews") && !flag("--watch") {
        let pv = PreviewIndexer(config: config)
        let r = try await pv.run(full: flag("--full"), log: stamp)
        stamp("previews done: fetched \(r.fetched), \(r.ok) with metadata (total \(r.total))")
        exit(0)
    }

    // Standalone image (Vision tags + OCR) pass.
    if flag("--images") && !flag("--watch") {
        let im = ImageIndexer(config: config)
        let r = try await im.run(full: flag("--full"), log: stamp)
        stamp("images done: \(r.processed) processed, \(r.ok) ok, \(r.missing) offloaded (total ok \(r.okTotal))")
        exit(0)
    }

    let indexer = Indexer(config: config)

    if flag("--watch") {
        let interval = TimeInterval(arg("--watch").flatMap { Double($0) } ?? 60)
        let alsoEmbed = flag("--embed")
        let alsoPreviews = flag("--previews")
        let alsoImages = flag("--images")
        let extras = [alsoEmbed ? "embeddings" : nil, alsoPreviews ? "previews" : nil,
                      alsoImages ? "images" : nil].compactMap { $0 }
        stamp("watch mode: polling every \(Int(interval))s\(extras.isEmpty ? "" : " (with \(extras.joined(separator: " + ")))"). Ctrl-C to stop.")
        let embedder = EmbeddingIndexer(config: config)
        let previewer = PreviewIndexer(config: config)
        let imager = ImageIndexer(config: config)
        // First pass: full if the index is empty, else incremental.
        var firstPass = true
        while true {
            let store = try? IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
            let needFull = firstPass && (store?.messageCount ?? 0) == 0
            let r = try indexer.indexMessages(full: needFull, log: { _ in })
            if r.added > 0 || firstPass {
                stamp("indexed +\(r.added) (total \(r.total), watermark \(r.watermark))")
            }
            // Images run every cycle (offloaded files may have downloaded), before
            // embeddings so new media_text is available to the chunker.
            if alsoImages {
                let im = try await imager.run(full: false, log: { _ in })
                if im.ok > 0 { stamp("images +\(im.ok) ok (\(im.missing) offloaded, total ok \(im.okTotal))") }
            }
            if alsoEmbed && (r.added > 0 || firstPass) {
                let e = try await embedder.run(full: needFull, log: { _ in })
                if e.chunksAdded > 0 { stamp("embedded +\(e.chunksAdded) chunks (total \(e.totalChunks))") }
            }
            if alsoPreviews && (r.added > 0 || firstPass) {
                let p = try await previewer.run(full: false, log: { _ in })
                if p.fetched > 0 { stamp("previews +\(p.fetched) fetched (total \(p.total))") }
            }
            firstPass = false
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    // One-shot: full if requested or if index is empty.
    let store = try? IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
    let full = flag("--full") || (store?.messageCount ?? 0) == 0
    let r = try indexer.indexMessages(full: full, log: stamp)
    stamp("done: +\(r.added) messages (total \(r.total), watermark \(r.watermark))")
} catch {
    FileHandle.standardError.write(Data("indexer error: \(error)\n".utf8))
    exit(1)
}
