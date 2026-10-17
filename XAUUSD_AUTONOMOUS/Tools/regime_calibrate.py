#!/usr/bin/env python3
"""Calibración de los umbrales de ADX del RegimeEngine para un instrumento (1.2.0).

Lee los CSV de Tests/Backtesting/RegimeLogger.mq5 (por ejemplo de Volatility 75 Index) y responde:

  1. ¿Cuánto tiempo pasa el instrumento en cada régimen y en la zona neutral de ADX
     (entre range_adx_max y trend_adx_min), donde el EA no opera?
  2. ¿Hay persistencia de tendencia, y desde qué ADX? Para cada quintil de ADX H1 se mide el
     retorno futuro en la dirección de la pendiente H1 (en ATR H1), con muestras no solapadas.
     Si la tendencia persiste, la media es > 0 y crece con el ADX. Sin persistencia, bajar el
     umbral solo aumenta el número de operaciones, no la ventaja.

No optimiza nada ni toca el EA: propone un umbral solo si hay evidencia (t >= 2) y avisa cuando
no la hay. Es una prueba aproximada en una sola muestra (múltiples comparaciones): cualquier
umbral nuevo debe confirmarse fuera de muestra y en demo.

Uso:
  python3 regime_calibrate.py regime_Volatility*.csv [--horizons 12,48] [--trend 22 --range 18]
Solo usa la librería estándar de Python 3.8+.
"""
import argparse
import csv
import math
import statistics
from datetime import datetime, timedelta

BAR_MINUTES = 5
T_THRESHOLD = 2.0
MIN_N = 30


def load(paths):
    rows = []
    for path in paths:
        with open(path, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                try:
                    rows.append({
                        "time": datetime.strptime(r["server_time"], "%Y.%m.%d %H:%M"),
                        "close": float(r["m5_close"]),
                        "atr": float(r["h1_atr"]),
                        "adx": float(r["h1_adx"]),
                        "slope": float(r["h1_slope"]),
                        "regime": r["regime"],
                        "raw": r["raw_regime"],
                    })
                except (KeyError, ValueError) as exc:
                    raise SystemExit(f"Fila inválida en {path}: {exc}")
    rows.sort(key=lambda x: x["time"])
    out = []
    for r in rows:
        if not out or out[-1]["time"] != r["time"]:
            out.append(r)
    return out


def percentile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * p
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def stats(values):
    n = len(values)
    if n < 2:
        return {"n": n, "mean": float("nan"), "t": float("nan")}
    mean = statistics.fmean(values)
    sd = statistics.stdev(values)
    return {"n": n, "mean": mean, "t": mean / (sd / math.sqrt(n)) if sd > 0 else 0.0}


def signed_forward(rows, horizon):
    """Muestras no solapadas: (adx, retorno futuro en ATR H1 en la dirección de la pendiente H1)."""
    max_gap = timedelta(minutes=BAR_MINUTES * horizon * 1.5)
    out = []
    for i in range(0, len(rows) - horizon, horizon):
        r, f = rows[i], rows[i + horizon]
        if r["atr"] <= 0 or r["slope"] == 0 or f["time"] - r["time"] > max_gap:
            continue
        direction = 1.0 if r["slope"] > 0 else -1.0
        out.append((r["adx"], direction * (f["close"] - r["close"]) / r["atr"]))
    return out


def analyze(rows, horizons, trend_min, range_max):
    res = {"rows": len(rows)}
    if not rows:
        return res
    res["period"] = (rows[0]["time"], rows[-1]["time"])
    n = len(rows)
    res["share"] = {}
    for r in rows:
        res["share"][r["regime"]] = res["share"].get(r["regime"], 0) + 1 / n
    adx = sorted(r["adx"] for r in rows)
    res["adx_pct"] = {p: percentile(adx, p) for p in (0.1, 0.25, 0.5, 0.75, 0.9)}
    res["neutral"] = sum(1 for a in adx if range_max < a < trend_min) / n
    res["above_trend"] = sum(1 for a in adx if a >= trend_min) / n
    res["below_range"] = sum(1 for a in adx if a <= range_max) / n
    edges = [percentile(adx, q) for q in (0.2, 0.4, 0.6, 0.8)]
    res["edges"] = edges
    res["horizons"] = {}
    for h in horizons:
        samples = signed_forward(rows, h)
        buckets = [[] for _ in range(5)]
        for a, v in samples:
            k = sum(1 for e in edges if a > e)
            buckets[k].append(v)
        res["horizons"][h] = {"all": stats([v for _, v in samples]), "buckets": [stats(b) for b in buckets]}
    res["suggestion"] = suggest(res, horizons, edges)
    return res


def suggest(res, horizons, edges):
    """Umbral de tendencia = límite inferior del primer quintil desde el que TODOS los quintiles
    superiores tienen persistencia significativa en todos los horizontes. None si no hay evidencia."""
    lows = [None] + edges          # límite inferior de cada quintil
    for k in range(1, 5):
        ok = True
        for h in horizons:
            for b in res["horizons"][h]["buckets"][k:]:
                if b["n"] < MIN_N or not (b["t"] >= T_THRESHOLD and b["mean"] > 0):
                    ok = False
        if ok:
            return lows[k]
    return None


def render(res, paths, trend_min, range_max):
    if not res.get("rows"):
        return "Sin filas: revisa que el CSV sea de RegimeLogger."
    a, b = res["period"]
    L = [f"# Calibración del régimen — {', '.join(paths)}",
         f"Periodo {a:%Y-%m-%d %H:%M} → {b:%Y-%m-%d %H:%M}, {res['rows']} velas M5.", "",
         "## Tiempo por régimen (confirmado)"]
    for k, v in sorted(res["share"].items(), key=lambda x: -x[1]):
        L.append(f"- {k}: {v * 100:.1f} %")
    p = res["adx_pct"]
    L += ["", "## ADX H1",
          f"- Percentiles 10/25/50/75/90: {p[0.1]:.1f} / {p[0.25]:.1f} / {p[0.5]:.1f} / {p[0.75]:.1f} / {p[0.9]:.1f}",
          f"- ≤ {range_max:g} (rango posible): {res['below_range'] * 100:.1f} % · zona neutral ({range_max:g}, {trend_min:g}): "
          f"{res['neutral'] * 100:.1f} % · ≥ {trend_min:g} (tendencia posible): {res['above_trend'] * 100:.1f} %", "",
          "## Persistencia de tendencia por quintil de ADX",
          "Retorno futuro en la dirección de la pendiente H1, en ATR H1 (muestras no solapadas). "
          "Persistencia = media > 0 con t ≥ 2."]
    e = res["edges"]
    names = [f"≤ {e[0]:.1f}", f"{e[0]:.1f}–{e[1]:.1f}", f"{e[1]:.1f}–{e[2]:.1f}", f"{e[2]:.1f}–{e[3]:.1f}", f"> {e[3]:.1f}"]
    for h, d in res["horizons"].items():
        al = d["all"]
        L += ["", f"### Horizonte {h} velas M5 ({h * BAR_MINUTES} min) — todas: n={al['n']}, media {al['mean']:+.3f}, t {al['t']:+.2f}",
              "| ADX H1 | n | media (ATR) | t |", "|---|---|---|---|"]
        for name, s in zip(names, d["buckets"]):
            L.append(f"| {name} | {s['n']} | {s['mean']:+.3f} | {s['t']:+.2f} |")
    L += ["", "## Conclusión"]
    sug = res["suggestion"]
    if sug is None:
        L.append("Sin evidencia de persistencia de tendencia que dependa del ADX en esta muestra. "
                 "Bajar `InpTrendAdxMin` haría operar más sin ventaja demostrada: se recomienda NO cambiarlo. "
                 "(En un índice que se comporta como caminata aleatoria es el resultado esperado.)")
    else:
        L.append(f"Persistencia significativa desde ADX ≈ {sug:.1f} en todos los horizontes. Candidato: "
                 f"`InpTrendAdxMin={sug:.1f}` (actual {trend_min:g}), a confirmar fuera de muestra y en demo antes de usarlo.")
    return "\n".join(L)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--horizons", default="12,48")
    ap.add_argument("--trend", type=float, default=22.0, help="InpTrendAdxMin vigente")
    ap.add_argument("--range", type=float, default=18.0, help="InpRangeAdxMax vigente")
    ap.add_argument("--out")
    args = ap.parse_args(argv)
    horizons = [int(x) for x in args.horizons.split(",") if x.strip()]
    text = render(analyze(load(args.csv), horizons, args.trend, args.range), args.csv, args.trend, args.range)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
