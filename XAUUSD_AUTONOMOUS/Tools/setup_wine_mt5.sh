#!/usr/bin/env bash
# Instala Wine + Xvfb + MetaTrader 5 (incluye MetaEditor) en Ubuntu 24.04 para
# compilar y ejecutar pruebas MQL5 sin Windows. Solo para desarrollo/CI:
# el terminal NO se conecta a ninguna cuenta.
# Nota: MT5 advierte que Wine 9.0 "no está soportado" (recomienda Wine >= 10);
# la compilación y los scripts de prueba funcionaron con Wine 9.0 (2026-10-12).
set -euo pipefail

export WINEPREFIX="${WINEPREFIX:-/root/.wine-mt5}"
export WINEDEBUG=-all
export DISPLAY="${DISPLAY:-:99}"
MT_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5"
DL_DIR="${DL_DIR:-$(mktemp -d)}"

dpkg --add-architecture i386
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wine64 wine32:i386 xvfb

pgrep -x Xvfb >/dev/null || (Xvfb "$DISPLAY" -screen 0 1024x768x16 >/dev/null 2>&1 &)
sleep 2
wineboot -i >/dev/null 2>&1

# Instalador oficial de MetaQuotes (instalación silenciosa con /auto)
curl -sSL -o "$DL_DIR/mt5setup.exe" https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe
timeout 500 wine "$DL_DIR/mt5setup.exe" /auto || true
[ -f "$MT_DIR/MetaEditor64.exe" ] || { echo "ERROR: MetaEditor no instalado"; exit 1; }

# Primer arranque en modo portable: crea MQL5/ con la librería estándar
(timeout 90 wine "$MT_DIR/terminal64.exe" /portable >/dev/null 2>&1 &)
for _ in $(seq 1 18); do sleep 5; [ -f "$MT_DIR/MQL5/Include/Trade/Trade.mqh" ] && break; done
wineserver -k || true
[ -f "$MT_DIR/MQL5/Include/Trade/Trade.mqh" ] || { echo "ERROR: MQL5/Include no generado"; exit 1; }
echo "OK: MetaTrader 5 listo en $MT_DIR"
