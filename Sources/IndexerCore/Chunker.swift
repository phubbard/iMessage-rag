import Foundation

/// A conversational window over consecutive messages — the unit we embed and
/// retrieve for RAG. See PLAN §8.
public struct Chunk: Sendable {
    public let startID: Int64
    public let endID: Int64
    public let tsStart: Double
    public let tsEnd: Double
    public let text: String     // rendered "Name (YYYY-MM-DD HH:MM): body" lines
}

/// Groups messages into time-bounded windows. A new chunk starts when the gap to
/// the previous message exceeds `gapSeconds`, or the window hits `maxMessages`.
/// Consecutive chunks share `overlap` trailing messages for retrieval continuity.
public struct Chunker: Sendable {
    public var maxMessages: Int
    public var gapSeconds: Double
    public var overlap: Int

    public init(maxMessages: Int = 30, gapSeconds: Double = 1800, overlap: Int = 3) {
        self.maxMessages = maxMessages
        self.gapSeconds = gapSeconds
        self.overlap = overlap
    }

    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func render(_ m: IndexedMessage) -> String {
        let who = m.senderName ?? (m.isFromMe ? "Me" : m.sender)
        let when = Self.lineFormatter.string(from: Date(timeIntervalSince1970: m.tsUnix))
        // Combine message text with any image tags/OCR so photos are embeddable.
        let content = [m.body, m.mediaText].compactMap { $0?.nonEmpty }.joined(separator: " ")
        return "\(who) (\(when)): \(content)"
    }

    /// `messages` must be sorted by id ascending. Only text-bearing messages
    /// should be passed (media/empty rows excluded by the caller).
    public func chunk(_ messages: [IndexedMessage]) -> [Chunk] {
        guard !messages.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var window: [IndexedMessage] = []

        func flush() {
            guard !window.isEmpty else { return }
            let text = window.map(render).joined(separator: "\n")
            chunks.append(Chunk(
                startID: window.first!.id, endID: window.last!.id,
                tsStart: window.first!.tsUnix, tsEnd: window.last!.tsUnix,
                text: text))
        }

        for m in messages {
            if let last = window.last {
                let gap = m.tsUnix - last.tsUnix
                if gap > gapSeconds || window.count >= maxMessages {
                    flush()
                    // Carry overlap from the tail of the previous window.
                    window = overlap > 0 ? Array(window.suffix(overlap)) : []
                    // A large time gap means a fresh conversation — don't carry overlap across it.
                    if gap > gapSeconds { window = [] }
                }
            }
            window.append(m)
        }
        flush()
        return chunks
    }
}
