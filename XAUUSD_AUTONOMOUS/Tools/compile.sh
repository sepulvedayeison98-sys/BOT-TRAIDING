#!/usr/bin/env bash
# Compila archivos .mq5 del proyecto con MetaEditor bajo Wine (Linux).
# Uso: Tools/compile.sh <archivo.mq5> [más archivos...]
# Requisitos: wine, Xvfb y MetaTrader 5 instalado en $WINEPREFIX (ver Documentation/INSTALLATION.md).
# Sale con código != 0 si algún archivo tiene errores.
set -u

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}"
export WINEDEBUG="${WINEDEBUG:--all}"
export DISPLAY="${DISPLAY:-:99}"
MT_DIR="${MT_DIR:-$WINEPREFIX/drive_c/Program Files/MetaTrader 5}"
MQL5_DIR="$MT_DIR/MQL5"

if [ ! -f "$MT_DIR/MetaEditor64.exe" ]; then
  echo "ERROR: MetaEditor64.exe no encontrado en $MT_DIR" >&2
  exit 2
fi
if ! pgrep -x Xvfb >/dev/null 2>&1; then
  (Xvfb "$DISPLAY" -screen 0 1024x768x16 >/dev/null 2>&1 &)
  sleep 2
fi

# Enlaza los includes del proyecto dentro de MQL5/Include para que <XAUUSD/...> resuelva.
mkdir -p "$MQL5_DIR/Include"
ln -sfn "$PROJECT_DIR/Include/XAUUSD" "$MQL5_DIR/Include/XAUUSD"
# MetaEditor no acepta rutas con espacios en /include: usar un enlace sin espacios.
MQL5_LINK="${MQL5_LINK:-$HOME/.mt5_mql5}"
ln -sfn "$MQL5_DIR" "$MQL5_LINK"

to_win() { echo "Z:$(readlink -f "$1" | sed 's#/#\\#g')"; }

status=0
for src in "$@"; do
  if [ ! -f "$src" ]; then
    echo "ERROR: no existe $src" >&2; status=1; continue
  fi
  log="${src%.mq5}.compile.log"
  rm -f "$log"
  wine "$MT_DIR/MetaEditor64.exe" /compile:"$(to_win "$src")" /log:"$(to_win "$(dirname "$src")")\\$(basename "$log")" \
       /include:"Z:$(echo "$MQL5_LINK" | sed 's#/#\\#g')" >/dev/null 2>&1
  if [ ! -f "$log" ]; then
    echo "ERROR: MetaEditor no generó log para $src" >&2; status=1; continue
  fi
  text="$(iconv -f UTF-16LE -t UTF-8 "$log" 2>/dev/null | tr -d '\r' | sed 's/^\xEF\xBB\xBF//')"
  echo "$text" | grep -E ": (error|warning) " || true
  result="$(echo "$text" | grep -E '^Result:' | tail -1)"
  echo "== $(basename "$src"): ${result:-sin resultado}"
  if ! echo "$result" | grep -q '^Result: 0 errors'; then status=1; fi
  rm -f "$log"
done
exit $status
