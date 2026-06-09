# iMessage Family Search — Build Plan

> Self-contained spec for building a LAN web app that gives a family far better search
> (full-text + semantic/RAG) over their long-running iMessage group chat than the native
> Messages app provides. This document assumes **no prior conversation context** — everything
> needed to build is here.

---

## 1. Goal

Native Messages search is inadequate for a long-running family group chat. Build:

- **v1 — Full-text search (FTS):** fast, ranked, filterable search over the entire chat history.
- **v2 — RAG (semantic Q&A):** ask natural-language questions ("what did we decide about the
  Thanksgiving trip?") and get answers grounded in the actual messages, with citations.

Delivered as a **LAN web app** so any family member can use it from a browser with **no install**.

---

## 2. Locked decisions (do not relitigate)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Delivery | **LAN web app** | No per-person install; central index; one place for the LLM. |
| Topology | **Single box** — everything on `axiom` | `axiom` is an always-on Mac Studio that already has the data + the LLM. |
| Host | **`axiom` (Mac Studio, always-on, macOS 26)** | Always-on; runs LM Studio; signed into the same Apple ID with Messages in iCloud. |
| Data source | `axiom:~/Library/Messages/chat.db` | Messages in iCloud keeps a full local SQLite copy on axiom. **No cross-machine sync needed.** |
| Language | **All-Swift** | One language to an eventual SwiftUI app; native `NSUnarchiver` for decode. |
| Web framework | **Hummingbird** (or Vapor) | Lightweight async HTTP server for macOS. |
| AI backend | **LM Studio on axiom** (OpenAI-compatible API at `axiom.phfactor.net`, localhost on the box) | gpt-oss 120b for generation + an embedding model for vectors. Keeps all family data on the user's own hardware. |
| Vector store | **`sqlite-vec`** (SQLite extension) | Keeps vectors in the same file as FTS5; one store, simple ops. |
| Privacy | Local-first; **LAN-only bind + auth** | It's the whole family's private history. |

**⚠ Must verify first:** axiom *should* have the full chat history via Messages in iCloud, but the
user only said "I think so." **Gate the whole build on running the probe (Section 9) on axiom** to
confirm message counts, date range, and that `attributedBody` decodes there.

---

## 3. Architecture

```
axiom (Mac Studio, always-on, macOS 26)
│
│  ~/Library/Messages/chat.db   ◄── Messages in iCloud
│        │
│        │  (snapshot: copy db + -wal + -shm to read consistently)
│        ▼
│  ① INDEXER (Swift CLI, launchd timer)
│        • decode attributedBody → plain text   (NSUnarchiver — proven, see §6)
│        • normalize → messages table
│        • build FTS5 index
│        • embed (LM Studio) → sqlite-vec
│        • incremental by ROWID watermark
│        ▼
│  index.db   =  messages + messages_fts (FTS5) + vec_chunks (sqlite-vec) + meta
│        ▲
│        │  read-only
│  ② WEB SERVER (Hummingbird)
│        • GET  /api/search   hybrid FTS5 + vector (RRF)
│        • POST /api/ask      RAG: retrieve → gpt-oss 120b → stream (SSE)
│        • GET  /api/context  messages around a hit
│        • basic-auth, bound to LAN interface
│        │            └──► LM Studio @ localhost (gpt-oss 120b + embeddings)
│        ▼
│  ③ WEB UI (static HTML/JS, served by ②)
│        ▲
└────────┴──►  family browsers on the LAN
```

The **only macOS-locked component is the indexer** (it uses Apple's `NSUnarchiver`). Because the
indexer decodes everything to plain text *once*, the server + UI touch only SQLite text and need no
Apple APIs — they could be ported to anything later.

---

## 4. Environment facts (verified)

- **axiom:** Mac Studio, macOS 26.x, always-on. Runs LM Studio (OpenAI-compatible) with **gpt-oss 120b**
  and an embedding model. Reachable as `axiom.phfactor.net`; on the box itself use `http://localhost:<port>/v1`.
- **chat.db:** SQLite, WAL mode, ~hundreds of MB. Lives at `~/Library/Messages/chat.db`.
- **TCC / permissions:** `~/Library/Messages` is TCC-protected. The file is `rw`/user-owned, but any
  process needs **Full Disk Access** to `open()` it. Confirmed on the dev machine that both `sqlite3`
  and `cp` get `Operation not permitted` without FDA. → Grant FDA to **Terminal** (during dev) and to the
  **indexer executable / launchd context** (in production) on axiom.
- **`sqlite3` CLI** and the **Swift toolchain** are present on macOS.

---

## 5. chat.db schema (the parts we use)

Relevant tables:

- `message` — one row per message.
  - `ROWID` — monotonic id; use as the incremental **watermark**.
  - `text` — message body, **often NULL on modern macOS** (see §6).
  - `attributedBody` — BLOB; the real body when `text` is NULL (`streamtyped` serialization).
  - `date` — **Apple-epoch nanoseconds** (offset `978307200` seconds from Unix epoch). Convert:
    `unix_secs = date/1e9 + 978307200` (older DBs stored seconds; detect by magnitude).
  - `is_from_me` — 1 if sent by the account owner.
  - `handle_id` — FK → `handle.ROWID` (the sender; NULL/own for outgoing).
  - `associated_message_type` — non-zero for tapbacks/reactions (filter these out of the text index).
- `handle` — `ROWID`, `id` (phone number or Apple ID / email of a participant).
- `chat` — `ROWID`, `display_name`, `chat_identifier` (group name vs identifier).
- `chat_message_join` — (`chat_id`, `message_id`).
- `chat_handle_join` — (`chat_id`, `handle_id`) → participant count per chat.
- `attachment` + `message_attachment_join` — media (out of scope for text index; record presence/filename only).

**Identifying the family group chat:** group chats have ≥3 participants (`chat_handle_join`). The target
is almost certainly the chat with the most messages among those. Allow it to be pinned by `chat.ROWID`
in config once identified.

**Contact names:** `handle.id` is a phone number / email, not a display name. For nice sender labels,
optionally map handles → names. Pulling from Contacts (AddressBook) is extra TCC scope and fiddly;
acceptable v1 fallback is a small hand-written `handles.json` map, or just show the raw `id`.

---

## 6. The attributedBody decode (the #1 risk — already solved)

On modern macOS, `message.text` is frequently NULL and the body lives in `message.attributedBody`,
serialized in Apple's legacy **`streamtyped`** (NSArchiver) format. **This is proven to decode in one
line** with the deprecated-but-functional `NSUnarchiver` (validated on macOS 26 in Swift):

```swift
import Foundation

/// Decode Messages' streamtyped attributedBody blob → plain text. Returns nil if undecodable.
func decodeAttributedBody(_ data: Data) -> String? {
    if let s = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
        return s.string
    }
    return nil
}
```

Notes:
- `NSUnarchiver` is deprecated (since 10.13) but works fine; suppress the warning with
  `@available`-guarded wrapper or accept it. It is the pragmatic choice for a personal app.
- Resolution order per message: use `text` if non-empty; else decode `attributedBody`; else mark as
  non-text (media/tapback) and skip from the FTS index (still keep the row for context/threading).
- **Future-proofing (optional, not v1):** if a later macOS removes `NSUnarchiver`, port a `typedstream`
  parser (cf. the Rust `imessage-exporter` project). Not needed now.

---

## 7. index.db schema (our own store)

A separate SQLite file the indexer writes and the server reads. Decoupled from `chat.db`.

```sql
-- Normalized messages (decoded to plain text at index time)
CREATE TABLE messages (
  id           INTEGER PRIMARY KEY,   -- mirrors chat.db message.ROWID
  chat_id      INTEGER NOT NULL,
  ts_unix      REAL    NOT NULL,      -- converted from Apple-epoch ns
  sender       TEXT    NOT NULL,      -- handle.id or 'me'
  sender_name  TEXT,                  -- optional friendly name
  is_from_me   INTEGER NOT NULL,
  body         TEXT,                  -- decoded text (NULL for non-text rows)
  has_media    INTEGER NOT NULL DEFAULT 0,
  reply_to     INTEGER                -- threaded reply target if available
);
CREATE INDEX idx_messages_ts ON messages(ts_unix);
CREATE INDEX idx_messages_chat ON messages(chat_id);

-- Full-text search (external-content FTS5 over messages.body)
CREATE VIRTUAL TABLE messages_fts USING fts5(
  body,
  content='messages', content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
-- keep in sync via triggers or rebuild after batch insert

-- Vector chunks for RAG (sqlite-vec). Chunk = a conversational window, not a single message.
CREATE TABLE chunks (
  id         INTEGER PRIMARY KEY,
  chat_id    INTEGER NOT NULL,
  start_id   INTEGER NOT NULL,   -- first message.id in the window
  end_id     INTEGER NOT NULL,   -- last message.id in the window
  ts_start   REAL NOT NULL,
  ts_end     REAL NOT NULL,
  text       TEXT NOT NULL       -- rendered window: "Name (time): body\n..." for embedding + context
);
-- vec0 virtual table; dimension must match the embedding model output
CREATE VIRTUAL TABLE vec_chunks USING vec0(
  chunk_id INTEGER PRIMARY KEY,
  embedding FLOAT[<DIM>]         -- set <DIM> to the LM Studio embedding model's dimension
);

-- Bookkeeping
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
-- meta: last_indexed_rowid, target_chat_id, embed_model, embed_dim, schema_version
```

---

## 8. RAG design

- **Chunking:** group consecutive messages into windows by a time-gap heuristic (e.g., start a new
  chunk when the gap to the previous message > ~30 min) with a max window size (e.g., 20–40 messages),
  plus a small overlap. Render each chunk as `Name (YYYY-MM-DD HH:MM): body` lines — this gives the
  embedding (and the LLM) speaker + time context.
- **Embeddings:** call LM Studio `/v1/embeddings` in batches; store `embedding` in `vec_chunks` and
  record model + dimension in `meta`. The initial full-history pass is a one-time spike — **throttle it**
  so it doesn't starve interactive LLM use.
- **Retrieval (hybrid):** for a query, run **FTS5 `bm25()`** over messages AND **vector kNN** over
  `vec_chunks`, then fuse with **Reciprocal Rank Fusion (RRF)**. Hybrid beats either alone for chat.
- **Generation:** build a prompt with the top-k fused chunks (each tagged with a citation id) + the
  user question; call gpt-oss 120b via `/v1/chat/completions` with streaming; **stream tokens to the
  browser via SSE**. Instruct the model to cite chunk ids; map citations back to message ranges so the
  UI can deep-link into the thread.
- **Date/sender filters** apply to both retrieval arms.

---

## 9. Verification gate — run the probe on axiom FIRST

A read-only Swift probe already exists at `probe.swift` (in this directory). It snapshots `chat.db`,
enumerates group chats with counts + date ranges, and decodes real `attributedBody` samples — proving
the entire read path end to end. **Run it on axiom before building anything:**

1. Grant **Full Disk Access** to Terminal on axiom (System Settings → Privacy & Security → Full Disk Access).
2. Copy `probe.swift` to axiom and run: `swift probe.swift`
3. Confirm from the output:
   - total message count and a sensible **date range** (i.e., the full history is present, not a stub);
   - the family **group chat** appears with a large message count;
   - `attributedBody` **decodes** (the sample messages print real text).

If the history is **not** fully present on axiom (Messages in iCloud didn't materialize it), fall back to
the two-box model: run the indexer on the desktop that *does* have the history and `rsync` `index.db` to
axiom on a timer. Everything else in this plan is unchanged.

The probe's decode function and date conversion are the reference implementations for the indexer.

---

## 10. Project layout (Swift Package Manager, all-Swift)

```
imessage-rag/
├── Package.swift
├── PLAN.md                  ← this file
├── probe.swift              ← standalone verification probe
├── Sources/
│   ├── IndexerCore/         ← library: chat.db read, decode, normalize, FTS, chunk, embed
│   │   ├── ChatDBReader.swift
│   │   ├── AttributedBodyDecoder.swift
│   │   ├── IndexStore.swift        (index.db schema + writes; loads sqlite-vec)
│   │   ├── Chunker.swift
│   │   └── EmbeddingClient.swift   (LM Studio /v1/embeddings)
│   ├── indexer/             ← executable: one-shot + watch modes, watermark logic
│   │   └── main.swift
│   └── server/              ← executable: Hummingbird app
│       ├── main.swift
│       ├── SearchService.swift     (FTS5 + vector + RRF)
│       ├── AskService.swift        (RAG; LM Studio /v1/chat/completions; SSE)
│       ├── Auth.swift              (basic-auth middleware)
│       └── Public/                 (static web UI: index.html, app.js, style.css)
├── config.json              ← target_chat_id, lm_studio_base_url, embed_model, auth, bind addr
└── launchd/
    └── net.phfactor.imessage-indexer.plist   (timer to run the indexer)
```

Dependencies: `hummingbird`, a SQLite layer (GRDB.swift recommended, or raw SQLite3 C API),
`sqlite-vec` (load the prebuilt extension dylib at runtime). Pin the embedding model + dimension in config.

---

## 11. Phased task list (for the build session)

### Phase 0 — Verify (gate)
- [ ] Run `probe.swift` on axiom; confirm history present + decode works (§9).
- [ ] Record: total messages, target group chat `ROWID`, date range, embedding model name + dimension.

### Phase 1 — Indexer + FTS (yields a usable search index)
- [ ] SPM project scaffold; add deps; load `sqlite-vec`.
- [ ] `AttributedBodyDecoder` (port from probe) + unit test against a synthetic streamtyped blob.
- [ ] `ChatDBReader`: snapshot db (+wal/shm), open read-only, stream messages for the target chat,
      resolve text vs attributedBody, convert dates, skip tapbacks.
- [ ] `IndexStore`: create `index.db` schema; batch upsert into `messages`; populate `messages_fts`.
- [ ] Incremental mode: read `meta.last_indexed_rowid`, index only newer rows, advance watermark.
- [ ] CLI: `indexer --full` and `indexer --watch`.

### Phase 2 — Search API + Web UI (usable v1 for the family)
- [ ] Hummingbird server; `config.json`; bind to LAN interface; basic-auth middleware.
- [ ] `GET /api/search?q=&from=&to=&sender=&limit=` → FTS5 `bm25()` ranked, snippet-highlighted.
- [ ] `GET /api/context/:id?window=` → messages surrounding a hit.
- [ ] Static UI: search box, filters, ranked results (sender, date, highlighted snippet), expand-to-context.
- [ ] **Ship checkpoint:** family can search the full history from a browser.

### Phase 3 — RAG (semantic Q&A)
- [ ] `Chunker`: conversational-window chunking (§8) → `chunks`.
- [ ] `EmbeddingClient`: batch-embed chunks via LM Studio; fill `vec_chunks`; throttle the initial pass.
- [ ] `SearchService`: add vector kNN; fuse with bm25 via RRF.
- [ ] `AskService`: `POST /api/ask` → retrieve → prompt gpt-oss 120b → **SSE stream**; return citations.
- [ ] UI "Ask" mode: streamed answer + clickable citations that deep-link into the thread.

### Phase 4 — Operationalize
- [ ] `launchd` agent runs `indexer --watch` (or on a timer); FDA granted to its executable.
- [ ] Server as a `launchd` service; restart-on-crash; log rotation.
- [ ] README: how to grant FDA, set config, find the chat id, start/stop.

---

## 12. Risks & mitigations

| Risk | Mitigation |
|------|------------|
| axiom lacks full history via iCloud | **Probe first (§9)**; fall back to two-box (desktop indexes → rsync index.db). |
| `NSUnarchiver` removed in a future macOS | Works on macOS 26 today; port a typedstream parser later if needed. |
| Reading live WAL DB mid-write | Always **snapshot** chat.db (+ -wal/-shm) before reading. |
| Initial embedding pass starves the LLM | Throttle/batch; run off-hours; it's one-time. |
| Embedding dimension mismatch | Pin model + dim in `meta`/`config`; rebuild `vec_chunks` if the model changes. |
| Private data exposed on the network | Bind to LAN only (not 0.0.0.0 public); basic-auth; never expose to the internet. |
| Contact display names | v1: show `handle.id` or a small `handles.json` map; Contacts integration later. |
| Apple-epoch unit drift (ns vs s) | Detect by magnitude when converting `date`. |

---

## 13. Acceptance criteria

- **v1 (FTS):** any family member, from a browser on the LAN (behind auth), can search the entire group
  chat and get ranked, snippet-highlighted results filterable by sender and date, and expand any hit into
  its surrounding conversation — clearly better than native Messages search.
- **v2 (RAG):** a natural-language question returns a streamed, grounded answer with citations that link
  back to the actual messages.
- **Ops:** new messages appear in search automatically (indexer on a timer); the server survives reboots.

---

## 14. Quick reference — constants & endpoints

- Apple-epoch → Unix: `unix_secs = apple_date_ns / 1_000_000_000 + 978_307_200`.
- chat.db: `~/Library/Messages/chat.db` (+ `-wal`, `-shm`). Snapshot before reading.
- LM Studio (OpenAI-compatible): `…/v1/embeddings`, `…/v1/chat/completions` (model `gpt-oss 120b`).
- Decode body: `NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString` → `.string`.
- FDA: System Settings → Privacy & Security → Full Disk Access → add Terminal (dev) and the indexer/server executables (prod).
