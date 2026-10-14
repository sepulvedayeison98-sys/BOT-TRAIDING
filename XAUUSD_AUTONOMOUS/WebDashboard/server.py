#!/usr/bin/env python3
"""Dashboard web del XAUUSD Autonomous Trading System.

Servidor HTTP con SOLO la librería estándar de Python (3.8+): http.server, sqlite3,
hmac, hashlib. Pensado para correr en 127.0.0.1 detrás de un proxy con TLS (Caddy,
nginx). Ver WebDashboard/README.md.

Seguridad:
  - El EA se autentica con HMAC-SHA256 sobre "timestamp\\nnonce\\nmétodo ruta\\ncuerpo"
    usando un token de dashboard compartido (NO es una credencial de trading).
    Se rechazan firmas inválidas, timestamps con más de 120 s y nonces repetidos.
  - Los comandos que el EA recoge van firmados por el servidor con el mismo token;
    el EA los verifica (y rechaza los viejos o repetidos).
  - Solo existen PAUSE, RESUME y SAFE_MODE. Nunca abrir/cerrar operaciones ni tocar riesgo.
  - La persona entra con contraseña (hash PBKDF2-SHA256) -> cookie de sesión firmada,
    HttpOnly, SameSite=Strict (Secure detrás de TLS) + protección CSRF por doble envío.
  - Límite de intentos de login por IP, cabeceras de seguridad (CSP sin scripts inline),
    tamaño máximo de petición, registro de auditoría de comandos.

Uso:
  python3 server.py hash-password            # genera XAD_PASSWORD_HASH
  python3 server.py new-token                # genera un token de dashboard
  XAD_TOKEN=... XAD_PASSWORD_HASH=... XAD_SESSION_SECRET=... python3 server.py serve
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ALLOWED_COMMANDS = ("PAUSE", "RESUME", "SAFE_MODE")
MAX_SKEW_SEC = 120
MAX_BODY = 64 * 1024
SESSION_TTL_SEC = 12 * 3600
LOGIN_MAX_PER_MIN = 5
EA_ONLINE_SEC = 120
COMMAND_TTL_SEC = 600
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}


# ------------------------------------------------------------------ utilidades
def sign(token, message):
    return hmac.new(token.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def ea_message(ts, nonce, method, path, body):
    return f"{ts}\n{nonce}\n{method} {path}\n{body}"


def command_message(cid, cmd, created):
    return f"{cid}|{cmd}|{created}"


def hash_password(password, iterations=200_000, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2${iterations}${base64.b64encode(salt).decode()}${base64.b64encode(dk).decode()}"


def verify_password(password, stored):
    try:
        algo, iters, salt_b64, hash_b64 = stored.split("$")
        if algo != "pbkdf2":
            return False
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), base64.b64decode(salt_b64), int(iters))
        return hmac.compare_digest(base64.b64encode(dk).decode(), hash_b64)
    except (ValueError, TypeError):
        return False


class Config:
    def __init__(self, env=None):
        env = env if env is not None else os.environ
        self.token = env.get("XAD_TOKEN", "")
        self.password_hash = env.get("XAD_PASSWORD_HASH", "")
        self.session_secret = env.get("XAD_SESSION_SECRET", "")
        self.db_path = env.get("XAD_DB", "dashboard.sqlite3")
        self.bind = env.get("XAD_BIND", "127.0.0.1")
        self.port = int(env.get("XAD_PORT", "8080"))
        self.cookie_secure = env.get("XAD_COOKIE_SECURE", "1") == "1"
        self.allow_commands = env.get("XAD_ALLOW_COMMANDS", "1") == "1"
        # Detrás de un proxy local (Caddy/nginx) todas las conexiones llegan desde 127.0.0.1:
        # con XAD_TRUST_PROXY=1 se usa la última IP de X-Forwarded-For (la que añade el proxy).
        # No activarlo si el puerto es accesible sin pasar por el proxy.
        self.trust_proxy = env.get("XAD_TRUST_PROXY", "0") == "1"

    def validate(self):
        problems = []
        if len(self.token) < 32:
            problems.append("XAD_TOKEN debe tener al menos 32 caracteres (python3 server.py new-token)")
        if not self.password_hash.startswith("pbkdf2$"):
            problems.append("XAD_PASSWORD_HASH ausente o inválido (python3 server.py hash-password)")
        if len(self.session_secret) < 32:
            problems.append("XAD_SESSION_SECRET debe tener al menos 32 caracteres")
        return problems


# ------------------------------------------------------------------ almacenamiento
class Store:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS telemetry(ts INTEGER, received INTEGER, body TEXT);
            CREATE INDEX IF NOT EXISTS telemetry_ts ON telemetry(received);
            CREATE TABLE IF NOT EXISTS nonces(nonce TEXT PRIMARY KEY, ts INTEGER);
            CREATE TABLE IF NOT EXISTS commands(id INTEGER PRIMARY KEY AUTOINCREMENT, cmd TEXT, created INTEGER,
                                                delivered INTEGER, acked INTEGER, requested_by TEXT);
            CREATE TABLE IF NOT EXISTS audit(ts INTEGER, actor TEXT, action TEXT, detail TEXT);
        """)
        self.db.commit()

    def use_nonce(self, nonce, now):
        with self.lock:
            self.db.execute("DELETE FROM nonces WHERE ts < ?", (now - 2 * MAX_SKEW_SEC,))
            try:
                self.db.execute("INSERT INTO nonces(nonce, ts) VALUES(?, ?)", (nonce, now))
                self.db.commit()
                return True
            except sqlite3.IntegrityError:
                return False

    def add_telemetry(self, ts, body, now):
        with self.lock:
            self.db.execute("INSERT INTO telemetry(ts, received, body) VALUES(?, ?, ?)", (ts, now, body))
            self.db.execute("DELETE FROM telemetry WHERE received < ?", (now - 30 * 86400,))
            self.db.commit()

    def latest(self):
        with self.lock:
            row = self.db.execute("SELECT received, body FROM telemetry ORDER BY received DESC, rowid DESC LIMIT 1").fetchone()
        return (row[0], json.loads(row[1])) if row else (0, None)

    def equity_series(self, since, now, buckets=720):
        # Un punto por intervalo (el último reporte de cada uno): ~720 puntos cubren la ventana
        # completa sea cual sea la frecuencia de telemetría. En SQLite, con MAX() las columnas
        # no agregadas toman los valores de la fila del máximo.
        step = max(1, (now - since) // buckets)
        with self.lock:
            rows = self.db.execute("SELECT MAX(received), body FROM telemetry WHERE received >= ? "
                                   "GROUP BY received / ? ORDER BY 1", (since, step)).fetchall()
        out = []
        for received, body in rows:
            try:
                eq = json.loads(body).get("equity")
                if isinstance(eq, (int, float)):
                    out.append([received, eq])
            except ValueError:
                continue
        return out

    def add_command(self, cmd, actor, now):
        with self.lock:
            cur = self.db.execute("INSERT INTO commands(cmd, created, delivered, acked, requested_by) VALUES(?, ?, 0, 0, ?)",
                                  (cmd, now, actor))
            self.db.execute("INSERT INTO audit(ts, actor, action, detail) VALUES(?, ?, 'command', ?)", (now, actor, cmd))
            self.db.commit()
            return cur.lastrowid

    def pending_commands(self, now):
        with self.lock:
            rows = self.db.execute("SELECT id, cmd, created FROM commands WHERE acked = 0 AND created >= ? ORDER BY id",
                                   (now - COMMAND_TTL_SEC,)).fetchall()
            self.db.execute("UPDATE commands SET delivered = delivered + 1 WHERE acked = 0 AND created >= ?",
                            (now - COMMAND_TTL_SEC,))
            self.db.commit()
        return rows

    def ack(self, cid, now):
        with self.lock:
            cur = self.db.execute("UPDATE commands SET acked = ? WHERE id = ? AND acked = 0", (now, cid))
            self.db.commit()
            return cur.rowcount == 1

    def command_history(self, limit=20):
        with self.lock:
            return self.db.execute("SELECT id, cmd, created, delivered, acked, requested_by FROM commands ORDER BY id DESC LIMIT ?",
                                   (limit,)).fetchall()

    def audit(self, actor, action, detail, now):
        with self.lock:
            self.db.execute("INSERT INTO audit(ts, actor, action, detail) VALUES(?, ?, ?, ?)", (now, actor, action, detail))
            self.db.commit()


# ------------------------------------------------------------------ aplicación
class App:
    def __init__(self, cfg, store, clock=time.time):
        self.cfg = cfg
        self.store = store
        self.clock = clock
        self.login_attempts = {}
        self.lock = threading.Lock()

    def now(self):
        return int(self.clock())

    # --- autenticación del EA
    def verify_ea(self, headers, method, path, body):
        ts = headers.get("X-XAD-Timestamp", "")
        nonce = headers.get("X-XAD-Nonce", "")
        sig = headers.get("X-XAD-Signature", "")
        if not ts.isdigit() or not (8 <= len(nonce) <= 64) or len(sig) != 64:
            return "cabeceras de firma ausentes o inválidas"
        if abs(self.now() - int(ts)) > MAX_SKEW_SEC:
            return "timestamp fuera de la ventana permitida"
        expected = sign(self.cfg.token, ea_message(ts, nonce, method, path, body))
        if not hmac.compare_digest(expected, sig.lower()):
            return "firma inválida"
        if not self.store.use_nonce(nonce, self.now()):
            return "nonce repetido (posible reenvío)"
        return ""

    # --- sesiones de la persona
    def make_session(self):
        exp = self.now() + SESSION_TTL_SEC
        csrf = secrets.token_hex(16)
        payload = f"{exp}.{csrf}"
        return f"{payload}.{sign(self.cfg.session_secret, payload)}", csrf

    def check_session(self, cookie_value):
        try:
            exp, csrf, mac = cookie_value.split(".")
        except (AttributeError, ValueError):
            return None
        if not hmac.compare_digest(sign(self.cfg.session_secret, f"{exp}.{csrf}"), mac):
            return None
        if not exp.isdigit() or int(exp) < self.now():
            return None
        return csrf

    def login_allowed(self, ip):
        now = self.now()
        with self.lock:
            attempts = [t for t in self.login_attempts.get(ip, []) if t > now - 60]
            self.login_attempts[ip] = attempts
            if len(attempts) >= LOGIN_MAX_PER_MIN:
                return False
            attempts.append(now)
            return True

    def state(self):
        received, latest = self.store.latest()
        now = self.now()
        return {
            "now": now,
            "ea_online": bool(latest) and now - received <= EA_ONLINE_SEC,
            "last_seen": received,
            "telemetry": latest,
            "equity": self.store.equity_series(now - 3 * 86400, now),
            "commands": [{"id": r[0], "cmd": r[1], "created": r[2], "delivered": r[3], "acked": r[4], "by": r[5]}
                         for r in self.store.command_history()],
            "allow_commands": self.cfg.allow_commands,
            "allowed": list(ALLOWED_COMMANDS),
        }


def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        server_version = "XADashboard"
        sys_version = ""
        # HTTP/1.1 con Content-Length en todas las respuestas: conexiones persistentes
        # (el cliente WinINet de MT5 reutiliza la conexión entre peticiones).
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # registro mínimo, sin cuerpos
            sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

        # --- respuestas
        def send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=None):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                             "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def json(self, code, obj, extra=None):
            self.send(code, json.dumps(obj, ensure_ascii=False), extra=extra)

        def body(self):
            try:
                n = int(self.headers.get("Content-Length", "0") or 0)
            except ValueError:
                n = MAX_BODY + 1
            if n < 0 or n > MAX_BODY:
                self.close_connection = True   # el cuerpo no se lee: no reutilizar la conexión
                return None
            return self.rfile.read(n).decode("utf-8") if n else ""

        def cookie(self, name):
            raw = self.headers.get("Cookie", "")
            for part in raw.split(";"):
                k, _, v = part.strip().partition("=")
                if k == name:
                    return v
            return ""

        def client_ip(self):
            if app.cfg.trust_proxy:
                fwd = self.headers.get("X-Forwarded-For", "")
                if fwd.strip():
                    return fwd.split(",")[-1].strip()[:64]
            return self.client_address[0]

        def session_csrf(self):
            return app.check_session(self.cookie("xad_session"))

        def set_cookie(self, value, max_age):
            secure = "; Secure" if app.cfg.cookie_secure else ""
            return f"xad_session={value}; Path=/; HttpOnly; SameSite=Strict; Max-Age={max_age}{secure}"

        # --- rutas
        def do_GET(self):
            if self.headers.get("Content-Length", "0") not in ("", "0"):
                self.close_connection = True   # un GET con cuerpo no leído no debe reutilizar la conexión
            path = urlparse(self.path).path
            if path == "/api/ea/commands":
                err = app.verify_ea(self.headers, "GET", path, "")
                if err:
                    return self.send(401, err, "text/plain; charset=utf-8")
                now = app.now()
                lines = [f"{cid}|{cmd}|{created}|{sign(app.cfg.token, command_message(cid, cmd, created))}"
                         for cid, cmd, created in app.store.pending_commands(now)] if app.cfg.allow_commands else []
                return self.send(200, "\n".join(lines), "text/plain; charset=utf-8")
            if path == "/api/state":
                if self.session_csrf() is None:
                    return self.json(401, {"error": "no autenticado"})
                return self.json(200, app.state())
            if path == "/api/session":
                csrf = self.session_csrf()
                return self.json(200, {"authenticated": csrf is not None, "csrf": csrf or ""})
            if path == "/favicon.ico":
                return self.send(204)
            # estáticos
            name = "index.html" if path in ("/", "/index.html") else path.lstrip("/").replace("static/", "", 1)
            if "/" in name or name.startswith(".") or os.path.splitext(name)[1] not in STATIC_TYPES:
                return self.send(404, "no encontrado", "text/plain; charset=utf-8")
            full = os.path.join(STATIC_DIR, name)
            if not os.path.isfile(full):
                return self.send(404, "no encontrado", "text/plain; charset=utf-8")
            with open(full, "rb") as fh:
                return self.send(200, fh.read(), STATIC_TYPES[os.path.splitext(name)[1]])

        def do_POST(self):
            path = urlparse(self.path).path
            body = self.body()
            if body is None:
                return self.send(413, "petición demasiado grande", "text/plain; charset=utf-8")
            if path in ("/api/ea/telemetry", "/api/ea/ack"):
                err = app.verify_ea(self.headers, "POST", path, body)
                if err:
                    return self.send(401, err, "text/plain; charset=utf-8")
                if path == "/api/ea/ack":
                    ok = body.strip().isdigit() and app.store.ack(int(body.strip()), app.now())
                    return self.send(200 if ok else 404, "ok" if ok else "comando desconocido", "text/plain; charset=utf-8")
                try:
                    obj = json.loads(body)
                    if not isinstance(obj, dict):
                        raise ValueError
                except ValueError:
                    return self.send(400, "JSON inválido", "text/plain; charset=utf-8")
                app.store.add_telemetry(int(self.headers.get("X-XAD-Timestamp")), json.dumps(obj), app.now())
                return self.send(200, "ok", "text/plain; charset=utf-8")
            if path == "/api/login":
                ip = self.client_ip()
                if not app.login_allowed(ip):
                    return self.json(429, {"error": "demasiados intentos; espera un minuto"})
                try:
                    password = json.loads(body or "{}").get("password", "")
                except ValueError:
                    password = ""
                if not isinstance(password, str) or not verify_password(password, app.cfg.password_hash):
                    app.store.audit(ip, "login_failed", "", app.now())
                    return self.json(401, {"error": "contraseña incorrecta"})
                value, csrf = app.make_session()
                app.store.audit(ip, "login", "", app.now())
                return self.json(200, {"ok": True, "csrf": csrf}, extra={"Set-Cookie": self.set_cookie(value, SESSION_TTL_SEC)})
            # rutas que exigen sesión + CSRF
            csrf = self.session_csrf()
            if csrf is None:
                return self.json(401, {"error": "no autenticado"})
            if not hmac.compare_digest(self.headers.get("X-XAD-CSRF", ""), csrf):
                return self.json(403, {"error": "CSRF inválido"})
            if path == "/api/logout":
                return self.json(200, {"ok": True}, extra={"Set-Cookie": self.set_cookie("", 0)})
            if path == "/api/command":
                if not app.cfg.allow_commands:
                    return self.json(403, {"error": "los comandos remotos están desactivados"})
                try:
                    cmd = json.loads(body or "{}").get("cmd", "")
                except ValueError:
                    cmd = ""
                if cmd not in ALLOWED_COMMANDS:
                    return self.json(400, {"error": "comando no permitido"})
                cid = app.store.add_command(cmd, self.client_ip(), app.now())
                return self.json(200, {"ok": True, "id": cid})
            return self.json(404, {"error": "no encontrado"})

    return Handler


def serve(cfg):
    problems = cfg.validate()
    if problems:
        raise SystemExit("Configuración inválida:\n- " + "\n- ".join(problems))
    app = App(cfg, Store(cfg.db_path))
    httpd = ThreadingHTTPServer((cfg.bind, cfg.port), make_handler(app))
    print(f"Dashboard en http://{cfg.bind}:{cfg.port} (publícalo SOLO detrás de un proxy con TLS)")
    httpd.serve_forever()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "hash-password":
        import getpass
        p1 = getpass.getpass("Contraseña: ")
        p2 = getpass.getpass("Repite la contraseña: ")
        if p1 != p2 or len(p1) < 12:
            raise SystemExit("Las contraseñas no coinciden o tienen menos de 12 caracteres")
        print(hash_password(p1))
        return 0
    if cmd == "new-token":
        print(secrets.token_hex(32))
        return 0
    if cmd == "serve":
        serve(Config())
        return 0
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
