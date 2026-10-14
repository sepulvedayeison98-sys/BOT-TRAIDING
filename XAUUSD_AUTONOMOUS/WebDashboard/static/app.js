// Dashboard web del XAUUSD Autonomous Trading System (sin dependencias).
// Lee /api/state cada 10 s; los comandos van con el token CSRF de la sesión.
"use strict";

const $ = (id) => document.getElementById(id);
let csrf = "";
let timer = null;
let pendingCmd = null;
let lastEquity = [];
let resizeTimer = null;
const SVG_NS = "http://www.w3.org/2000/svg";

function text(id, value) {
  const el = $(id);
  if (el) el.textContent = (value === undefined || value === null || value === "") ? "—" : String(value);
}

function fmtMoney(v, cur) {
  if (typeof v !== "number") return "—";
  return v.toLocaleString("es-CO", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + (cur ? " " + cur : "");
}

function fmtNum(v, digits) {
  return typeof v === "number" ? v.toLocaleString("es-CO", { minimumFractionDigits: digits, maximumFractionDigits: digits }) : "—";
}

function fmtPct(v) {
  return typeof v === "number" ? fmtNum(v, 2) + " %" : "—";
}

function fmtTime(epoch) {
  if (!epoch) return "—";
  return new Date(epoch * 1000).toLocaleString("es-CO", { hour12: false });
}

async function api(path, options = {}) {
  const opts = Object.assign({ credentials: "same-origin", headers: {} }, options);
  if (opts.method === "POST") {
    opts.headers["Content-Type"] = "application/json";
    if (csrf) opts.headers["X-XAD-CSRF"] = csrf;
  }
  const res = await fetch(path, opts);
  let data = {};
  try { data = await res.json(); } catch (e) { data = {}; }
  return { status: res.status, data };
}

function showLogin() {
  $("app").hidden = true;
  $("login").hidden = false;
  if (timer) { clearInterval(timer); timer = null; }
}

function showApp() {
  $("login").hidden = true;
  $("app").hidden = false;
  refresh();
  if (!timer) timer = setInterval(refresh, 10000);
}

// --- estado -------------------------------------------------------------
const STATE_STYLE = {
  RUNNING: ["state-good", "✓"],
  PAUSED: ["state-warning", "⏸"],
  DAILY_LIMIT: ["state-warning", "⚠"],
  SAFE_MODE: ["state-critical", "⛔"],
  HALTED: ["state-critical", "⛔"],
  INIT: ["", "…"],
};

function render(s) {
  const t = s.telemetry || {};
  const online = $("online");
  online.className = "badge " + (s.ea_online ? "ok" : "off");
  online.textContent = s.ea_online ? "EA en línea" : "EA sin reportar";
  text("subtitle", t.symbol ? `${t.symbol} · ${t.account_mode || ""} · último reporte ${fmtTime(s.last_seen)}` : "Sin datos del EA todavía");
  text("equity", fmtMoney(t.equity, t.currency));
  text("equity-sub", typeof t.balance === "number" ? "Balance " + fmtMoney(t.balance, t.currency) : "");
  const st = (t.state || "INIT").toUpperCase();
  const [cls, icon] = STATE_STYLE[st] || ["", "•"];
  $("state").className = cls;
  text("state", st);
  text("state-icon", icon);
  text("state-reason", t.state_reason);
  text("daily-loss", fmtPct(t.daily_loss_pct));
  text("daily-limit", typeof t.daily_limit_pct === "number" ? "límite " + fmtPct(t.daily_limit_pct) : "");
  const meter = $("daily-meter");
  if (typeof t.daily_loss_pct === "number" && t.daily_limit_pct > 0) {
    const ratio = Math.min(1, t.daily_loss_pct / t.daily_limit_pct);
    meter.style.width = (ratio * 100).toFixed(1) + "%";
    meter.className = ratio >= 1 ? "critical" : (ratio >= 0.66 ? "warning" : "");
  }
  text("daily-gain", fmtPct(t.daily_gain_pct));
  text("exposure", fmtPct(t.exposure_pct));
  text("exposure-sub", typeof t.risk_pct === "number" ? "riesgo por operación " + fmtPct(t.risk_pct) : "");
  text("positions", t.positions);
  text("drawdown", fmtPct(t.drawdown_pct));
  text("regime", t.regime);
  text("session", t.session ? "Sesión " + t.session : "");
  text("spread", typeof t.spread === "number" ? `${fmtNum(t.spread, 0)} pts (media ${fmtNum(t.spread_avg, 0)})` : "—");
  text("atr", fmtNum(t.atr_m15, 2));
  text("rsi", fmtNum(t.rsi_m15, 1));
  text("news", t.news);
  text("last-signal", t.last_signal);
  text("last-trade", t.last_trade);
  text("blocks", t.blocks);
  lastEquity = s.equity || [];
  renderChart(lastEquity);
  renderTable(s.equity || []);
  renderCommands(s.commands || [], s.allow_commands);
}

function renderCommands(rows, allowed) {
  document.querySelectorAll("#actions button").forEach((b) => { b.disabled = !allowed; });
  if (!allowed) text("cmd-msg", "Los comandos remotos están desactivados en el servidor.");
  const tbody = document.querySelector("#commands tbody");
  tbody.replaceChildren();
  rows.forEach((r) => {
    const tr = document.createElement("tr");
    const status = r.acked ? "aplicado " + fmtTime(r.acked) : (r.delivered ? "entregado, sin confirmar" : "pendiente");
    [r.id, r.cmd, fmtTime(r.created), status].forEach((v) => {
      const td = document.createElement("td");
      td.textContent = String(v);
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
}

// --- gráfico de equity (una serie: sin leyenda; el título la nombra) -----
function el(name, attrs) {
  const n = document.createElementNS(SVG_NS, name);
  Object.entries(attrs || {}).forEach(([k, v]) => n.setAttribute(k, v));
  return n;
}

function renderChart(points) {
  const box = $("chart");
  box.replaceChildren();
  if (points.length < 2) {
    const p = document.createElement("p");
    p.className = "muted";
    p.textContent = "Aún no hay suficientes reportes para dibujar la curva.";
    box.appendChild(p);
    return;
  }
  const W = box.clientWidth || 600, H = box.clientHeight || 220;
  const m = { l: 64, r: 12, t: 10, b: 24 };
  const xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
  const x0 = Math.min(...xs), x1 = Math.max(...xs);
  let y0 = Math.min(...ys), y1 = Math.max(...ys);
  if (y1 - y0 < 1e-9) { y0 -= 1; y1 += 1; }
  const pad = (y1 - y0) * 0.1; y0 -= pad; y1 += pad;
  const sx = (x) => m.l + (x - x0) / Math.max(1, x1 - x0) * (W - m.l - m.r);
  const sy = (y) => m.t + (1 - (y - y0) / (y1 - y0)) * (H - m.t - m.b);
  const svg = el("svg", { viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none" });
  for (let i = 0; i <= 3; i++) {
    const v = y0 + (y1 - y0) * i / 3;
    svg.appendChild(el("line", { class: "gridline", x1: m.l, x2: W - m.r, y1: sy(v), y2: sy(v) }));
    const lab = el("text", { class: "axis", x: m.l - 6, y: sy(v) + 4, "text-anchor": "end" });
    lab.textContent = v.toLocaleString("es-CO", { maximumFractionDigits: 0 });
    svg.appendChild(lab);
  }
  [x0, x1].forEach((x, i) => {
    const lab = el("text", { class: "axis", x: sx(x), y: H - 6, "text-anchor": i ? "end" : "start" });
    lab.textContent = new Date(x * 1000).toLocaleString("es-CO", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
    svg.appendChild(lab);
  });
  const d = points.map((p, i) => (i ? "L" : "M") + sx(p[0]).toFixed(1) + "," + sy(p[1]).toFixed(1)).join(" ");
  svg.appendChild(el("path", { class: "line", d }));
  const cross = el("line", { class: "cross", y1: m.t, y2: H - m.b, x1: -10, x2: -10 });
  const dot = el("circle", { class: "dot", r: 5, cx: -10, cy: -10 });
  svg.appendChild(cross);
  svg.appendChild(dot);
  const hit = el("rect", { x: m.l, y: 0, width: W - m.l - m.r, height: H, fill: "transparent" });
  svg.appendChild(hit);
  const tip = $("chart-tip");
  hit.addEventListener("mousemove", (ev) => {
    const rect = svg.getBoundingClientRect();
    const px = (ev.clientX - rect.left) * (W / rect.width);
    let best = 0;
    points.forEach((p, i) => { if (Math.abs(sx(p[0]) - px) < Math.abs(sx(points[best][0]) - px)) best = i; });
    const p = points[best];
    cross.setAttribute("x1", sx(p[0])); cross.setAttribute("x2", sx(p[0]));
    dot.setAttribute("cx", sx(p[0])); dot.setAttribute("cy", sy(p[1]));
    tip.hidden = false;
    tip.textContent = `${fmtTime(p[0])} · equity ${fmtMoney(p[1])}`;
    tip.style.left = (ev.clientX + 12) + "px";
    tip.style.top = (ev.clientY - 28) + "px";
  });
  hit.addEventListener("mouseleave", () => { tip.hidden = true; cross.setAttribute("x1", -10); cross.setAttribute("x2", -10); dot.setAttribute("cx", -10); });
  box.appendChild(svg);
}

function renderTable(points) {
  const tbody = document.querySelector("#equity-table tbody");
  tbody.replaceChildren();
  points.slice(-50).reverse().forEach((p) => {
    const tr = document.createElement("tr");
    [fmtTime(p[0]), fmtMoney(p[1])].forEach((v) => { const td = document.createElement("td"); td.textContent = v; tr.appendChild(td); });
    tbody.appendChild(tr);
  });
}

async function refresh() {
  const r = await api("/api/state");
  if (r.status === 401) return showLogin();
  if (r.status === 200) render(r.data);
}

// --- eventos --------------------------------------------------------------
document.addEventListener("DOMContentLoaded", async () => {
  const s = await api("/api/session");
  if (s.data.authenticated) { csrf = s.data.csrf; showApp(); } else showLogin();

  $("login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    text("login-error", "");
    const r = await api("/api/login", { method: "POST", body: JSON.stringify({ password: $("password").value }) });
    $("password").value = "";
    if (r.status === 200) { csrf = r.data.csrf; showApp(); }
    else $("login-error").textContent = r.data.error || "No se pudo entrar";
  });

  $("logout").addEventListener("click", async () => { await api("/api/logout", { method: "POST", body: "{}" }); csrf = ""; showLogin(); });

  $("toggle-table").addEventListener("click", () => {
    const t = $("equity-table");
    t.hidden = !t.hidden;
    $("toggle-table").textContent = t.hidden ? "Ver tabla" : "Ocultar tabla";
  });

  const labels = { PAUSE: "pausar las entradas nuevas", RESUME: "reanudar las entradas nuevas", SAFE_MODE: "activar el MODO SEGURO (salir de él solo es posible desde MT5)" };
  document.querySelectorAll("#actions button").forEach((b) => b.addEventListener("click", () => {
    pendingCmd = b.dataset.cmd;
    $("confirm-text").textContent = `¿Confirmas ${labels[pendingCmd]}? El EA lo aplicará en su próxima consulta (≤ 1 min).`;
    $("confirm").showModal();
  }));
  $("confirm").addEventListener("close", async () => {
    if ($("confirm").returnValue !== "ok" || !pendingCmd) return;
    const r = await api("/api/command", { method: "POST", body: JSON.stringify({ cmd: pendingCmd }) });
    text("cmd-msg", r.status === 200 ? `Comando ${pendingCmd} en cola (#${r.data.id}).` : (r.data.error || "Error al enviar el comando"));
    pendingCmd = null;
    refresh();
  });
  // al redimensionar solo se redibuja el gráfico con los datos ya cargados (sin pedir al servidor)
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => renderChart(lastEquity), 150);
  });
});
