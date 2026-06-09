import Foundation
import IndexerCore

/// Fan-out hub for live updates. Each connected SSE client gets an AsyncStream of
/// pre-formatted SSE frames; `broadcast` pushes a frame to all of them. Dropped
/// clients are pruned automatically via the stream's termination handler.
actor UpdateBroadcaster {
    private var clients: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Register a client. Returns its id and a stream of SSE frames to write out.
    func subscribe() -> (id: UUID, stream: AsyncStream<String>) {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(32))
        clients[id] = cont
        cont.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        return (id, stream)
    }

    func remove(_ id: UUID) { clients[id] = nil }

    /// Push a raw SSE frame (already terminated with a blank line) to all clients.
    func broadcast(_ frame: String) {
        for c in clients.values { c.yield(frame) }
    }

    var clientCount: Int { clients.count }
}

/// The event the UI consumes: latest stats (incl. newest message id) on any change.
struct UpdateEvent: Encodable {
    let type = "update"
    let stats: StatsResponse
}

/// Encode an UpdateEvent as an SSE `data:` frame.
func sseFrame(_ event: UpdateEvent) -> String {
    guard let data = try? JSONEncoder().encode(event),
          let json = String(data: data, encoding: .utf8) else { return ": noop\n\n" }
    return "data: \(json)\n\n"
}
