import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fetched preview of a URL shared in the chat (OpenGraph / <title> metadata).
public struct LinkPreview: Sendable, Codable {
    public let url: String
    public let status: String          // "ok" | "error"
    public let title: String?
    public let description: String?
    public let imageURL: String?
    public let siteName: String?
    public let fetchedAt: Double

    public init(url: String, status: String, title: String?, description: String?,
                imageURL: String?, siteName: String?, fetchedAt: Double) {
        self.url = url; self.status = status; self.title = title
        self.description = description; self.imageURL = imageURL
        self.siteName = siteName; self.fetchedAt = fetchedAt
    }
}

/// Extracts http(s) URLs from message text.
public enum URLExtractor {
    // URLs run until whitespace or a quote/bracket; trailing punctuation is trimmed.
    private static let regex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'\)\]]+"#, options: [])
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)»\"'”’]}")

    public static func extract(_ text: String) -> [String] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            var url = ns.substring(with: m.range)
            while let last = url.unicodeScalars.last, trailing.contains(last) { url.removeLast() }
            if url.count > 7, seen.insert(url).inserted { out.append(url) }
        }
        return out
    }
}

/// Fetches a URL and parses OpenGraph / HTML metadata into a `LinkPreview`.
/// Best-effort and defensive: short timeout, size cap, HTML-only, never throws
/// (failures are recorded as status "error" so we don't refetch endlessly).
public struct LinkPreviewFetcher: Sendable {
    let session: URLSession
    let maxBytes: Int

    public init(timeout: TimeInterval = 12, maxBytes: Int = 1_500_000) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpAdditionalHeaders = [
            // Many sites gate OG tags behind a browser-ish UA.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) imessage-rag-linkbot",
            "Accept": "text/html,application/xhtml+xml"
        ]
        self.session = URLSession(configuration: cfg)
        self.maxBytes = maxBytes
    }

    public func fetch(_ url: String, now: Double) async -> LinkPreview {
        func failure() -> LinkPreview {
            LinkPreview(url: url, status: "error", title: nil, description: nil,
                        imageURL: nil, siteName: nil, fetchedAt: now)
        }
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return failure() }

        do {
            var req = URLRequest(url: u)
            req.httpMethod = "GET"
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return failure()
            }
            // HTML only; skip images/pdfs/etc.
            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard ctype.isEmpty || ctype.contains("html") || ctype.contains("xml") else { return failure() }

            let slice = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
            let html = String(decoding: slice, as: UTF8.self)
            let meta = HTMLMeta.parse(html)
            let title = meta["og:title"] ?? meta["twitter:title"] ?? meta["__title__"]
            let desc = meta["og:description"] ?? meta["description"] ?? meta["twitter:description"]
            var image = meta["og:image"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]
            if let img = image { image = absoluteURL(img, base: u) }
            let site = meta["og:site_name"] ?? u.host

            // If we got nothing useful, still record ok so we don't refetch forever.
            return LinkPreview(url: url, status: "ok",
                               title: title?.trimmed.nonEmpty,
                               description: desc?.trimmed.nonEmpty,
                               imageURL: image?.trimmed.nonEmpty,
                               siteName: site?.trimmed.nonEmpty,
                               fetchedAt: now)
        } catch {
            return failure()
        }
    }

    private func absoluteURL(_ s: String, base: URL) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        return URL(string: s, relativeTo: base)?.absoluteString ?? s
    }
}

/// Fetches a preview via Firecrawl (firecrawl.dev) — a hosted scraper that
/// renders JS and gets past bot protection that 403s our direct fetcher (NYT,
/// AllTrails, etc.). Sends the URL to a third party; opt-in via an API key.
public struct FirecrawlClient: Sendable {
    public let baseURL: String
    let apiKey: String?
    let session: URLSession

    /// `baseURL` is the Firecrawl host (self-hosted on the LAN or
    /// https://api.firecrawl.dev). `apiKey` is optional (self-hosted needs none).
    public init(baseURL: String = "https://api.firecrawl.dev", apiKey: String? = nil, timeout: TimeInterval = 45) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: cfg)
    }

    public func fetch(_ url: String, now: Double) async -> LinkPreview? {
        // One retry — the self-hosted instance occasionally drops a connection.
        for attempt in 0..<2 {
            if let result = await attemptFetch(url, now: now) { return result }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        return nil
    }

    private func attemptFetch(_ url: String, now: Double) async -> LinkPreview? {
        guard let endpoint = URL(string: baseURL + "/v1/scrape") else { return nil }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        if let apiKey { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["url": url, "formats": ["markdown"], "onlyMainContent": true]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let meta = payload["metadata"] as? [String: Any]
        else { return nil }

        func str(_ keys: [String]) -> String? {
            for k in keys {
                if let s = meta[k] as? String, !s.trimmed.isEmpty { return s.trimmed }
                if let arr = meta[k] as? [String], let s = arr.first, !s.trimmed.isEmpty { return s.trimmed }
            }
            return nil
        }
        let title = str(["title", "ogTitle"])
        let desc = str(["description", "ogDescription"])
        let image = str(["ogImage", "image", "twitterImage"])
        let site = str(["ogSiteName"]) ?? URL(string: url)?.host

        // Distinguish a real preview from a bot-block page. When the origin
        // returned a 4xx/5xx AND we got no image and no description, this is a
        // block page (e.g. the self-hosted instance's 403 with title == bare
        // domain) — return nil so the caller falls through to the next tier.
        // Commercial Firecrawl often returns rich title+image while still
        // reporting the origin's 403, so we KEEP results that have an image or
        // a description regardless of statusCode.
        let statusCode = (meta["statusCode"] as? Int) ?? (meta["statusCode"] as? NSNumber)?.intValue
        if let code = statusCode, code >= 400, image == nil, desc == nil { return nil }

        guard title != nil || desc != nil else { return nil }
        return LinkPreview(url: url, status: "ok", title: title, description: desc,
                           imageURL: image, siteName: site, fetchedAt: now)
    }
}

/// Minimal HTML <meta>/<title> scraper. Returns a dict keyed by og/twitter
/// property or meta name; `__title__` holds the <title> text.
enum HTMLMeta {
    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive])
    private static let attr = try! NSRegularExpression(
        pattern: "(property|name|content)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive])
    private static let titleTag = try! NSRegularExpression(
        pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: [.caseInsensitive])

    static func parse(_ html: String) -> [String: String] {
        // Only scan the head-ish prefix; OG tags live near the top.
        let head = String(html.prefix(200_000))
        let ns = head as NSString
        var out: [String: String] = [:]

        for tm in metaTag.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: tm.range)
            let tns = tag as NSString
            var key: String? = nil
            var content: String? = nil
            for am in attr.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                let name = tns.substring(with: am.range(at: 1)).lowercased()
                let val = valueOf(am, in: tns)
                switch name {
                case "property", "name": key = val.lowercased()
                case "content": content = val
                default: break
                }
            }
            if let key, let content, out[key] == nil { out[key] = decodeEntities(content) }
        }

        if let t = titleTag.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) {
            out["__title__"] = decodeEntities(ns.substring(with: t.range(at: 1))).trimmed
        }
        return out
    }

    private static func valueOf(_ m: NSTextCheckingResult, in ns: NSString) -> String {
        for i in [3, 4] where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return ""
    }

    /// Decode the handful of HTML entities that show up in titles/descriptions.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities &#NNNN;
        if r.contains("&#") {
            let numeric = try! NSRegularExpression(pattern: "&#(\\d+);")
            let ns = r as NSString
            var result = ""
            var last = 0
            for m in numeric.matches(in: r, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                if let code = Int(ns.substring(with: m.range(at: 1))), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            r = result
        }
        return r
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}
