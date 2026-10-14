#!/usr/bin/env bash
# Prueba de humo del EA completo en el terminal MT5 bajo Wine, SIN cuenta (las entradas
# quedan bloqueadas por el gate de conexión/permisos, que es lo esperado):
#   - el EA se carga en el gráfico EURUSD H1 (sincronizado sin conexión) y opera XAUSYN
#     mediante InpSymbolOverride (solo pruebas): el terminal desconectado no inicializa
#     un EA en el gráfico de un símbolo personalizado ("symbol synchronization timeout"),
#   - FeedTicksSmoke inyecta ticks acelerados y cierra el terminal,
#   - se verifican el log del EA, el archivo de estado y el cierre ordenado.
# Requiere que XAUSYN exista (Tests/Backtesting/CreateSyntheticXAU.mq5).
# SMOKE_WEB=1: además arranca WebDashboard/server.py en 127.0.0.1:8080 con un token temporal,
#   encola un PAUSE y verifica telemetría, aplicación del comando, confirmación y persistencia
#   (requiere http://127.0.0.1:8080 permitida para WebRequest en este terminal; ver run_web_e2e.sh).
set -u
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}" WINEDEBUG=-all DISPLAY="${DISPLAY:-:99}"
MT_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
cd "$PROJECT_DIR" || exit 2
Tools/compile.sh Experts/XAUUSD_Autonomous.mq5 Tests/StressTests/FeedTicksSmoke.mq5 Tests/Backtesting/CreateSyntheticXAU.mq5 || exit 1
# SMOKE_RESTART=1: segunda ejecución sobre el estado guardado (prueba de reinicio)
RESTART="${SMOKE_RESTART:-0}"
if [ "$RESTART" != "1" ]; then
# 1) símbolo sintético fresco que termina "ahora" (uno antiguo puede no sincronizar a tiempo)
mkdir -p "$MT_DIR/MQL5/Scripts/XAUUSD_Tests" "$MT_DIR/MQL5/Presets"
cp Tests/Backtesting/CreateSyntheticXAU.ex5 "$MT_DIR/MQL5/Scripts/XAUUSD_Tests/"
printf 'InpName=XAUSYN\r\nInpDays=40\r\nInpSeed=42\r\nInpCloseTerminal=true\r\n' > "$MT_DIR/MQL5/Presets/xau_syn40.set"
rm -f "$MT_DIR/MQL5/Files/XAUUSD/reports/CreateSyntheticXAU.txt"
printf '[StartUp]\r\nScript=XAUUSD_Tests\\CreateSyntheticXAU\r\nScriptParameters=xau_syn40.set\r\nSymbol=EURUSD\r\nPeriod=H1\r\n' > "$WINEPREFIX/drive_c/xau_syn.ini"
find "$MT_DIR/MQL5/Profiles/Charts/Default/" -name "chart*.chr" ! -name "chart01.chr" -delete 2>/dev/null
pgrep -x Xvfb >/dev/null || (Xvfb "$DISPLAY" -screen 0 1280x900x16 >/dev/null 2>&1 &)
# cierre ordenado (TerminalClose): necesario para que la definición del símbolo se guarde
timeout 300 wine "$MT_DIR/terminal64.exe" /portable /config:C:\\xau_syn.ini >/dev/null 2>&1
wineserver -w >/dev/null 2>&1
echo "símbolo sintético: $(cat "$MT_DIR/MQL5/Files/XAUUSD/reports/CreateSyntheticXAU.txt" 2>/dev/null)"
fi
mkdir -p "$MT_DIR/MQL5/Experts/XAUUSD" "$MT_DIR/MQL5/Scripts/XAUUSD_Tests" "$MT_DIR/MQL5/Presets"
cp Experts/XAUUSD_Autonomous.ex5 "$MT_DIR/MQL5/Experts/XAUUSD/"
cp Tests/StressTests/FeedTicksSmoke.ex5 "$MT_DIR/MQL5/Scripts/XAUUSD_Tests/"
printf 'InpAllowAnySymbol=true\r\nInpSymbolOverride=XAUSYN\r\nInpRunTag=smoke\r\nInpShowDashboard=true\r\n' > "$MT_DIR/MQL5/Presets/xau_smoke.set"
WEB="${SMOKE_WEB:-0}"
if [ "$WEB" = "1" ]; then
  WORK="$(mktemp -d)"
  export XAD_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  export XAD_SESSION_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  export XAD_PASSWORD_HASH="$(python3 -c 'import sys; sys.path.insert(0, "WebDashboard"); import server; print(server.hash_password("smoke-password-123", 2000))')"
  export XAD_DB="$WORK/smoke.sqlite3" XAD_PORT=8080 XAD_BIND=127.0.0.1 XAD_COOKIE_SECURE=0
  python3 WebDashboard/server.py serve > "$WORK/server.log" 2>&1 &
  SRV=$!
  trap 'kill $SRV 2>/dev/null' EXIT
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:8080/" && break; sleep 0.5; done
  python3 -c 'import sys, time; sys.path.insert(0, "WebDashboard"); import server; server.Store(sys.argv[1]).add_command("PAUSE", "smoke", int(time.time()))' "$XAD_DB"
  printf 'InpWebEnabled=true\r\nInpWebUrl=http://127.0.0.1:8080\r\nInpWebToken=%s\r\nInpWebIntervalSec=10\r\n' "$XAD_TOKEN" >> "$MT_DIR/MQL5/Presets/xau_smoke.set"
fi
LOGDIR="$MT_DIR/MQL5/Files/XAUUSD/logs"
STATE="$MT_DIR/MQL5/Files/XAUUSD/state_XAUSYN_26101201.dat"
rm -f "$LOGDIR"/XAUUSD_Autonomous_*.log "$MT_DIR/MQL5/Files/XAUUSD/reports/FeedTicksSmoke.txt"
# SMOKE_STATE_EDIT=pause|corrupt|scope: modifica el estado guardado antes del reinicio
#   scope: bloqueo diario guardado con alcance "toda la cuenta" (E0 10000, equity sin cuenta = 0,
#   es decir -100 %): con el alcance por defecto "solo EA" debe reevaluarse y NO bloquear.
EDIT="${SMOKE_STATE_EDIT:-}"
if [ "$RESTART" = "1" ]; then
  [ -f "$STATE" ] || { echo "FAIL: no hay estado previo para la prueba de reinicio"; exit 1; }
  if [ "$EDIT" = "pause" ]; then python3 Tools/edit_state.py "$STATE" set ea.state PAUSED; fi
  if [ "$EDIT" = "corrupt" ]; then python3 Tools/edit_state.py "$STATE" corrupt; fi
  if [ "$EDIT" = "scope" ]; then
    python3 Tools/edit_state.py "$STATE" set daily.e0 10000.00000000 && python3 Tools/edit_state.py "$STATE" set daily.limit 1 \
      && python3 Tools/edit_state.py "$STATE" set daily.scope ACCOUNT || { echo "FAIL: no se pudo editar el estado"; exit 1; }
  fi
else
  rm -f "$STATE"
fi
printf '[StartUp]\r\nExpert=XAUUSD\\XAUUSD_Autonomous\r\nExpertParameters=xau_smoke.set\r\nSymbol=EURUSD\r\nPeriod=H1\r\nScript=XAUUSD_Tests\\FeedTicksSmoke\r\n' > "$WINEPREFIX/drive_c/xau_smoke.ini"
find "$MT_DIR/MQL5/Profiles/Charts/Default/" -name "chart*.chr" ! -name "chart01.chr" -delete 2>/dev/null
pgrep -x Xvfb >/dev/null || (Xvfb "$DISPLAY" -screen 0 1280x900x16 >/dev/null 2>&1 &)
timeout "${SMOKE_TIMEOUT_SEC:-600}" wine "$MT_DIR/terminal64.exe" /portable /config:C:\\xau_smoke.ini >/dev/null 2>&1
wineserver -w >/dev/null 2>&1
LOG="$(ls -t "$LOGDIR"/XAUUSD_Autonomous_*.log 2>/dev/null | head -1)"
status=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; status=1; fi; }
cat "$MT_DIR/MQL5/Files/XAUUSD/reports/FeedTicksSmoke.txt" 2>/dev/null
check "log del EA creado" "[ -n \"$LOG\" ]"
[ -n "$LOG" ] || exit 1
c() { grep -c -P "\t$1\t" "$LOG"; }
echo "eventos: START=$(c START) BAR=$(c BAR) SIGNAL=$(c SIGNAL) PROPOSAL=$(c PROPOSAL) PROPOSAL_BLOCKED=$(c PROPOSAL_BLOCKED) REGIME_CHANGE=$(c REGIME_CHANGE) CRITICAL=$(grep -c $'\tCRITICAL\t' "$LOG") STOP=$(c STOP)"
check "OnInit completo (RECOVERED)" "[ $(c RECOVERED) -ge 1 ]"
check "sin INIT_FAILED" "[ $(c INIT_FAILED) -eq 0 ]"
check "pipeline ejecutado en >= 50 velas M5" "[ $(c BAR) -ge 50 ]"
check "sin órdenes enviadas (sin cuenta)" "[ $(c EXECUTED) -eq 0 ]"
check "cierre ordenado (STOP en OnDeinit)" "[ $(c STOP) -ge 1 ]"
check "estado persistido con checksum" "grep -q '^#checksum=' \"$STATE\""
if [ "$RESTART" = "1" ]; then
  if [ "$EDIT" = "corrupt" ]; then
    check "reinicio con estado alterado: detectado como corrupto" "grep -q 'estado persistente corrupto' \"$LOG\""
    check "reinicio con estado alterado: modo seguro (entradas bloqueadas)" "grep -P '\tBAR\t' \"$LOG\" | grep -q 'ESTADO SAFE_MODE'"
  else
    check "reinicio: estado previo válido (sin modo seguro)" "! grep -q 'estado persistente corrupto' \"$LOG\""
  fi
  if [ "$EDIT" = "scope" ]; then
    check "alcance cambiado: el bloqueo guardado se reevalúa" "grep -q 'DAILY_SCOPE_CHANGED' \"$LOG\""
    check "alcance EA: la pérdida de la cuenta (-100 %) no cuenta" "grep -P '\tDAILY_SCOPE\t' \"$LOG\" | grep -q 'solo operaciones del EA; hoy 0.00%'"
    check "alcance EA: sin bloqueo diario en las velas" "! grep -P '\tBAR\t' \"$LOG\" | grep -q 'LÍMITE DIARIO\|DAILY_LIMIT'"
  fi
  if [ "$EDIT" = "pause" ]; then
    check "reinicio: pausa restaurada" "grep -q 'restaurado: entradas pausadas' \"$LOG\""
    check "reinicio: entradas bloqueadas por PAUSED" "grep -P '\tBAR\t' \"$LOG\" | grep -q 'ESTADO PAUSED'"
  fi
fi
[ "$EDIT" = "corrupt" ] || check "sin errores críticos" "[ $(grep -c $'\tCRITICAL\t' "$LOG") -eq 0 ]"
if [ "$WEB" = "1" ]; then
  WEBRES="$(python3 - "$XAD_DB" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
rows = [json.loads(r[0]) for r in db.execute("SELECT body FROM telemetry ORDER BY rowid")]
cmd = db.execute("SELECT acked FROM commands ORDER BY id LIMIT 1").fetchone()
states = {r.get("state") for r in rows}
print(len(rows), rows[-1].get("symbol") if rows else "-", int(bool(cmd and cmd[0])), int("PAUSED" in states))
PY
)"
  read -r WN WSYM WACK WPAUSED <<< "$WEBRES"
  echo "web: telemetrías=$WN símbolo=$WSYM confirmado=$WACK estado_PAUSED_reportado=$WPAUSED"
  check "web: telemetría recibida (>= 2 envíos)" "[ \"$WN\" -ge 2 ]"
  check "web: símbolo correcto en la telemetría" "[ \"$WSYM\" = XAUSYN ]"
  check "web: comando PAUSE aplicado por el EA" "grep -q 'pausa remota desde el dashboard web' \"$LOG\""
  check "web: comando confirmado al servidor" "[ \"$WACK\" = 1 ]"
  check "web: el servidor ve el estado PAUSED" "[ \"$WPAUSED\" = 1 ]"
  check "web: entradas bloqueadas por PAUSED tras el comando" "grep -P '\tBAR\t' \"$LOG\" | grep -q 'ESTADO PAUSED'"
  check "web: último comando persistido" "grep -q '^web.last_cmd=1' \"$STATE\""
fi
echo "--- últimas decisiones ---"
grep -P "\tBAR\t" "$LOG" | tail -3 | cut -f7 | cut -c1-300
exit $status
