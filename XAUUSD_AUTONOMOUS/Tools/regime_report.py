#!/usr/bin/env python3
"""Validación estadística del RegimeEngine (Fase 3).

Lee uno o más CSV generados por Tests/Backtesting/RegimeLogger.mq5 y evalúa si
cada régimen tiene el comportamiento que su nombre promete en los datos:

  TREND_UP        -> retorno futuro medio > 0
  TREND_DOWN      -> retorno futuro medio < 0
  HIGH_VOLATILITY -> movimiento absoluto futuro mayor que el promedio
  RANGE           -> reversión a la media: posición en el rango y retorno
                     futuro correlacionados negativamente

Los retornos se miden en múltiplos del ATR H1 para comparar periodos con
volatilidad distinta. Se muestrea una vela de cada `horizonte` (retornos NO
solapados): así, si el precio fuera una caminata aleatoria, cada retorno
sería independiente de la información usada para clasificarlo y el t-test
es válido. (Con retornos solapados y la posición en el rango, que es muy
persistente, aparecen correlaciones espurias: lo detectó la prueba con
caminata aleatoria en tests/test_regime_report.py.)

Es una prueba de hipótesis aproximada, NO una prueba de rentabilidad: hay
múltiples comparaciones y un resultado "consistente" en una muestra puede
no repetirse fuera de ella.

Uso:
  python3 regime_report.py regime_XAUUSD_*.csv [--horizons 12,48] [--out reporte.md]
Solo usa la librería estándar de Python 3.8+.
"""
import argparse
import csv
import math
import statistics
import sys
from datetime import datetime, timedelta

BAR_MINUTES = 5
REGIMES = ["TREND_UP", "TREND_DOWN", "RANGE", "HIGH_VOLATILITY", "NO_TRADE"]
MIN_EFFECTIVE_N = 30
RANGE_EXTREME = 0.25      # |posición - 0.5| mínima para considerar un extremo del rango
T_THRESHOLD = 2.0
HIGH_VOL_ABS_FACTOR = 1.3


def load_rows(paths):
    rows = []
    for path in paths:
        with open(path, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                try:
                    rows.append({
                        "time": datetime.strptime(r["server_time"], "%Y.%m.%d %H:%M"),
                        "session": r["session"],
                        "close": float(r["m5_close"]),
                        "atr": float(r["h1_atr"]),
                        "regime": r["regime"],
                        "raw": r["raw_regime"],
                        "range_high": float(r["range_high"]),
                        "range_low": float(r["range_low"]),
                    })
                except (KeyError, ValueError) as exc:
                    raise SystemExit(f"Fila inválida en {path}: {exc}")
    rows.sort(key=lambda x: x["time"])
    # descarta duplicados exactos de hora (p. ej. CSV concatenados que se solapan)
    unique = []
    for r in rows:
        if unique and unique[-1]["time"] == r["time"]:
            continue
        unique.append(r)
    return unique


def forward_returns(rows, horizon):
    """Retorno a `horizon` velas en ATR H1. None si cruza un hueco de datos."""
    max_gap = timedelta(minutes=BAR_MINUTES * horizon * 1.5)
    out = []
    for i, r in enumerate(rows):
        j = i + horizon
        if j >= len(rows) or r["atr"] <= 0 or rows[j]["time"] - r["time"] > max_gap:
            out.append(None)
        else:
            out.append((rows[j]["close"] - r["close"]) / r["atr"])
    return out


def describe(values):
    """Estadísticos de una muestra de retornos no solapados."""
    n = len(values)
    if n == 0:
        return None
    mean = statistics.fmean(values)
    std = statistics.stdev(values) if n > 1 else 0.0
    t = mean / (std / math.sqrt(n)) if std > 0 else 0.0
    return {
        "n": n,
        "n_eff": n,
        "mean": mean,
        "std": std,
        "t": t,
        "pct_up": sum(1 for v in values if v > 0) / n,
        "mean_abs": statistics.fmean(abs(v) for v in values),
    }


def run_lengths(rows):
    runs = {k: [] for k in REGIMES}
    if not rows:
        return runs
    cur, length = rows[0]["regime"], 1
    for prev, r in zip(rows, rows[1:]):
        contiguous = r["time"] - prev["time"] <= timedelta(minutes=BAR_MINUTES * 3)
        if r["regime"] == cur and contiguous:
            length += 1
        else:
            runs.setdefault(cur, []).append(length)
            cur, length = r["regime"], 1
    runs.setdefault(cur, []).append(length)
    return runs


def analyze(rows, horizons):
    result = {"rows": len(rows), "horizons": {}, "share": {}, "runs": {}, "verdicts": []}
    if not rows:
        return result
    days = max((rows[-1]["time"] - rows[0]["time"]).total_seconds() / 86400.0, 1e-9)
    result["period"] = (rows[0]["time"], rows[-1]["time"])
    for reg in REGIMES:
        result["share"][reg] = sum(1 for r in rows if r["regime"] == reg) / len(rows)
    runs = run_lengths(rows)
    switches = sum(len(v) for v in runs.values()) - 1
    result["switches_per_day"] = switches / days
    for reg, lens in runs.items():
        if lens:
            result["runs"][reg] = {"count": len(lens), "median_bars": statistics.median(lens),
                                   "mean_bars": statistics.fmean(lens)}

    for h in horizons:
        fwd = forward_returns(rows, h)
        sampled = [i for i in range(0, len(rows), h) if fwd[i] is not None]
        base = describe([fwd[i] for i in sampled])
        per = {reg: describe([fwd[i] for i in sampled if rows[i]["regime"] == reg]) for reg in REGIMES}
        # reversión a la media en RANGE: retorno firmado desde los extremos del rango
        # (positivo si el precio vuelve hacia el centro)
        reversion = []
        for i in sampled:
            r = rows[i]
            width = r["range_high"] - r["range_low"]
            if r["regime"] != "RANGE" or width <= 0:
                continue
            pos = (r["close"] - r["range_low"]) / width - 0.5
            if abs(pos) >= RANGE_EXTREME:
                reversion.append(-math.copysign(1.0, pos) * fwd[i])
        rev = describe(reversion)
        result["horizons"][h] = {"all": base, "per": per, "range_reversion": rev}
        result["verdicts"].extend(verdicts(h, base, per, rev))
    return result


def verdicts(h, base, per, rev):
    out = []

    def sample_ok(st):
        return st is not None and st["n_eff"] >= MIN_EFFECTIVE_N

    up = per.get("TREND_UP")
    if not sample_ok(up):
        out.append((h, "TREND_UP", "MUESTRA INSUFICIENTE", "n_eff < %d" % MIN_EFFECTIVE_N))
    elif up["mean"] > 0 and up["t"] >= T_THRESHOLD:
        out.append((h, "TREND_UP", "CONSISTENTE", "media %+.3f ATR, t=%.2f" % (up["mean"], up["t"])))
    else:
        out.append((h, "TREND_UP", "NO DEMOSTRADO", "media %+.3f ATR, t=%.2f" % (up["mean"], up["t"])))

    dn = per.get("TREND_DOWN")
    if not sample_ok(dn):
        out.append((h, "TREND_DOWN", "MUESTRA INSUFICIENTE", "n_eff < %d" % MIN_EFFECTIVE_N))
    elif dn["mean"] < 0 and dn["t"] <= -T_THRESHOLD:
        out.append((h, "TREND_DOWN", "CONSISTENTE", "media %+.3f ATR, t=%.2f" % (dn["mean"], dn["t"])))
    else:
        out.append((h, "TREND_DOWN", "NO DEMOSTRADO", "media %+.3f ATR, t=%.2f" % (dn["mean"], dn["t"])))

    hv = per.get("HIGH_VOLATILITY")
    if not sample_ok(hv) or base is None:
        out.append((h, "HIGH_VOLATILITY", "MUESTRA INSUFICIENTE", "n_eff < %d" % MIN_EFFECTIVE_N))
    elif hv["mean_abs"] >= HIGH_VOL_ABS_FACTOR * base["mean_abs"]:
        out.append((h, "HIGH_VOLATILITY", "CONSISTENTE",
                    "|mov| %.3f vs %.3f global" % (hv["mean_abs"], base["mean_abs"])))
    else:
        out.append((h, "HIGH_VOLATILITY", "NO DEMOSTRADO",
                    "|mov| %.3f vs %.3f global" % (hv["mean_abs"], base["mean_abs"])))

    if not sample_ok(rev):
        out.append((h, "RANGE", "MUESTRA INSUFICIENTE", "n extremos < %d" % MIN_EFFECTIVE_N))
    elif rev["mean"] > 0 and rev["t"] >= T_THRESHOLD:
        out.append((h, "RANGE", "CONSISTENTE", "reversión media %+.3f ATR desde extremos, t=%.2f" % (rev["mean"], rev["t"])))
    else:
        out.append((h, "RANGE", "NO DEMOSTRADO", "reversión media %+.3f ATR desde extremos, t=%.2f" % (rev["mean"], rev["t"])))
    return out


def fmt(st):
    if st is None:
        return "| — | — | — | — | — | — |"
    return "| %d | %.0f | %+.3f | %.2f | %.0f%% | %.3f |" % (
        st["n"], st["n_eff"], st["mean"], st["t"], 100 * st["pct_up"], st["mean_abs"])


def render(res, sources):
    lines = ["# Validación del RegimeEngine", ""]
    lines.append("Fuentes: " + ", ".join(sources))
    if not res["rows"]:
        lines.append("\nSin filas que analizar.")
        return "\n".join(lines)
    a, b = res["period"]
    lines += [f"Periodo: {a} → {b} · filas: {res['rows']} · cambios de régimen por día: {res['switches_per_day']:.2f}", ""]
    lines += ["## Distribución y persistencia", "", "| Régimen | % del tiempo | Episodios | Mediana (velas M5) | Media (velas M5) |",
              "|---|---|---|---|---|"]
    for reg in REGIMES:
        rr = res["runs"].get(reg)
        lines.append("| %s | %.1f%% | %s | %s | %s |" % (
            reg, 100 * res["share"].get(reg, 0), rr["count"] if rr else 0,
            "%.0f" % rr["median_bars"] if rr else "—", "%.1f" % rr["mean_bars"] if rr else "—"))
    for h, data in res["horizons"].items():
        lines += ["", f"## Horizonte {h} velas M5 ({h * BAR_MINUTES} min) — retorno en ATR H1", "",
                  "| Régimen | n (no solapados) | n_eff | media | t | % sube | media abs |", "|---|---|---|---|---|---|---|"]
        lines.append("| TODOS " + fmt(data["all"]))
        for reg in REGIMES:
            lines.append(f"| {reg} " + fmt(data["per"][reg]))
        rv = data["range_reversion"]
        lines.append("")
        lines.append("RANGE, retorno firmado desde extremos (|posición| ≥ %.2f, positivo = vuelve al centro): %s" % (
            RANGE_EXTREME, "media %+.3f ATR, t=%.2f, n=%d" % (rv["mean"], rv["t"], rv["n"]) if rv else "—"))
    lines += ["", "## Veredictos (hipótesis, no garantía)", "", "| Horizonte | Régimen | Estado | Detalle |", "|---|---|---|---|"]
    for h, reg, status, detail in res["verdicts"]:
        lines.append(f"| {h} | {reg} | {status} | {detail} |")
    lines += ["", "Notas:",
              f"- Se usa una muestra cada `horizonte` velas (retornos no solapados). Se exigen ≥ {MIN_EFFECTIVE_N} observaciones.",
              f"- |t| ≥ {T_THRESHOLD} es un umbral aproximado; con varias pruebas simultáneas algún resultado puede salir 'consistente' por azar.",
              "- Un umbral calibrado en este periodo debe confirmarse en un periodo distinto (fuera de muestra) antes de aceptarse."]
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--horizons", default="12,48", help="horizontes en velas M5, separados por coma")
    ap.add_argument("--out", help="archivo Markdown de salida (por defecto, stdout)")
    args = ap.parse_args(argv)
    horizons = [int(x) for x in args.horizons.split(",") if x.strip()]
    if any(h <= 0 for h in horizons):
        raise SystemExit("Los horizontes deben ser > 0")
    res = analyze(load_rows(args.csv), horizons)
    text = render(res, args.csv)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
