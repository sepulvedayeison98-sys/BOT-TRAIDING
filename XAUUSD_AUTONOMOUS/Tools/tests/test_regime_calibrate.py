"""Pruebas de Tools/regime_calibrate.py con series de comportamiento conocido.

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
import regime_calibrate as rc  # noqa: E402

HEADER = ["server_time", "utc_time", "session", "m5_close", "h1_atr", "regime", "raw_regime", "h1_adx",
          "h1_atr_ratio", "m15_atr_ratio", "h1_slope", "h1_structure", "m15_structure", "range_high",
          "range_low", "spread_ratio", "reason"]


def series(n_blocks, persistent, seed=3, block=96):
    """Bloques de `block` velas con ADX constante. Con `persistent`, los bloques de ADX alto
    (>= 30) tienen deriva en la dirección de la pendiente; el resto es caminata aleatoria."""
    rng = random.Random(seed)
    t, price, rows = datetime(2026, 1, 5), 400000.0, []
    for _ in range(n_blocks):
        adx = rng.uniform(10, 45)
        slope = rng.choice([-0.2, 0.2])
        drift = (0.6 if slope > 0 else -0.6) if (persistent and adx >= 30) else 0.0
        for _ in range(block):
            price += drift + rng.gauss(0, 3.0)
            rows.append([t.strftime("%Y.%m.%d %H:%M"), t.strftime("%Y.%m.%d %H:%M"), "NONE", "%.2f" % price,
                         "20.0", "NO_TRADE", "NO_TRADE", "%.1f" % adx, "1.0", "1.0", "%.3f" % slope, "MIXED", "MIXED",
                         "0", "0", "1.0", "test"])
            t += timedelta(minutes=5)
    return rows


def write_csv(rows):
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        w.writerows(rows)
    return path


class RegimeCalibrateTest(unittest.TestCase):
    def run_on(self, rows):
        path = write_csv(rows)
        try:
            data = rc.load([path])
            return rc.analyze(data, [12, 48], 22.0, 18.0), rc.render(rc.analyze(data, [12, 48], 22.0, 18.0), [path], 22.0, 18.0)
        finally:
            os.remove(path)

    def test_random_walk_gives_no_suggestion(self):
        res, text = self.run_on(series(400, persistent=False))
        self.assertIsNone(res["suggestion"])
        self.assertIn("NO cambiarlo", text)

    def test_persistence_above_adx_30_is_found(self):
        res, text = self.run_on(series(400, persistent=True))
        self.assertIsNotNone(res["suggestion"])
        self.assertGreaterEqual(res["suggestion"], 25.0)       # no propone umbrales donde no hay persistencia
        top = res["horizons"][48]["buckets"][4]
        self.assertGreater(top["t"], 2.0)
        self.assertIn("Candidato", text)

    def test_zone_shares_add_up(self):
        res, _ = self.run_on(series(50, persistent=False))
        self.assertAlmostEqual(res["neutral"] + res["above_trend"] + res["below_range"], 1.0, places=9)
        self.assertAlmostEqual(sum(res["share"].values()), 1.0, places=9)

    def test_empty_file(self):
        res, text = self.run_on([])
        self.assertEqual(res["rows"], 0)
        self.assertIn("Sin filas", text)


if __name__ == "__main__":
    unittest.main()
