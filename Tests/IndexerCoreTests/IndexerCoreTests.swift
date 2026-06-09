import Foundation
import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import IndexerCore

final class IndexerCoreTests: XCTestCase {

    func testSqliteVecLoads() throws {
        // In-memory DB with sqlite-vec registered via the C shim.
        let db = try Database(path: ":memory:", enableVec: true)
        let version = try db.scalarText("SELECT vec_version()")
        XCTAssertNotNil(version)

        try db.exec("CREATE VIRTUAL TABLE v USING vec0(emb FLOAT[4])")
        try db.exec("INSERT INTO v(rowid, emb) VALUES (1,'[1,2,3,4]'),(2,'[9,9,9,9]')")
        let nearest = try db.scalarInt(
            "SELECT rowid FROM v WHERE emb MATCH '[1,2,3,4]' ORDER BY distance LIMIT 1")
        XCTAssertEqual(nearest, 1)
    }

    func testAppleDateConversion() {
        let unix = 1_625_416_200.0
        let apple = AppleDate.unixToAppleNanos(unix)
        let back = AppleDate.toUnix(apple)
        XCTAssertEqual(back, unix, accuracy: 1.0)
        let secsRaw: Int64 = 600_000_000  // < 1e12 threshold → treated as seconds
        XCTAssertEqual(AppleDate.toUnix(secsRaw), Double(secsRaw) + AppleDate.epochOffset)
    }

    func testAttributedBodyRoundTrip() throws {
        let original = NSAttributedString(string: "Thanksgiving trip planning ✈️")
        let blob = NSArchiver.archivedData(withRootObject: original)
        let decoded = AttributedBodyDecoder.decode(blob)
        XCTAssertEqual(decoded, "Thanksgiving trip planning ✈️")
    }

    func testIndexStoreUpsertAndFTS() throws {
        let path = NSTemporaryDirectory() + "imsg-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try IndexStore(path: path, embedDim: 1024)

        let msgs = [
            IndexedMessage(id: 1, chatID: 5, tsUnix: 1_700_000_000, sender: "a@x.com", senderName: "Alice",
                           isFromMe: false, body: "Let's plan the Thanksgiving trip to Oregon", hasMedia: false, replyTo: nil),
            IndexedMessage(id: 2, chatID: 5, tsUnix: 1_700_000_100, sender: "me", senderName: "Me",
                           isFromMe: true, body: "Sounds good, booking flights", hasMedia: false, replyTo: 1),
            IndexedMessage(id: 3, chatID: 5, tsUnix: 1_700_000_200, sender: "a@x.com", senderName: "Alice",
                           isFromMe: false, body: nil, hasMedia: true, replyTo: nil) // media, no body
        ]
        try store.upsert(msgs)

        XCTAssertEqual(store.messageCount, 3)
        try store.setLastIndexedRowID(3)
        XCTAssertEqual(store.lastIndexedRowID, 3)

        // FTS finds the Thanksgiving message, not the media row.
        let hit = try store.db.scalarInt(
            "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'thanksgiving' ORDER BY bm25(messages_fts) LIMIT 1")
        XCTAssertEqual(hit, 1)

        // All rows are indexed (media row as an empty doc that matches nothing).
        let ftsCount = try store.db.scalarInt("SELECT COUNT(*) FROM messages_fts")
        XCTAssertEqual(ftsCount, 3)
        // The media row (id 3) does not match a content query.
        let flightHit = try store.db.scalarInt(
            "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'flights' LIMIT 1")
        XCTAssertEqual(flightHit, 2)

        // Re-upsert is idempotent (triggers keep FTS consistent, no duplicates).
        try store.upsert(msgs)
        let ftsCount2 = try store.db.scalarInt("SELECT COUNT(*) FROM messages_fts")
        XCTAssertEqual(ftsCount2, 3)
        XCTAssertEqual(store.messageCount, 3)
        // bm25 ranking still returns the thanksgiving row for that query.
        let hit2 = try store.db.scalarInt(
            "SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'thanksgiving' ORDER BY bm25(messages_fts) LIMIT 1")
        XCTAssertEqual(hit2, 1)
    }

    func testURLExtraction() {
        let body = "see https://example.com/a, and (https://nytimes.com/x) plus http://b.org. dup https://example.com/a"
        let urls = URLExtractor.extract(body)
        XCTAssertEqual(urls, ["https://example.com/a", "https://nytimes.com/x", "http://b.org"])
        XCTAssertTrue(URLExtractor.extract("no links here").isEmpty)
    }

    func testHTMLMetaParsing() {
        let html = """
        <html><head>
        <title>Fallback &amp; Title</title>
        <meta property="og:title" content="Morro Bay Sand Spit Trail">
        <meta name="description" content="A flat trail &#8212; great for kids">
        <meta property="og:image" content="https://cdn.example.com/img.jpg">
        <meta property="og:site_name" content="AllTrails">
        </head><body>...</body></html>
        """
        let m = HTMLMeta.parse(html)
        XCTAssertEqual(m["og:title"], "Morro Bay Sand Spit Trail")
        XCTAssertEqual(m["og:site_name"], "AllTrails")
        XCTAssertEqual(m["og:image"], "https://cdn.example.com/img.jpg")
        XCTAssertEqual(m["description"], "A flat trail — great for kids")  // numeric entity decoded
        XCTAssertEqual(m["__title__"], "Fallback & Title")                  // named entity decoded
    }

    func testImageMediaTextFTS() throws {
        let path = NSTemporaryDirectory() + "imsg-img-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try IndexStore(path: path, embedDim: 1024)

        // A media-only message (no body) gets searchable via image tags + OCR.
        try store.upsert([IndexedMessage(id: 10, chatID: 5, tsUnix: 1, sender: "a", senderName: nil,
                                         isFromMe: false, body: nil, hasMedia: true, replyTo: nil)])
        try store.upsertImageMeta([ImageRecord(
            attachmentID: 100, messageID: 10, path: "/x.heic", mime: "image/heic",
            status: "ok", tags: "dog, beach", ocr: "Welcome to Oregon", processedAt: 0)])
        try store.rebuildMediaText(messageID: 10)

        XCTAssertEqual(try store.db.scalarInt("SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'dog'"), 10)
        XCTAssertEqual(try store.db.scalarInt("SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'oregon'"), 10)
        XCTAssertEqual(store.imageOKCount, 1)

        // Offloaded image → recorded missing, not searchable, doesn't crash media_text.
        try store.upsert([IndexedMessage(id: 11, chatID: 5, tsUnix: 2, sender: "a", senderName: nil,
                                         isFromMe: false, body: nil, hasMedia: true, replyTo: nil)])
        try store.upsertImageMeta([ImageRecord(
            attachmentID: 101, messageID: 11, path: "/y.heic", mime: "image/heic",
            status: "missing", tags: nil, ocr: nil, processedAt: 0)])
        try store.rebuildMediaText(messageID: 11)
        XCTAssertEqual(store.imageMissingCount, 1)
        XCTAssertNil(try store.db.scalarText("SELECT media_text FROM messages WHERE id=11"))
    }

    func testVisionOCRRoundTrip() throws {
        // Render high-contrast text to a PNG, then OCR it back through VisionTagger.
        let size = CGSize(width: 700, height: 220)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw XCTSkip("no CGContext")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 72, nil),
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "HELLO OREGON", attributes: attrs))
        ctx.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { throw XCTSkip("no image") }

        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw XCTSkip("no dest") }
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let analysis = VisionTagger().analyze(url: url)
        XCTAssertNotNil(analysis)
        XCTAssertTrue(analysis!.ocr.uppercased().contains("OREGON"),
                      "OCR was: \(analysis?.ocr ?? "nil")")
    }

    func testConfigDefaultsAndOverrides() throws {
        let json = """
        { "targetChatID": 5, "authPassword": "s3cret" }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(cfg.targetChatID, 5)
        XCTAssertEqual(cfg.authPassword, "s3cret")
        XCTAssertEqual(cfg.embedDim, 1024)            // default preserved
        XCTAssertEqual(cfg.embedModel, "text-embedding-bge-m3")
    }
}
