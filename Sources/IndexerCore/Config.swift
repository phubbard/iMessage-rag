import Foundation

/// App configuration, loaded from config.json. All fields have sensible defaults
/// matching the verified Phase 0 facts so a minimal config still works.
public struct Config: Codable, Sendable {
    // Data
    public var targetChatID: Int
    public var chatDBPath: String
    public var indexDBPath: String

    // LM Studio (OpenAI-compatible)
    public var lmStudioBaseURL: String
    public var embedModel: String
    public var embedDim: Int
    public var genModel: String

    // Server
    public var bindHost: String
    public var bindPort: Int
    public var authUser: String
    public var authPassword: String

    // Optional friendly sender names: handle.id -> display name
    public var handles: [String: String]

    // Firecrawl — optional link-preview scraping for sites that block our direct
    // fetcher (nytimes, alltrails). Order of attempts: direct HTTP → self-hosted
    // Firecrawl (firecrawlBaseURL, on the LAN, no credits) → commercial
    // (api.firecrawl.dev with firecrawlAPIKey). The commercial key is a secret —
    // set it via config.local.json (gitignored) or the FIRECRAWL_API_KEY env var.
    public var firecrawlBaseURL: String   // e.g. http://web.phfactor.net:3002 ("" = skip self-hosted)
    public var firecrawlAPIKey: String

    /// Effective key: explicit config value, else FIRECRAWL_API_KEY env var.
    public var resolvedFirecrawlKey: String? {
        if !firecrawlAPIKey.isEmpty { return firecrawlAPIKey }
        if let env = ProcessInfo.processInfo.environment["FIRECRAWL_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    public init(
        targetChatID: Int = 5,
        chatDBPath: String = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath,
        indexDBPath: String = NSString(string: "~/.imessage-rag/index.db").expandingTildeInPath,
        lmStudioBaseURL: String = "http://localhost:1234/v1",
        embedModel: String = "text-embedding-bge-m3",
        embedDim: Int = 1024,
        genModel: String = "openai/gpt-oss-120b",
        bindHost: String = "127.0.0.1",
        bindPort: Int = 8765,
        authUser: String = "family",
        authPassword: String = "changeme",
        handles: [String: String] = [:],
        firecrawlBaseURL: String = "",
        firecrawlAPIKey: String = ""
    ) {
        self.firecrawlBaseURL = firecrawlBaseURL
        self.firecrawlAPIKey = firecrawlAPIKey
        self.targetChatID = targetChatID
        self.chatDBPath = chatDBPath
        self.indexDBPath = indexDBPath
        self.lmStudioBaseURL = lmStudioBaseURL
        self.embedModel = embedModel
        self.embedDim = embedDim
        self.genModel = genModel
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.authUser = authUser
        self.authPassword = authPassword
        self.handles = handles
    }

    // Decode with defaults for any missing key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        targetChatID    = try c.decodeIfPresent(Int.self, forKey: .targetChatID) ?? d.targetChatID
        chatDBPath      = (try c.decodeIfPresent(String.self, forKey: .chatDBPath) ?? d.chatDBPath).expandedPath
        indexDBPath     = (try c.decodeIfPresent(String.self, forKey: .indexDBPath) ?? d.indexDBPath).expandedPath
        lmStudioBaseURL = try c.decodeIfPresent(String.self, forKey: .lmStudioBaseURL) ?? d.lmStudioBaseURL
        embedModel      = try c.decodeIfPresent(String.self, forKey: .embedModel) ?? d.embedModel
        embedDim        = try c.decodeIfPresent(Int.self, forKey: .embedDim) ?? d.embedDim
        genModel        = try c.decodeIfPresent(String.self, forKey: .genModel) ?? d.genModel
        bindHost        = try c.decodeIfPresent(String.self, forKey: .bindHost) ?? d.bindHost
        bindPort        = try c.decodeIfPresent(Int.self, forKey: .bindPort) ?? d.bindPort
        authUser        = try c.decodeIfPresent(String.self, forKey: .authUser) ?? d.authUser
        authPassword    = try c.decodeIfPresent(String.self, forKey: .authPassword) ?? d.authPassword
        handles         = try c.decodeIfPresent([String: String].self, forKey: .handles) ?? d.handles
        firecrawlBaseURL = try c.decodeIfPresent(String.self, forKey: .firecrawlBaseURL) ?? d.firecrawlBaseURL
        firecrawlAPIKey = try c.decodeIfPresent(String.self, forKey: .firecrawlAPIKey) ?? d.firecrawlAPIKey
    }

    /// Load `config.json`, then overlay `config.local.json` (gitignored) from the
    /// same directory if present — keeps secrets like the Firecrawl key out of git.
    public static func load(path: String) throws -> Config {
        let mainURL = URL(fileURLWithPath: path.expandedPath)
        var merged: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: mainURL.path),
           let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: mainURL)) as? [String: Any] {
            merged = obj
        }
        let localURL = mainURL.deletingLastPathComponent().appendingPathComponent("config.local.json")
        if FileManager.default.fileExists(atPath: localURL.path),
           let localData = try? Data(contentsOf: localURL),
           let obj = (try? JSONSerialization.jsonObject(with: localData)) as? [String: Any] {
            for (k, v) in obj { merged[k] = v }   // local overrides (malformed file ignored)
        }
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Resolve config path: explicit arg > ./config.json.
    public static func resolveAndLoad(_ explicit: String?) throws -> Config {
        let path = explicit ?? "config.json"
        return try load(path: path)
    }
}

extension String {
    var expandedPath: String { NSString(string: self).expandingTildeInPath }
}
