#!/usr/bin/env bash
# Prueba de extremo a extremo del dashboard web: servidor real (WebDashboard/server.py) en
# 127.0.0.1 + cliente MQL5 (Test_WebDashboard.mq5) en el terminal MT5 bajo Wine.
# 1) arranca el servidor con un token temporal, 2) encola un comando PAUSE,
# 3) el script MQL5 envía telemetría firmada, recibe y verifica el comando y lo confirma,
# 4) se comprueba en la base de datos del servidor.
# REQUISITO: http://127.0.0.1:8080 debe estar en Herramientas > Opciones > Asesores Expertos >
# "Permitir WebRequest para las URL listadas" de ESTE terminal (se guarda cifrado en
# Config/common.ini; las claves WebRequest/WebRequestUrl en texto plano de un .ini de arranque
# NO lo configuran). Sin eso el script MQL5 informa "URL no permitida" (error 4014).
set -u
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 2
export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}" WINEDEBUG=-all DISPLAY="${DISPLAY:-:99}"
MT_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
PORT="${E2E_PORT:-8080}"
WORK="$(mktemp -d)"
export XAD_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export XAD_SESSION_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export XAD_PASSWORD_HASH="$(python3 -c 'import sys; sys.path.insert(0, "WebDashboard"); import server; print(server.hash_password("e2e-password-123", 2000))')"
export XAD_DB="$WORK/e2e.sqlite3" XAD_PORT="$PORT" XAD_BIND="127.0.0.1" XAD_COOKIE_SECURE=0
python3 WebDashboard/server.py serve > "$WORK/server.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.5; done
python3 - <<PY
import sys, time; sys.path.insert(0, "WebDashboard"); import server
s = server.Store("$XAD_DB"); print("comando encolado id", s.add_command("PAUSE", "e2e", int(time.time())))
PY
Tools/compile.sh Tests/Validation/Test_WebDashboard.mq5 || exit 1
mkdir -p "$MT_DIR/MQL5/Scripts/XAUUSD_Tests" "$MT_DIR/MQL5/Presets"
cp Tests/Validation/Test_WebDashboard.ex5 "$MT_DIR/MQL5/Scripts/XAUUSD_Tests/"
printf 'InpE2EUrl=http://127.0.0.1:%s\r\nInpE2EToken=%s\r\nInpReportName=Test_WebDashboard_E2E\r\n' "$PORT" "$XAD_TOKEN" > "$MT_DIR/MQL5/Presets/xau_web_e2e.set"
REPORT="$MT_DIR/MQL5/Files/XAUUSD/reports/Test_WebDashboard_E2E.txt"
rm -f "$REPORT"
printf '[Experts]\r\nAllowLiveTrading=0\r\nAllowDllImport=0\r\nEnabled=1\r\n[StartUp]\r\nScript=XAUUSD_Tests\\Test_WebDashboard\r\nScriptParameters=xau_web_e2e.set\r\nSymbol=EURUSD\r\nPeriod=H1\r\n' > "$WINEPREFIX/drive_c/xau_web_e2e.ini"
find "$MT_DIR/MQL5/Profiles/Charts/Default/" -name "chart*.chr" ! -name "chart01.chr" -delete 2>/dev/null
pgrep -x Xvfb >/dev/null || (Xvfb "$DISPLAY" -screen 0 1280x900x16 >/dev/null 2>&1 &)
(timeout 240 wine "$MT_DIR/terminal64.exe" /portable /config:C:\\xau_web_e2e.ini >/dev/null 2>&1 &)
for _ in $(seq 1 110); do [ -f "$REPORT" ] && break; sleep 2; done
sleep 2; wineserver -k >/dev/null 2>&1
cat "$REPORT" 2>/dev/null || echo "SIN REPORTE"
echo "--- servidor ---"
grep -E "api/ea" "$WORK/server.log" | tail -6
python3 - <<PY
import sqlite3, json
db = sqlite3.connect("$XAD_DB")
t = db.execute("SELECT body FROM telemetry ORDER BY rowid DESC LIMIT 1").fetchone()
c = db.execute("SELECT id, cmd, delivered, acked FROM commands").fetchall()
print("telemetría recibida:", json.loads(t[0]) if t else None)
print("comandos:", c)
ok = bool(t) and json.loads(t[0]).get("last_signal") == 'prueba "E2E" ñ' and c and c[0][3] > 0
print("E2E:", "PASS" if ok else "FAIL")
raise SystemExit(0 if ok else 1)
PY
