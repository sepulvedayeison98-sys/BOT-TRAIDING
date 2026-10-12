"""Pruebas de Tools/regime_report.py con datos sintéticos de comportamiento conocido.

Ejecutar: python3 -m unittest discover -s XAUUSD_AUTONOMOUS/Tools/tests -v
"""
import csv
import os
import random
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import regime_report as rr  # noqa: E402

HEADER = ["server_time", "utc_time", "session", "m5_close", "h1_atr", "regime", "raw_regime", "h1_adx",
          "h1_atr_ratio", "m15_atr_ratio", "h1_slope", "h1_structure", "m15_structure", "range_high",
          "range_low", "spread_ratio", "reason"]


def make_rows(segments, seed=7, start=datetime(2025, 1, 6, 0, 0)):
    """segments: lista de (régimen, n_velas, función(paso, precio, rng) -> precio, (rango_alto, rango_bajo))."""
    rng = random.Random(seed)
    t, price, rows = start, 2400.0, []
    for regime, n, step, rbounds in segments:
        for _ in range(n):
            price = step(price, rng)
            hi, lo = rbounds if rbounds else (0.0, 0.0)
            rows.append([t.strftime("%Y.%m.%d %H:%M"), t.strftime("%Y.%m.%d %H:%M"), "LONDON", "%.2f" % price,
                         "5.0", regime, regime, "25", "1.0", "1.0", "0.1", "MIXED", "MIXED", "%.2f" % hi,
                         "%.2f" % lo, "1.0", "test"])
            t += timedelta(minutes=5)
    return rows


def write_csv(rows):
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        w.writerows(rows)
    return path


def up(p, r):
    return p + 0.25 + r.gauss(0, 0.8)


def down(p, r):
    return p - 0.25 + r.gauss(0, 0.8)


def walk(p, r):
    return p + r.gauss(0, 0.8)


def wild(p, r):
    return p + r.gauss(0, 4.0)


def revert(p, r):
    return p + 0.08 * (2400.0 - p) + r.gauss(0, 0.8)


def verdict(res, h, regime):
    for hh, reg, status, _ in res["verdicts"]:
        if hh == h and reg == regime:
            return status
    return None


class RegimeReportTest(unittest.TestCase):
    def analyze(self, segments, horizons=(12,), seed=7):
        path = write_csv(make_rows(segments, seed))
        try:
            return rr.analyze(rr.load_rows([path]), list(horizons))
        finally:
            os.remove(path)

    def test_known_behaviour_is_detected(self):
        res = self.analyze([
            # RANGE primero: el proceso revierte hacia 2400, precio inicial de la serie
            ("RANGE", 3000, revert, (2404.0, 2396.0)),  # ±2 desviaciones del proceso
            ("TREND_UP", 3000, up, None),
            ("TREND_DOWN", 3000, down, None),
            ("HIGH_VOLATILITY", 3000, wild, None),
            ("NO_TRADE", 3000, walk, None),
        ])
        self.assertEqual(verdict(res, 12, "TREND_UP"), "CONSISTENTE")
        self.assertEqual(verdict(res, 12, "TREND_DOWN"), "CONSISTENTE")
        self.assertEqual(verdict(res, 12, "HIGH_VOLATILITY"), "CONSISTENTE")
        self.assertEqual(verdict(res, 12, "RANGE"), "CONSISTENTE")

    def test_random_walk_labelled_as_trend_is_not_confirmed(self):
        res = self.analyze([
            ("TREND_UP", 6000, walk, None),
            ("TREND_DOWN", 6000, walk, None),
            ("HIGH_VOLATILITY", 3000, walk, None),
            ("RANGE", 6000, walk, (2500.0, 2300.0)),
        ])
        self.assertEqual(verdict(res, 12, "TREND_UP"), "NO DEMOSTRADO")
        self.assertEqual(verdict(res, 12, "TREND_DOWN"), "NO DEMOSTRADO")
        self.assertEqual(verdict(res, 12, "HIGH_VOLATILITY"), "NO DEMOSTRADO")
        self.assertEqual(verdict(res, 12, "RANGE"), "NO DEMOSTRADO")

    def test_small_sample_is_flagged(self):
        res = self.analyze([("TREND_UP", 200, up, None), ("NO_TRADE", 200, walk, None)])
        self.assertEqual(verdict(res, 12, "TREND_UP"), "MUESTRA INSUFICIENTE")
        self.assertEqual(verdict(res, 12, "RANGE"), "MUESTRA INSUFICIENTE")

    def test_forward_return_skips_data_gaps(self):
        rows = [
            {"time": datetime(2025, 1, 10, 21, 50), "close": 100.0, "atr": 1.0},
            {"time": datetime(2025, 1, 10, 21, 55), "close": 101.0, "atr": 1.0},
            {"time": datetime(2025, 1, 13, 0, 0), "close": 150.0, "atr": 1.0},   # fin de semana
        ]
        fwd = rr.forward_returns(rows, 1)
        self.assertAlmostEqual(fwd[0], 1.0)
        self.assertIsNone(fwd[1])
        self.assertIsNone(fwd[2])

    def test_runs_and_share(self):
        res = self.analyze([("TREND_UP", 100, up, None), ("NO_TRADE", 50, walk, None), ("TREND_UP", 100, up, None)])
        self.assertEqual(res["runs"]["TREND_UP"]["count"], 2)
        self.assertEqual(res["runs"]["TREND_UP"]["median_bars"], 100)
        self.assertAlmostEqual(res["share"]["NO_TRADE"], 50 / 250)

    def test_header_matches_regime_logger(self):
        """El CSV que escribe RegimeLogger.mq5 debe tener exactamente las columnas que este reporte lee."""
        src = os.path.join(os.path.dirname(__file__), "..", "..", "Tests", "Backtesting", "RegimeLogger.mq5")
        with open(src, encoding="utf-8") as fh:
            code = fh.read()
        start = code.index('FileWriteString(g_csv, "server_time')
        chunk = code[start:code.index(";", start)]
        header = "".join(part for i, part in enumerate(chunk.split('"')) if i % 2 == 1).replace("\\r\\n", "")
        self.assertEqual(header.split(","), HEADER)

    def test_render_and_cli(self):
        path = write_csv(make_rows([("TREND_UP", 500, up, None)]))
        out = path + ".md"
        try:
            self.assertEqual(rr.main([path, "--horizons", "12,48", "--out", out]), 0)
            with open(out, encoding="utf-8") as fh:
                text = fh.read()
            self.assertIn("Horizonte 48", text)
            self.assertIn("Veredictos", text)
        finally:
            os.remove(path)
            if os.path.exists(out):
                os.remove(out)


if __name__ == "__main__":
    unittest.main()
