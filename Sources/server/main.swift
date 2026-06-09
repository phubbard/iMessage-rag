import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import Logging
import IndexerCore

// server — LAN web app: full-text search (Phase 2) + RAG (Phase 3) over the
// family chat. Reads index.db; talks to LM Studio for embeddings/generation.
//
//   server [--config <path>]

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let config: Config
do { config = try Config.resolveAndLoad(arg("--config")) }
catch { FileHandle.standardError.write(Data("config error: \(error)\n".utf8)); exit(1) }

let search: SearchService
do { search = try SearchService(config: config) }
catch {
    FileHandle.standardError.write(Data("cannot open index.db at \(config.indexDBPath): \(error)\n".utf8))
    FileHandle.standardError.write(Data("run the indexer first: indexer --full\n".utf8))
    exit(1)
}
let ask = AskService(config: config, search: search)

// --- helpers ---------------------------------------------------------------

let jsonEncoder = JSONEncoder()

func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
    do {
        let data = try jsonEncoder.encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    } catch {
        return Response(status: .internalServerError)
    }
}

extension Request {
    func query(_ key: String) -> String? {
        guard let v = uri.queryParameters[key[...]] else { return nil }
        return v.removingPercentEncoding ?? String(v)
    }
    func queryDouble(_ key: String) -> Double? { query(key).flatMap(Double.init) }
    func queryInt(_ key: String) -> Int? { query(key).flatMap { Int($0) } }
}

// --- routes ----------------------------------------------------------------

let router = Router()
router.add(middleware: LogRequestsMiddleware(.info))
router.add(middleware: BasicAuthMiddleware(user: config.authUser, password: config.authPassword))

// GET /api/search?q=&from=&to=&sender=&limit=
router.get("/api/search") { request, _ -> Response in
    guard let q = request.query("q"), !q.isEmpty else {
        return json(SearchResponse(query: "", count: 0, hits: []))
    }
    let limit = min(max(request.queryInt("limit") ?? 50, 1), 200)
    let result = try await search.search(
        query: q,
        from: request.queryDouble("from"),
        to: request.queryDouble("to"),
        sender: request.query("sender"),
        limit: limit)
    return json(result)
}

// GET /api/senders
router.get("/api/senders") { _, _ -> Response in
    json(try await search.senders())
}

// GET /api/context/:id?window=
router.get("/api/context/:id") { request, context -> Response in
    guard let idStr = context.parameters.get("id"), let id = Int64(idStr) else {
        throw HTTPError(.badRequest, message: "invalid id")
    }
    let window = min(max(request.queryInt("window") ?? 12, 1), 100)
    let result = try await search.context(id: id, window: window)
    return json(result)
}

// POST /api/ask  → SSE stream (Phase 3)
router.post("/api/ask") { request, context -> Response in
    try await ask.handle(request: request, context: context)
}

// GET /api/image/:id?thumb=1  → JPEG thumbnail of an attachment (if on disk)
let attachmentsRoot = NSString(string: "~/Library/Messages/Attachments").expandingTildeInPath
router.get("/api/image/:id") { request, context -> Response in
    guard let idStr = context.parameters.get("id"), let id = Int64(idStr) else {
        throw HTTPError(.badRequest, message: "invalid id")
    }
    guard let info = try await search.imagePath(attachmentID: id), info.status == "ok" else {
        throw HTTPError(.notFound)  // offloaded / unknown
    }
    // Path-traversal guard: only serve files under the Messages Attachments dir.
    let resolved = (info.path as NSString).standardizingPath
    guard resolved.hasPrefix(attachmentsRoot) else { throw HTTPError(.forbidden) }
    let maxPixel = (request.query("thumb") != nil) ? 400 : 1600
    guard let data = ImageThumbnailer.jpeg(path: resolved, maxPixel: maxPixel) else {
        throw HTTPError(.notFound)
    }
    return Response(
        status: .ok,
        headers: [.contentType: "image/jpeg", .cacheControl: "private, max-age=86400"],
        body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

// GET /api/health
router.get("/api/health") { _, _ -> Response in
    json(["status": "ok"])
}

// Static UI (index.html etc.) from the bundled Public/ folder. no-cache so the
// browser always revalidates — avoids stale CSS/JS after a redeploy.
let publicDir = Bundle.module.resourcePath.map { $0 + "/Public" } ?? "Public"
let noCache = CacheControl([
    (MediaType(type: .text), [.noCache]),
    (MediaType(type: .application), [.noCache])
])
router.add(middleware: FileMiddleware(publicDir, cacheControl: noCache, searchForIndexHtml: true))

// --- run -------------------------------------------------------------------

let app = Application(
    router: router,
    configuration: .init(
        address: .hostname(config.bindHost, port: config.bindPort),
        serverName: "imessage-rag"))

print("imessage-rag server on http://\(config.bindHost):\(config.bindPort)  (chat \(config.targetChatID))")
print("serving UI from \(publicDir)")
try await app.runService()
