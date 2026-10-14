"""Pruebas del servidor del dashboard (servidor HTTP real en un puerto local).

Ejecutar: python3 -m unittest discover -s XAUUSD_AUTONOMOUS/WebDashboard/tests -v
"""
import http.client
import json
import os
import secrets
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import server as srv  # noqa: E402

TOKEN = "t" * 40
PASSWORD = "contraseña-de-prueba-123"


class Clock:
    def __init__(self):
        self.t = time.time()

    def __call__(self):
        return self.t


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        env = {"XAD_TOKEN": TOKEN, "XAD_PASSWORD_HASH": srv.hash_password(PASSWORD, iterations=2000),
               "XAD_SESSION_SECRET": "s" * 40, "XAD_DB": os.path.join(cls.tmp, "db.sqlite3"),
               "XAD_COOKIE_SECURE": "0"}
        cls.cfg = srv.Config(env)
        assert not cls.cfg.validate()
        cls.clock = Clock()
        cls.app = srv.App(cls.cfg, srv.Store(cls.cfg.db_path), clock=cls.clock)
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), srv.make_handler(cls.app))
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    # --- utilidades
    def req(self, method, path, body="", headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        c.request(method, path, body=body.encode("utf-8"), headers=headers or {})
        r = c.getresponse()
        data = r.read().decode("utf-8")
        hdrs = dict(r.getheaders())
        c.close()
        return r.status, data, hdrs

    def ea(self, method, path, body="", ts=None, nonce=None, token=TOKEN):
        ts = str(int(self.clock()) if ts is None else ts)
        nonce = nonce or secrets.token_hex(8)
        sig = srv.sign(token, srv.ea_message(ts, nonce, method, path, body))
        return self.req(method, path, body, {"X-XAD-Timestamp": ts, "X-XAD-Nonce": nonce, "X-XAD-Signature": sig})

    def login(self):
        st, data, hdrs = self.req("POST", "/api/login", json.dumps({"password": PASSWORD}))
        self.assertEqual(st, 200, data)
        cookie = hdrs["Set-Cookie"].split(";")[0]
        return cookie, json.loads(data)["csrf"]

    # --- EA
    def test_telemetry_signed_ok(self):
        body = json.dumps({"equity": 10000.5, "state": "RUNNING", "symbol": "XAUUSD"})
        st, data, _ = self.ea("POST", "/api/ea/telemetry", body)
        self.assertEqual(st, 200, data)
        _, latest = self.app.store.latest()
        self.assertEqual(latest["equity"], 10000.5)

    def test_bad_signature_rejected(self):
        st, data, _ = self.ea("POST", "/api/ea/telemetry", "{}", token="x" * 40)
        self.assertEqual(st, 401)
        self.assertIn("firma", data)

    def test_tampered_body_rejected(self):
        ts, nonce = str(int(self.clock())), secrets.token_hex(8)
        sig = srv.sign(TOKEN, srv.ea_message(ts, nonce, "POST", "/api/ea/telemetry", '{"equity": 1}'))
        st, _, _ = self.req("POST", "/api/ea/telemetry", '{"equity": 999999}',
                            {"X-XAD-Timestamp": ts, "X-XAD-Nonce": nonce, "X-XAD-Signature": sig})
        self.assertEqual(st, 401)

    def test_replay_rejected(self):
        nonce = secrets.token_hex(8)
        self.assertEqual(self.ea("POST", "/api/ea/telemetry", "{}", nonce=nonce)[0], 200)
        st, data, _ = self.ea("POST", "/api/ea/telemetry", "{}", nonce=nonce)
        self.assertEqual(st, 401)
        self.assertIn("nonce", data)

    def test_stale_timestamp_rejected(self):
        st, data, _ = self.ea("POST", "/api/ea/telemetry", "{}", ts=int(self.clock()) - 300)
        self.assertEqual(st, 401)
        self.assertIn("timestamp", data)

    def test_keep_alive_same_connection(self):
        # El cliente WinINet de MT5 reutiliza la conexión: varias peticiones por el mismo socket.
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            for method, path, body in (("POST", "/api/ea/telemetry", "{}"), ("GET", "/api/ea/commands", ""),
                                       ("GET", "/api/ea/commands", "")):
                ts, nonce = str(int(self.clock())), secrets.token_hex(8)
                sig = srv.sign(TOKEN, srv.ea_message(ts, nonce, method, path, body))
                c.request(method, path, body=body.encode("utf-8"),
                          headers={"X-XAD-Timestamp": ts, "X-XAD-Nonce": nonce, "X-XAD-Signature": sig})
                r = c.getresponse()
                r.read()
                self.assertEqual(r.status, 200)
        finally:
            c.close()

    def test_invalid_json_rejected(self):
        self.assertEqual(self.ea("POST", "/api/ea/telemetry", "no es json")[0], 400)
        self.assertEqual(self.ea("POST", "/api/ea/telemetry", "[1,2]")[0], 400)

    def test_body_too_large(self):
        st, _, _ = self.ea("POST", "/api/ea/telemetry", "x" * (srv.MAX_BODY + 10))
        self.assertEqual(st, 413)

    # --- persona
    def test_login_required(self):
        self.assertEqual(self.req("GET", "/api/state")[0], 401)
        st, _, _ = self.req("POST", "/api/command", json.dumps({"cmd": "PAUSE"}))
        self.assertEqual(st, 401)

    def test_wrong_password(self):
        st, _, _ = self.req("POST", "/api/login", json.dumps({"password": "incorrecta-123456"}),
                            {"X-Forwarded-For": "1.2.3.4"})
        self.assertEqual(st, 401)

    def test_login_rate_limit(self):
        app = srv.App(self.cfg, self.app.store, clock=self.clock)
        for _ in range(srv.LOGIN_MAX_PER_MIN):
            self.assertTrue(app.login_allowed("9.9.9.9"))
        self.assertFalse(app.login_allowed("9.9.9.9"))
        self.clock.t += 61
        self.assertTrue(app.login_allowed("9.9.9.9"))

    def test_trust_proxy_client_ip(self):
        cfg = srv.Config({"XAD_TRUST_PROXY": "1"})
        self.assertTrue(cfg.trust_proxy)
        self.assertFalse(srv.Config({}).trust_proxy)
        self.assertFalse(self.cfg.trust_proxy)   # el servidor de prueba no confía en X-Forwarded-For
        # sin confianza, una cabecera falsificada no esquiva el límite: todos cuentan como 127.0.0.1
        app = srv.App(self.cfg, self.app.store, clock=self.clock)
        handler_cls = srv.make_handler(app)
        h = handler_cls.__new__(handler_cls)
        h.client_address = ("127.0.0.1", 5000)
        h.headers = {"X-Forwarded-For": "6.6.6.6"}
        self.assertEqual(h.client_ip(), "127.0.0.1")
        app.cfg = cfg
        h.headers = {"X-Forwarded-For": "6.6.6.6, 203.0.113.9"}
        self.assertEqual(h.client_ip(), "203.0.113.9")

    def test_favicon_no_404(self):
        self.assertEqual(self.req("GET", "/favicon.ico")[0], 204)

    def test_state_and_cookie_flags(self):
        _, _, hdrs = self.req("POST", "/api/login", json.dumps({"password": PASSWORD}))
        self.assertIn("HttpOnly", hdrs["Set-Cookie"])
        self.assertIn("SameSite=Strict", hdrs["Set-Cookie"])
        cookie, _ = self.login()
        self.ea("POST", "/api/ea/telemetry", json.dumps({"equity": 10100.0}))
        st, data, hdrs = self.req("GET", "/api/state", headers={"Cookie": cookie})
        self.assertEqual(st, 200)
        state = json.loads(data)
        self.assertTrue(state["ea_online"])
        self.assertIn("default-src 'self'", hdrs["Content-Security-Policy"])
        self.assertEqual(hdrs["X-Frame-Options"], "DENY")

    def test_tampered_session_rejected(self):
        cookie, _ = self.login()
        bad = cookie[:-1] + ("0" if cookie[-1] != "0" else "1")
        self.assertEqual(self.req("GET", "/api/state", headers={"Cookie": bad})[0], 401)

    def test_expired_session_rejected(self):
        cookie, _ = self.login()
        self.clock.t += srv.SESSION_TTL_SEC + 10
        try:
            self.assertEqual(self.req("GET", "/api/state", headers={"Cookie": cookie})[0], 401)
        finally:
            self.clock.t -= srv.SESSION_TTL_SEC + 10

    def test_command_flow(self):
        cookie, csrf = self.login()
        # sin CSRF -> 403
        st, _, _ = self.req("POST", "/api/command", json.dumps({"cmd": "PAUSE"}), {"Cookie": cookie})
        self.assertEqual(st, 403)
        # comando no permitido
        st, _, _ = self.req("POST", "/api/command", json.dumps({"cmd": "CLOSE_ALL"}), {"Cookie": cookie, "X-XAD-CSRF": csrf})
        self.assertEqual(st, 400)
        st, data, _ = self.req("POST", "/api/command", json.dumps({"cmd": "PAUSE"}), {"Cookie": cookie, "X-XAD-CSRF": csrf})
        self.assertEqual(st, 200)
        cid = json.loads(data)["id"]
        # el EA recoge el comando firmado
        st, data, _ = self.ea("GET", "/api/ea/commands")
        self.assertEqual(st, 200)
        line = [ln for ln in data.splitlines() if ln.startswith(f"{cid}|")][0]
        c_id, cmd, created, sig = line.split("|")
        self.assertEqual(cmd, "PAUSE")
        self.assertEqual(sig, srv.sign(TOKEN, srv.command_message(int(c_id), cmd, int(created))))
        # confirmación
        self.assertEqual(self.ea("POST", "/api/ea/ack", str(cid))[0], 200)
        self.assertEqual(self.ea("POST", "/api/ea/ack", str(cid))[0], 404)   # ya confirmado
        st, data, _ = self.ea("GET", "/api/ea/commands")
        self.assertNotIn(f"{cid}|", data)

    def test_commands_expire(self):
        cid = self.app.store.add_command("RESUME", "test", int(self.clock()) - srv.COMMAND_TTL_SEC - 5)
        st, data, _ = self.ea("GET", "/api/ea/commands")
        self.assertEqual(st, 200)
        self.assertNotIn(f"{cid}|", data)

    def test_static_files_and_traversal(self):
        st, data, hdrs = self.req("GET", "/")
        self.assertEqual(st, 200)
        self.assertIn("XAUUSD Autonomous", data)
        self.assertEqual(self.req("GET", "/static/app.js")[0], 200)
        self.assertEqual(self.req("GET", "/static/../server.py")[0], 404)
        self.assertEqual(self.req("GET", "/server.py")[0], 404)
        self.assertEqual(self.req("GET", "/static/%2e%2e/server.py")[0], 404)

    def test_no_inline_script_or_style(self):
        with open(os.path.join(srv.STATIC_DIR, "index.html"), encoding="utf-8") as fh:
            html = fh.read()
        self.assertNotIn("<script>", html)
        self.assertNotIn("style=", html)
        self.assertNotIn("onclick", html)


class UnitTest(unittest.TestCase):
    def test_password_hash(self):
        h = srv.hash_password("una-clave-larga-123", iterations=1000)
        self.assertTrue(srv.verify_password("una-clave-larga-123", h))
        self.assertFalse(srv.verify_password("otra-clave-123456", h))
        self.assertFalse(srv.verify_password("x", "basura"))

    def test_equity_series_downsampled(self):
        store = srv.Store(os.path.join(tempfile.mkdtemp(), "eq.sqlite3"))
        now = 1_760_000_000
        since = now - 3 * 86400
        for i in range(0, 3 * 86400, 120):   # 3 días de telemetría cada 2 min = 2160 filas
            store.add_telemetry(since + i, json.dumps({"equity": 10000 + i / 120}), since + i)
        series = store.equity_series(since, now)
        self.assertLessEqual(len(series), 721)
        self.assertGreater(len(series), 600)
        self.assertEqual(series[-1], [now - 120, 10000 + (3 * 86400 - 120) / 120])   # el último reporte siempre está
        self.assertLess(series[0][0], since + 600)                                 # y cubre el inicio de la ventana
        self.assertEqual([p[0] for p in series], sorted(p[0] for p in series))

    def test_config_validation(self):
        self.assertTrue(srv.Config({}).validate())
        self.assertTrue(any("XAD_TOKEN" in p for p in srv.Config({"XAD_TOKEN": "corto"}).validate()))

    def test_known_answer_hmac(self):
        # Mismo vector que verifica Test_WebDashboard.mq5 (consistencia Python <-> MQL5).
        msg = srv.ea_message("1760000000", "abcdef0123456789", "POST", "/api/ea/telemetry", '{"equity":1}')
        self.assertEqual(srv.sign("k" * 32, msg), "c88d5f8b42836270ba6c1f859d8eb282b414c7fcc7e638a72d1405887a21bac7")
        self.assertEqual(srv.sign("k" * 32, srv.command_message(7, "PAUSE", 1760000000)),
                         "d35b08c8a6c43c53c3151dadbdef9896c94c9481cb32de93f90f30fcf91614e7")
        # clave más larga que el bloque (64 bytes): se resume con SHA-256 antes
        self.assertEqual(srv.sign("K" * 100, "mensaje con clave larga"),
                         "8995e873e48253cc25933f2443131857e2817e0c86908b52505fd11251b03503")
        # RFC 4231, caso 2
        self.assertEqual(srv.sign("Jefe", "what do ya want for nothing?"),
                         "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")


if __name__ == "__main__":
    unittest.main()
