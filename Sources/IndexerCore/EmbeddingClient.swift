import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Calls LM Studio's OpenAI-compatible /v1/embeddings endpoint. See PLAN §8.
public struct EmbeddingClient: Sendable {
    let baseURL: String
    let model: String
    let session: URLSession

    public init(baseURL: String, model: String, timeout: TimeInterval = 120) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: cfg)
    }

    struct Request: Encodable { let model: String; let input: [String] }
    struct Response: Decodable {
        struct Item: Decodable { let embedding: [Float]; let index: Int }
        let data: [Item]
    }

    /// Embed a batch of texts; returns vectors in the same order as `texts`.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var req = URLRequest(url: URL(string: baseURL + "/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(model: model, input: texts))

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EmbeddingError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Restore request order by index.
        let sorted = decoded.data.sorted { $0.index < $1.index }
        guard sorted.count == texts.count else {
            throw EmbeddingError.countMismatch(expected: texts.count, got: sorted.count)
        }
        return sorted.map { $0.embedding }
    }

    public enum EmbeddingError: Error, CustomStringConvertible {
        case http(Int, String)
        case countMismatch(expected: Int, got: Int)
        public var description: String {
            switch self {
            case .http(let code, let body): return "embeddings HTTP \(code): \(body.prefix(200))"
            case .countMismatch(let e, let g): return "embeddings returned \(g) vectors, expected \(e)"
            }
        }
    }
}

/// Serialize a vector to the JSON text form sqlite-vec accepts for vec0 columns.
public func vecJSON(_ v: [Float]) -> String {
    "[" + v.map { String($0) }.joined(separator: ",") + "]"
}
