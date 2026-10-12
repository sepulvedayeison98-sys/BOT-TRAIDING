#!/usr/bin/env python3
"""Challenger offline del XAUUSD Autonomous Trading System (Fase 9).

El Challenger NO opera, NO modifica el EA en producción y NO toca parámetros de
riesgo. Analiza diarios de operaciones exportados por el EA (CSV en la carpeta
común de MT5) de corridas del Strategy Tester y propone, o no, promover una
configuración. La promoción exige tu aprobación explícita (comando `approve`).

Comandos:
  report  CSV...                         métricas totales y por estrategia/sesión/régimen
  compare CSV... [--champion champ] [--challenger chal]
                                         Champion vs Challenger por pliegues IS/OOS
  approve --params P --version V --by NOMBRE --i-approve --out champion.model
                                         genera el modelo firmado (sha256) que el EA acepta
  folds   --start --end --is-months --oos-months --step-months --base-set --out
                                         archivos .ini/.set para walk-forward en el tester

Convención de run_tag (input InpRunTag del EA): <modelo>_<pliegue>_<IS|OOS>,
por ejemplo champ_f1_IS, chal_f1_OOS.

Solo librería estándar (Python 3.8+).
"""
import argparse
import csv
import hashlib
import math
import os
import random
import statistics
import sys
from datetime import date, datetime

# Debe coincidir EXACTAMENTE con CLearningEngine::AllowedKey (lo verifica la prueba).
ALLOWED_KEYS = [
    "adaptive.min_score", "adaptive.high_score",
    "regime.trend_adx_min", "regime.range_adx_max", "regime.high_vol_h1_atr_ratio", "regime.high_vol_m15_atr_ratio",
    "regime.low_vol_atr_ratio", "regime.trend_min_slope", "regime.range_max_slope", "regime.confirm_evaluations",
    "smc.lookback_m15", "smc.sweep_min_pen_atr", "smc.fvg_min_atr", "smc.require_discount",
    "breakout.box_bars", "breakout.max_box_atr", "breakout.min_break_atr", "breakout.min_body_ratio",
    "breakout.require_volume", "breakout.max_bars_since_break",
    "reversal.lookback_m15", "reversal.rsi_min_diff", "reversal.extension_atr", "reversal.min_confirmations",
    "strategy.smc_enabled", "strategy.breakout_enabled", "strategy.reversal_enabled",
]

# Criterios de promoción (documentados en Documentation/TESTING.md)
MIN_OOS_TRADES = 100
MIN_OOS_PF = 1.2
MIN_POSITIVE_FOLD_SHARE = 2.0 / 3.0
MAX_DD_WORSENING = 1.2
BOOTSTRAP_SAMPLES = 2000


# ----------------------------------------------------------------- datos
def load_trades(paths):
    rows = []
    for p in paths:
        with open(p, newline="", encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                try:
                    rows.append({
                        "run_tag": r["run_tag"],
                        "strategy": r["strategy"],
                        "session": r["session"],
                        "regime": r["regime"],
                        "open_time": r["open_time"],
                        "net": float(r["net"]),
                        "r": float(r["r_multiple"]),
                        "commission": float(r["commission"]),
                        "swap": float(r["swap"]),
                        "slippage": float(r["slippage_points"]),
                    })
                except (KeyError, ValueError) as exc:
                    raise SystemExit(f"Fila inválida en {p}: {exc}")
    rows.sort(key=lambda x: x["open_time"])
    return rows


def parse_tag(tag):
    parts = tag.split("_")
    if len(parts) < 3 or parts[-1] not in ("IS", "OOS"):
        return None
    return "_".join(parts[:-2]), parts[-2], parts[-1]


# ------------------------------------------------------------- métricas
def metrics(trades):
    n = len(trades)
    m = {"trades": n, "net": 0.0, "win_rate": 0.0, "pf": 0.0, "exp": 0.0, "exp_r": 0.0,
         "max_dd": 0.0, "max_dd_r": 0.0, "max_loss_streak": 0, "commission": 0.0, "swap": 0.0, "slippage": 0.0}
    if n == 0:
        return m
    gp = sum(t["net"] for t in trades if t["net"] > 0)
    gl = -sum(t["net"] for t in trades if t["net"] <= 0)
    m["net"] = sum(t["net"] for t in trades)
    m["win_rate"] = sum(1 for t in trades if t["net"] > 0) / n
    m["pf"] = gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)
    m["exp"] = m["net"] / n
    m["exp_r"] = sum(t["r"] for t in trades) / n
    m["commission"] = sum(t["commission"] for t in trades)
    m["swap"] = sum(t["swap"] for t in trades)
    m["slippage"] = sum(t["slippage"] for t in trades) / n
    eq = peak = eq_r = peak_r = 0.0
    streak = 0
    for t in trades:
        eq += t["net"]
        eq_r += t["r"]
        peak = max(peak, eq)
        peak_r = max(peak_r, eq_r)
        m["max_dd"] = max(m["max_dd"], peak - eq)
        m["max_dd_r"] = max(m["max_dd_r"], peak_r - eq_r)
        streak = streak + 1 if t["net"] <= 0 else 0
        m["max_loss_streak"] = max(m["max_loss_streak"], streak)
    return m


def bootstrap_diff_ci(a, b, samples=BOOTSTRAP_SAMPLES, seed=12345):
    """IC 95 % de mean(a) - mean(b) por remuestreo independiente."""
    if not a or not b:
        return None
    rng = random.Random(seed)
    diffs = []
    for _ in range(samples):
        ma = sum(rng.choice(a) for _ in range(len(a))) / len(a)
        mb = sum(rng.choice(b) for _ in range(len(b))) / len(b)
        diffs.append(ma - mb)
    diffs.sort()
    return diffs[int(0.025 * samples)], diffs[int(0.975 * samples) - 1]


def model_summary(rows, model):
    folds = {}
    for t in rows:
        tag = parse_tag(t["run_tag"])
        if not tag or tag[0] != model:
            continue
        folds.setdefault(tag[1], {"IS": [], "OOS": []})[tag[2]].append(t)
    oos_all = [t for f in folds.values() for t in f["OOS"]]
    is_all = [t for f in folds.values() for t in f["IS"]]
    fold_oos = {k: metrics(v["OOS"])["exp_r"] for k, v in folds.items() if v["OOS"]}
    m_oos = metrics(oos_all)
    m_is = metrics(is_all)
    std_fold = statistics.pstdev(fold_oos.values()) if len(fold_oos) > 1 else 0.0
    degradation = max(0.0, m_is["exp_r"] - m_oos["exp_r"]) if is_all else 0.0
    robust = m_oos["exp_r"] - 0.5 * degradation - 0.5 * std_fold - 0.02 * m_oos["max_dd_r"]
    return {"folds": fold_oos, "oos": m_oos, "is": m_is, "std_fold": std_fold, "degradation": degradation,
            "robust": robust, "oos_r": [t["r"] for t in oos_all]}


def compare(rows, champion="champ", challenger="chal"):
    ch = model_summary(rows, champion)
    cl = model_summary(rows, challenger)
    reasons = []
    o = cl["oos"]
    if o["trades"] < MIN_OOS_TRADES:
        reasons.append(f"Challenger con {o['trades']} operaciones OOS (< {MIN_OOS_TRADES}): muestra insuficiente")
    if o["exp_r"] <= 0:
        reasons.append(f"esperanza OOS {o['exp_r']:+.3f}R no positiva")
    if o["pf"] < MIN_OOS_PF:
        reasons.append(f"profit factor OOS {o['pf']:.2f} < {MIN_OOS_PF}")
    pos = [v for v in cl["folds"].values() if v > 0]
    if cl["folds"] and len(pos) / len(cl["folds"]) < MIN_POSITIVE_FOLD_SHARE:
        reasons.append(f"solo {len(pos)}/{len(cl['folds'])} pliegues OOS positivos (inestable)")
    if ch["oos"]["trades"] > 0 and o["max_dd_r"] > MAX_DD_WORSENING * max(ch["oos"]["max_dd_r"], 1e-9):
        reasons.append(f"drawdown OOS {o['max_dd_r']:.2f}R > {MAX_DD_WORSENING}x el del Champion ({ch['oos']['max_dd_r']:.2f}R)")
    if cl["robust"] <= ch["robust"]:
        reasons.append(f"puntuación robusta {cl['robust']:+.3f} <= Champion {ch['robust']:+.3f}")
    ci = bootstrap_diff_ci(cl["oos_r"], ch["oos_r"]) if ch["oos_r"] else None
    if ch["oos_r"] and (ci is None or ci[0] <= 0):
        reasons.append("la mejora OOS frente al Champion no es significativa (IC 95 % incluye 0)")
    return {"champion": ch, "challenger": cl, "ci": ci, "promote": not reasons, "reasons": reasons}


# ----------------------------------------------------------------- informes
def fmt_m(m):
    pf = "inf" if m["pf"] == float("inf") else f"{m['pf']:.2f}"
    return (f"n={m['trades']} acierto={100 * m['win_rate']:.1f}% PF={pf} neto={m['net']:.2f} "
            f"esperanza={m['exp']:.2f} ({m['exp_r']:+.3f}R) DD={m['max_dd']:.2f} ({m['max_dd_r']:.2f}R) "
            f"racha-={m['max_loss_streak']} comisión={m['commission']:.2f} swap={m['swap']:.2f} slippage={m['slippage']:.1f}")


def report(rows):
    lines = ["# Reporte de operaciones", "", "TOTAL: " + fmt_m(metrics(rows))]
    for key in ("strategy", "session", "regime", "run_tag"):
        lines += ["", f"## Por {key}"]
        for v in sorted({t[key] for t in rows}):
            lines.append(f"- {v}: " + fmt_m(metrics([t for t in rows if t[key] == v])))
    lines += ["", "Con pocas operaciones estas cifras no son estadísticamente concluyentes."]
    return "\n".join(lines)


def render_compare(res, champion, challenger):
    lines = ["# Champion vs Challenger", ""]
    for name, s in ((champion, res["champion"]), (challenger, res["challenger"])):
        lines += [f"## {name}", f"- IS:  {fmt_m(s['is'])}", f"- OOS: {fmt_m(s['oos'])}",
                  f"- esperanza OOS por pliegue: " + ", ".join(f"{k}={v:+.3f}R" for k, v in sorted(s["folds"].items())),
                  f"- degradación IS→OOS {s['degradation']:.3f}R · dispersión entre pliegues {s['std_fold']:.3f}R",
                  f"- puntuación robusta = espOOS − 0.5·degradación − 0.5·dispersión − 0.02·DD(R) = {s['robust']:+.3f}", ""]
    if res["ci"]:
        lines.append(f"Diferencia OOS (Challenger − Champion), IC 95 % bootstrap: [{res['ci'][0]:+.3f}R, {res['ci'][1]:+.3f}R]")
    lines.append("")
    if res["promote"]:
        lines.append("**VEREDICTO: se RECOMIENDA promover el Challenger. Requiere tu aprobación explícita (`approve`).**")
    else:
        lines.append("**VEREDICTO: NO promover.**")
        lines += [f"- {r}" for r in res["reasons"]]
    lines += ["", "Ningún resultado histórico garantiza rendimiento futuro. La promoción nunca es automática."]
    return "\n".join(lines)


# ----------------------------------------------------------------- modelo
def model_body(params, version, by, at):
    lines = [f"version={version}", "approved=yes", f"approved_by={by}", f"approved_at={at}"]
    for k, v in params:
        lines.append(f"{k}={v}")
    return "".join(line + "\n" for line in lines)


def read_params(path):
    params = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise SystemExit(f"Línea sin '=': {line}")
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if k not in ALLOWED_KEYS:
                raise SystemExit(f"Clave no permitida: {k}. El modelo no puede tocar riesgo, ejecución ni noticias.")
            params.append((k, v))
    if not params:
        raise SystemExit("El archivo de parámetros está vacío")
    return params


def write_model(params, version, by, out, at=None):
    at = at or date.today().isoformat()
    body = model_body(params, version, by, at)
    sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body + f"sha256={sha}\n")
    return sha


# ----------------------------------------------------------------- pliegues
def add_months(d, months):
    y = d.year + (d.month - 1 + months) // 12
    m = (d.month - 1 + months) % 12 + 1
    return date(y, m, 1)


def make_folds(start, end, is_months, oos_months, step_months):
    folds = []
    s = start
    i = 1
    while True:
        is_end = add_months(s, is_months)
        oos_end = add_months(is_end, oos_months)
        if oos_end > end:
            break
        folds.append((f"f{i}", s, is_end, oos_end))
        s = add_months(s, step_months)
        i += 1
    return folds


def write_folds(folds, model, base_set, out_dir, expert, symbol, tester_model):
    os.makedirs(out_dir, exist_ok=True)
    base = []
    if base_set:
        with open(base_set, encoding="utf-8-sig") as fh:
            base = [ln.rstrip("\r\n") for ln in fh if not ln.startswith("InpRunTag=")]
    files = []
    for name, a, b, c in folds:
        for seg, f, t in (("IS", a, b), ("OOS", b, c)):
            tag = f"{model}_{name}_{seg}"
            with open(os.path.join(out_dir, tag + ".set"), "w", encoding="utf-8", newline="\r\n") as fh:
                fh.write("\n".join(base + [f"InpRunTag={tag}"]) + "\n")
            ini = ["[Tester]", f"Expert={expert}", f"Symbol={symbol}", "Period=M5", f"Model={tester_model}",
                   "Optimization=0", f"FromDate={f:%Y.%m.%d}", f"ToDate={t:%Y.%m.%d}", f"ExpertParameters={tag}.set",
                   f"Report={tag}", "ReplaceReport=1", "ShutdownTerminal=1"]
            with open(os.path.join(out_dir, tag + ".ini"), "w", encoding="utf-8", newline="\r\n") as fh:
                fh.write("\n".join(ini) + "\n")
            files.append(tag)
    return files


# ----------------------------------------------------------------- CLI
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("csv", nargs="+")
    c = sub.add_parser("compare")
    c.add_argument("csv", nargs="+")
    c.add_argument("--champion", default="champ")
    c.add_argument("--challenger", default="chal")
    a = sub.add_parser("approve")
    a.add_argument("--params", required=True)
    a.add_argument("--version", required=True)
    a.add_argument("--by", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--i-approve", action="store_true", help="confirmación explícita obligatoria")
    f = sub.add_parser("folds")
    f.add_argument("--start", required=True)
    f.add_argument("--end", required=True)
    f.add_argument("--is-months", type=int, default=12)
    f.add_argument("--oos-months", type=int, default=3)
    f.add_argument("--step-months", type=int, default=3)
    f.add_argument("--model", default="chal")
    f.add_argument("--base-set")
    f.add_argument("--expert", default="XAUUSD\\XAUUSD_Autonomous")
    f.add_argument("--symbol", default="XAUUSD")
    f.add_argument("--tester-model", type=int, default=4, help="4 = ticks reales (según la configuración del tester de MT5)")
    f.add_argument("--out", required=True)
    for p in (r, c):
        p.add_argument("--out")
    args = ap.parse_args(argv)

    if args.cmd == "report":
        text = report(load_trades(args.csv))
    elif args.cmd == "compare":
        res = compare(load_trades(args.csv), args.champion, args.challenger)
        text = render_compare(res, args.champion, args.challenger)
    elif args.cmd == "approve":
        if not args.i_approve:
            raise SystemExit("Falta --i-approve: la promoción del modelo requiere aprobación explícita.")
        sha = write_model(read_params(args.params), args.version, args.by, args.out)
        print(f"Modelo escrito en {args.out} (sha256 {sha}). Cópialo a <Common>/Files/XAUUSD/champion.model")
        return 0
    else:
        start = datetime.strptime(args.start, "%Y-%m-%d").date()
        end = datetime.strptime(args.end, "%Y-%m-%d").date()
        folds = make_folds(start, end, args.is_months, args.oos_months, args.step_months)
        if not folds:
            raise SystemExit("El periodo no alcanza para un pliegue IS + OOS")
        tags = write_folds(folds, args.model, args.base_set, args.out, args.expert, args.symbol, args.tester_model)
        print(f"{len(tags)} corridas generadas en {args.out}")
        return 0
    if getattr(args, "out", None):
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
