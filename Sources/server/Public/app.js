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
function switchMode(mode) {
  const s = mode === "search";
  $("#tab-search").classList.toggle("active", s);
  $("#tab-ask").classList.toggle("active", !s);
  $("#mode-search").hidden = !s;
  $("#mode-ask").hidden = s;
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
