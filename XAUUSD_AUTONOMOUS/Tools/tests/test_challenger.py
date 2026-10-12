"""Pruebas de Tools/challenger.py.

Ejecutar: python3 -m unittest discover -s XAUUSD_AUTONOMOUS/Tools/tests -v
"""
import csv
import hashlib
import os
import random
import re
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
import challenger as ch  # noqa: E402

HEADER = ("run_tag,identifier,signal_id,setup_key,strategy,direction,session,regime,score,open_time,close_time,volume,"
          "entry_price,exit_price,initial_sl,tp,risk_money,profit,commission,swap,net,r_multiple,slippage_points,spread_points").split(",")


def trade_rows(tag, rs, start=datetime(2025, 1, 6, 9, 0), strategy="SMC"):
    rows = []
    t = start
    for i, r in enumerate(rs):
        net = 100.0 * r
        rows.append([tag, str(i), f"S{i}", f"K{i}", strategy, "LONG", "LONDON", "TREND_UP", "80",
                     t.strftime("%Y.%m.%d %H:%M:%S"), (t + timedelta(hours=2)).strftime("%Y.%m.%d %H:%M:%S"),
                     "0.20", "2400", "2410", "2395", "2410", "100", f"{net + 1.4:.2f}", "-1.40", "0.00",
                     f"{net:.2f}", f"{r:.4f}", "2.0", "20"])
        t += timedelta(hours=6)
    return rows


def write(rows):
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        w.writerows(rows)
    return path


def r_series(n, mean, sd, seed):
    rng = random.Random(seed)
    return [rng.gauss(mean, sd) for _ in range(n)]


class MetricsTest(unittest.TestCase):
    def test_metrics_by_hand(self):
        trades = [{"net": 200, "r": 2, "commission": -1, "swap": 0, "slippage": 2},
                  {"net": -100, "r": -1, "commission": -1, "swap": 0, "slippage": 0},
                  {"net": -100, "r": -1, "commission": -1, "swap": -0.5, "slippage": 4},
                  {"net": 300, "r": 3, "commission": -1, "swap": 0, "slippage": 2}]
        m = ch.metrics(trades)
        self.assertEqual(m["trades"], 4)
        self.assertAlmostEqual(m["net"], 300)
        self.assertAlmostEqual(m["pf"], 500 / 200)
        self.assertAlmostEqual(m["win_rate"], 0.5)
        self.assertAlmostEqual(m["exp_r"], 0.75)
        self.assertAlmostEqual(m["max_dd"], 200)        # 200 -> 0
        self.assertAlmostEqual(m["max_dd_r"], 2)
        self.assertEqual(m["max_loss_streak"], 2)
        self.assertAlmostEqual(m["commission"], -4)
        self.assertAlmostEqual(m["slippage"], 2)

    def test_empty_and_no_losses(self):
        self.assertEqual(ch.metrics([])["trades"], 0)
        self.assertEqual(ch.metrics([{"net": 5, "r": 1, "commission": 0, "swap": 0, "slippage": 0}])["pf"], float("inf"))

    def test_parse_tag(self):
        self.assertEqual(ch.parse_tag("chal_f2_OOS"), ("chal", "f2", "OOS"))
        self.assertEqual(ch.parse_tag("my_model_f1_IS"), ("my_model", "f1", "IS"))
        self.assertIsNone(ch.parse_tag("live"))


class CompareTest(unittest.TestCase):
    def build(self, chal_is, chal_oos, champ_is=0.10, champ_oos=0.10, n=60, folds=3):
        rows = []
        for k in range(folds):
            f = f"f{k + 1}"
            rows += trade_rows(f"champ_{f}_IS", r_series(n, champ_is, 1.0, 100 + k))
            rows += trade_rows(f"champ_{f}_OOS", r_series(n, champ_oos, 1.0, 200 + k))
            rows += trade_rows(f"chal_{f}_IS", r_series(n, chal_is, 1.0, 300 + k))
            rows += trade_rows(f"chal_{f}_OOS", r_series(n, chal_oos, 1.0, 400 + k))
        path = write(rows)
        try:
            return ch.compare(ch.load_trades([path]))
        finally:
            os.remove(path)

    def test_better_challenger_is_recommended(self):
        res = self.build(chal_is=0.6, chal_oos=0.6, champ_oos=0.05)
        self.assertTrue(res["promote"], res["reasons"])
        self.assertGreater(res["ci"][0], 0)

    def test_overfit_challenger_is_rejected(self):
        res = self.build(chal_is=1.5, chal_oos=-0.1, champ_oos=0.05)
        self.assertFalse(res["promote"])
        self.assertTrue(any("esperanza OOS" in r for r in res["reasons"]))
        self.assertGreater(res["challenger"]["degradation"], 1.0)

    def test_small_sample_is_rejected(self):
        res = self.build(chal_is=0.6, chal_oos=0.6, champ_oos=0.05, n=20)
        self.assertFalse(res["promote"])
        self.assertTrue(any("insuficiente" in r for r in res["reasons"]))

    def test_not_significant_is_rejected(self):
        res = self.build(chal_is=0.12, chal_oos=0.12, champ_oos=0.10)
        self.assertFalse(res["promote"])

    def test_report_text(self):
        path = write(trade_rows("chal_f1_OOS", [1, -1, 2]))
        try:
            text = ch.report(ch.load_trades([path]))
        finally:
            os.remove(path)
        self.assertIn("TOTAL: n=3", text)
        self.assertIn("Por strategy", text)


class ModelTest(unittest.TestCase):
    def test_whitelist_matches_mql5(self):
        src = os.path.join(HERE, "..", "..", "Include", "XAUUSD", "LearningEngine.mqh")
        with open(src, encoding="utf-8") as fh:
            code = fh.read()
        block = code[code.index("string allowed[] ="):code.index("};", code.index("string allowed[] ="))]
        mql_keys = re.findall(r'"([a-z0-9_.]+)"', block)
        self.assertEqual(mql_keys, ch.ALLOWED_KEYS)

    def test_no_risk_keys_allowed(self):
        for k in ch.ALLOWED_KEYS:
            self.assertFalse(k.startswith(("risk.", "position.", "execution.", "news.")), k)

    def test_write_model_and_hash(self):
        d = tempfile.mkdtemp()
        params = os.path.join(d, "p.txt")
        with open(params, "w") as fh:
            fh.write("# comentario\nadaptive.min_score=70\nregime.trend_adx_min=24\n")
        out = os.path.join(d, "champion.model")
        sha = ch.write_model(ch.read_params(params), "v3", "Yeison", out, at="2026-10-12")
        with open(out, encoding="utf-8") as fh:
            text = fh.read()
        body = text[:text.index("sha256=")]
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(), sha)
        self.assertTrue(text.endswith(f"sha256={sha}\n"))
        self.assertIn("approved=yes\napproved_by=Yeison\napproved_at=2026-10-12\n", text)

    def test_known_answer_body_hash(self):
        # Mismo cuerpo y hash que verifica Test_Phase9.mq5 (consistencia Python <-> MQL5)
        body = ch.model_body([("adaptive.min_score", "70")], "v1", "Tester", "2026-10-12")
        self.assertEqual(body, "version=v1\napproved=yes\napproved_by=Tester\napproved_at=2026-10-12\nadaptive.min_score=70\n")
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(),
                         "7e40c42c224938bdb08d756d608c0ef0c1ef84773ae17d104e0765c435ede425")

    def test_forbidden_key_rejected(self):
        d = tempfile.mkdtemp()
        params = os.path.join(d, "p.txt")
        with open(params, "w") as fh:
            fh.write("risk.risk_pct=5\n")
        with self.assertRaises(SystemExit):
            ch.read_params(params)

    def test_approve_requires_flag(self):
        d = tempfile.mkdtemp()
        params = os.path.join(d, "p.txt")
        with open(params, "w") as fh:
            fh.write("adaptive.min_score=70\n")
        with self.assertRaises(SystemExit):
            ch.main(["approve", "--params", params, "--version", "v", "--by", "x", "--out", os.path.join(d, "m")])
        self.assertEqual(ch.main(["approve", "--params", params, "--version", "v", "--by", "x",
                                  "--out", os.path.join(d, "m"), "--i-approve"]), 0)


class FoldsTest(unittest.TestCase):
    def test_walk_forward_dates(self):
        folds = ch.make_folds(date(2023, 1, 1), date(2025, 1, 1), 12, 3, 3)
        self.assertEqual(folds[0], ("f1", date(2023, 1, 1), date(2024, 1, 1), date(2024, 4, 1)))
        self.assertEqual(folds[1][1], date(2023, 4, 1))
        self.assertEqual(len(folds), 4)          # el último OOS termina el 2025-01-01
        for _, a, b, c in folds:
            self.assertLess(a, b)
            self.assertLess(b, c)

    def test_write_folds(self):
        d = tempfile.mkdtemp()
        base = os.path.join(d, "base.set")
        with open(base, "w") as fh:
            fh.write("InpRiskPct=1.0\nInpRunTag=old\n")
        tags = ch.write_folds(ch.make_folds(date(2023, 1, 1), date(2024, 4, 1), 12, 3, 3), "chal", base,
                              os.path.join(d, "out"), "XAUUSD\\XAUUSD_Autonomous", "XAUUSD", 4)
        self.assertEqual(tags, ["chal_f1_IS", "chal_f1_OOS"])
        with open(os.path.join(d, "out", "chal_f1_OOS.set"), encoding="utf-8") as fh:
            s = fh.read()
        self.assertIn("InpRunTag=chal_f1_OOS", s)
        self.assertNotIn("InpRunTag=old", s)
        self.assertIn("InpRiskPct=1.0", s)
        with open(os.path.join(d, "out", "chal_f1_OOS.ini"), encoding="utf-8") as fh:
            ini = fh.read()
        self.assertIn("FromDate=2024.01.01", ini)
        self.assertIn("ToDate=2024.04.01", ini)


if __name__ == "__main__":
    unittest.main()
