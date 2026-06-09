"use strict";

const $ = (sel) => document.querySelector(sel);
const el = (tag, cls) => { const e = document.createElement(tag); if (cls) e.className = cls; return e; };

// --- helpers ---------------------------------------------------------------

function esc(s) {
  return (s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
// Escape text but keep server-provided <mark> highlight tags.
function snippetHTML(s) {
  return esc(s).replace(/&lt;mark&gt;/g, "<mark>").replace(/&lt;\/mark&gt;/g, "</mark>");
}
function fmtDate(ts) {
  const d = new Date(ts * 1000);
  return d.toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}
function senderLabel(m) { return m.senderName || (m.isFromMe ? "Me" : m.sender); }
function dayStart(v) { return v ? Date.parse(v + "T00:00:00") / 1000 : null; }
function dayEnd(v) { return v ? Date.parse(v + "T23:59:59") / 1000 : null; }

// --- tabs ------------------------------------------------------------------

$("#tab-search").onclick = () => switchMode("search");
$("#tab-ask").onclick = () => switchMode("ask");
$("#tab-browse").onclick = () => switchMode("browse");
function switchMode(mode) {
  for (const m of ["search", "ask", "browse"]) {
    $("#tab-" + m).classList.toggle("active", m === mode);
    $("#mode-" + m).hidden = m !== mode;
  }
  if (mode === "browse" && !threadLoaded) loadThreadInitial();
}

// --- search ----------------------------------------------------------------

let searchTimer = null;
function scheduleSearch() { clearTimeout(searchTimer); searchTimer = setTimeout(runSearch, 180); }

$("#q").addEventListener("input", scheduleSearch);
["from", "to", "sender"].forEach((id) => $("#" + id).addEventListener("change", runSearch));
$("#search-form").addEventListener("submit", (e) => { e.preventDefault(); runSearch(); });

async function runSearch() {
  const q = $("#q").value.trim();
  const results = $("#results");
  const status = $("#status");
  if (!q) { results.innerHTML = ""; status.textContent = ""; return; }

  const params = new URLSearchParams({ q, limit: "100" });
  const from = dayStart($("#from").value), to = dayEnd($("#to").value), sender = $("#sender").value;
  if (from) params.set("from", from);
  if (to) params.set("to", to);
  if (sender) params.set("sender", sender);

  status.textContent = "Searching…";
  try {
    const r = await fetch("/api/search?" + params.toString());
    if (!r.ok) throw new Error("HTTP " + r.status);
    const data = await r.json();
    status.textContent = data.count ? `${data.count} result${data.count === 1 ? "" : "s"}` : "No results";
    results.innerHTML = "";
    for (const h of data.hits) results.appendChild(renderHit(h));
  } catch (err) {
    status.textContent = "Error: " + err.message;
  }
}

function renderHit(h) {
  const li = el("li", "hit");
  li.innerHTML =
    `<div class="meta"><span class="sender">${esc(h.senderName || (h.isFromMe ? "Me" : h.sender))}</span>` +
    `<span>${fmtDate(h.ts)}</span></div>` +
    `<div class="snippet">${snippetHTML(h.snippet)}</div>`;
  if (h.images && h.images.length) li.appendChild(imageStrip(h.images));
  if (h.links && h.links.length) li.appendChild(linkCards(h.links));
  li.onclick = () => openContext(h.id);
  return li;
}

// Thumbnails + content tag chips for a message's images.
function imageStrip(images) {
  const wrap = el("div", "imgstrip");
  for (const im of images) {
    const cell = el("div", "imgcell");
    if (im.hasFile) {
      const img = el("img", "thumb");
      img.src = `/api/image/${im.attachmentID}?thumb=1`;
      img.loading = "lazy";
      img.onerror = () => img.remove();
      img.onclick = (e) => { e.stopPropagation(); window.open(`/api/image/${im.attachmentID}`, "_blank"); };
      cell.appendChild(img);
    } else {
      const ph = el("div", "thumb placeholder");
      ph.textContent = "☁︎";
      ph.title = "Photo offloaded to iCloud";
      cell.appendChild(ph);
    }
    if (im.tags && im.tags.length) {
      const chips = el("div", "chips");
      for (const t of im.tags.slice(0, 4)) { const c = el("span", "chip"); c.textContent = t; chips.appendChild(c); }
      cell.appendChild(chips);
    }
    wrap.appendChild(cell);
  }
  return wrap;
}

// Build a row of link-preview cards. Clicks open the URL (not the parent).
function linkCards(links) {
  const wrap = el("div", "linkcards");
  for (const p of links) {
    const a = el("a", "linkcard");
    a.href = p.url; a.target = "_blank"; a.rel = "noopener noreferrer";
    a.onclick = (e) => e.stopPropagation();
    if (p.imageURL) {
      const img = el("img", "lc-img");
      img.src = p.imageURL; img.loading = "lazy"; img.referrerPolicy = "no-referrer";
      img.onerror = () => img.remove();
      a.appendChild(img);
    }
    const body = el("div", "lc-body");
    if (p.siteName) { const s = el("div", "lc-site"); s.textContent = p.siteName; body.appendChild(s); }
    const t = el("div", "lc-title"); t.textContent = p.title || p.url; body.appendChild(t);
    if (p.description) { const d = el("div", "lc-desc"); d.textContent = p.description; body.appendChild(d); }
    a.appendChild(body);
    wrap.appendChild(a);
  }
  return wrap;
}

// --- context drawer --------------------------------------------------------

const drawer = $("#drawer"), scrim = $("#scrim");
$("#drawer-close").onclick = closeDrawer;
scrim.onclick = closeDrawer;
function closeDrawer() { drawer.hidden = true; scrim.hidden = true; }

async function openContext(id) {
  drawer.hidden = false; scrim.hidden = false;
  const body = $("#drawer-body");
  body.innerHTML = "<p style='color:var(--muted)'>Loading…</p>";
  try {
    const r = await fetch(`/api/context/${id}?window=14`);
    const data = await r.json();
    body.innerHTML = "";
    for (const m of data.messages) body.appendChild(renderBubble(m));
    const hit = body.querySelector(".bubble.hit");
    if (hit) hit.scrollIntoView({ block: "center" });
  } catch (err) {
    body.innerHTML = "<p>Error: " + esc(err.message) + "</p>";
  }
}

function renderBubble(m) {
  const b = el("div", "bubble" + (m.isFromMe ? " me" : "") + (m.isHit ? " hit" : ""));
  let inner = `<div class="who">${esc(senderLabel(m))}</div>`;
  if (m.body) inner += esc(m.body);
  else if (m.hasMedia) { b.classList.add("media"); inner += "<em>📎 attachment</em>"; }
  else inner += "<em>·</em>";
  inner += `<div class="when">${fmtDate(m.ts)}</div>`;
  b.innerHTML = inner;
  if (m.images && m.images.length) b.appendChild(imageStrip(m.images));
  if (m.links && m.links.length) b.appendChild(linkCards(m.links));
  return b;
}

// --- sender dropdown -------------------------------------------------------

async function loadSenders() {
  try {
    const r = await fetch("/api/senders");
    if (!r.ok) return;
    const data = await r.json();
    const sel = $("#sender");
    for (const s of data.senders) {
      const o = el("option");
      o.value = s.sender;
      o.textContent = s.name || s.sender;
      sel.appendChild(o);
    }
  } catch (_) {}
}
loadSenders();

// --- ask (RAG, Phase 3) ----------------------------------------------------

$("#ask-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const question = $("#question").value.trim();
  if (!question) return;
  const answer = $("#answer"), cites = $("#citations");
  answer.innerHTML = "<span class='cursor'>▍</span>";
  cites.innerHTML = "";
  let text = "";

  try {
    const r = await fetch("/api/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question })
    });
    if (!r.ok) { answer.textContent = "Error: HTTP " + r.status; return; }

    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const events = buf.split("\n\n");
      buf = events.pop();
      for (const ev of events) {
        const line = ev.split("\n").find((l) => l.startsWith("data:"));
        if (!line) continue;
        const payload = JSON.parse(line.slice(5).trim());
        if (payload.type === "token") {
          text += payload.text;
          answer.innerHTML = esc(text) + "<span class='cursor'>▍</span>";
        } else if (payload.type === "citations") {
          renderCitations(payload.items);
        } else if (payload.type === "error") {
          answer.textContent = "Error: " + payload.message;
        }
      }
    }
    answer.innerHTML = esc(text);
  } catch (err) {
    answer.textContent = "Error: " + err.message;
  }
});

function renderCitations(items) {
  const cites = $("#citations");
  cites.innerHTML = "";
  (items || []).forEach((c) => {
    const d = el("div", "cite");
    d.innerHTML = `<span class="cid">[${c.id}]</span>${esc(c.label || "")}`;
    d.onclick = () => openContext(c.centerID || c.startID);
    cites.appendChild(d);
  });
}

// --- browse the thread -----------------------------------------------------

let threadLoaded = false, oldestId = null, loadingOlder = false, noMoreOlder = false;
const threadEl = $("#thread");

async function loadThreadInitial() {
  try {
    const r = await fetch("/api/thread?limit=60");
    const data = await r.json();
    threadEl.innerHTML = "";
    for (const m of data.messages) threadEl.appendChild(renderBubble(m));
    if (data.messages.length) {
      oldestId = data.messages[0].id;
      newestLoadedId = data.messages[data.messages.length - 1].id;
    }
    threadLoaded = true;
    $("#browse-status").textContent = "";
    threadEl.scrollTop = threadEl.scrollHeight;        // jump to most recent
    threadEl.addEventListener("scroll", onThreadScroll);
  } catch (err) {
    $("#browse-status").textContent = "Error: " + err.message;
  }
}

function onThreadScroll() {
  if (threadEl.scrollTop < 120) loadOlder();
}

async function loadOlder() {
  if (loadingOlder || noMoreOlder || oldestId == null) return;
  loadingOlder = true;
  const prevHeight = threadEl.scrollHeight;
  try {
    const r = await fetch(`/api/thread?before=${oldestId}&limit=60`);
    const data = await r.json();
    if (!data.messages.length) { noMoreOlder = true; return; }
    const frag = document.createDocumentFragment();
    for (const m of data.messages) frag.appendChild(renderBubble(m));
    threadEl.insertBefore(frag, threadEl.firstChild);
    oldestId = data.messages[0].id;
    threadEl.scrollTop = threadEl.scrollHeight - prevHeight;   // keep view anchored
  } catch (_) {} finally { loadingOlder = false; }
}

// --- ambient footer stats --------------------------------------------------

function relTime(unix) {
  if (!unix) return "never";
  const s = Math.max(0, Date.now() / 1000 - unix);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  return Math.floor(s / 86400) + "d ago";
}
function nf(n) { return (n || 0).toLocaleString(); }

function renderFooter(d) {
  $("#footer").textContent = [
    `${nf(d.messages)} messages`,
    `${nf(d.chunks)} chunks`,
    `${nf(d.linkPreviews)} links`,
    `${nf(d.taggedImages)} tagged photos`,
    `updated ${relTime(d.lastIndexedAt)}`
  ].join("  ·  ");
}
async function loadStats() {
  try {
    const r = await fetch("/api/stats");
    if (r.ok) { const d = await r.json(); renderFooter(d); newestId = d.latestMessageID || newestId; }
  } catch (_) {}
}
loadStats();
setInterval(loadStats, 60000);   // fallback if the live stream drops

// --- live updates (SSE) ----------------------------------------------------

let newestId = 0;          // newest message id the server knows about
let newestLoadedId = 0;    // newest id currently rendered in Browse

function connectEvents() {
  const es = new EventSource("/api/events");   // browser carries Basic-auth creds; auto-reconnects
  es.onmessage = (e) => {
    let ev; try { ev = JSON.parse(e.data); } catch (_) { return; }
    if (ev.type === "update" && ev.stats) onUpdate(ev.stats);
  };
}
connectEvents();

function onUpdate(stats) {
  renderFooter(stats);
  const id = stats.latestMessageID || 0;
  const grew = id > newestId;
  newestId = id;
  if (!grew) return;

  // Browse: pull in the new messages.
  if (threadLoaded && newestLoadedId && id > newestLoadedId) appendNewThread();

  // Search: if results are showing, offer to refresh (don't disrupt the current view).
  if (!$("#mode-search").hidden && $("#results").children.length) {
    $("#search-new").hidden = false;
  }
}

$("#search-new").onclick = () => { $("#search-new").hidden = true; runSearch(); };
$("#browse-new").onclick = () => {
  threadEl.scrollTop = threadEl.scrollHeight;
  $("#browse-new").hidden = true;
};

async function appendNewThread() {
  const atBottom = threadEl.scrollTop + threadEl.clientHeight >= threadEl.scrollHeight - 50;
  try {
    const r = await fetch(`/api/thread?after=${newestLoadedId}&limit=100`);
    const data = await r.json();
    if (!data.messages.length) return;
    for (const m of data.messages) threadEl.appendChild(renderBubble(m));
    newestLoadedId = data.messages[data.messages.length - 1].id;
    if (atBottom) threadEl.scrollTop = threadEl.scrollHeight;   // follow the conversation
    else $("#browse-new").hidden = false;                       // nudge to jump down
  } catch (_) {}
}
