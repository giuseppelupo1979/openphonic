"use strict";
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const view = $("#view");
let caps = null;
let pollTimer = null;

const h = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmtBytes = (b) => b > 1e6 ? (b / 1e6).toFixed(1) + " MB" : b > 1e3 ? (b / 1e3).toFixed(0) + " KB" : b + " B";
const fmtTime = (t) => {
  t = Math.max(0, t || 0);
  const hh = Math.floor(t / 3600), mm = Math.floor(t / 60) % 60, ss = Math.floor(t % 60);
  return (hh ? hh + ":" + String(mm).padStart(2, "0") : mm) + ":" + String(ss).padStart(2, "0");
};
const clone = (o) => JSON.parse(JSON.stringify(o));
function deepMerge(base, over) {
  const out = clone(base);
  for (const [k, v] of Object.entries(over || {})) {
    out[k] = v && typeof v === "object" && !Array.isArray(v) && out[k] && typeof out[k] === "object" ? deepMerge(out[k], v) : clone(v);
  }
  return out;
}
function toast(msg) {
  const t = document.createElement("div");
  t.className = "toast"; t.textContent = msg; document.body.append(t);
  setTimeout(() => t.remove(), 3000);
}
async function api(path, opts = {}) {
  const r = await fetch(path, opts);
  if (!r.ok) {
    let msg = r.statusText;
    try { const j = await r.json(); msg = typeof j.detail === "string" ? j.detail : JSON.stringify(j.detail); } catch {}
    throw new Error(msg);
  }
  return r.json();
}

/* ------------------------------------------------------------------ router */
async function route() {
  clearInterval(pollTimer);
  if (!caps) caps = await api("api/capabilities");
  const [, page, id] = location.hash.split("/");
  $$("nav a").forEach((a) => a.classList.toggle("on", a.dataset.nav === (page || "new")));
  if (page === "productions") return renderList();
  if (page === "p" && id) return renderDetail(id);
  if (page === "api") return renderApi();
  return renderNew(page === "edit" ? id : null);
}
addEventListener("hashchange", route);

/* ------------------------------------------------------------------ new production */
const state = { mode: "single", tracks: [], reprocess: null };

function setField(form, name, value) {
  const el = form.elements[name];
  if (!el) return;
  if (el.type === "checkbox") el.checked = !!value;
  else el.value = value ?? "";
  const out = $(`output[data-for="${name}"]`, form);
  if (out) out.textContent = value + "%";
}
function fillForm(form, s) {
  const walk = (obj, prefix) => {
    for (const [k, v] of Object.entries(obj)) {
      const name = prefix ? prefix + "." + k : k;
      if (v && typeof v === "object" && !Array.isArray(v)) walk(v, name);
      else if (!Array.isArray(v)) setField(form, name, v);
    }
  };
  walk(s, "");
  $("#outputs").innerHTML = "";
  s.outputs.forEach(addOutputRow);
  $("#chapters").innerHTML = "";
  s.chapters.forEach(addChapterRow);
}
function readForm(form) {
  const s = clone(caps.defaults);
  for (const el of form.elements) {
    if (!el.name || el.closest(".row")) continue;
    const path = el.name.split(".");
    let o = s;
    path.slice(0, -1).forEach((p) => (o = o[p]));
    const key = path.at(-1);
    const cur = o[key];
    if (el.type === "checkbox") o[key] = el.checked;
    else if (typeof cur === "number") o[key] = parseFloat(el.value);
    else o[key] = el.value;
  }
  s.outputs = $$("#outputs .row").map((r) => ({
    format: $("[data-k=format]", r).value,
    bitrate: parseInt($("[data-k=bitrate]", r).value, 10),
    channels: $("[data-k=channels]", r).value,
    sample_rate: parseInt($("[data-k=sample_rate]", r).value, 10),
  }));
  s.chapters = $$("#chapters .row").map((r) => ({ start: $("[data-k=start]", r).value.trim(), title: $("[data-k=title]", r).value.trim() }))
    .filter((c) => c.start !== "" && c.title);
  s.tracks = state.mode === "multi" ? state.tracks.map((t) => ({ role: t.role, process: true }))
    : [{ role: $("#content").value, process: true }];
  return s;
}

function addOutputRow(o = { format: "mp3", bitrate: 128, channels: "keep", sample_rate: 0 }) {
  const row = document.createElement("div");
  row.className = "row output-row";
  const opt = (vals, cur) => vals.map(([v, l]) => `<option value="${v}" ${String(v) === String(cur) ? "selected" : ""}>${l}</option>`).join("");
  row.innerHTML = `
    <select data-k="format">${opt([["mp3", "MP3"], ["aac", "AAC (M4A)"], ["opus", "Opus"], ["ogg", "Ogg Vorbis"], ["flac", "FLAC"], ["wav", "WAV 24-bit"], ["video", "Video MP4"]], o.format)}</select>
    <select data-k="bitrate">${opt([[32, "32 kbps"], [48, "48 kbps"], [64, "64 kbps"], [96, "96 kbps"], [128, "128 kbps"], [160, "160 kbps"], [192, "192 kbps"], [256, "256 kbps"], [320, "320 kbps"]], o.bitrate)}</select>
    <select data-k="channels">${opt([["keep", "Canali: originali"], ["mono", "Mono"], ["stereo", "Stereo"]], o.channels)}</select>
    <select data-k="sample_rate">${opt([[0, "48 kHz"], [44100, "44.1 kHz"], [22050, "22 kHz"]], o.sample_rate)}</select>
    <button type="button" title="Rimuovi">×</button>`;
  const fmt = $("[data-k=format]", row), br = $("[data-k=bitrate]", row);
  const sync = () => (br.disabled = ["flac", "wav"].includes(fmt.value));
  fmt.onchange = sync; sync();
  $("button", row).onclick = () => row.remove();
  $("#outputs").append(row);
}
function addChapterRow(c = { start: "", title: "" }) {
  const row = document.createElement("div");
  row.className = "row chapter-row";
  row.innerHTML = `<input data-k="start" placeholder="00:00:00" value="${h(c.start)}"><input data-k="title" placeholder="Titolo capitolo" value="${h(c.title)}"><button type="button" title="Rimuovi">×</button>`;
  $("button", row).onclick = () => row.remove();
  $("#chapters").append(row);
}

function renderTracks() {
  const ul = $("#tracklist");
  ul.innerHTML = "";
  state.tracks.forEach((t, i) => {
    const li = document.createElement("li");
    li.innerHTML = `<span class="name">${h(t.file.name)} <span class="muted">· ${fmtBytes(t.file.size)}</span></span>
      ${state.mode === "multi" ? `<select><option value="speech">Voce</option><option value="music">Musica</option></select>` : ""}
      <button type="button" title="Rimuovi">×</button>`;
    const sel = $("select", li);
    if (sel) { sel.value = t.role; sel.onchange = () => (t.role = sel.value); }
    $("button", li).onclick = () => { state.tracks.splice(i, 1); renderTracks(); };
    ul.append(li);
  });
  const t = $("input[name='metadata.title']");
  if (t && !t.value && state.tracks[0]) t.placeholder = state.tracks[0].file.name.replace(/\.[^.]+$/, "");
}
function addFiles(list) {
  for (const f of list) {
    if (state.mode !== "multi") state.tracks = [];
    state.tracks.push({ file: f, role: state.mode === "multi" && /music|musica|jingle|bed/i.test(f.name) ? "music" : "speech" });
  }
  renderTracks();
}

async function loadPresets(select, form) {
  const p = await api("api/presets");
  select.innerHTML = `<optgroup label="Predefiniti">${Object.keys(p.builtin).map((n) => `<option value="b:${h(n)}">${h(n)}</option>`).join("")}</optgroup>` +
    (Object.keys(p.user).length ? `<optgroup label="I miei preset">${Object.keys(p.user).map((n) => `<option value="u:${h(n)}">${h(n)}</option>`).join("")}</optgroup>` : "");
  select.onchange = () => {
    const [kind, ...rest] = select.value.split(":");
    const name = rest.join(":");
    const s = kind === "b" ? deepMerge(caps.defaults, p.builtin[name]) : deepMerge(caps.defaults, p.user[name]);
    const keepMeta = readForm(form).metadata;
    fillForm(form, { ...s, metadata: keepMeta, chapters: readForm(form).chapters });
    $("#content").value = s.tracks?.[0]?.role || "speech";
    $("#del-preset").hidden = kind !== "u";
  };
  return p;
}

async function renderNew(editId) {
  view.innerHTML = "";
  view.append($("#tpl-new").content.cloneNode(true));
  const form = $("#form");
  state.tracks = []; state.mode = "single"; state.reprocess = null;
  let initial = clone(caps.defaults);
  if (editId) {
    const job = await api(`api/productions/${editId}`);
    initial = job.settings;
    state.reprocess = job;
    $(".inputs h2").innerHTML = `Rielabora: ${h(job.title)} <span class="muted" style="font-weight:400;font-size:.85rem">· i file originali vengono riusati</span>`;
    $("#mode").hidden = true; $("#drop").hidden = true;
    $$(".extras").forEach((e) => (e.hidden = true));
    $$(".inputs h3")[0].hidden = true;
    $("#start").textContent = "Rielabora con queste impostazioni";
  }
  fillForm(form, initial);
  if (initial.tracks?.length === 1) $("#content").value = initial.tracks[0].role;
  if (!caps.speech_recognition) { $("#asr-missing").hidden = false; }

  $$("#mode button").forEach((b) => (b.onclick = () => {
    state.mode = b.dataset.mode;
    $$("#mode button").forEach((x) => x.classList.toggle("on", x === b));
    $("#drop").hidden = state.mode === "url";
    $("#urlbox").hidden = state.mode !== "url";
    $("#multi-opts").hidden = state.mode !== "multi";
    $("#content-type").hidden = state.mode === "multi";
    $("#files").multiple = state.mode === "multi";
    if (state.mode !== "multi" && state.tracks.length > 1) state.tracks = state.tracks.slice(0, 1);
    renderTracks();
  }));
  const drop = $("#drop");
  $("#files").onchange = (e) => { addFiles(e.target.files); e.target.value = ""; };
  drop.ondragover = (e) => { e.preventDefault(); drop.classList.add("over"); };
  drop.ondragleave = () => drop.classList.remove("over");
  drop.ondrop = (e) => { e.preventDefault(); drop.classList.remove("over"); addFiles(e.dataTransfer.files); };
  $$(".file-pill input").forEach((inp) => (inp.onchange = () => {
    const pill = inp.closest(".file-pill");
    pill.classList.toggle("has", !!inp.files[0]);
    $("em", pill).textContent = inp.files[0] ? inp.files[0].name : "nessuno";
  }));
  $("input[name='leveler.strength']").oninput = (e) => ($("output[data-for='leveler.strength']").textContent = e.target.value + "%");
  $("#add-output").onclick = () => addOutputRow();
  $("#add-chapter").onclick = () => addChapterRow();

  const presetSel = $("#preset");
  await loadPresets(presetSel, form);
  if (!editId) presetSel.value = presetSel.options[0].value;
  else presetSel.selectedIndex = -1;
  $("#save-preset").onclick = async () => {
    const name = prompt("Nome del preset:");
    if (!name) return;
    const s = readForm(form);
    s.metadata = caps.defaults.metadata; s.chapters = [];
    await api("api/presets", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name, settings: s }) });
    await loadPresets(presetSel, form);
    presetSel.value = "u:" + name; $("#del-preset").hidden = false;
    toast("Preset salvato");
  };
  $("#del-preset").onclick = async () => {
    const name = presetSel.value.slice(2);
    if (!confirm(`Eliminare il preset “${name}”?`)) return;
    await api(`api/presets/${encodeURIComponent(name)}`, { method: "DELETE" });
    await loadPresets(presetSel, form);
    $("#del-preset").hidden = true;
  };

  form.onsubmit = async (e) => {
    e.preventDefault();
    const s = readForm(form);
    if (!s.outputs.length) return toast("Aggiungi almeno un formato in uscita");
    if (state.reprocess) {
      try {
        await api(`api/productions/${state.reprocess.id}/reprocess`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ settings: s }) });
        location.hash = `#/p/${state.reprocess.id}`;
      } catch (err) { toast(err.message); }
      return;
    }
    const url = $("#url").value.trim();
    if (state.mode === "url" ? !url : !state.tracks.length) return toast(state.mode === "url" ? "Inserisci un URL" : "Scegli un file da elaborare");
    const fd = new FormData();
    fd.append("settings", JSON.stringify(s));
    fd.append("title", s.metadata.title || "");
    if (state.mode === "url") fd.append("url", url);
    else state.tracks.forEach((t) => fd.append("tracks", t.file, t.file.name));
    for (const k of ["intro", "outro", "cover"]) if ($("#" + k).files[0]) fd.append(k, $("#" + k).files[0]);
    upload(fd);
  };
}

function upload(fd) {
  const btn = $("#start"), bar = $("#upbar");
  btn.disabled = true; bar.hidden = false;
  const xhr = new XMLHttpRequest();
  xhr.open("POST", "api/productions");
  xhr.upload.onprogress = (e) => {
    if (!e.lengthComputable) return;
    const p = (e.loaded / e.total) * 100;
    $("div", bar).style.width = p + "%";
    $("span", bar).textContent = p < 100 ? `Caricamento ${p.toFixed(0)}% · ${fmtBytes(e.loaded)} di ${fmtBytes(e.total)}` : "Avvio elaborazione…";
  };
  xhr.onload = () => {
    btn.disabled = false;
    if (xhr.status >= 200 && xhr.status < 300) location.hash = `#/p/${JSON.parse(xhr.responseText).id}`;
    else { bar.hidden = true; let m = xhr.statusText; try { m = JSON.parse(xhr.responseText).detail; } catch {} toast("Errore: " + m); }
  };
  xhr.onerror = () => { btn.disabled = false; bar.hidden = true; toast("Errore di rete durante il caricamento"); };
  xhr.send(fd);
}

/* ------------------------------------------------------------------ list */
const STATUS = { uploading: "Caricamento", queued: "In coda", processing: "In elaborazione", done: "Completata", error: "Errore" };
async function renderList() {
  const draw = async () => {
    const items = await api("api/productions");
    if (!location.hash.startsWith("#/productions")) return;
    if (!items.length) {
      view.innerHTML = `<div class="card empty"><h2>Nessuna produzione</h2><p>Carica il tuo primo file audio per iniziare.</p><p><a href="#/new"><button class="primary">Nuova produzione</button></a></p></div>`;
      return;
    }
    view.innerHTML = `<h1>Produzioni</h1><div class="list">${items.map((j) => `
      <a class="card prod" href="#/p/${j.id}">
        <div><div class="t">${h(j.title)}</div><div class="d">${new Date(j.created * 1000).toLocaleString()}</div></div>
        <div>${j.status === "done" || j.status === "error" ? `<span class="d">${h(j.status === "error" ? j.error : "")}</span>` : `<div class="d">${h(j.step)}</div><div class="bar"><div style="width:${j.progress}%"></div></div>`}</div>
        <span class="status ${j.status}">${STATUS[j.status] || j.status}</span>
      </a>`).join("")}</div>`;
    clearInterval(pollTimer);
    if (items.some((j) => ["queued", "processing", "uploading"].includes(j.status))) pollTimer = setInterval(draw, 2000);
  };
  await draw();
}

/* ------------------------------------------------------------------ detail */
async function renderDetail(id) {
  let job;
  try { job = await api(`api/productions/${id}`); } catch (e) { view.innerHTML = `<div class="card empty">${h(e.message)}</div>`; return; }
  const head = `
    <div class="detail-head">
      <div><h1>${h(job.title)}</h1><span class="status ${job.status}">${STATUS[job.status] || job.status}</span>
      <span class="muted" style="font-size:.85rem;margin-left:8px">${new Date(job.created * 1000).toLocaleString()}</span></div>
      <div class="actions">
        ${["done", "error"].includes(job.status) ? `<a href="#/edit/${id}"><button>Modifica e rielabora</button></a>` : ""}
        ${job.status !== "processing" ? `<button class="danger" id="del">Elimina</button>` : ""}
      </div>
    </div>`;
  if (job.status !== "done") {
    view.innerHTML = head + (job.status === "error"
      ? `<div class="card"><h2>Elaborazione non riuscita</h2><pre class="err">${h(job.error)}</pre></div>`
      : `<div class="card running"><h2>${h(job.step)}</h2><div class="bar"><div style="width:${job.progress}%"></div></div><div class="muted">${job.progress.toFixed(0)}%</div></div>`);
    bindDelete(id);
    if (job.status !== "error") pollTimer = setTimeout(() => location.hash === `#/p/${id}` && renderDetail(id), 1200);
    return;
  }
  const r = job.result, b = r.before, a = r.after;
  const file = (n) => `api/productions/${id}/files/${encodeURIComponent(n)}`;
  const row = (label, k, unit, better) => {
    const d = a[k] - b[k];
    return `<tr><td>${label}</td><td>${b[k] ?? "–"} ${unit}</td><td class="after">${a[k] ?? "–"} ${unit}${better && Math.abs(d) >= 0.5 ? `<span class="delta">${d > 0 ? "+" : ""}${d.toFixed(1)}</span>` : ""}</td></tr>`;
  };
  const media = r.files.filter((f) => !["txt", "srt", "vtt", "json"].includes(f.format));
  const subs = r.files.filter((f) => ["txt", "srt", "vtt", "json"].includes(f.format));
  view.innerHTML = head + `
  <div class="two">
    <div class="stack">
      <section class="card">
        <h2>Ascolta il risultato</h2>
        <div class="wave-label"><i style="background:var(--before)"></i>Prima · originale</div>
        <canvas class="wave" id="wb"></canvas>
        <div class="wave-label"><i style="background:var(--after)"></i>Dopo · OpenPhonic</div>
        <canvas class="wave" id="wa"></canvas>
        <div class="player">
          <button class="play" id="play" aria-label="Play"><svg width="18" height="18" viewBox="0 0 24 24"><path id="pi" d="M7 4v16l13-8z" fill="currentColor"/></svg></button>
          <div class="ab"><button data-ab="before">Prima</button><button data-ab="after" class="on">Dopo</button></div>
          <span class="time" id="time">0:00 / ${fmtTime(a.duration)}</span>
        </div>
        <audio id="aud-before" preload="metadata" src="${file("_preview_before.mp3")}?inline=1"></audio>
        <audio id="aud-after" preload="metadata" src="${file("_preview_after.mp3")}?inline=1"></audio>
      </section>
      <section class="card spec">
        <h2>Spettrogramma</h2>
        <div class="wave-label"><i style="background:var(--before)"></i>Prima</div>
        <img src="${file("spectrum_before.png")}?inline=1" alt="Spettrogramma prima" loading="lazy">
        <div class="wave-label"><i style="background:var(--after)"></i>Dopo</div>
        <img src="${file("spectrum_after.png")}?inline=1" alt="Spettrogramma dopo" loading="lazy">
      </section>
      ${subs.length ? `<section class="card"><h2>Trascrizione</h2><div class="transcript" id="transcript"><span class="muted">Caricamento…</span></div></section>` : ""}
    </div>
    <div class="stack">
      <section class="card">
        <h2>Download</h2>
        <div class="files">${[...media, ...subs].map((f) => `<a class="file" href="${file(f.name)}" download><span class="fmt">${h(f.name.split(".").pop())}</span><span class="fn">${h(f.name)}</span><span class="sz">${fmtBytes(f.size)}</span></a>`).join("")}</div>
      </section>
      <section class="card">
        <h2>Statistiche audio</h2>
        <table class="stats"><thead><tr><th></th><th>Prima</th><th>Dopo</th></tr></thead><tbody>
          ${row("Loudness integrata", "integrated_lufs", "LUFS")}
          ${row("True peak", "true_peak_dbtp", "dBTP")}
          ${row("Loudness range", "lra_lu", "LU")}
          ${row("Rumore di fondo", "noise_floor_db", "dBFS")}
          ${row("Rapporto segnale/rumore", "snr_db", "dB", true)}
          ${row("Durata", "duration", "s")}
        </tbody></table>
        <p class="muted" style="font-size:.85rem;margin:12px 0 0">Elaborata in ${r.processing_seconds} s · ${r.input.tracks} tracc${r.input.tracks > 1 ? "e" : "ia"} · ${h(r.input.codec)} ${r.input.sample_rate / 1000} kHz ${r.input.channels > 1 ? "stereo" : "mono"}${r.input.has_video ? " · video" : ""}</p>
      </section>
      <section class="card">
        <h2>Cosa è stato fatto</h2>
        <ul class="notes">${r.warnings.map((w) => `<li class="w">${h(w)}</li>`).join("")}${r.notes.map((n) => `<li>${h(n)}</li>`).join("") || "<li>Nessun intervento necessario</li>"}
</ul>
      </section>
      ${r.chapters.length ? `<section class="card"><h2>Capitoli</h2><ul class="chapters-list">${r.chapters.map((c) => `<li data-t="${c.start}"><time>${fmtTime(c.start)}</time>${h(c.title)}</li>`).join("")}</ul></section>` : ""}
    </div>
  </div>`;
  bindDelete(id);
  setupPlayer(b, a);
  const json = subs.find((f) => f.format === "json");
  if (json) {
    const t = await api(file(json.name) + "?inline=1");
    $("#transcript").innerHTML = t.segments.map((s) => `<p><time data-t="${s.start}">${fmtTime(s.start)}</time>${h(s.text)}</p>`).join("") || "<span class='muted'>Nessun parlato rilevato</span>";
  }
}

function bindDelete(id) {
  const d = $("#del");
  if (d) d.onclick = async () => {
    if (!confirm("Eliminare definitivamente questa produzione e i suoi file?")) return;
    await api(`api/productions/${id}`, { method: "DELETE" });
    location.hash = "#/productions";
  };
}

function setupPlayer(before, after) {
  const auds = { before: $("#aud-before"), after: $("#aud-after") };
  let cur = "after";
  const canv = { before: $("#wb"), after: $("#wa") };
  const css = getComputedStyle(document.documentElement);
  const draw = (c, peaks, color, frac) => {
    const dpr = devicePixelRatio || 1, w = c.clientWidth, hh = c.clientHeight;
    c.width = w * dpr; c.height = hh * dpr;
    const g = c.getContext("2d"); g.scale(dpr, dpr);
    const n = peaks.length, mid = hh / 2;
    for (let x = 0; x < w; x++) {
      const v = peaks[Math.floor((x / w) * n)] || 0;
      g.fillStyle = x / w <= frac ? color : color + "66";
      const y = Math.max(0.5, v * (mid - 4));
      g.fillRect(x, mid - y, 1, y * 2);
    }
  };
  const redraw = () => {
    const ad = auds[cur];
    const frac = ad.duration ? ad.currentTime / ad.duration : 0;
    draw(canv.before, before.peaks, css.getPropertyValue("--before").trim(), cur === "before" ? frac : 0);
    draw(canv.after, after.peaks, css.getPropertyValue("--after").trim(), cur === "after" ? frac : 0);
    $("#time").textContent = `${fmtTime(ad.currentTime)} / ${fmtTime(ad.duration || 0)}`;
  };
  const setIcon = (playing) => $("#pi").setAttribute("d", playing ? "M6 4h4v16H6zM14 4h4v16h-4z" : "M7 4v16l13-8z");
  $("#play").onclick = () => { const ad = auds[cur]; ad.paused ? ad.play() : ad.pause(); };
  for (const ad of Object.values(auds)) {
    ad.ontimeupdate = redraw; ad.onloadedmetadata = redraw;
    ad.onplay = () => setIcon(true); ad.onpause = () => setIcon(false); ad.onended = () => setIcon(false);
  }
  const switchTo = (k) => {
    if (k === cur) return;
    const from = auds[cur], to = auds[k], playing = !from.paused;
    const frac = from.duration ? from.currentTime / from.duration : 0;
    from.pause();
    to.currentTime = frac * (to.duration || 0);
    cur = k;
    $$(".ab button").forEach((b) => b.classList.toggle("on", b.dataset.ab === k));
    if (playing) to.play();
    redraw();
  };
  $$(".ab button").forEach((b) => (b.onclick = () => switchTo(b.dataset.ab)));
  for (const [k, c] of Object.entries(canv)) {
    c.onclick = (e) => {
      switchTo(k);
      const ad = auds[k], rect = c.getBoundingClientRect();
      if (ad.duration) ad.currentTime = ((e.clientX - rect.left) / rect.width) * ad.duration;
      redraw();
    };
  }
  const seekAfter = (t) => { switchTo("after"); auds.after.currentTime = t; auds.after.play(); };
  view.onclick = (e) => {
    const t = e.target.closest("[data-t]");
    if (t) seekAfter(parseFloat(t.dataset.t));
  };
  onresize = redraw;
  redraw();
}

/* ------------------------------------------------------------------ API docs */
function renderApi() {
  const base = (location.origin + location.pathname).replace(/\/$/, "");
  view.innerHTML = `<div class="card" style="max-width:860px">
    <h1>API REST</h1>
    <p>Tutto ciò che fa l'interfaccia è disponibile via HTTP. Se il server è protetto da password, usa <code>-u utente:PASSWORD</code> oppure l'header <code>Authorization: Bearer PASSWORD</code>. Documentazione interattiva completa su <a href="docs">/docs</a>.</p>
    <h3>Crea una produzione</h3>
<pre class="code">curl -X POST ${base}/api/productions \\
  -F tracks=@episodio.wav \\
  -F cover=@copertina.jpg \\
  -F 'settings={"loudness":{"target":-16},"denoise":{"method":"both"},
      "cutting":{"silence":true},"speech":{"enabled":true,"language":"it"},
      "metadata":{"title":"Episodio 12"},
      "outputs":[{"format":"mp3","bitrate":128},{"format":"flac"}]}'</pre>
    <h3>Stato e risultato</h3>
<pre class="code">curl ${base}/api/productions/ID</pre>
    <h3>Scarica un file</h3>
<pre class="code">curl -O ${base}/api/productions/ID/files/Episodio_12.mp3</pre>
    <h3>Rielabora con altre impostazioni</h3>
<pre class="code">curl -X POST ${base}/api/productions/ID/reprocess \\
  -H 'Content-Type: application/json' -d '{"settings":{"loudness":{"target":-23}}}'</pre>
    <h3>Impostazioni predefinite</h3>
<pre class="code">${h(JSON.stringify(caps.defaults, null, 2))}</pre>
  </div>`;
}

route();
