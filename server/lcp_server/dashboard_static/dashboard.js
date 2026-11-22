(() => {
  "use strict";

  const state = { records: [], filter: "all", query: "", selected: null };
  const $ = (selector) => document.querySelector(selector);
  const escapeHTML = (value) => String(value ?? "").replace(/[&<>'"]/g, (char) => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[char]));
  const number = (value, digits = 0) => Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : "—";
  const duration = (seconds) => {
    const total = Math.max(0, Math.round(Number(seconds) || 0));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const remaining = total % 60;
    return hours ? `${hours}h ${String(minutes).padStart(2, "0")}m` : `${minutes}m ${String(remaining).padStart(2, "0")}s`;
  };
  const date = (value) => {
    if (!value) return { day: "—", time: "" };
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) return { day: value, time: "" };
    return { day: parsed.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }), time: parsed.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" }) };
  };
  const ago = (value) => {
    if (!value) return "No sync recorded";
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) return "Last sync unavailable";
    const seconds = Math.max(0, (Date.now() - parsed.getTime()) / 1000);
    if (seconds < 60) return "Updated just now";
    if (seconds < 3600) return `Updated ${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `Updated ${Math.floor(seconds / 3600)}h ago`;
    return `Updated ${Math.floor(seconds / 86400)}d ago`;
  };
  const label = (value) => ({ published: "Published", blocked: "Blocked", review: "Review", ready: "Local only", processing: "Processing", error: "Error", pass: "Pass", warn: "Review", unknown: "Unknown", indexed: "Indexed", local: "Local only" }[value] || value || "Unknown");

  function setLoading(loading) {
    $("#loading-state").hidden = !loading;
    if (loading) { $("#empty-state").hidden = true; $("#error-state").hidden = true; }
  }

  function matchesFilter(record) {
    if (state.filter === "published") return record.status === "published";
    if (state.filter === "blocked") return record.status === "blocked";
    if (state.filter === "review") return record.status !== "blocked" && (record.quality?.relevance === "needs_review" || record.quality?.status === "warn");
    return true;
  }

  function visibleRecords() {
    const query = state.query.trim().toLowerCase();
    return state.records.filter((record) => matchesFilter(record) && (!query || `${record.course} ${record.filename}`.toLowerCase().includes(query)));
  }

  function showError(error) {
    setLoading(false);
    $("#error-state").hidden = false;
    $("#error-message").textContent = error?.message || "Retry when the worker is reachable.";
    $("#api-state").textContent = "API OFFLINE";
    $(".status-dot").style.background = "var(--coral)";
  }

  function updateSummary(payload) {
    const summary = payload.summary || {};
    $("#metric-total").textContent = summary.total ?? 0;
    $("#metric-published").textContent = summary.published ?? 0;
    $("#metric-review").textContent = summary.review ?? 0;
    $("#metric-blocked").textContent = summary.blocked ?? 0;
    $("#filter-all").textContent = summary.total ?? 0;
    $("#filter-published").textContent = summary.published ?? 0;
    $("#filter-review").textContent = summary.review ?? 0;
    $("#filter-blocked").textContent = summary.blocked ?? 0;
    $("#ledger-count").textContent = `${summary.total ?? 0} jobs`;
    $("#last-sync").textContent = ago(summary.last_change || payload.generated_at);
    $("#footer-updated").textContent = payload.generated_at ? `DATA REFRESHED ${new Date(payload.generated_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" })}` : "—";
  }

  function renderRows() {
    const records = visibleRecords();
    const body = $("#transcript-rows");
    body.innerHTML = records.map((record) => {
      const when = date(record.recorded_at);
      const quality = record.quality || {};
      const qualityStatus = quality.status === "blocked" || record.status === "blocked" ? "blocked" : quality.status === "warn" ? "warn" : quality.status === "pass" ? "pass" : "unknown";
      const delivery = record.delivery || "local";
      const signal = record.status === "blocked" || qualityStatus === "blocked" ? "blocked" : qualityStatus === "warn" || record.status === "ready" ? "review" : "";
      return `<tr tabindex="0" data-id="${escapeHTML(record.id)}">
        <td><div class="recording-cell"><span class="signal-rail ${signal}" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span><span class="recording-name"><strong title="${escapeHTML(record.filename)}">${escapeHTML(record.course)}</strong><span title="${escapeHTML(record.filename)}">${escapeHTML(record.filename)}</span></span></div></td>
        <td class="date-cell">${escapeHTML(when.day)}<small>${escapeHTML(when.time)}</small></td>
        <td class="duration-cell">${escapeHTML(duration(quality.duration_seconds))}</td>
        <td class="quality-cell"><span class="pill ${qualityStatus}">${escapeHTML(label(qualityStatus))}</span></td>
        <td class="delivery-cell"><span class="pill ${escapeHTML(delivery)}">${escapeHTML(label(delivery))}</span></td>
        <td><span class="row-arrow" aria-hidden="true">↗</span></td>
      </tr>`;
    }).join("");
    $("#empty-state").hidden = records.length !== 0;
    $("#error-state").hidden = true;
    body.querySelectorAll("tr").forEach((row) => {
      row.addEventListener("click", () => openDrawer(row.dataset.id));
      row.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); openDrawer(row.dataset.id); } });
    });
  }

  function renderDrawer(record) {
    const quality = record.quality || {};
    const status = record.status === "blocked" ? "blocked" : record.status === "published" ? "published" : record.status === "error" ? "error" : "processing";
    const warningItems = (quality.warnings || []).map((warning) => `<li class="${warning.blocking ? "blocking" : ""}"><strong>${escapeHTML(warning.code)}</strong><p>${escapeHTML(warning.message)}</p></li>`).join("");
    const artifacts = ["md", "txt", "srt"].map((suffix) => `<span class="artifact-chip ${record.artifacts?.[suffix] ? "ready" : "missing"}">${suffix.toUpperCase()} ${record.artifacts?.[suffix] ? "READY" : "MISSING"}</span>`).join("");
    const repair = record.repair || {};
    const repairAttempts = Number.isInteger(repair.attempts) ? repair.attempts : 0;
    const repairHistory = Array.isArray(repair.history) ? repair.history : [];
    const repairLabel = repairAttempts ? `${repairAttempts} automatic repair${repairAttempts === 1 ? "" : "s"} attempted` : "No automatic repair attempted";
    const repairBackend = repair.fallback_used ? `local Whisper · ${repair.fallback_settings?.vad_filter === false ? "VAD off" : "VAD on"}` : (repair.backend || "ElevenLabs primary");
    const repairTrail = repairHistory.length ? repairHistory.map((item) => `<span class="artifact-chip ready">attempt ${escapeHTML(item.attempt)} · ${(item.warning_codes || []).map(escapeHTML).join(", ") || "timestamp repair"}</span>`).join("") : "";
    const density = Math.max(0, Math.min(100, Number(quality.speech_density || 0) * 100));
    $("#detail-title").textContent = record.course || "Transcript detail";
    $("#drawer-content").innerHTML = `
      <p class="drawer-course">${escapeHTML(record.course)}</p>
      <p class="drawer-meta">${escapeHTML(record.filename)}<br>job ${escapeHTML(record.id.slice(0, 16))}…</p>
      <div class="detail-status"><div><strong>${escapeHTML(label(status))}</strong><small>${escapeHTML(record.stage || "Unknown stage")} · ${escapeHTML(label(record.delivery || "local"))}</small></div><span class="pill ${status}">${escapeHTML(label(status))}</span></div>
      <section class="detail-section"><h3>Signal profile</h3><div class="detail-metrics"><div class="detail-metric"><strong>${escapeHTML(duration(quality.duration_seconds))}</strong><span>duration</span></div><div class="detail-metric"><strong>${escapeHTML(number(quality.cue_count))}</strong><span>cues</span></div><div class="detail-metric"><strong>${escapeHTML(number(quality.speaker_count))}</strong><span>speakers</span></div></div><div class="detail-bar"><span style="width:${density}%"></span></div><div class="detail-bar-label"><span>speech density</span><span>${escapeHTML(number(density, 0))}%</span></div></section>
      <section class="detail-section"><h3>Delivery path</h3><div class="detail-metrics"><div class="detail-metric"><strong>${record.published ? "YES" : "NO"}</strong><span>Drive</span></div><div class="detail-metric"><strong>${record.grok_ingested ? "YES" : "—"}</strong><span>Grok</span></div><div class="detail-metric"><strong>${escapeHTML(number(quality.diarization_coverage * 100, 0))}%</strong><span>speaker map</span></div></div></section>
      <section class="detail-section"><h3>Repair trail</h3><p class="clean-note">${escapeHTML(repairLabel)} · ${escapeHTML(repairBackend)}</p>${repairTrail ? `<div class="artifact-list">${repairTrail}</div>` : ""}</section>
      <section class="detail-section"><h3>Artifacts</h3><div class="artifact-list">${artifacts}</div></section>
      <section class="detail-section"><h3>Quality findings</h3>${warningItems ? `<ul class="warning-list">${warningItems}</ul>` : `<p class="clean-note">No quality warnings are recorded for this transcript.</p>`}</section>
      ${record.last_error ? `<section class="detail-section"><h3>Last error</h3><p class="warning-list"><span class="warning-list"><li class="blocking"><strong>WORKER ERROR</strong><p>${escapeHTML(record.last_error)}</p></li></span></p></section>` : ""}
    `;
  }

  function openDrawer(id) {
    const record = state.records.find((item) => item.id === id);
    if (!record) return;
    state.selected = id;
    renderDrawer(record);
    $("#drawer-backdrop").hidden = false;
    $("#detail-drawer").hidden = false;
    $("#detail-drawer").classList.add("open");
    $("#detail-drawer").setAttribute("aria-hidden", "false");
    $("#detail-drawer").focus();
  }

  function closeDrawer() {
    $("#detail-drawer").classList.remove("open");
    $("#detail-drawer").setAttribute("aria-hidden", "true");
    $("#detail-drawer").hidden = true;
    $("#drawer-backdrop").hidden = true;
    state.selected = null;
  }

  async function load({ quiet = false } = {}) {
    if (!quiet) setLoading(true);
    try {
      const response = await fetch("/api/status", { cache: "no-store" });
      if (!response.ok) throw new Error(`API returned ${response.status}`);
      const payload = await response.json();
      const provider = $("#provider");
      provider.textContent = payload.service?.provider || "";
      provider.hidden = !provider.textContent;
      state.records = Array.isArray(payload.transcripts) ? payload.transcripts : [];
      $("#api-state").textContent = "API LIVE";
      $(".status-dot").style.background = "var(--mint)";
      updateSummary(payload);
      setLoading(false);
      renderRows();
      if (state.selected) {
        const selected = state.records.find((item) => item.id === state.selected);
        if (selected) renderDrawer(selected);
      }
    } catch (error) {
      showError(error);
    }
  }

  $("#refresh-button").addEventListener("click", () => { load(); const toast = $("#toast"); toast.textContent = "Transcript status refreshed"; toast.classList.add("show"); window.setTimeout(() => toast.classList.remove("show"), 2200); });
  $("#search").addEventListener("input", (event) => { state.query = event.target.value; renderRows(); });
  document.querySelectorAll(".filter-tab").forEach((button) => button.addEventListener("click", () => { state.filter = button.dataset.filter; document.querySelectorAll(".filter-tab").forEach((item) => { const active = item === button; item.classList.toggle("active", active); item.setAttribute("aria-selected", active ? "true" : "false"); }); renderRows(); }));
  $("#close-drawer").addEventListener("click", closeDrawer);
  $("#drawer-backdrop").addEventListener("click", closeDrawer);
  document.addEventListener("keydown", (event) => { if (event.key === "Escape" && state.selected) closeDrawer(); });
  load();
  window.setInterval(() => load({ quiet: true }), 30000);
})();
