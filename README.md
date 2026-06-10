# iMessage Family Search

A LAN web app that gives a family far better search — full-text **and** semantic
(RAG) — over their long-running iMessage group chat than the native Messages app.

- **Search (v1):** fast, ranked, snippet-highlighted full-text search over the
  whole history, filterable by sender and date, with expand-to-context.
- **Ask (v2):** natural-language questions answered from the actual messages, with
  streamed responses and citations that deep-link back into the thread.

Everything runs on one always-on Mac (`axiom`) and keeps all family data on the
user's own hardware. See [PLAN.md](PLAN.md) for the full design.

## Architecture

```
chat.db (Messages in iCloud)
   │  snapshot + decode (NSUnarchiver)
   ▼
indexer ──► index.db  (messages + FTS5 + sqlite-vec chunks)
   │                         ▲ read-only
   │  embeddings (LM Studio) │
   ▼                         │
server (Hummingbird) ────────┘──► family browsers on the LAN
   └──► LM Studio @ localhost (gpt-oss-120b + bge-m3 embeddings)
```

The only macOS-locked component is the indexer (it uses Apple's `NSUnarchiver`
to decode `attributedBody`). The server + UI touch only SQLite text.

## Prerequisites

- macOS (built/verified on macOS 26). Build uses the **Xcode** toolchain because
  CommandLineTools lacks XCTest:
  ```
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  ```
- **LM Studio** running with an OpenAI-compatible server (default `http://localhost:1234/v1`),
  loaded with a generation model (`openai/gpt-oss-120b`) and an embedding model
  (`text-embedding-bge-m3`, 1024-dim).
- **Full Disk Access** for whatever runs the indexer (Terminal during dev; the
  indexer binary in production) — required to read `~/Library/Messages/chat.db`.
  System Settings → Privacy & Security → Full Disk Access.

## Configure

Edit [config.json](config.json). Verified defaults are already filled in:

| key | meaning |
|-----|---------|
| `targetChatID` | chat.db ROWID of the group chat (find it with `indexer --chats`) |
| `chatDBPath` | source Messages DB (default `~/Library/Messages/chat.db`) |
| `indexDBPath` | our index (default `~/.imessage-rag/index.db`) |
| `lmStudioBaseURL` | LM Studio OpenAI endpoint |
| `embedModel` / `embedDim` | embedding model + dimension (must match the model) |
| `genModel` | generation model |
| `bindHost` / `bindPort` | server bind address (use `0.0.0.0` for LAN) |
| `authUser` / `authPassword` | HTTP Basic credentials — **change the password** |

> ⚠️ `index.db`'s `vec_chunks` dimension is fixed at creation. If you change the
> embedding model/dimension, re-run `indexer --embed --full` to rebuild vectors.

## Build

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release          # builds indexer + server
swift test                      # runs the IndexerCore unit tests
```

## Run

```
# 1. Find / confirm the target chat id
.build/release/indexer --chats

# 2. Build the full-text index (fast — seconds)
.build/release/indexer --full

# 3. Build embeddings for RAG (one-time spike; throttled)
.build/release/indexer --embed --full

# 4. Fetch link previews for shared URLs (OpenGraph/title)
.build/release/indexer --previews

# 5. Tag + OCR image attachments with Apple Vision
.build/release/indexer --images
#   (then re-embed so image tags/OCR enter RAG)
.build/release/indexer --embed --full

# 6. Start the web server
.build/release/server
#   → open http://<axiom-ip>:8765  (Basic auth)
```

Incremental updates (new messages → search, embeddings, previews, image tags/OCR):

```
.build/release/indexer            # incremental message index
.build/release/indexer --embed    # incremental embeddings
.build/release/indexer --previews # new URL previews
.build/release/indexer --images   # new/now-downloaded images (Vision tags + OCR)
# all-in-one watch loop (event-driven + backstop poll, does everything):
.build/release/indexer --watch 300 --embed --previews --images
```

### Live updates

`--watch` is **event-driven**: a `DispatchSource` watches `chat.db-wal` and runs an
incremental pass within seconds of a new message (debounced; the numeric interval
is a safety-net backstop, not the primary trigger). Each pass runs the full
pipeline (messages → images → embeddings → previews) and stamps `last_indexed_at`.

The **server** is decoupled: a background task polls its own `index.db` every ~10s
and, on any change, pushes a Server-Sent Event to connected browsers
(`GET /api/events`, with a 25s heartbeat). The web UI opens an `EventSource` and:
- updates the footer stats live,
- shows a "↻ New messages" pill in Search (click to refresh results),
- live-appends to the Browse thread (or shows a "↓ New messages" pill if you've
  scrolled up).

No WebSocket and no IPC between processes — the indexer only touches `chat.db`, the
server only reads `index.db`.

### Config hot-reload

The server watches `config.json` and `config.local.json` (FileWatcher / DispatchSource)
and reloads on change — no restart needed. Hot-applied immediately: **auth credentials**
and the LM Studio / model settings used by `/api/ask`. On reload the server also pushes a
`{"type":"config"}` SSE event so open browsers refresh. Settings bound at startup still need
a restart: `bindHost`/`bindPort`, `targetChatID`, and the db paths.

### Link previews & Firecrawl

`--previews` fetches OpenGraph/title metadata for shared URLs. Each URL is tried
through a fallback chain, stopping at the first usable result:

1. **Direct HTTP** (free, fast) — works for most sites.
2. **Self-hosted Firecrawl** on the LAN (`firecrawlBaseURL`) — renders JS, no
   credits, keeps traffic local. Set in `config.json`:
   ```json
   { "firecrawlBaseURL": "http://web.phfactor.net:3002" }
   ```
3. **Commercial Firecrawl** (api.firecrawl.dev) — has anti-bot proxies that get
   past sites the self-hosted instance can't (e.g. `nytimes.com`, `alltrails.com`
   return HTTP 403 even to self-hosted Firecrawl). Needs a key — set it
   **without committing it** via `config.local.json` (gitignored, overlays
   `config.json`) or the `FIRECRAWL_API_KEY` env var:
   ```json
   // config.local.json
   { "firecrawlAPIKey": "fc-..." }
   ```

URLs that even commercial Firecrawl can't get (paywalls/dead links) fall back to a
card synthesized from the URL slug + domain, so every link still renders.

Credits/cost: each tier is only tried when the previous one fails, so the LAN
instance absorbs most work and commercial credits are spent only on hard cases.
`--previews` (incremental) processes **new** URLs only; `--previews --full` retries
all prior failures through the chain. Privacy: Firecrawl tiers receive the shared
URLs — the LAN tier keeps that on your hardware; the commercial tier is a third
party (opt-in, off unless a key is set).

### Images (content tags + OCR)

`--images` runs Apple's Vision framework on image attachments in the chat:
`VNClassifyImageRequest` for content tags (search "dog", "beach", "toy") and
`VNRecognizeTextRequest` for OCR (screenshots, memes, signs). Results land in
`messages.media_text`, so they feed both FTS search and RAG. Each image also gets
a thumbnail via `GET /api/image/:id?thumb=1`.

> **iCloud offload:** Messages' "Optimize Mac Storage" offloads most attachment
> files. `--images` tags whatever is on disk and records the rest as `missing`;
> every run re-checks `missing` ones, so coverage grows automatically as files
> download. To tag everything at once, turn off Optimize Mac Storage in Messages
> first (uses more disk), then run `--images --full`.

## HTTP API

All endpoints sit behind HTTP Basic auth.

- `GET /api/search?q=&from=&to=&sender=&limit=` — FTS5 bm25 ranked, `<mark>`-highlighted snippets.
- `GET /api/context/:id?window=` — messages surrounding a hit.
- `GET /api/senders` — distinct senders (filter list).
- `GET /api/stats` — ambient counts + freshness (powers the footer).
- `GET /api/thread?before=&after=&limit=` — a page of the conversation for the Browse tab.
- `GET /api/events` — Server-Sent Events stream of live index updates.
- `GET /api/image/:attachmentID?thumb=1` — JPEG thumbnail of an image attachment
  (404 if offloaded). Path-restricted to the Messages Attachments dir.
- `POST /api/ask` — `{ "question": "...", "from": <unix?>, "to": <unix?> }` → SSE
  stream of `{type:"token"|"citations"|"done"|"error"}` events.
- `GET /api/health`.

Search hits and context messages carry `links` (URL previews) and `images`
(`{attachmentID, tags, hasFile}`) for rich rendering in the UI.

## Operationalize (launchd)

Plists live in [launchd/](launchd/). Edit the absolute paths, then:

```
cp launchd/net.phfactor.imessage-indexer.plist ~/Library/LaunchAgents/
cp launchd/net.phfactor.imessage-server.plist  ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/net.phfactor.imessage-indexer.plist
launchctl load -w ~/Library/LaunchAgents/net.phfactor.imessage-server.plist
```

Grant the indexer binary Full Disk Access. Logs go to `~/.imessage-rag/*.log`.

To stop: `launchctl unload ~/Library/LaunchAgents/net.phfactor.imessage-*.plist`.

## Security

It's the whole family's private history. Bind to the LAN only, never expose to
the internet, keep Basic auth on, and pick a real password. `index.db` and any
`config.local.json` are gitignored.

## Layout

```
Sources/
  CSQLiteVec/     sqlite-vec compiled with -DSQLITE_CORE + registration shim
  IndexerCore/    chat.db read, decode, FTS store, chunker, embeddings
  indexer/        CLI: --full / --watch / --embed / --chats
  server/         Hummingbird app: search, context, ask (RAG); static UI in Public/
vendor/sqlite-vec/  vendored amalgamation
launchd/          LaunchAgent plists
```
