// LiveDashboard (multi-tab) front end.
// All URLs are relative so the app works at a site root or under an IIS
// sub-path such as /dashboards/.
// Each tab is one dashboard from "LiveDashboards:Dashboards" in appsettings.json.
// Every tab keeps its own data, selection, sort and filter while you switch.
(() => {
  const MIN_FALLBACK_POLL_MS = 2000;   // floor for browser polling when SignalR can't connect
  const NUMERIC = new Set(["number", "currency", "percent"]);

  const $ = id => document.getElementById(id);
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const nf = {
    number:  new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }),
    percent: new Intl.NumberFormat(undefined, { style: "percent", maximumFractionDigits: 1 }),
  };
  const dateFmt = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });
  const dtFmt = new Intl.DateTimeFormat(undefined, { dateStyle: "short", timeStyle: "short" });
  const dtLong = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "medium" });
  const rel = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const clock = new Intl.DateTimeFormat(undefined, { timeStyle: "medium" });
  const clockShort = new Intl.DateTimeFormat(undefined, { timeStyle: "short" });
  const humanize = k => k.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/_/g, " ").replace(/^./, c => c.toUpperCase());

  let appTitle = "Live Dashboards";
  const tabs = new Map();   // id -> tab state
  let T = null;             // the active tab's state

  function newTab(id, title) {
    return {
      id, title,
      cfg: null, fields: [], gridFields: [], detailFields: [],
      statusMap: new Map(), currencyFmt: null,
      rows: [], view: [], previous: new Map(),
      selectedKey: null, removedRow: null,
      sort: { key: null, dir: 1 }, search: "",
      loaded: false, dirty: false, loading: null, reloadQueued: false, error: null,
      // refresh tracking
      refreshedAt: null,     // Date: last time the data was confirmed current (server check or our fetch)
      dataAt: null,          // Date: last successful fetch of rows
      sourceOk: true, failingSince: null,
      // row limit (MaxRows)
      totalRows: 0, truncated: false, maxRows: 0, serverSummary: null,
    };
  }

  // ---------------------------------------------------------------- formatting
  const keyOf = r => String(r[T.cfg.keyField]);
  const labelOf = f => f.label || humanize(f.field);

  const COLORS = {
    green:  { css: "var(--good)",     ink: "#fff",    icon: "✓" },
    yellow: { css: "var(--warning)",  ink: "#0b0b0b", icon: "…" },
    red:    { css: "var(--critical)", ink: "#fff",    icon: "✕" },
    blue:   { css: "var(--series-1)", ink: "#fff",    icon: ""  },
    gray:   { outline: true,                          icon: ""  },
  };
  COLORS.grey = COLORS.gray;

  const inkFor = hex => {
    let h = hex.slice(1);
    if (h.length === 3) h = [...h].map(c => c + c).join("");
    const [r, g, b] = [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16) / 255)
      .map(c => c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.4 ? "#0b0b0b" : "#fff";
  };

  function statusStyle(v) {
    const exact = T.statusMap.get(String(v).toLowerCase());
    const s = exact || T.statusMap.get("*") || {};
    const name = String(s.color || "gray").trim().toLowerCase();
    let c = COLORS[name];
    if (!c && /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(name)) c = { css: name, ink: inkFor(name), icon: "" };
    c ||= COLORS.gray;
    return { ...c, icon: s.icon ?? c.icon, label: (exact && exact.label) || String(v) };
  }

  function statusHtml(v, labelOverride) {
    if (v == null || v === "") return `<span class="null">—</span>`;
    const st = statusStyle(v);
    const dot = st.outline
      ? `<span class="status-icon outline" aria-hidden="true">${esc(st.icon)}</span>`
      : `<span class="status-icon" aria-hidden="true" style="background:${st.css};color:${st.ink}">${esc(st.icon)}</span>`;
    return `<span class="status">${dot}${esc(labelOverride || st.label)}</span>`;
  }

  function ago(iso) {
    const s = (new Date(iso) - Date.now()) / 1000;
    for (const [u, n] of [["year", 31536000], ["month", 2592000], ["day", 86400], ["hour", 3600], ["minute", 60]])
      if (Math.abs(s) >= n) return rel.format(Math.round(s / n), u);
    return rel.format(Math.round(s), "second");
  }

  function fmt(v, format, long = false) {
    if (v == null || v === "") return `<span class="null">—</span>`;
    switch (format) {
      case "number": case "percent":
        return typeof v === "number" ? nf[format].format(v) : esc(v);
      case "currency":
        return typeof v === "number" ? T.currencyFmt.format(v) : esc(v);
      case "date": {
        const [y, m, d] = String(v).slice(0, 10).split("-").map(Number);
        return y ? dateFmt.format(new Date(y, m - 1, d)) : esc(v);
      }
      case "datetime": {
        const d = new Date(v);
        if (isNaN(d)) return esc(v);
        return long ? `${dtLong.format(d)}<span class="sub">${ago(v)}</span>` : dtFmt.format(d);
      }
      case "status":  return statusHtml(v);
      case "boolean": return v === true || v === 1 || v === "true" ? "Yes" : "No";
      default:        return esc(v);
    }
  }

  function text(v, format) {
    if (v == null) return "";
    if (format === "status") return `${v} ${statusStyle(v).label}`;
    const div = document.createElement("div");
    div.innerHTML = fmt(v, format);
    return div.textContent;
  }

  function compare(a, b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (typeof a === "number" && typeof b === "number") return a - b;
    return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: "base" });
  }

  // ---------------------------------------------------------------- tabs
  async function loadTabList() {
    const res = await fetch("api/dashboards", { cache: "no-store" });
    if (!res.ok) throw new Error(`Dashboards: HTTP ${res.status}`);
    const data = await res.json();
    appTitle = data.title || appTitle;
    rotation.configure(data.rotation);
    $("title").textContent = appTitle;

    const ids = new Set(data.dashboards.map(d => d.id));
    for (const id of [...tabs.keys()]) if (!ids.has(id)) tabs.delete(id);   // removed from config
    for (const d of data.dashboards) {
      const t = tabs.get(d.id);
      const t2 = t || newTab(d.id, d.title);
      t2.title = d.title;
      t2.rotationSeconds = d.rotationSeconds || null;
      t2.includeInRotation = d.includeInRotation !== false;
      if (!t) tabs.set(d.id, t2);
    }
    // keep config order
    const ordered = data.dashboards.map(d => tabs.get(d.id));
    tabs.clear(); ordered.forEach(t => tabs.set(t.id, t));
    renderTabs();
  }

  function renderTabs() {
    $("tabs").innerHTML = `<div class="tabs-label" aria-hidden="true">Dashboards</div>` + [...tabs.values()].map(t => `
      <button role="tab" id="tab-${esc(t.id)}" data-id="${esc(t.id)}" aria-controls="panel"
              aria-selected="${t === T}" tabindex="${t === T ? 0 : -1}">
        ${esc(t.title || t.id)}${t.dirty && t !== T ? `<span class="tab-dot" title="Updated since you last viewed it"></span><span class="sr-only"> (updated)</span>` : ""}
      </button>`).join("");
    $("sidebar").hidden = tabs.size < 2;
    rotation.render();
  }

  async function activate(id, { pushHash = true, auto = false } = {}) {
    const next = tabs.get(id) || tabs.values().next().value;
    if (!next) { showError("No dashboards are configured. Add one under LiveDashboards:Dashboards in appsettings.json."); return; }
    const prev = T;
    if (prev && prev !== next) prev.search = $("search").value;
    T = next;
    if (prev !== T) watch(prev, T);
    rotation.restartDwell();   // the new tab gets its full time on screen
    if (pushHash && location.hash.slice(1) !== T.id) history.replaceState(null, "", `#${encodeURIComponent(T.id)}`);
    document.title = `${T.title} · ${appTitle}`;
    $("search").value = T.search;
    renderTabs();

    try {
      if (!T.cfg) await loadConfig(T);
      applyLayout();
      loadStatus(T);
      if (pollTimer) restartPolling();
      if (!T.loaded || T.dirty) await load(T);
      else { render(); if (pollTimer) load(T); }   // polling mode can't flag background changes
    } catch (err) {
      showError(`Couldn't load “${T.title}”: ${err.message}`);
    }
  }

  // ---------------------------------------------------------------- config
  async function loadConfig(t) {
    const res = await fetch(`api/dashboards/${encodeURIComponent(t.id)}/config`, { cache: "no-store" });
    if (!res.ok) throw new Error(`config HTTP ${res.status}`);
    const cfg = await res.json();
    cfg.fields ??= []; cfg.summary ??= []; cfg.statuses ??= {};
    t.cfg = cfg;
    t.statusMap = new Map(Object.entries(cfg.statuses).map(([k, v]) => [k.toLowerCase(), v]));
    try {
      t.currencyFmt = new Intl.NumberFormat(undefined, { style: "currency", currency: cfg.currencyCode || "USD", maximumFractionDigits: 0 });
    } catch {
      t.currencyFmt = new Intl.NumberFormat(undefined, { style: "currency", currency: "USD", maximumFractionDigits: 0 });
    }
    buildFields(t);
  }

  function buildFields(t) {
    const first = t.rows[0] || {};
    t.fields = t.cfg.fields.length ? t.cfg.fields
      : Object.keys(first).map(k => ({ field: k, label: humanize(k), format: typeof first[k] === "number" ? "number" : "text", grid: true, detail: true }));
    t.gridFields = t.fields.filter(f => f.grid !== false);
    t.detailFields = t.fields.filter(f => f.detail !== false && f.field !== t.cfg.titleField);
    if (!t.gridFields.some(f => f.field === t.sort.key))
      t.sort = { key: t.cfg.defaultSort || t.gridFields[0]?.field, dir: t.cfg.defaultSortDescending ? -1 : 1 };
  }

  function applyLayout() {
    $("head").innerHTML = T.gridFields.map(f =>
      `<th data-key="${esc(f.field)}" class="${NUMERIC.has(f.format) ? "num" : ""}" scope="col">${esc(labelOf(f))}</th>`).join("");
    $("panel").setAttribute("aria-labelledby", `tab-${T.id}`);
  }

  // ---------------------------------------------------------------- data
  async function load(t = T) {
    if (t.loading) { t.reloadQueued = true; return t.loading; }
    t.loading = (async () => {
      try {
        const res = await fetch(`api/dashboards/${encodeURIComponent(t.id)}/rows`, { cache: "no-store" });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const body = await res.json();
        const next = Array.isArray(body) ? body : (body.rows || []);
        const key = r => String(r[t.cfg.keyField]);

        const snap = new Map(next.map(r => [key(r), JSON.stringify(r)]));
        const changed = new Set(t.previous.size ? [...snap].filter(([k, j]) => t.previous.get(k) !== j).map(([k]) => k) : []);
        if (t.selectedKey != null && !snap.has(t.selectedKey))
          t.removedRow = t.rows.find(r => key(r) === t.selectedKey) || t.removedRow;

        const needFields = !t.cfg.fields.length && !t.rows.length;
        t.rows = next;
        t.previous = snap;
        t.truncated = !!body.truncated;
        t.totalRows = body.totalRows ?? next.length;
        t.maxRows = body.maxRows ?? 0;
        t.serverSummary = t.truncated && Array.isArray(body.summary) ? body.summary : null;
        t.loaded = true;
        t.dirty = false;
        t.error = null;
        t.dataAt = new Date();
        if (!t.refreshedAt || t.dataAt > t.refreshedAt) t.refreshedAt = t.dataAt;
        if (needFields) buildFields(t);

        if (t === T) {
          if (needFields) applyLayout();
          render(changed);
          renderTabs();
        }
      } catch (err) {
        t.error = err.message;
        if (t === T) showError(`Couldn't load data: ${err.message}`);
      } finally {
        t.loading = null;
        if (t.reloadQueued) { t.reloadQueued = false; load(t); }
      }
    })();
    return t.loading;
  }

  function showError(msg) {
    $("kpis").innerHTML = "";
    $("rows").innerHTML = `<tr><td colspan="${T?.gridFields.length || 1}" class="error">${esc(msg)}</td></tr>`;
    $("detail").innerHTML = "";
  }

  // ---------------------------------------------------------------- render
  function render(changed = new Set()) {
    renderSummary();
    renderGrid(changed);
    if (T.selectedKey == null && T.view.length) T.selectedKey = keyOf(T.view[0]);
    markSelection(true);
    renderDetail(changed.has(T.selectedKey));
    renderFresh();
  }

  function renderSummary() {
    const { cfg, rows, fields } = T;
    $("kpis").innerHTML = cfg.summary.map((s, i) => {
      const fromServer = T.serverSummary && i < T.serverSummary.length;
      const subset = s.match != null && s.field ? rows.filter(r => String(r[s.field]) === String(s.match)) : rows;
      const nums = s.field ? subset.map(r => r[s.field]).filter(v => typeof v === "number") : [];
      const agg = (s.agg || "count").toLowerCase();
      const value = fromServer ? T.serverSummary[i] :
        agg === "sum" ? nums.reduce((a, b) => a + b, 0) :
        agg === "avg" ? (nums.length ? nums.reduce((a, b) => a + b, 0) / nums.length : null) :
        agg === "min" ? (nums.length ? Math.min(...nums) : null) :
        agg === "max" ? (nums.length ? Math.max(...nums) : null) :
        subset.length;
      const isStatus = s.match != null && fields.find(f => f.field === s.field)?.format === "status";
      const label = isStatus ? statusHtml(s.match, s.label) : esc(s.label);
      return `<div class="card kpi"><div class="label">${label}</div><div class="value">${fmt(value, s.format || "number")}</div></div>`;
    }).join("");
    $("kpis").hidden = !cfg.summary.length;
  }

  function renderGrid(changed = new Set()) {
    const q = $("search").value.trim().toLowerCase();
    const { gridFields, fields, sort } = T;
    const sortField = fields.find(f => f.field === sort.key);
    T.view = T.rows
      .filter(r => !q || gridFields.some(f => text(r[f.field], f.format).toLowerCase().includes(q)))
      .sort((a, b) => sortField ? compare(a[sort.key], b[sort.key]) * sort.dir : 0);

    document.querySelectorAll("#head th").forEach(th =>
      th.setAttribute("aria-sort", th.dataset.key === sort.key ? (sort.dir > 0 ? "ascending" : "descending") : "none"));

    const n = nf.number, loaded = T.rows.length, shown = T.view.length;
    const count = $("count");
    if (T.truncated) {
      // e.g. "1,000 of 8,412 rows" or, when filtered, "12 of 1,000 loaded (8,412 total)"
      count.innerHTML = (shown === loaded
        ? `${n.format(loaded)} of ${n.format(T.totalRows)} rows`
        : `${n.format(shown)} of ${n.format(loaded)} loaded (${n.format(T.totalRows)} total)`)
        + ` <span class="limit">limit ${n.format(T.maxRows)}</span>`;
      count.title = `This tab loads at most ${n.format(T.maxRows)} rows (MaxRows). ` +
        `Summary tiles still cover all ${n.format(T.totalRows)} rows; the filter, sort and related rows cover the ones loaded.`;
    } else {
      count.textContent = shown === loaded ? `${n.format(loaded)} rows` : `${n.format(shown)} of ${n.format(loaded)} rows`;
      count.title = "";
    }

    $("rows").innerHTML = shown ? T.view.map(r => {
      const k = keyOf(r);
      return `<tr data-key="${esc(k)}" role="row" aria-selected="false" class="${changed.has(k) ? "flash" : ""}">${
        gridFields.map(f => `<td class="${NUMERIC.has(f.format) ? "num" : ""}">${fmt(r[f.field], f.format)}</td>`).join("")
      }</tr>`;
    }).join("")
      : `<tr><td colspan="${gridFields.length || 1}" class="empty">${total ? "No matches" : "No data"}</td></tr>`;
  }

  function markSelection(scroll = false) {
    for (const tr of $("rows").rows) {
      const on = tr.dataset.key != null && tr.dataset.key === T.selectedKey;
      tr.setAttribute("aria-selected", on ? "true" : "false");
      if (on && scroll) tr.scrollIntoView({ block: "nearest" });
    }
  }

  function renderDetail(flash = false) {
    if (!detailOpen) return;
    const pane = $("detail");
    const { cfg, fields, detailFields, rows } = T;
    const live = rows.find(r => keyOf(r) === T.selectedKey);
    const r = live || T.removedRow;
    if (!r) { pane.innerHTML = `<div class="placeholder">Select a row to see its details.</div>`; return; }

    const keyField = fields.find(f => f.field === cfg.keyField);
    const title = cfg.titleField ? r[cfg.titleField] : null;
    const statusField = fields.find(f => f.format === "status");

    let html = `
      <div class="eyebrow">${esc(keyField ? labelOf(keyField) : cfg.keyField)} ${esc(r[cfg.keyField])}</div>
      <h2>${esc(title ?? `Row ${r[cfg.keyField]}`)}</h2>
      ${statusField ? statusHtml(r[statusField.field]) : ""}
      ${live ? "" : `<div class="notice">This row no longer exists in the database. Showing its last known values.</div>`}
      <section>
        <h3>Details</h3>
        <dl>${detailFields.map(f => {
          const wide = f.format === "multiline" ? " wide" : "";
          const empty = r[f.field] == null || r[f.field] === "" ? " null" : "";
          return `<dt class="${wide}">${esc(labelOf(f))}</dt><dd class="${wide}${empty}">${fmt(r[f.field], f.format, true)}</dd>`;
        }).join("")}</dl>
      </section>`;

    const g = cfg.group;
    const loadedNote = T.truncated
      ? `<div class="meter-caption muted-note">Based on the ${nf.number.format(rows.length)} rows loaded, not all ${nf.number.format(T.totalRows)}.</div>` : "";
    if (g?.field && r[g.field] != null) {
      const groupLabel = esc(r[g.field]);
      const same = rows.filter(x => x[g.field] === r[g.field]);
      const valueFmt = fields.find(f => f.field === g.valueField)?.format || "number";
      if (live && g.valueField && typeof r[g.valueField] === "number") {
        const total = same.reduce((a, x) => a + (typeof x[g.valueField] === "number" ? x[g.valueField] : 0), 0);
        const share = total ? r[g.valueField] / total : 0;
        html += `
          <section>
            <h3>Share of ${groupLabel}</h3>
            <div class="meter" role="img" aria-label="${nf.percent.format(share)} of ${groupLabel}"><div style="width:${share * 100}%"></div></div>
            <div class="meter-caption">${nf.percent.format(share)} of ${fmt(total, valueFmt)} across ${same.length} row${same.length === 1 ? "" : "s"}</div>
            ${loadedNote}
          </section>`;
      }
      const sibs = same.filter(x => keyOf(x) !== keyOf(r))
        .sort((a, b) => g.valueField ? compare(b[g.valueField], a[g.valueField]) : 0);
      if (sibs.length) html += `
        <section>
          <h3>Other rows in ${groupLabel}</h3>
          <ul class="siblings">${sibs.map(x => `
            <li data-key="${esc(keyOf(x))}"><span>${esc(cfg.titleField ? x[cfg.titleField] : keyOf(x))}</span>
            <span class="num">${g.valueField ? fmt(x[g.valueField], valueFmt) : statusField ? statusHtml(x[statusField.field]) : ""}</span></li>`).join("")}
          </ul>
          ${g.valueField ? "" : loadedNote}
        </section>`;
    }

    pane.innerHTML = html;
    if (flash) { pane.classList.remove("flash"); void pane.offsetWidth; pane.classList.add("flash"); }
  }

  // ---------------------------------------------------------------- last refreshed
  // `live` = this status was just pushed by the server, so it's current as of
  // right now on this browser's clock (avoids server/browser clock skew).
  function applyStatus(t, st, live = false) {
    if (!st) return;
    if (st.refreshMs) t.refreshMs = st.refreshMs;
    t.sourceOk = st.ok !== false;
    t.failingSince = st.failingSinceUtc ? new Date(Math.min(Date.parse(st.failingSinceUtc), Date.now())) : null;
    if (st.ok !== false && st.lastCheckedUtc) {
      const checked = live ? new Date() : new Date(Math.min(Date.parse(st.lastCheckedUtc), Date.now()));
      if (!t.refreshedAt || checked > t.refreshedAt) t.refreshedAt = checked;
    }
    if (t === T) renderFresh();
  }

  async function loadStatus(t) {
    try {
      const res = await fetch(`api/dashboards/${encodeURIComponent(t.id)}/status`, { cache: "no-store" });
      if (res.ok) applyStatus(t, await res.json());
    } catch { /* not critical */ }
  }

  const secs = ms => {
    const s = Math.round(ms / 1000);
    return s < 60 ? `${s}s` : s % 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s / 60} min`;
  };

  function renderFresh() {
    const el = $("fresh"), out = $("freshText");
    if (!T) { el.dataset.state = "none"; out.textContent = "—"; return; }
    const every = T.refreshMs || T.cfg?.refreshMs;
    const everyTxt = every ? `<span class="muted"> · checks every ${secs(every)}</span>` : "";

    if (!T.sourceOk) {
      el.dataset.state = "error";
      const since = T.failingSince ? ` since ${clockShort.format(T.failingSince)}` : "";
      const showing = T.refreshedAt ? `, showing data from <time>${clock.format(T.refreshedAt)}</time>` : "";
      out.innerHTML = `Data source unavailable${since}${showing}`;
      el.title = "The server can't reach this tab's database. It keeps retrying.";
      return;
    }
    if (!T.refreshedAt) { el.dataset.state = "none"; out.textContent = "Not refreshed yet"; return; }

    const age = Date.now() - T.refreshedAt;
    const interval = every || 5000;
    const stale = age > Math.max(interval * 3, interval + 10000);
    el.dataset.state = stale ? "stale" : "ok";
    out.innerHTML = `Last refreshed <time datetime="${T.refreshedAt.toISOString()}">${clock.format(T.refreshedAt)}</time>` +
      `<span class="muted"> (${ago(T.refreshedAt)})</span>` + (stale ? " · overdue" : everyTxt);
    el.title = `Last refreshed ${dtLong.format(T.refreshedAt)}` + (T.dataAt ? `\nData last loaded ${dtLong.format(T.dataAt)}` : "");
  }

  setInterval(renderFresh, 1000);

  function select(key, scroll = false) {
    if (key == null) return;
    T.selectedKey = key;
    T.removedRow = null;
    markSelection(scroll);
    renderDetail();
  }

  // ---------------------------------------------------------------- interactions
  $("tabs").addEventListener("click", e => {
    const b = e.target.closest("button[data-id]");
    if (b) activate(b.dataset.id);
  });
  $("tabs").addEventListener("keydown", e => {
    const list = [...tabs.keys()], i = list.indexOf(T?.id);
    // Up/Down for the vertical sidebar; Left/Right too (the strip is horizontal on narrow screens).
    const moves = { ArrowDown: i + 1, ArrowUp: i - 1, ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: list.length - 1 };
    if (!(e.key in moves)) return;
    e.preventDefault();
    const id = list[(moves[e.key] + list.length) % list.length];
    activate(id).then(() => document.getElementById(`tab-${id}`)?.focus());
  });
  addEventListener("hashchange", () => {
    const id = decodeURIComponent(location.hash.slice(1));
    if (id && id !== T?.id && tabs.has(id)) activate(id, { pushHash: false });
  });

  // ---------------------------------------------------------------- detail pane open / closed
  // Closing it gives the grid the full width. The choice is remembered in this browser.
  const DETAIL_KEY = "liveDashboards.detailOpen";
  let detailOpen = true;
  try { detailOpen = localStorage.getItem(DETAIL_KEY) !== "false"; } catch { /* storage unavailable */ }

  function setDetailOpen(open, { focus } = {}) {
    detailOpen = open;
    document.querySelector(".workspace").classList.toggle("no-detail", !open);
    $("toggleDetail").setAttribute("aria-pressed", String(open));
    try { localStorage.setItem(DETAIL_KEY, String(open)); } catch { /* storage unavailable */ }
    if (open && T?.cfg) renderDetail();           // catch up with the current selection
    if (focus === "toggle") $("toggleDetail").focus();
    if (focus === "grid") $("gridWrap").focus({ preventScroll: true });
  }
  setDetailOpen(detailOpen);

  $("toggleDetail").addEventListener("click", () => setDetailOpen(!detailOpen));
  $("closeDetail").addEventListener("click", () => setDetailOpen(false, { focus: "toggle" }));

  $("rows").addEventListener("click", e => {
    const tr = e.target.closest("tr[data-key]");
    if (tr) { select(tr.dataset.key); $("gridWrap").focus({ preventScroll: true }); }
  });
  $("rows").addEventListener("dblclick", e => {
    if (e.target.closest("tr[data-key]") && !detailOpen) setDetailOpen(true);
  });

  $("detailPane").addEventListener("keydown", e => {
    if (e.key === "Escape") { e.preventDefault(); setDetailOpen(false, { focus: "grid" }); }
  });

  $("detail").addEventListener("click", e => {
    const li = e.target.closest("li[data-key]");
    if (!li) return;
    if (!T.view.some(r => keyOf(r) === li.dataset.key)) { $("search").value = ""; renderGrid(); }
    select(li.dataset.key, true);
  });

  $("gridWrap").addEventListener("keydown", e => {
    if (!T?.view.length) return;
    if (e.key === "Enter") { e.preventDefault(); if (!detailOpen) setDetailOpen(true, { focus: "grid" }); return; }
    const idx = T.view.findIndex(r => keyOf(r) === T.selectedKey);
    const page = Math.max(1, Math.floor($("gridWrap").clientHeight / 40) - 1);
    const moves = { ArrowDown: idx + 1, ArrowUp: idx - 1, PageDown: idx + page, PageUp: idx - page, Home: 0, End: T.view.length - 1 };
    if (!(e.key in moves)) return;
    e.preventDefault();
    const next = Math.min(T.view.length - 1, Math.max(0, idx < 0 ? 0 : moves[e.key]));
    select(keyOf(T.view[next]), true);
  });

  $("search").addEventListener("input", () => { if (!T?.cfg) return; renderGrid(); markSelection(); });

  $("head").addEventListener("click", e => {
    const th = e.target.closest("th[data-key]");
    if (!th) return;
    T.sort = { key: th.dataset.key, dir: T.sort.key === th.dataset.key ? -T.sort.dir : 1 };
    renderGrid();
    markSelection(true);
  });

  setInterval(() => { if (T?.selectedKey != null && T.cfg) renderDetail(); }, 30000);

  // ---------------------------------------------------------------- auto-rotation
  // Cycles through the tabs every IntervalSeconds (or a tab's RotationSeconds).
  // A click, key press, scroll or touch pauses it for PauseOnInteractionSeconds,
  // so it never switches tabs on someone who's reading. Moving the mouse doesn't count.
  // A screen can override the config with ?rotate=0 (off), ?rotate=1 (on) or ?rotate=SECONDS.
  const rotation = (() => {
    const PAUSED_KEY = "liveDashboards.rotationPaused";
    const ICON_PAUSE = '<rect x="2" y="1.5" width="2.6" height="9" rx=".8" fill="currentColor"/><rect x="7.4" y="1.5" width="2.6" height="9" rx=".8" fill="currentColor"/>';
    const ICON_PLAY  = '<path d="M3 1.6v8.8a.6.6 0 0 0 .9.5l7-4.4a.6.6 0 0 0 0-1L3.9 1.1a.6.6 0 0 0-.9.5z" fill="currentColor"/>';

    let enabled = false, intervalSec = 60, pauseSec = 120;
    let userPaused = false, idleUntil = 0, startedAt = 0, endsAt = 0, wasWaiting = false, busy = false;
    try { userPaused = localStorage.getItem(PAUSED_KEY) === "true"; } catch { }

    // ?rotate=... on this screen beats the config
    const param = new URLSearchParams(location.search).get("rotate");
    const override = param == null ? null : Number(param);

    const list = () => [...tabs.values()].filter(t => t.includeInRotation !== false);
    const dwellMs = t => Math.max(5, (t?.rotationSeconds || intervalSec)) * 1000;
    const active = () => enabled && list().length > 1;

    function configure(cfg = {}) {
      enabled = !!cfg.enabled;
      intervalSec = Math.max(5, cfg.intervalSeconds || 60);
      pauseSec = Math.max(0, cfg.pauseOnInteractionSeconds ?? 120);
      if (override != null && !Number.isNaN(override)) {
        enabled = override !== 0;
        if (override >= 5) intervalSec = override;
      }
      restartDwell();
    }

    function restartDwell() { startedAt = Date.now(); endsAt = startedAt + dwellMs(T); }

    async function advance() {
      const l = list(); if (l.length < 2 || busy) return;
      const i = l.indexOf(T);
      const next = l[(i + 1) % l.length];     // T not in the list (skipped tab) → i = -1 → first tab
      busy = true;
      try { await activate(next.id, { auto: true }); } finally { busy = false; restartDwell(); }
    }

    function tick() {
      if (!active() || !T) { render(); return; }
      const now = Date.now();
      const waiting = now < idleUntil;
      if (wasWaiting && !waiting) restartDwell();   // someone stopped interacting: start a fresh countdown
      wasWaiting = waiting;
      if (!userPaused && !waiting && now >= endsAt) advance();
      render();
    }

    function render() {
      const box = $("rotate");
      if (!active()) { box.hidden = true; box.dataset.state = "off"; return; }
      box.hidden = false;
      const now = Date.now();
      const waiting = now < idleUntil;
      const state = userPaused ? "paused" : waiting ? "waiting" : "running";
      box.dataset.state = state;

      const l = list(), i = l.indexOf(T);
      const next = l[(i + 1) % l.length];
      const left = Math.max(0, Math.ceil((endsAt - now) / 1000));
      $("rotSub").textContent =
        state === "paused"  ? "Paused" :
        state === "waiting" ? `Paused while you work · resumes in ${secs(idleUntil - now)}` :
                              `Next: ${next?.title ?? ""} in ${secs(left * 1000)}`;
      const frac = state === "running" ? Math.min(1, (now - startedAt) / Math.max(1, endsAt - startedAt)) : 0;
      $("rotFill").style.width = `${(frac * 100).toFixed(1)}%`;

      const btn = $("rotToggle");
      btn.setAttribute("aria-pressed", String(!userPaused));
      const label = userPaused ? "Resume auto-rotate" : "Pause auto-rotate";
      btn.setAttribute("aria-label", label); btn.title = label;
      const icon = userPaused ? ICON_PLAY : ICON_PAUSE;
      if ($("rotIcon").dataset.icon !== icon) { $("rotIcon").innerHTML = icon; $("rotIcon").dataset.icon = icon; }
    }

    function toggle() {
      userPaused = !userPaused;
      try { localStorage.setItem(PAUSED_KEY, String(userPaused)); } catch { }
      idleUntil = 0; wasWaiting = false;
      restartDwell(); render();
    }

    // Real user input pauses rotation for a while (the play/pause button handles itself).
    function interacted(e) {
      if (!active() || pauseSec === 0) return;
      if (e.target.closest?.("#rotToggle")) return;
      idleUntil = Date.now() + pauseSec * 1000;
      render();
    }
    for (const ev of ["pointerdown", "keydown", "wheel", "touchstart"])
      document.addEventListener(ev, interacted, { capture: true, passive: true });

    $("rotToggle").addEventListener("click", toggle);
    setInterval(tick, 250);

    return { configure, restartDwell, render };
  })();

  // ---------------------------------------------------------------- live updates
  let conn = null;
  function watch(prev, next) {
    if (!conn || conn.state !== "Connected") return;
    if (prev) conn.invoke("Unwatch", prev.id).catch(() => {});
    if (next) conn.invoke("Watch", next.id).catch(() => {});
  }

  function onRefreshed(st) {
    const t = [...tabs.values()].find(x => x.id.toLowerCase() === String(st?.id).toLowerCase());
    if (t) applyStatus(t, st, true);
  }

  function onDataChanged(id) {
    const t = [...tabs.values()].find(x => x.id.toLowerCase() === String(id).toLowerCase());
    if (!t) return;
    if (t === T) load(t);
    else { t.dirty = true; renderTabs(); }   // fetched when the tab is opened
  }

  async function onConfigChanged() {
    try {
      for (const t of tabs.values()) { t.cfg = null; t.loaded = false; }   // refetch on next view, no "updated" dot
      await loadTabList();
      await activate(T && tabs.has(T.id) ? T.id : decodeURIComponent(location.hash.slice(1)));
    } catch (err) { console.warn(err); }
  }

  function setLive(state, label) { $("live").dataset.state = state; $("liveText").textContent = label; }

  // Fallback when SignalR is unavailable: the browser polls the active tab at
  // that tab's refresh interval (but not faster than MIN_FALLBACK_POLL_MS).
  let pollTimer = null;
  const pollMs = () => Math.max(MIN_FALLBACK_POLL_MS, T?.cfg?.refreshMs || 5000);
  function startPolling() {
    if (pollTimer) return;
    const ms = pollMs();
    setLive("polling", `Polling every ${secs(ms)}`);
    pollTimer = setInterval(() => { if (T?.cfg) { load(T); loadStatus(T); } }, ms);
  }
  function stopPolling() { clearInterval(pollTimer); pollTimer = null; }
  function restartPolling() { stopPolling(); startPolling(); }

  async function connect() {
    if (!window.signalR) { startPolling(); return; }
    conn = new signalR.HubConnectionBuilder()
      .withUrl("hubs/dashboard")
      .withAutomaticReconnect([0, 2000, 5000, 10000, 30000])
      .build();

    conn.on("dataChanged", onDataChanged);
    conn.on("configChanged", onConfigChanged);
    conn.on("refreshed", onRefreshed);
    conn.onreconnecting(() => { setLive("offline", "Reconnecting…"); startPolling(); });
    conn.onreconnected(() => {
      stopPolling(); setLive("live", "Live");
      watch(null, T);                                                // groups don't survive a reconnect
      for (const t of tabs.values()) if (t !== T) t.dirty = true;   // may have missed changes
      renderTabs(); if (T?.cfg) load(T);
    });
    conn.onclose(() => { setLive("offline", "Disconnected"); startPolling(); setTimeout(connect, 10000); });

    try {
      await conn.start();
      stopPolling();
      setLive("live", "Live");
      watch(null, T);
      if (T?.cfg) { load(T); loadStatus(T); }
    } catch {
      startPolling();
      setTimeout(connect, 10000);
    }
  }

  (async () => {
    try { await loadTabList(); }
    catch (err) { showError(`Couldn't load dashboards: ${err.message}`); return; }
    await activate(decodeURIComponent(location.hash.slice(1)));
    connect();
  })();
})();
