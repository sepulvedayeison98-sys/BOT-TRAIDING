# Instalación

> Estado: **Fase 2**. Todavía no existe el EA operativo (`XAUUSD_Autonomous.mq5` llega en la Fase 11).
> Lo que se puede instalar hoy: herramientas de diagnóstico de solo lectura y pruebas.

## 1. Requisitos (uso real)
- Windows con MetaTrader 5 de Deriv y MetaEditor (incluido con MT5).
- Cuenta **demo** de Deriv MT5. No usar cuenta real.
- Trading algorítmico habilitado en el terminal (*Herramientas → Opciones → Asesores Expertos*). Las herramientas de la Fase 2 no operan, pero un EA necesita el permiso para cargarse.

## 2. Copiar archivos al terminal
1. En MT5: *Archivo → Abrir carpeta de datos* → carpeta `MQL5/`.
2. Copiar (o enlazar con `mklink /J`):
   - `XAUUSD_AUTONOMOUS/Include/XAUUSD/` → `MQL5/Include/XAUUSD/`
   - `XAUUSD_AUTONOMOUS/Tests/Validation/SymbolSpecDump.mq5` → `MQL5/Scripts/XAUUSD/`
   - `XAUUSD_AUTONOMOUS/Tests/Validation/Test_*.mq5` y `TestFramework.mqh` → `MQL5/Scripts/XAUUSD/`
   - `XAUUSD_AUTONOMOUS/Tests/Validation/MarketEngineMonitor.mq5` → `MQL5/Experts/XAUUSD/`
3. Abrir cada `.mq5` en MetaEditor y compilar (F7). Resultado esperado: `0 errors, 0 warnings`.

## 3. Lo que necesito que ejecutes (Fase 2)
1. **Especificaciones reales**: abre un gráfico XAUUSD (cuenta demo Deriv) y arrastra `SymbolSpecDump`. Envíame `MQL5/Files/XAUUSD/reports/symbol_spec_<símbolo>.txt`. No contiene número de cuenta ni credenciales; revísalo antes de compartirlo.
2. **Datos reales**: carga `MarketEngineMonitor` en un gráfico XAUUSD (cualquier TF) durante al menos una sesión de Londres o NY, o ejecútalo en el Strategy Tester. Envíame `MQL5/Files/XAUUSD/logs/MarketEngineMonitor_<fecha>.log`.
   - En el Strategy Tester, configura `InpTesterGmtOffsetMin` e `InpTesterDstRule` con el offset del servidor de Deriv (lo indica `server_gmt_offset_sec_raw` del paso 1).

## 4. Compilar y probar en Linux (desarrollo)
```bash
XAUUSD_AUTONOMOUS/Tools/setup_wine_mt5.sh          # una vez: Wine + Xvfb + MT5
XAUUSD_AUTONOMOUS/Tools/compile.sh <archivo.mq5>   # compila con MetaEditor
XAUUSD_AUTONOMOUS/Tools/run_tests.sh XAUUSD_AUTONOMOUS/Tests/Validation/Test_Phase2.mq5 \
                                     XAUUSD_AUTONOMOUS/Tests/Validation/Test_MarketEngine_Custom.mq5
```
El terminal bajo Wine **no se conecta a ninguna cuenta**: solo compila y ejecuta pruebas con datos sintéticos. MT5 advierte que Wine 9.0 no está soportado oficialmente; la compilación y las pruebas funcionaron, pero el resultado definitivo es el de tu MetaEditor en Windows.

## 5. Seguridad
- Nunca subir al repositorio: contraseñas, número de cuenta, tokens de API, ficheros `.set`/`.ini` con datos sensibles (están en `.gitignore`).
- El EA no necesita credenciales: usa la sesión ya abierta del terminal.
