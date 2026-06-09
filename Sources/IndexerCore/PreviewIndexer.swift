import Foundation

/// Scans indexed messages for URLs and fetches a preview (OpenGraph/title) for
/// each distinct one, caching results in `link_previews`. Incremental by default
/// (skips URLs already fetched); `--full` refetches everything. Throttled and
/// concurrency-limited so it stays polite and doesn't hammer the network.
public final class PreviewIndexer {
    public let config: Config

    public init(config: Config) { self.config = config }

    public struct Result: Sendable {
        public let fetched: Int
        public let ok: Int
        public let total: Int64
    }

    public func run(
        full: Bool,
        concurrency: Int = 6,
        throttleMs: Int = 100,
        log: ((String) -> Void)? = nil
    ) async throws -> Result {
        let store = try IndexStore(path: config.indexDBPath, embedDim: config.embedDim)
        let fetcher = LinkPreviewFetcher()

        // Firecrawl tiers tried in order: self-hosted (LAN, free) then commercial.
        let firecrawlTiers: [FirecrawlClient] = {
            var t: [FirecrawlClient] = []
            if !config.firecrawlBaseURL.isEmpty {
                t.append(FirecrawlClient(baseURL: config.firecrawlBaseURL, apiKey: nil))
            }
            if let key = config.resolvedFirecrawlKey {
                t.append(FirecrawlClient(baseURL: "https://api.firecrawl.dev", apiKey: key))
            }
            return t
        }()
        let firecrawlEnabled = !firecrawlTiers.isEmpty

        let bodies = try store.bodiesWithLinks(chatID: config.targetChatID)
        var urls = Set<String>()
        for b in bodies { for u in URLExtractor.extract(b) { urls.insert(u) } }

        // Incremental: only new URLs (never re-hit failures — that would burn
        // Firecrawl credits every watch cycle). `--full` retries everything, so
        // it's the knob for re-attempting prior failures via Firecrawl.
        let already = full ? [] : try store.knownPreviewURLs()
        let todo = urls.subtracting(already).sorted()
        let tierNote = firecrawlEnabled ? " [Firecrawl: \(firecrawlTiers.count) tier(s)]" : ""
        log?("found \(urls.count) distinct URLs; \(todo.count) to fetch\(full ? " (full refetch)" : "")\(tierNote)")

        guard !todo.isEmpty else {
            return Result(fetched: 0, ok: 0, total: store.previewCount)
        }

        func hasMeta(_ p: LinkPreview) -> Bool { p.status == "ok" && (p.title != nil || p.description != nil) }

        // No-downgrade guard: never overwrite an already-good preview with a worse
        // result (e.g. a transient failure during a --full refetch).
        let alreadyGood = try store.successfulPreviewURLs()

        var okCount = 0, done = 0, firecrawlUsed = 0
        for wave in stride(from: 0, to: todo.count, by: concurrency) {
            let batch = Array(todo[wave..<min(wave + concurrency, todo.count)])
            let now = Date().timeIntervalSince1970
            let results = await withTaskGroup(of: (LinkPreview, Bool).self) { group -> [(LinkPreview, Bool)] in
                for url in batch {
                    group.addTask {
                        // Direct fetch first (free); then each Firecrawl tier in order
                        // (LAN, then commercial) until one returns usable metadata.
                        let direct = await fetcher.fetch(url, now: now)
                        if hasMeta(direct) { return (direct, false) }
                        for tier in firecrawlTiers {
                            if let viaFC = await tier.fetch(url, now: now) { return (viaFC, true) }
                        }
                        return (direct, false)
                    }
                }
                var collected: [(LinkPreview, Bool)] = []
                for await r in group { collected.append(r) }
                return collected
            }
            // Skip writes that would downgrade an existing good preview to a worse one.
            let toWrite = results.map { $0.0 }.filter { hasMeta($0) || !alreadyGood.contains($0.url) }
            try store.upsertPreviews(toWrite)
            okCount += results.filter { hasMeta($0.0) }.count
            firecrawlUsed += results.filter { $0.1 }.count
            done += batch.count
            log?("  \(done)/\(todo.count) fetched (\(okCount) with metadata, \(firecrawlUsed) via Firecrawl)")
            if throttleMs > 0 { try await Task.sleep(nanoseconds: UInt64(throttleMs) * 1_000_000) }
        }

        return Result(fetched: done, ok: okCount, total: store.previewCount)
    }
}
