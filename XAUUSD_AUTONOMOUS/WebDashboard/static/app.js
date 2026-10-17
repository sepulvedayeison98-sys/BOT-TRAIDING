// Dashboard web del XAUUSD Autonomous Trading System (sin dependencias).
// Lee /api/state cada 10 s (pausa mientras la pestaña está oculta). Los comandos van con el
// token CSRF de la sesión. window.XAD_DEMO (solo en la vista previa publicada) sustituye la API.
// Con varias instancias del EA (un gráfico por símbolo) se elige cuál ver; los comandos van a
// esa instancia o a todas.
"use strict";

const $ = (id) => document.getElementById(id);
const SVG_NS = "http://www.w3.org/2000/svg";
const REFRESH_MS = 10000;
const COMMAND_TTL = 600;
let csrf = "";
let timer = null;
let pendingCmd = null;
let lastState = null;
let range = 259200;
let lastSeen = 0;
let serverSkew = 0;
let instance = null;      // instancia que se muestra (null = la que reportó por última vez)
let cmdTarget = "one";    // "one" = la instancia mostrada, "all" = todas
try { instance = localStorage.getItem("xad.instance"); } catch (e) { instance = null; }
function rememberInstance(v) { try { localStorage.setItem("xad.instance", v); } catch (e) { /* sin almacenamiento */ } }

// ---------- utilidades ----------
const LOCALE = "es-CO";
function num(v, d = 2) {
  return typeof v === "number" && isFinite(v)
    ? v.toLocaleString(LOCALE, { minimumFractionDigits: d, maximumFractionDigits: d }) : "—";
}
function pct(v, d = 2) { return typeof v === "number" ? num(v, d) + " %" : "—"; }
function money(v, cur) { return typeof v === "number" ? num(v, 2) + (cur ? " " + cur : "") : "—"; }
function signed(v, d = 2) { return typeof v === "number" ? (v > 0 ? "+" : v < 0 ? "−" : "") + num(Math.abs(v), d) : "—"; }
function text(id, value) {
  const el = $(id);
  if (el) el.textContent = value === undefined || value === null || value === "" ? "—" : String(value);
}
function cls(el, base, extra) { el.className = base + (extra ? " " + extra : ""); }
function fmtTime(epoch, withDate = true) {
  if (!epoch) return "—";
  const o = withDate
    ? { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", hour12: false }
    : { hour: "2-digit", minute: "2-digit", hour12: false };
  return new Date(epoch * 1000).toLocaleString(LOCALE, o);
}
function ago(sec) {
  if (sec < 0) sec = 0;
  if (sec < 60) return `hace ${Math.floor(sec)} s`;
  if (sec < 3600) return `hace ${Math.floor(sec / 60)} min`;
  if (sec < 86400) return `hace ${Math.floor(sec / 3600)} h ${Math.floor((sec % 3600) / 60)} min`;
  return `hace ${Math.floor(sec / 86400)} d`;
}
function minutesText(m) {
  if (typeof m !== "number" || m < 0) return "";
  if (m < 60) return `${m} min`;
  return `${Math.floor(m / 60)} h ${m % 60} min`;
}
function el(tag, attrs, children) {
  const n = document.createElement(tag);
  Object.entries(attrs || {}).forEach(([k, v]) => {
    if (k === "text") n.textContent = v; else if (k === "class") n.className = v; else n.setAttribute(k, v);
  });
  (children || []).forEach((c) => n.appendChild(c));
  return n;
}
function svgEl(name, attrs) {
  const n = document.createElementNS(SVG_NS, name);
  Object.entries(attrs || {}).forEach(([k, v]) => n.setAttribute(k, v));
  return n;
}
function icon(id) {
  const s = svgEl("svg", { class: "ic", "aria-hidden": "true" });
  s.appendChild(svgEl("use", { href: "#" + id }));
  return s;
}
function chip(label, sev, iconId) {
  const c = el("span", { class: "chip " + sev });
  if (iconId) c.appendChild(icon(iconId));
  c.appendChild(document.createTextNode(label));
  return c;
}
function setMeter(id, ratio, sevByRatio = true) {
  const m = $(id);
  if (!m) return;
  const r = Math.max(0, Math.min(1, ratio || 0));
  m.style.width = (r * 100).toFixed(1) + "%";
  m.className = !sevByRatio ? "" : r >= 1 ? "critical" : r >= 0.66 ? "warning" : "";
}

// ---------- API ----------
async function api(path, options = {}) {
  if (window.XAD_DEMO) return window.XAD_DEMO(path, options);
  const opts = Object.assign({ credentials: "same-origin", headers: {} }, options);
  if (opts.method === "POST") {
    opts.headers["Content-Type"] = "application/json";
    if (csrf) opts.headers["X-XAD-CSRF"] = csrf;
  }
  try {
    const res = await fetch(path, opts);
    let data = {};
    try { data = await res.json(); } catch (e) { data = {}; }
    return { status: res.status, data };
  } catch (e) {
    return { status: 0, data: { error: "No hay conexión con el servidor del dashboard." } };
  }
}

// ---------- vistas ----------
const VIEWS = ["resumen", "riesgo", "mercado", "control"];
function setView(name, focus) {
  if (!VIEWS.includes(name)) name = "resumen";
  VIEWS.forEach((v) => {
    const tab = $("tab-" + v);
    const on = v === name;
    tab.setAttribute("aria-selected", on ? "true" : "false");
    tab.tabIndex = on ? 0 : -1;
    $("view-" + v).hidden = !on;
  });
  if (focus) $("tab-" + name).focus();
  if (location.hash !== "#" + name) history.replaceState(null, "", "#" + name);
  if (name === "resumen" && lastState) renderChart(lastState.equity || []);
}

function showLogin() {
  $("app").hidden = true;
  $("login").hidden = false;
  stopPolling();
  setTimeout(() => $("password").focus(), 0);
}
function showApp() {
  $("login").hidden = true;
  $("app").hidden = false;
  setView(location.hash.slice(1));
  refresh();
  startPolling();
}
function startPolling() { if (!timer) timer = setInterval(refresh, REFRESH_MS); }
function stopPolling() { if (timer) { clearInterval(timer); timer = null; } }

async function refresh() {
  const r = await api("/api/state" + (instance !== null ? "?i=" + encodeURIComponent(instance) : ""));
  if (r.status === 401) return showLogin();
  if (r.status === 200) render(r.data);
  else text("refresh-note", "Sin conexión con el servidor del dashboard: reintentando cada 10 s");
}

// ---------- traducciones ----------
const STATE = {
  RUNNING: { label: "Operando", sev: "good", icon: "i-check" },
  PAUSED: { label: "En pausa", sev: "warning", icon: "i-pause" },
  DAILY_LIMIT: { label: "Límite diario", sev: "warning", icon: "i-alert" },
  SAFE_MODE: { label: "Modo seguro", sev: "critical", icon: "i-shield" },
  HALTED: { label: "Detenido", sev: "critical", icon: "i-stop" },
  INIT: { label: "Iniciando", sev: "", icon: "i-clock" },
};
const REGIME = {
  TREND_UP: ["Tendencia alcista", "up"], TREND_DOWN: ["Tendencia bajista", "down"], RANGE: ["Rango", "range"],
  HIGH_VOLATILITY: ["Volatilidad alta", "vol"], NO_TRADE: ["Sin régimen operable", ""],
};
const STRUCT = { BULLISH: "Alcista", BEARISH: "Bajista", MIXED: "Mixta", UNKNOWN: "Sin datos" };
const SESSION = { LONDON: "Sesión de Londres", NEWYORK: "Sesión de Nueva York", OVERLAP: "Londres + Nueva York", NONE: "Fuera de sesión" };
const QUALITY = { HIGH: "Alta", MODERATE: "Moderada", DISCARD: "Descartada" };
const PROFILE = { XAUUSD: "Oro", SINTETICO: "Índice sintético", SINTETICO_SPIKE: "Sintético con spikes" };
const synthetic = (t) => t.uses_sessions === false;
const priceDigits = (t) => (typeof t.digits === "number" ? Math.min(Math.max(t.digits, 0), 5) : 2);
const portfolioPositions = (t) => (typeof t.portfolio_positions === "number" ? t.portfolio_positions : t.positions);

// Bloqueos del EA ("CLAVE: detalle; ...") -> título comprensible, severidad e icono.
const BLOCKS = [
  ["ESTADO", (d) => ({ t: "El EA no está en modo operativo", d, sev: "warning" })],
  ["CUENTA", (d) => ({ t: "Cuenta no permitida", d, sev: "crit" })],
  ["CONEXIÓN/PERMISOS", (d) => ({ t: "Sin conexión o trading deshabilitado", d: d + ". Revisa el botón Trading algorítmico y la casilla del EA.", sev: "crit" })],
  ["DATOS", (d) => ({ t: "Datos insuficientes", d, sev: "warning" })],
  ["SESIÓN", () => ({ t: "Fuera de horario", d: "Solo abre operaciones en las sesiones de Londres y Nueva York.", sev: "info" })],
  ["SPREAD", (d) => ({ t: "Spread demasiado alto", d, sev: "warning" })],
  ["MERCADO", (d) => ({ t: "Mercado cerrado o sin cotización", d, sev: "info" })],
  ["NOTICIAS", (d) => ({ t: "Ventana de noticias", d, sev: "warning" })],
  ["LÍMITE DIARIO", (d) => ({ t: "Límite de pérdida diaria alcanzado", d, sev: "warning" })],
  ["RÉGIMEN", (d) => ({ t: "Régimen de mercado no operable", d, sev: "info" })],
  ["PENDIENTE", (d) => ({ t: "Orden pendiente de confirmar", d, sev: "info" })],
];
function parseBlocks(raw) {
  if (!raw || raw === "ninguno" || raw === "—") return [];
  return raw.split(/;\s+/).map((s) => s.trim()).filter(Boolean).map((part) => {
    const hit = BLOCKS.find(([k]) => part.startsWith(k));
    if (!hit) return { t: part, d: "", sev: "info" };
    const detail = part.slice(hit[0].length).replace(/^[\s:]+/, "").replace(/[;\s]+$/, "");
    return hit[1](detail);
  });
}

// ---------- render ----------
function render(s) {
  lastState = s;
  const t = s.telemetry || {};
  serverSkew = (s.now || Date.now() / 1000) - Date.now() / 1000;
  lastSeen = s.last_seen || 0;
  const online = !!s.ea_online;
  if (typeof s.instance === "string") instance = s.instance;
  renderInstances(s);

  // cabecera
  const side = t.only_dir === "BUY" ? "solo compras" : t.only_dir === "SELL" ? "solo ventas" : "";
  text("subtitle", t.symbol ? [t.symbol, PROFILE[t.profile] || "", side, (t.account_mode || "").replace("DEMO", "Demo").replace("REAL", "REAL"), t.run_tag ? "corrida " + t.run_tag : ""].filter(Boolean).join(" · ") : "Esperando el primer reporte del EA");
  cls($("online"), "live", online ? "ok" : "off");
  text("online-text", online ? "En línea" : (t.symbol ? "Sin reportar" : "Sin datos"));
  text("time-server", t.time_server ? t.time_server.slice(11) : "—");
  text("time-col", t.time_col ? t.time_col.slice(11) : "—");
  text("version", t.version ? "v" + t.version : "—");
  tick();
  $("offline").hidden = online;
  if (!online) text("offline-text", lastSeen
    ? `Último reporte ${ago(Date.now() / 1000 + serverSkew - lastSeen)}. Revisa que el PC y MetaTrader 5 estén encendidos y el EA activo.`
    : "Todavía no ha llegado ningún reporte. Activa InpWebEnabled en el EA y revisa la URL y el token.");

  renderStatus(t, online);
  renderKpis(t);
  renderChart(s.equity || []);
  renderEquityTable(s.equity || []);
  renderPositions(t);
  renderDecision(t);
  renderRisk(t);
  renderMarket(t);
  renderControl(s, t, online);
  text("refresh-note", `Actualiza cada 10 s · última lectura ${new Date().toLocaleTimeString(LOCALE, { hour12: false })}`);
}

function renderInstances(s) {
  const list = s.instances || [];
  const box = $("instances");
  box.hidden = list.length < 2;
  const wrap = $("inst-list");
  wrap.replaceChildren();
  if (list.length < 2) return;
  list.forEach((i) => {
    const b = el("button", { type: "button", class: "inst", "aria-pressed": i.instance === s.instance ? "true" : "false",
      title: (i.online ? "En línea" : "Sin reportar") + (i.state ? " · " + ((STATE[i.state] || {}).label || i.state) : "") });
    b.appendChild(el("i", { class: i.online ? "ok" : "" }));
    b.appendChild(document.createTextNode(i.symbol || i.instance || "EA 1.1.x"));
    if (i.state) b.appendChild(el("small", { text: (STATE[i.state] || {}).label || i.state }));
    b.addEventListener("click", () => {
      instance = i.instance;
      rememberInstance(instance);
      refresh();
    });
    wrap.appendChild(b);
  });
}

function tick() {
  if (!lastSeen) { text("last-seen", "—"); return; }
  text("last-seen", ago(Date.now() / 1000 + serverSkew - lastSeen));
}

function renderStatus(t, online) {
  const st = (t.state || "INIT").toUpperCase();
  const info = STATE[st] || { label: st, sev: "", icon: "i-clock" };
  cls($("state-chip"), "state-chip", info.sev ? "state-" + info.sev : "");
  $("state-icon").setAttribute("href", "#" + info.icon);
  text("state", info.label);
  text("state-reason", t.state_reason || "");

  const list = $("blockers");
  list.replaceChildren();
  const blocks = parseBlocks(t.blocks);
  const ans = $("gate-answer");
  if (!online) {
    ans.textContent = "Sin datos recientes del EA";
    ans.className = "gate-answer no";
  } else if (!blocks.length) {
    ans.textContent = "Sí · buscando entradas en cada vela M5";
    ans.className = "gate-answer yes";
  } else {
    ans.textContent = `No · ${blocks.length} ${blocks.length === 1 ? "bloqueo" : "bloqueos"}`;
    ans.className = "gate-answer no";
  }
  const order = { crit: 0, warning: 1, info: 2 };
  blocks.sort((a, b) => order[a.sev] - order[b.sev]).forEach((b) => {
    const li = el("li", { class: b.sev });
    li.appendChild(icon(b.sev === "crit" ? "i-stop" : b.sev === "warning" ? "i-alert" : "i-clock"));
    li.appendChild(el("b", { text: b.t }));
    li.appendChild(el("span", { text: b.d || " " }));
    list.appendChild(li);
  });
}

function renderKpis(t) {
  const cur = t.currency || "";
  text("equity", num(t.equity));
  text("currency", cur);
  text("equity-sub", typeof t.balance === "number" ? `Balance ${money(t.balance, cur)}` : "—");

  // resultado del EA hoy
  const own = typeof t.own_pnl_today === "number" ? t.own_pnl_today
    : (typeof t.daily_gain_pct === "number" && typeof t.daily_loss_pct === "number" && typeof t.day_start_equity === "number"
      ? (t.daily_gain_pct - t.daily_loss_pct) / 100 * t.day_start_equity : null);
  const pnlEl = $("pnl");
  pnlEl.textContent = own === null ? "—" : signed(own);
  pnlEl.className = own > 0 ? "pos" : own < 0 ? "neg" : "";
  text("pnl-cur", cur);
  const base = t.day_start_equity;
  text("pnl-sub", own !== null && base > 0 ? `${signed(own / base * 100)} % sobre la equity al inicio del día` : "sobre la equity al inicio del día");
  const lossRatio = t.daily_limit_pct > 0 ? (t.daily_loss_pct || 0) / t.daily_limit_pct : 0;
  setMeter("loss-meter", lossRatio);
  const scope = t.daily_scope === "ACCOUNT" ? "toda la cuenta" : "solo el EA";
  text("loss-foot", `pérdida ${pct(t.daily_loss_pct)} de ${pct(t.daily_limit_pct)} · ${scope}`);
  cls($("kpi-pnl"), "kpi", lossRatio >= 1 ? "critical" : lossRatio >= 0.66 ? "warning" : own > 0 ? "good" : "");

  // exposición
  const maxExp = t.max_exposure_pct || 2;
  text("exposure", num(t.exposure_pct));
  text("exposure-sub", t.shared_portfolio ? "riesgo abierto de toda la cartera hasta el SL" : "riesgo abierto hasta el stop loss");
  const expRatio = (t.exposure_pct || 0) / maxExp;
  setMeter("exposure-meter", expRatio);
  text("exposure-foot", `máximo ${pct(maxExp)} · ${pct(t.risk_pct)} por operación`);
  cls($("kpi-exposure"), "kpi", expRatio >= 1 ? "critical" : expRatio >= 0.66 ? "warning" : "");

  // posiciones
  const maxPos = t.max_positions || 3;
  const pp = portfolioPositions(t);
  const n = typeof pp === "number" ? pp : 0;
  text("positions", typeof pp === "number" ? pp : "—");
  text("positions-max", `/ ${maxPos}`);
  const openPl = (t.open_positions || []).reduce((a, p) => a + (p.profit || 0), 0);
  const others = typeof t.positions === "number" ? n - t.positions : 0;
  text("positions-sub", others > 0 ? `${t.positions} en ${t.symbol}, ${others} en otros símbolos`
    : n ? `P/L flotante ${signed(openPl)} ${cur}` : "sin posiciones abiertas");
  const slots = $("slots");
  slots.replaceChildren();
  for (let i = 0; i < maxPos; i++) slots.appendChild(el("i", { class: i < n ? "on" : "" }));
  cls($("kpi-positions"), "kpi", n >= maxPos ? "warning" : "");

  // drawdown
  text("drawdown", num(t.drawdown_pct));
  text("drawdown-sub", t.peak_equity > 0 ? `desde el máximo de ${money(t.peak_equity, cur)}` : "desde el máximo de equity");
  cls($("kpi-dd"), "kpi", (t.drawdown_pct || 0) >= 5 ? "critical" : (t.drawdown_pct || 0) >= 2 ? "warning" : "");
}

// ---------- gráfico de equity (una serie: el título la nombra, sin leyenda) ----------
function niceStep(span, target) {
  const raw = span / target;
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const f = raw / mag;
  return (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag;
}
function renderChart(all) {
  const box = $("chart");
  if (!box || $("view-resumen").hidden) return;
  box.replaceChildren();
  const now = Date.now() / 1000 + serverSkew;
  const points = all.filter((p) => p[0] >= now - range);
  const stats = $("chart-stats");
  stats.replaceChildren();
  if (points.length < 2) {
    box.appendChild(el("div", { class: "chart-empty", text: "Aún no hay suficientes reportes en este rango. El EA envía uno cada 30 s." }));
    return;
  }
  const first = points[0][1], last = points[points.length - 1][1];
  const ys = points.map((p) => p[1]);
  const hi = Math.max(...ys), lo = Math.min(...ys);
  const chg = last - first;
  [["Inicio", num(first)], ["Actual", num(last)], ["Cambio", `${signed(chg)} (${signed(first ? chg / first * 100 : 0)} %)`], ["Máximo", num(hi)], ["Mínimo", num(lo)]]
    .forEach(([k, v], i) => {
      const b = el("b", { text: v });
      if (i === 2) b.className = chg > 0 ? "pos" : chg < 0 ? "neg" : "";
      stats.appendChild(el("div", {}, [el("span", { class: "lbl", text: k }), b]));
    });

  const W = box.clientWidth || 800, H = box.clientHeight || 260;
  const m = { l: 62, r: W < 560 ? 54 : 64, t: 12, b: 26 };
  const x0 = points[0][0], x1 = points[points.length - 1][0];
  let y0 = lo, y1 = hi;
  if (y1 - y0 < 1e-9) { y0 -= 1; y1 += 1; }
  const step = niceStep(y1 - y0, 4);
  y0 = Math.floor(y0 / step) * step;
  y1 = Math.ceil(y1 / step) * step;
  const sx = (x) => m.l + (x - x0) / Math.max(1, x1 - x0) * (W - m.l - m.r);
  const sy = (y) => m.t + (1 - (y - y0) / (y1 - y0)) * (H - m.t - m.b);
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, role: "presentation" });
  const defs = svgEl("defs");
  const grad = svgEl("linearGradient", { id: "eq-fill", x1: "0", y1: "0", x2: "0", y2: "1" });
  grad.appendChild(svgEl("stop", { offset: "0", class: "area-top" }));
  grad.appendChild(svgEl("stop", { offset: "1", class: "area-bot" }));
  defs.appendChild(grad);
  svg.appendChild(defs);
  for (let v = y0; v <= y1 + step / 2; v += step) {
    svg.appendChild(svgEl("line", { class: "grid", x1: m.l, x2: W - m.r, y1: sy(v), y2: sy(v) }));
    const lab = svgEl("text", { class: "axis", x: m.l - 8, y: sy(v) + 4, "text-anchor": "end" });
    lab.textContent = v.toLocaleString(LOCALE, { maximumFractionDigits: step < 1 ? 2 : 0 });
    svg.appendChild(lab);
  }
  const xTicks = W < 560 ? [[x0, "start"], [x1, "end"]] : [[x0, "start"], [(x0 + x1) / 2, "middle"], [x1, "end"]];
  xTicks.forEach(([x, anchor]) => {
    const lab = svgEl("text", { class: "axis", x: sx(x), y: H - 6, "text-anchor": anchor });
    lab.textContent = W < 560
      ? new Date(x * 1000).toLocaleString(LOCALE, range > 86400 ? { day: "2-digit", month: "short" } : { hour: "2-digit", minute: "2-digit", hour12: false })
      : fmtTime(x, range > 86400);
    svg.appendChild(lab);
  });
  // referencia: equity al inicio del rango
  svg.appendChild(svgEl("line", { class: "base", x1: m.l, x2: W - m.r, y1: sy(first), y2: sy(first) }));
  const path = points.map((p, i) => (i ? "L" : "M") + sx(p[0]).toFixed(1) + "," + sy(p[1]).toFixed(1)).join(" ");
  svg.appendChild(svgEl("path", { d: `${path} L${sx(x1).toFixed(1)},${sy(y0).toFixed(1)} L${sx(x0).toFixed(1)},${sy(y0).toFixed(1)} Z`, fill: "url(#eq-fill)" }));
  svg.appendChild(svgEl("path", { class: "line", d: path }));
  svg.appendChild(svgEl("circle", { class: "end", r: 4.5, cx: sx(x1), cy: sy(last) }));
  const endLab = svgEl("text", { class: "end-lbl", x: sx(x1) + 9, y: sy(last) + 4 });
  endLab.textContent = num(last, 0);
  svg.appendChild(endLab);

  const cross = svgEl("line", { class: "cross", y1: m.t, y2: H - m.b, x1: 0, x2: 0, visibility: "hidden" });
  const dot = svgEl("circle", { class: "dot", r: 5, cx: 0, cy: 0, visibility: "hidden" });
  svg.appendChild(cross);
  svg.appendChild(dot);
  const hit = svgEl("rect", { class: "hit", x: m.l, y: 0, width: Math.max(0, W - m.l - m.r), height: H });
  svg.appendChild(hit);
  const tip = $("chart-tip");
  const move = (clientX, clientY) => {
    const rect = svg.getBoundingClientRect();
    const px = (clientX - rect.left) * (W / rect.width);
    let best = 0;
    points.forEach((p, i) => { if (Math.abs(sx(p[0]) - px) < Math.abs(sx(points[best][0]) - px)) best = i; });
    const p = points[best];
    cross.setAttribute("x1", sx(p[0])); cross.setAttribute("x2", sx(p[0]));
    dot.setAttribute("cx", sx(p[0])); dot.setAttribute("cy", sy(p[1]));
    cross.setAttribute("visibility", "visible"); dot.setAttribute("visibility", "visible");
    tip.hidden = false;
    tip.textContent = `${fmtTime(p[0])} · ${num(p[1])} · ${signed(p[1] - first)} vs inicio`;
    const tw = tip.offsetWidth || 220;
    tip.style.left = Math.min(clientX + 14, window.innerWidth - tw - 8) + "px";
    tip.style.top = Math.max(8, clientY - 40) + "px";
  };
  const leave = () => { tip.hidden = true; cross.setAttribute("visibility", "hidden"); dot.setAttribute("visibility", "hidden"); };
  hit.addEventListener("mousemove", (e) => move(e.clientX, e.clientY));
  hit.addEventListener("mouseleave", leave);
  hit.addEventListener("touchmove", (e) => { if (e.touches[0]) move(e.touches[0].clientX, e.touches[0].clientY); }, { passive: true });
  hit.addEventListener("touchend", leave);
  box.appendChild(svg);
}

function renderEquityTable(points) {
  const tbody = document.querySelector("#equity-table tbody");
  tbody.replaceChildren();
  points.slice(-100).reverse().forEach((p) => {
    tbody.appendChild(el("tr", {}, [el("td", { text: fmtTime(p[0]) }), el("td", { class: "num", text: num(p[1]) })]));
  });
}

function renderPositions(t) {
  const rows = t.open_positions || [];
  const tbody = document.querySelector("#positions-table tbody");
  tbody.replaceChildren();
  const d = priceDigits(t);
  rows.forEach((p) => {
    const pl = el("td", { class: "num " + (p.profit > 0 ? "pos" : p.profit < 0 ? "neg" : ""), text: signed(p.profit) });
    tbody.appendChild(el("tr", {}, [
      el("td", { class: "num", text: String(p.ticket) }),
      el("td", {}, [el("span", { class: "dir " + (p.dir === "BUY" ? "buy" : "sell"), text: p.dir === "BUY" ? "COMPRA" : "VENTA" })]),
      el("td", { class: "num", text: num(p.volume, Math.abs(p.volume * 100 - Math.round(p.volume * 100)) > 1e-6 ? 3 : 2) }),
      el("td", { class: "num", text: num(p.open, d) }),
      el("td", { class: "num", text: p.sl > 0 ? num(p.sl, d) : "sin SL" }),
      el("td", { class: "num", text: p.tp > 0 ? num(p.tp, d) : "—" }),
      pl,
    ]));
  });
  $("positions-table").hidden = !rows.length;
  $("positions-empty").hidden = !!rows.length;
  text("pos-tag", `${rows.length} / ${t.max_positions || 3}`);
}

function renderDecision(t) {
  text("last-signal", t.last_signal);
  text("last-trade", t.last_trade);
  text("strategy", t.strategy ? { SMC: "Smart Money Concepts", BREAKOUT: "Ruptura (breakout)", REVERSAL: "Reversión" }[t.strategy] || t.strategy : "—");
  if (typeof t.score === "number") {
    text("score", `${num(t.score, 0)} / 100 · calidad ${QUALITY[t.quality] || t.quality || "—"} (mínimo 65)`);
    setMeter("score-meter", t.score / 100, false);
    $("score-meter").className = t.score >= 80 ? "good" : t.score >= 65 ? "" : "warning";
  } else {
    text("score", "sin señales evaluadas todavía");
    setMeter("score-meter", 0, false);
  }
  const tag = $("decision-tag");
  tag.hidden = !t.session && !synthetic(t);
  tag.textContent = synthetic(t) ? "24/7" : SESSION[t.session] || "";
}

function ruleRow(name, note, actual, limit, ratio, status) {
  const use = el("div", { class: "use" });
  const meter = el("div", { class: "meter" }, [el("div")]);
  use.appendChild(meter);
  use.appendChild(el("span", { text: ratio === null ? "" : Math.round(ratio * 100) + " %" }));
  const bar = meter.firstChild;
  if (ratio !== null) {
    bar.style.width = Math.min(100, ratio * 100).toFixed(1) + "%";
    bar.className = status[1] === "critical" ? "critical" : status[1] === "warning" ? "warning" : "";
  }
  const nameTd = el("td", { text: name });
  if (note) nameTd.appendChild(el("small", { text: note }));
  return el("tr", {}, [
    nameTd,
    el("td", { class: "num", text: actual }),
    el("td", { class: "num", text: limit }),
    el("td", {}, ratio === null ? [] : [use]),
    el("td", {}, [chip(status[0], status[1], status[2])]),
  ]);
}
function statusFor(ratio, blockAt = 1) {
  if (ratio >= blockAt) return ["Bloquea", "critical", "i-stop"];
  if (ratio >= 0.66 * blockAt) return ["Atención", "warning", "i-alert"];
  return ["OK", "good", "i-check"];
}
function renderRisk(t) {
  const tbody = $("rules");
  tbody.replaceChildren();
  const maxExp = t.max_exposure_pct || 2, maxPos = t.max_positions || 3;
  const riskR = (t.risk_pct || 0) / 2;
  tbody.appendChild(ruleRow("Riesgo por operación", "pérdida máxima si toca el stop loss", pct(t.risk_pct), "2,00 % (tope duro)", riskR, statusFor(riskR, 1.0001)));
  const expR = (t.exposure_pct || 0) / maxExp;
  tbody.appendChild(ruleRow("Exposición agregada", t.shared_portfolio ? "riesgo abierto de todos los símbolos con la misma magic" : "suma del riesgo abierto de sus posiciones", pct(t.exposure_pct), pct(maxExp), expR, statusFor(expR)));
  const pp = portfolioPositions(t);
  const posR = (pp || 0) / maxPos;
  tbody.appendChild(ruleRow("Posiciones simultáneas", t.shared_portfolio ? "toda la cartera; en Netting, 1 por símbolo" : "en Netting el máximo es 1", String(pp ?? "—"), String(maxPos), posR, statusFor(posR)));
  const lossR = t.daily_limit_pct > 0 ? (t.daily_loss_pct || 0) / t.daily_limit_pct : 0;
  tbody.appendChild(ruleRow("Pérdida diaria", t.daily_scope === "ACCOUNT" ? "toda la cuenta" : "solo operaciones del EA", pct(t.daily_loss_pct), pct(t.daily_limit_pct), lossR, statusFor(lossR)));
  tbody.appendChild(ruleRow("Relación riesgo/beneficio", "mínimo exigido a cada operación", typeof t.min_rr === "number" ? "1 : " + num(t.min_rr, 1) : "—", "1 : 2,0 o más", null, ["Regla fija", "neutral", "i-info"]));
  tbody.appendChild(ruleRow("Drawdown", "caída desde el máximo de equity", pct(t.drawdown_pct), "—", null, ["Informativo", "neutral", "i-info"]));
  const ea = t.daily_scope !== "ACCOUNT";
  text("scope-tag", ea ? "Pérdida diaria: solo EA" : "Pérdida diaria: toda la cuenta");
  text("scope-text", (ea
    ? "La pérdida diaria cuenta solo las operaciones del EA (su número mágico). Tus operaciones manuales u otros robots en la misma cuenta no consumen este límite, así que la cuenta completa puede perder más en un día. Se reinicia a la hora configurada del servidor."
    : "La pérdida diaria cuenta todas las operaciones de la cuenta, incluidas las manuales y las de otros robots. Se reinicia a la hora configurada del servidor.")
    + (t.shared_portfolio ? " Los gráficos de otros símbolos con la misma magic comparten estos límites: exposición, posiciones y pérdida diaria son de toda la cartera." : ""));
}

function renderMarket(t) {
  text("session-tag", synthetic(t) ? "24/7 · sin filtro de sesión" : SESSION[t.session] || "Sesión sin datos");
  const [rName, rCls] = REGIME[t.regime] || [t.regime || "—", ""];
  const rEl = $("regime");
  rEl.textContent = rName;
  rEl.className = "big " + rCls;
  const raw = REGIME[t.regime_raw];
  const confirmed = t.regime_raw && t.regime_raw === t.regime;
  text("regime-raw", t.regime_raw ? (confirmed ? "Lectura actual confirmada" : `Lectura actual, sin confirmar: ${raw ? raw[0] : t.regime_raw}`) : "—");
  text("regime-note", t.regime_raw && t.regime_raw !== t.regime
    ? "El EA espera a que la lectura se confirme durante varias velas H1 antes de operarla."
    : t.regime === "NO_TRADE" ? "Sin una tendencia, un rango o una volatilidad claros, el EA no busca entradas." : "Régimen confirmado.");

  text("trend-h1", STRUCT[t.trend_h1] || t.trend_h1);
  text("adx", typeof t.adx_h1 === "number" ? `${num(t.adx_h1, 1)} · ${t.adx_h1 >= 25 ? "tendencia fuerte" : t.adx_h1 >= 18 ? "tendencia moderada" : "sin tendencia"}` : "—");
  text("ema", typeof t.ema_fast_above === "boolean" ? (t.ema_fast_above ? "EMA50 por encima · sesgo alcista" : "EMA50 por debajo · sesgo bajista") : "—");
  text("struct-m15", STRUCT[t.structure_m15] || t.structure_m15);
  text("momentum", typeof t.momentum_m5 === "boolean" ? (t.momentum_m5 ? "Cambio de momentum detectado" : "Sin cambio de momentum") : "—");

  if (typeof t.spread === "number") {
    const avg = t.spread_avg || t.spread;
    const scale = Math.max(avg * 2, t.spread, 1);
    text("spread", `${num(t.spread, 0)} pts` + (typeof t.spread_max === "number" ? ` · máx ${num(t.spread_max, 0)}` : ""));
    const bar = $("spread-bar");
    bar.style.width = Math.min(100, t.spread / scale * 100).toFixed(1) + "%";
    bar.className = t.spread > avg * 1.5 ? "warning" : "";
    $("spread-avg-mark").style.left = (avg / scale * 100).toFixed(1) + "%";
    text("spread-note", `Media ${num(avg, 0)} pts · actual ${num(t.spread / avg, 1)}× la media (marca blanca = media)`);
  } else {
    text("spread", "—"); text("spread-note", "Sin datos de mercado todavía");
  }
  text("atr", typeof t.atr_m15 === "number" ? (synthetic(t) ? `${num(t.atr_m15, priceDigits(t))} (precio)` : `${num(t.atr_m15, 2)} USD`) : "—");

  if (typeof t.rsi_m15 === "number") {
    text("rsi", num(t.rsi_m15, 1));
    $("rsi-mark").style.left = `calc(${Math.max(0, Math.min(100, t.rsi_m15)).toFixed(1)}% - 1.5px)`;
    text("rsi-note", t.rsi_m15 >= 70 ? "Sobrecompra (≥ 70)" : t.rsi_m15 <= 30 ? "Sobreventa (≤ 30)" : "Zona neutral (30–70)");
  } else { text("rsi", "—"); text("rsi-note", "—"); }

  const card = $("news-card");
  if (t.uses_news === false) {
    card.className = "card news-card";
    text("news-state", "No aplica");
    text("news-next", "Los índices sintéticos los genera el bróker con un algoritmo: no dependen de noticias económicas.");
    text("news-note", "El filtro de noticias USD solo se usa en XAUUSD.");
    return;
  }
  text("news-note", "Bloqueo de ±30 min en CPI, NFP, FOMC, PCE y tasas; ±20 min en otros eventos USD.");
  card.className = "card news-card" + (t.news_blocked ? " blocked" : "");
  text("news-state", t.news_blocked ? "Bloqueo activo" : "Libre");
  text("news-next", t.news_blocked
    ? (t.news || "").replace(/^BLOQUEO:\s*/, "")
    : t.news_minutes >= 0 && t.news_next ? `Próximo: ${t.news_next} en ${minutesText(t.news_minutes)}` : "Sin eventos USD relevantes próximos");
}

function renderControl(s, t, online) {
  const insts = s.instances || [];
  const multi = insts.length > 1;
  $("cmd-target").hidden = !multi;
  if (!multi) cmdTarget = "one";
  document.querySelectorAll("#target-seg button").forEach((b) => b.classList.toggle("on", b.dataset.target === cmdTarget));
  text("target-one", t.symbol || "Esta instancia");
  text("target-note", cmdTarget === "all"
    ? `Se envía a las ${insts.length} instancias; cada una lo aplica según su propio estado.`
    : `Solo lo aplica ${t.symbol || "esta instancia"}.`);
  const all = multi && cmdTarget === "all";
  const states = all ? insts.map((i) => (i.state || "").toUpperCase()) : [(t.state || "").toUpperCase()];
  const st = states[0];
  const allowed = !!s.allow_commands;
  const any = (f) => states.some(f);
  const rules = all ? {
    PAUSE: [any((x) => x === "RUNNING"), any((x) => x === "RUNNING") ? "Disponible: pausa las instancias que están operando." : "Ninguna instancia está operando."],
    RESUME: [any((x) => x === "PAUSED"), any((x) => x === "PAUSED") ? "Disponible: reanuda las instancias en pausa." : "Ninguna instancia está en pausa."],
    SAFE_MODE: [any((x) => x !== "SAFE_MODE" && x !== "HALTED"), "Disponible siempre."],
  } : {
    PAUSE: [st === "RUNNING", st === "RUNNING" ? "Disponible: el EA está operando." : `Sin efecto ahora: el EA está en ${STATE[st] ? STATE[st].label.toLowerCase() : st || "estado desconocido"}.`],
    RESUME: [st === "PAUSED", st === "PAUSED" ? "Disponible: el EA está en pausa." : "Solo actúa cuando el EA está en pausa."],
    SAFE_MODE: [st !== "SAFE_MODE" && st !== "HALTED", st === "SAFE_MODE" ? "Ya está en modo seguro." : "Disponible siempre."],
  };
  document.querySelectorAll("#actions button").forEach((b) => {
    const [ok, why] = rules[b.dataset.cmd];
    b.disabled = !allowed || !ok;
    text("when-" + b.dataset.cmd, !allowed ? "Los comandos remotos están desactivados en el servidor." : why + (ok && !online ? " El EA no está reportando: se aplicará si vuelve en menos de 10 min." : ""));
  });

  const rows = s.commands || [];
  const tbody = document.querySelector("#commands tbody");
  tbody.replaceChildren();
  const now = s.now || Date.now() / 1000;
  const names = { PAUSE: "Pausar entradas", RESUME: "Reanudar entradas", SAFE_MODE: "Modo seguro" };
  rows.forEach((r) => {
    let status;
    const acks = r.acks || [];
    if (r.acked && multi && (r.target || "*") === "*") status = chip(`Aplicado ${acks.length} de ${insts.length}`, acks.length >= insts.length ? "good" : "warning", acks.length >= insts.length ? "i-check" : "i-clock");
    else if (r.acked) status = chip("Aplicado " + fmtTime(r.acked, false), "good", "i-check");
    else if (now - r.created > COMMAND_TTL) status = chip("Caducado", "neutral");
    else if (r.delivered) status = chip("Entregado, sin confirmar", "warning", "i-clock");
    else status = chip("En cola", "neutral", "i-clock");
    tbody.appendChild(el("tr", {}, [
      el("td", { class: "num", text: String(r.id) }),
      el("td", { text: names[r.cmd] || r.cmd }),
      el("td", { text: (r.target || "*") === "*" ? "Todas" : r.target }),
      el("td", { text: fmtTime(r.created) }),
      el("td", {}, [status]),
    ]));
  });
  $("commands").hidden = !rows.length;
  $("commands-empty").hidden = !!rows.length;
}

// ---------- eventos ----------
document.addEventListener("DOMContentLoaded", async () => {
  document.querySelectorAll(".tabs button").forEach((b, i, all) => {
    b.addEventListener("click", () => setView(b.dataset.view));
    b.addEventListener("keydown", (e) => {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      const next = all[(i + (e.key === "ArrowRight" ? 1 : all.length - 1)) % all.length];
      setView(next.dataset.view, true);
    });
  });
  window.addEventListener("hashchange", () => setView(location.hash.slice(1)));

  document.querySelectorAll(".seg button").forEach((b) => b.addEventListener("click", () => {
    range = Number(b.dataset.range);
    document.querySelectorAll(".seg button").forEach((x) => x.classList.toggle("on", x === b));
    if (lastState) renderChart(lastState.equity || []);
  }));
  document.querySelectorAll("#target-seg button").forEach((b) => b.addEventListener("click", () => {
    cmdTarget = b.dataset.target;
    if (lastState) renderControl(lastState, lastState.telemetry || {}, !!lastState.ea_online);
  }));
  $("toggle-table").addEventListener("click", () => {
    const w = $("equity-table-wrap");
    w.hidden = !w.hidden;
    $("toggle-table").setAttribute("aria-expanded", String(!w.hidden));
  });

  $("login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    text("login-error", "");
    const r = await api("/api/login", { method: "POST", body: JSON.stringify({ password: $("password").value }) });
    $("password").value = "";
    if (r.status === 200) { csrf = r.data.csrf; showApp(); }
    else $("login-error").textContent = r.data.error || "No se pudo entrar. Revisa la contraseña.";
  });
  $("logout").addEventListener("click", async () => {
    await api("/api/logout", { method: "POST", body: "{}" });
    csrf = "";
    showLogin();
  });

  const labels = {
    PAUSE: "pausar las entradas nuevas. Las posiciones abiertas siguen gestionadas.",
    RESUME: "reanudar la búsqueda de entradas.",
    SAFE_MODE: "activar el MODO SEGURO. Para salir tendrás que hacerlo en el panel de MT5.",
  };
  document.querySelectorAll("#actions button").forEach((b) => b.addEventListener("click", () => {
    pendingCmd = b.dataset.cmd;
    const multi = lastState && (lastState.instances || []).length > 1;
    const who = !multi ? "" : cmdTarget === "all" ? "Todas las instancias: v" : `${(lastState.telemetry || {}).symbol || "Esta instancia"}: v`;
    text("confirm-text", `${who || "V"}as a ${labels[pendingCmd]} El EA lo aplica en su siguiente reporte (unos 30 s).`);
    $("confirm-ok").className = "btn " + (pendingCmd === "SAFE_MODE" ? "btn-danger" : pendingCmd === "PAUSE" ? "btn-warning" : "btn-primary");
    $("confirm").showModal();
  }));
  $("confirm").addEventListener("close", async () => {
    if ($("confirm").returnValue !== "ok" || !pendingCmd) { pendingCmd = null; return; }
    const multi = lastState && (lastState.instances || []).length > 1;
    const target = multi && cmdTarget === "one" && typeof instance === "string" ? instance : "*";
    const r = await api("/api/command", { method: "POST", body: JSON.stringify({ cmd: pendingCmd, target }) });
    const msg = $("cmd-msg");
    if (r.status === 200) { msg.textContent = `Comando #${r.data.id} en cola. Su estado aparece en el historial.`; msg.className = "cmd-msg ok"; }
    else { msg.textContent = r.data.error || "No se pudo enviar el comando."; msg.className = "cmd-msg err"; }
    pendingCmd = null;
    refresh();
  });

  let resizeTimer = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => { if (lastState) renderChart(lastState.equity || []); }, 150);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopPolling();
    else if (!$("app").hidden) { refresh(); startPolling(); }
  });
  setInterval(tick, 1000);

  const s = await api("/api/session");
  if (s.data.authenticated) { csrf = s.data.csrf; showApp(); } else showLogin();
});
