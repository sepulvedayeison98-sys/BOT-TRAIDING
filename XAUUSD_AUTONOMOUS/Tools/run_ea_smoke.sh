#!/usr/bin/env bash
# Prueba de humo del EA completo en el terminal MT5 bajo Wine, SIN cuenta (las entradas
# quedan bloqueadas por el gate de conexión/permisos, que es lo esperado):
#   - el EA se carga en el gráfico EURUSD H1 (sincronizado sin conexión) y opera XAUSYN
#     mediante InpSymbolOverride (solo pruebas): el terminal desconectado no inicializa
#     un EA en el gráfico de un símbolo personalizado ("symbol synchronization timeout"),
#   - FeedTicksSmoke inyecta ticks acelerados y cierra el terminal,
#   - se verifican el log del EA, el archivo de estado y el cierre ordenado.
# Requiere que XAUSYN exista (Tests/Backtesting/CreateSyntheticXAU.mq5).
set -u
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}" WINEDEBUG=-all DISPLAY="${DISPLAY:-:99}"
MT_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
cd "$PROJECT_DIR" || exit 2
Tools/compile.sh Experts/XAUUSD_Autonomous.mq5 Tests/StressTests/FeedTicksSmoke.mq5 Tests/Backtesting/CreateSyntheticXAU.mq5 || exit 1
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
mkdir -p "$MT_DIR/MQL5/Experts/XAUUSD" "$MT_DIR/MQL5/Scripts/XAUUSD_Tests" "$MT_DIR/MQL5/Presets"
cp Experts/XAUUSD_Autonomous.ex5 "$MT_DIR/MQL5/Experts/XAUUSD/"
cp Tests/StressTests/FeedTicksSmoke.ex5 "$MT_DIR/MQL5/Scripts/XAUUSD_Tests/"
printf 'InpAllowAnySymbol=true\r\nInpSymbolOverride=XAUSYN\r\nInpRunTag=smoke\r\nInpShowDashboard=true\r\n' > "$MT_DIR/MQL5/Presets/xau_smoke.set"
LOGDIR="$MT_DIR/MQL5/Files/XAUUSD/logs"
STATE="$MT_DIR/MQL5/Files/XAUUSD/state_XAUSYN_26101201.dat"
rm -f "$LOGDIR"/XAUUSD_Autonomous_*.log "$STATE" "$MT_DIR/MQL5/Files/XAUUSD/reports/FeedTicksSmoke.txt"
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
check "sin errores críticos" "[ $(grep -c $'\tCRITICAL\t' "$LOG") -eq 0 ]"
echo "--- últimas decisiones ---"
grep -P "\tBAR\t" "$LOG" | tail -3 | cut -f7 | cut -c1-300
exit $status
