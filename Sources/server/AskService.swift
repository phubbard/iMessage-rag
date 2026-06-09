import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import IndexerCore

/// RAG question-answering: retrieve top chunks (hybrid FTS+vector RRF) → prompt
/// gpt-oss-120b → stream tokens to the browser as SSE, then emit citations
/// that deep-link back into the thread. See PLAN §8.
struct AskService: Sendable {
    let config: Config
    let search: SearchService

    init(config: Config, search: SearchService) {
        self.config = config
        self.search = search
    }

    struct AskRequest: Decodable { let question: String; let from: Double?; let to: Double? }

    struct Citation: Encodable { let id: Int; let label: String; let centerID: Int64; let startID: Int64 }

    func handle(request: Request, context: some RequestContext) async throws -> Response {
        let buffer = try await request.body.collect(upTo: 64 * 1024)
        let req = try JSONDecoder().decode(AskRequest.self, from: Data(buffer: buffer))
        let question = req.question.trimmingCharacters(in: .whitespacesAndNewlines)

        let chunks = question.isEmpty ? [] :
            try await search.retrieveChunks(query: question, k: 8, from: req.from, to: req.to)

        let cfg = config
        let body = ResponseBody { writer in
            func emit(_ json: String) async throws {
                try await writer.write(ByteBuffer(string: "data: \(json)\n\n"))
            }
            func emitToken(_ text: String) async throws {
                try await emit(#"{"type":"token","text":\#(jsonString(text))}"#)
            }

            do {
                guard !question.isEmpty else {
                    try await emitToken("Please ask a question.")
                    try await emit(#"{"type":"done"}"#); return
                }
                guard !chunks.isEmpty else {
                    try await emitToken("I couldn't find anything relevant in the chat history.")
                    try await emit(#"{"type":"done"}"#); return
                }

                let (system, user) = Self.buildPrompt(question: question, chunks: chunks)
                try await Self.streamChat(cfg: cfg, system: system, user: user, emitToken: emitToken)

                // Citations after the answer.
                let cites = chunks.enumerated().map { (i, c) in
                    Citation(id: i + 1, label: Self.label(c), centerID: c.startID, startID: c.startID)
                }
                let data = try JSONEncoder().encode(cites)
                try await emit(#"{"type":"citations","items":\#(String(data: data, encoding: .utf8) ?? "[]")}"#)
                try await emit(#"{"type":"done"}"#)
            } catch {
                try? await emit(#"{"type":"error","message":\#(jsonString(String(describing: error)))}"#)
            }
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream; charset=utf-8",
                .cacheControl: "no-cache",
                .init("X-Accel-Buffering")!: "no"
            ],
            body: body)
    }

    // MARK: - Prompt

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func label(_ c: RetrievedChunk) -> String {
        let lo = dateFmt.string(from: Date(timeIntervalSince1970: c.tsStart))
        let hi = dateFmt.string(from: Date(timeIntervalSince1970: c.tsEnd))
        let preview = c.text.replacingOccurrences(of: "\n", with: " ").prefix(80)
        return lo == hi ? "\(lo): \(preview)" : "\(lo)…\(hi): \(preview)"
    }

    static func buildPrompt(question: String, chunks: [RetrievedChunk]) -> (system: String, user: String) {
        let system = """
        You answer questions about a family's private group chat using ONLY the \
        excerpts provided. Each excerpt is numbered. Cite the excerpts you rely on \
        inline using square brackets like [1] or [2]. If the excerpts do not contain \
        the answer, say you couldn't find it. Be concise and specific; refer to people \
        by the names shown in the excerpts.
        """
        var ctx = ""
        for (i, c) in chunks.enumerated() {
            ctx += "[\(i + 1)] (\(label(c)))\n\(c.text)\n\n"
        }
        let user = "Excerpts:\n\n\(ctx)Question: \(question)"
        return (system, user)
    }

    // MARK: - Streaming chat completion from LM Studio

    struct ChatReq: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Msg]
        let stream: Bool
        let temperature: Double
    }

    static func streamChat(cfg: Config, system: String, user: String,
                           emitToken: (String) async throws -> Void) async throws {
        let base = cfg.lmStudioBaseURL.hasSuffix("/") ? String(cfg.lmStudioBaseURL.dropLast()) : cfg.lmStudioBaseURL
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let payload = ChatReq(
            model: cfg.genModel,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            stream: true, temperature: 0.3)
        req.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AskError.upstream((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any]
            else { continue }
            // Stream the answer content only; ignore gpt-oss reasoning channel.
            if let content = delta["content"] as? String, !content.isEmpty {
                try await emitToken(content)
            }
        }
    }

    enum AskError: Error, CustomStringConvertible {
        case upstream(Int)
        var description: String { switch self { case .upstream(let c): return "LM Studio chat HTTP \(c)" } }
    }
}

/// Minimal JSON string encoder for embedding text safely in our SSE payloads.
func jsonString(_ s: String) -> String {
    let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
    return String(data: data, encoding: .utf8) ?? "\"\""
}
