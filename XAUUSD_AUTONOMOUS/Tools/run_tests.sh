#!/usr/bin/env bash
# Compila y ejecuta scripts de prueba MQL5 en el terminal MT5 bajo Wine (modo headless).
# Uso: Tools/run_tests.sh Tests/Validation/Test_X.mq5 [...]
# Cada script debe escribir MQL5/Files/XAUUSD/reports/<nombre>.txt con una línea
# "RESULT <nombre>: N passed, M failed" (ver Tests/Validation/TestFramework.mqh).
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"
MT_DIR="${MT_DIR:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5}"
REPORTS="$MT_DIR/MQL5/Files/XAUUSD/reports"
SCRIPTS="$MT_DIR/MQL5/Scripts/XAUUSD_Tests"
TIMEOUT_SEC="${TEST_TIMEOUT_SEC:-180}"

"$PROJECT_DIR/Tools/compile.sh" "$@" || { echo "Compilación fallida: no se ejecutan pruebas"; exit 1; }
mkdir -p "$SCRIPTS"

# cada ejecución abre un gráfico nuevo en el perfil: se limpian para que el terminal arranque rápido
find "$MT_DIR/MQL5/Profiles/Charts/Default/" -name "chart*.chr" ! -name "chart01.chr" -delete 2>/dev/null
status=0
for src in "$@"; do
  name="$(basename "${src%.mq5}")"
  ex5="${src%.mq5}.ex5"
  cp "$ex5" "$SCRIPTS/" || { status=1; continue; }
  rm -f "$REPORTS/$name.txt"
  printf '[StartUp]\r\nScript=XAUUSD_Tests\\%s\r\nSymbol=EURUSD\r\nPeriod=H1\r\n' "$name" > "$WINEPREFIX/drive_c/xau_test_startup.ini"
  (timeout "$TIMEOUT_SEC" wine "$MT_DIR/terminal64.exe" /portable /config:C:\\xau_test_startup.ini >/dev/null 2>&1 &)
  waited=0
  until [ -f "$REPORTS/$name.txt" ] || [ "$waited" -ge "$TIMEOUT_SEC" ]; do sleep 2; waited=$((waited + 2)); done
  sleep 1
  wineserver -k >/dev/null 2>&1
  if [ ! -f "$REPORTS/$name.txt" ]; then
    echo "== $name: SIN REPORTE (timeout ${TIMEOUT_SEC}s)"; status=1; continue
  fi
  cat "$REPORTS/$name.txt"
  grep -q "^RESULT $name: [0-9]* passed, 0 failed" "$REPORTS/$name.txt" || status=1
done
exit $status
