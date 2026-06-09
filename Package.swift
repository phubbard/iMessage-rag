// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "imessage-rag",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0")
    ],
    targets: [
        // C target: sqlite-vec compiled statically (SQLITE_CORE) + a small shim that
        // registers it on a live connection. See vendor/sqlite-vec.
        .target(
            name: "CSQLiteVec",
            cSettings: [
                .define("SQLITE_CORE")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Core library: chat.db read, decode, normalize, FTS, chunk, embed, index store.
        .target(
            name: "IndexerCore",
            dependencies: ["CSQLiteVec"]
        ),
        // Indexer executable: one-shot + watch modes.
        .executableTarget(
            name: "indexer",
            dependencies: ["IndexerCore"]
        ),
        // Web server executable: Hummingbird app (search + RAG).
        .executableTarget(
            name: "server",
            dependencies: [
                "IndexerCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types")
            ],
            resources: [
                .copy("Public")
            ]
        ),
        .testTarget(
            name: "IndexerCoreTests",
            dependencies: ["IndexerCore"]
        )
    ]
)
