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
  - Varias instancias del EA (un gráfico por símbolo): cada telemetría se guarda con su
    símbolo; un comando va a una instancia o a todas ("*") y cada instancia lo confirma por
    separado (?i=<símbolo> en la ruta firmada). Un EA anterior a 1.2.0 es la instancia "".
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
from urllib.parse import parse_qs, urlparse

ALLOWED_COMMANDS = ("PAUSE", "RESUME", "SAFE_MODE")
MAX_SKEW_SEC = 120
MAX_BODY = 64 * 1024
SESSION_TTL_SEC = 12 * 3600
LOGIN_MAX_PER_MIN = 5
EA_ONLINE_SEC = 120
COMMAND_TTL_SEC = 600
INSTANCE_MAX_LEN = 64
INSTANCE_LIST_SEC = 7 * 86400     # instancias que se listan (vistas en los últimos 7 días)
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
STATIC_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".woff2": "font/woff2"}


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
            CREATE TABLE IF NOT EXISTS command_acks(cmd_id INTEGER, instance TEXT, ts INTEGER, PRIMARY KEY(cmd_id, instance));
        """)
        # migración desde 1.1.x: instancia en la telemetría y destino en los comandos
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(telemetry)")}
        if "instance" not in cols:
            self.db.execute("ALTER TABLE telemetry ADD COLUMN instance TEXT NOT NULL DEFAULT ''")
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(commands)")}
        if "target" not in cols:
            self.db.execute("ALTER TABLE commands ADD COLUMN target TEXT NOT NULL DEFAULT '*'")
        self.db.execute("CREATE INDEX IF NOT EXISTS telemetry_inst ON telemetry(instance, received)")
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

    def add_telemetry(self, ts, body, now, instance=""):
        with self.lock:
            self.db.execute("INSERT INTO telemetry(ts, received, body, instance) VALUES(?, ?, ?, ?)", (ts, now, body, instance))
            self.db.execute("DELETE FROM telemetry WHERE received < ?", (now - 30 * 86400,))
            self.db.commit()

    def latest(self, instance=None):
        """Último reporte de una instancia (None = el más reciente de cualquiera)."""
        with self.lock:
            if instance is None:
                row = self.db.execute("SELECT received, body, instance FROM telemetry "
                                      "ORDER BY received DESC, rowid DESC LIMIT 1").fetchone()
            else:
                row = self.db.execute("SELECT received, body, instance FROM telemetry WHERE instance = ? "
                                      "ORDER BY received DESC, rowid DESC LIMIT 1", (instance,)).fetchone()
        return (row[0], json.loads(row[1]), row[2]) if row else (0, None, instance if instance is not None else "")

    def instances(self, now):
        """Instancias vistas en los últimos 7 días con un resumen de su último reporte."""
        with self.lock:
            rows = self.db.execute("SELECT instance, MAX(received), body FROM telemetry WHERE received >= ? "
                                   "GROUP BY instance ORDER BY instance", (now - INSTANCE_LIST_SEC,)).fetchall()
        out = []
        for inst, received, body in rows:
            try:
                t = json.loads(body)
            except ValueError:
                t = {}
            out.append({"instance": inst, "last_seen": received, "online": now - received <= EA_ONLINE_SEC,
                        "symbol": t.get("symbol", inst), "state": t.get("state", ""), "profile": t.get("profile", ""),
                        "daily_loss_pct": t.get("daily_loss_pct"), "positions": t.get("positions")})
        return out

    def equity_series(self, since, now, buckets=720, instance=None):
        # Un punto por intervalo (el último reporte de cada uno): ~720 puntos cubren la ventana
        # completa sea cual sea la frecuencia de telemetría. En SQLite, con MAX() las columnas
        # no agregadas toman los valores de la fila del máximo.
        step = max(1, (now - since) // buckets)
        where, args = ("received >= ?", [since]) if instance is None else ("received >= ? AND instance = ?", [since, instance])
        with self.lock:
            rows = self.db.execute(f"SELECT MAX(received), body FROM telemetry WHERE {where} "
                                   "GROUP BY received / ? ORDER BY 1", (*args, step)).fetchall()
        out = []
        for received, body in rows:
            try:
                eq = json.loads(body).get("equity")
                if isinstance(eq, (int, float)):
                    out.append([received, eq])
            except ValueError:
                continue
        return out

    def add_command(self, cmd, actor, now, target="*"):
        with self.lock:
            cur = self.db.execute("INSERT INTO commands(cmd, created, delivered, acked, requested_by, target) "
                                  "VALUES(?, ?, 0, 0, ?, ?)", (cmd, now, actor, target))
            self.db.execute("INSERT INTO audit(ts, actor, action, detail) VALUES(?, ?, 'command', ?)",
                            (now, actor, cmd if target == "*" else f"{cmd} -> {target}"))
            self.db.commit()
            return cur.lastrowid

    # Pendientes para una instancia: vigentes, dirigidos a ella o a todas, y que ELLA no ha confirmado.
    _PENDING = ("FROM commands c WHERE c.created >= ? AND (c.target = '*' OR c.target = ?) AND NOT EXISTS "
                "(SELECT 1 FROM command_acks a WHERE a.cmd_id = c.id AND a.instance = ?)")

    def pending_commands(self, now, instance=""):
        args = (now - COMMAND_TTL_SEC, instance, instance)
        with self.lock:
            rows = self.db.execute("SELECT c.id, c.cmd, c.created " + self._PENDING + " ORDER BY c.id", args).fetchall()
            self.db.execute("UPDATE commands SET delivered = delivered + 1 WHERE id IN (SELECT c.id " + self._PENDING + ")", args)
            self.db.commit()
        return rows

    def ack(self, cid, now, instance=""):
        """Confirmación de una instancia (idempotente). False si el comando no existe o no era para ella."""
        with self.lock:
            row = self.db.execute("SELECT target FROM commands WHERE id = ?", (cid,)).fetchone()
            if not row or row[0] not in ("*", instance):
                return False
            self.db.execute("INSERT OR IGNORE INTO command_acks(cmd_id, instance, ts) VALUES(?, ?, ?)", (cid, instance, now))
            self.db.execute("UPDATE commands SET acked = ? WHERE id = ? AND acked = 0", (now, cid))
            self.db.commit()
            return True

    def command_history(self, limit=20):
        with self.lock:
            rows = self.db.execute("SELECT id, cmd, created, delivered, acked, requested_by, target FROM commands "
                                   "ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
            acks = {}
            for cid, inst in self.db.execute("SELECT cmd_id, instance FROM command_acks WHERE cmd_id >= ? ORDER BY ts",
                                             (rows[-1][0] if rows else 0,)):
                acks.setdefault(cid, []).append(inst)
        return [r + (acks.get(r[0], []),) for r in rows]

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

    def state(self, instance=None):
        """Estado de una instancia (None = la que reportó por última vez) + lista de instancias."""
        now = self.now()
        instances = self.store.instances(now)
        if instance is not None and not any(i["instance"] == instance for i in instances):
            instance = None   # instancia desconocida o antigua: se muestra la más reciente
        received, latest, selected = self.store.latest(instance)
        return {
            "now": now,
            "instance": selected,
            "instances": instances,
            "ea_online": bool(latest) and now - received <= EA_ONLINE_SEC,
            "last_seen": received,
            "telemetry": latest,
            "equity": self.store.equity_series(now - 3 * 86400, now, instance=selected if latest else None),
            "commands": [{"id": r[0], "cmd": r[1], "created": r[2], "delivered": r[3], "acked": r[4], "by": r[5],
                          "target": r[6], "acks": r[7]}
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

        def instance_param(self):
            q = parse_qs(urlparse(self.path).query)
            return q["i"][0][:INSTANCE_MAX_LEN] if "i" in q else ""

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
                # la firma cubre la ruta completa tal como llegó (con ?i=<instancia> desde 1.2.0)
                err = app.verify_ea(self.headers, "GET", self.path, "")
                if err:
                    return self.send(401, err, "text/plain; charset=utf-8")
                now = app.now()
                inst = self.instance_param()
                lines = [f"{cid}|{cmd}|{created}|{sign(app.cfg.token, command_message(cid, cmd, created))}"
                         for cid, cmd, created in app.store.pending_commands(now, inst)] if app.cfg.allow_commands else []
                return self.send(200, "\n".join(lines), "text/plain; charset=utf-8")
            if path == "/api/state":
                if self.session_csrf() is None:
                    return self.json(401, {"error": "no autenticado"})
                q = parse_qs(urlparse(self.path).query)
                return self.json(200, app.state(q["i"][0][:INSTANCE_MAX_LEN] if "i" in q else None))
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
                err = app.verify_ea(self.headers, "POST", self.path, body)
                if err:
                    return self.send(401, err, "text/plain; charset=utf-8")
                if path == "/api/ea/ack":
                    ok = body.strip().isdigit() and app.store.ack(int(body.strip()), app.now(), self.instance_param())
                    return self.send(200 if ok else 404, "ok" if ok else "comando desconocido", "text/plain; charset=utf-8")
                try:
                    obj = json.loads(body)
                    if not isinstance(obj, dict):
                        raise ValueError
                except ValueError:
                    return self.send(400, "JSON inválido", "text/plain; charset=utf-8")
                sym = obj.get("symbol")
                inst = sym[:INSTANCE_MAX_LEN] if isinstance(sym, str) else ""
                app.store.add_telemetry(int(self.headers.get("X-XAD-Timestamp")), json.dumps(obj), app.now(), inst)
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
                    req = json.loads(body or "{}")
                    cmd, target = req.get("cmd", ""), req.get("target", "*")
                except (ValueError, AttributeError):
                    cmd, target = "", "*"
                if cmd not in ALLOWED_COMMANDS:
                    return self.json(400, {"error": "comando no permitido"})
                if not isinstance(target, str) or (target != "*" and
                                                   not any(i["instance"] == target for i in app.store.instances(app.now()))):
                    return self.json(400, {"error": "instancia de destino desconocida"})
                cid = app.store.add_command(cmd, self.client_ip(), app.now(), target)
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
