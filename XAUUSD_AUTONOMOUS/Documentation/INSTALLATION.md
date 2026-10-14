# Instalación y uso

> Estado: **EA completo integrado (Fase 11)**. Solo para **cuenta demo** hasta completar la validación (Fases 12–13). El trading real está deshabilitado por defecto y requiere dos confirmaciones explícitas.

## 1. Requisitos
- Windows con MetaTrader 5 de Deriv y MetaEditor (incluido con MT5).
- Cuenta **demo** de Deriv MT5.
- Trading algorítmico habilitado: *Herramientas → Opciones → Asesores Expertos → Permitir trading algorítmico*.
- Python 3.8+ (opcional, para los reportes y el Challenger; sin dependencias externas).

## 2. Copiar archivos al terminal
**Opción automática (Windows):** desde la carpeta del repositorio (rama actualizada), en PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File XAUUSD_AUTONOMOUS\Tools\instalar_windows.ps1
```
Busca la carpeta de datos de MT5 (prefiere la de Deriv; si hay varias, pregunta), guarda copia de seguridad de versiones anteriores, copia `Include\XAUUSD`, el EA y los scripts `SymbolSpecDump`/`ExportCalendar`, compila con MetaEditor mostrando el resultado y arranca el dashboard web (`-NoDashboard` para omitirlo). No modifica la configuración de MT5 ni otros EA. Probado con un MT5 simulado en PowerShell 7; confírmalo en tu equipo.

**Opción manual:**
En MT5: *Archivo → Abrir carpeta de datos* → carpeta `MQL5/`. Copiar (o enlazar con `mklink /J`):

| Origen (repositorio) | Destino (`MQL5/`) |
|---|---|
| `XAUUSD_AUTONOMOUS/Include/XAUUSD/` | `Include/XAUUSD/` |
| `XAUUSD_AUTONOMOUS/Experts/XAUUSD_Autonomous.mq5` | `Experts/XAUUSD/` |
| `XAUUSD_AUTONOMOUS/Tests/Validation/SymbolSpecDump.mq5`, `MarketEngineMonitor.mq5` | `Scripts/XAUUSD/` y `Experts/XAUUSD/` |
| `XAUUSD_AUTONOMOUS/Tests/Backtesting/ExportCalendar.mq5`, `RegimeLogger.mq5` | `Scripts/XAUUSD/` y `Experts/XAUUSD/` |

Compilar cada `.mq5` en MetaEditor (F7). Resultado esperado: `0 errors, 0 warnings` (así compila en el entorno de desarrollo; confirma en tu MetaEditor).

## 3. Antes del primer uso (obligatorio)
1. **`SymbolSpecDump`** sobre un gráfico XAUUSD (demo Deriv) → revisa y envíame `MQL5/Files/XAUUSD/reports/symbol_spec_<símbolo>.txt`. Comprueba: nombre exacto del símbolo, tamaño de contrato, valor del tick, lote mínimo/paso, stops/freeze level, modo Hedging/Netting, offset horario del servidor, disponibilidad del calendario.
2. **Comisión**: si Deriv cobra comisión en XAUUSD, configura `InpCommissionPerLot` (ida y vuelta por lote, en moneda de la cuenta).
3. **Calendario para backtest**: ejecuta `ExportCalendar` en vivo una vez; crea `<Common>/Files/XAUUSD/calendar_usd.csv`, que el EA usa en el Strategy Tester.

## 4. Ejecutar el EA en demo
1. Gráfico **XAUUSD** (cualquier temporalidad; el EA usa H1/M15/M5 internamente).
2. Arrastrar `XAUUSD_Autonomous`. Parámetros clave (valores por defecto aprobados):

| Grupo | Parámetro | Defecto |
|---|---|---|
| Riesgo | `InpRiskPct` / `InpMaxExposurePct` / `InpMaxPositions` / `InpDailyLossPct` / `InpMinRR` | 1 % / 2 % / 3 / 3 % / 2.0 |
| Riesgo | `InpDailyResetHour` | 0 (hora del servidor) |
| Riesgo | `InpDailyLossScope` | solo operaciones del EA (alternativa: toda la cuenta) |
| Seguridad | `InpAllowRealAccount` / `InpRealAccountConfirmation` | false / vacío |
| Posiciones | break-even / trailing | 1.0R / 1.5R (ATR M5 × 1.5) |
| Noticias | mayores / USD / bloqueo si no verificable | 30/30 min, 20/20 min, sí |
| Sesiones | Londres / Nueva York (hora local de cada plaza) | 08:00–16:30 / 08:00–17:00 |

3. El panel muestra estado, régimen, señales, riesgo, exposición, pérdida diaria, noticias y **motivos de bloqueo**. Botones: pausar/reanudar entradas, modo seguro, salir de modo seguro (doble clic), cerrar todo (doble clic), ver registros.
4. Valores fuera de los límites duros (riesgo > 2 %, exposición > 5 %, pérdida diaria > 6 %, R:R < 1, posiciones > 5) impiden que el EA arranque.

## 5. Strategy Tester
- Experto `XAUUSD\XAUUSD_Autonomous`, símbolo XAUUSD de Deriv, periodo M5, modelo **"Cada tick basado en ticks reales"** si Deriv provee ticks; si no, "OHLC en M1" (menos realista).
- Configura `InpTesterGmtOffsetMin` y `InpTesterDstRule` con el offset del servidor (lo indica `SymbolSpecDump`).
- El CSV del calendario debe estar en `<Common>/Files/XAUUSD/calendar_usd.csv` y cubrir el periodo probado; si no, **el EA bloquea todas las entradas** (política conservadora, decisión D3). Un backtest sin noticias no es válido para aprobar un modelo.
- Diario de operaciones: `<Common>/Files/XAUUSD/trades_<símbolo>_<InpRunTag>.csv`. Reporte: `<Common>/Files/XAUUSD/report_<símbolo>_<InpRunTag>.txt`.
- Walk-forward: `python3 Tools/challenger.py folds --start 2023-01-01 --end 2026-01-01 --base-set mi.set --out folds/` genera `.ini`/`.set` por pliegue (`terminal64.exe /config:folds\chal_f1_IS.ini`). Comparación: `python3 Tools/challenger.py compare trades_*.csv`.

## 6. Archivos que genera el EA
| Archivo | Contenido |
|---|---|
| `MQL5/Files/XAUUSD/logs/XAUUSD_Autonomous_<fecha>.log` | Registro TSV de cada decisión (vela, régimen, señales, puntuación, riesgo, ejecución, bloqueos) con IDs de correlación |
| `MQL5/Files/XAUUSD/state_<símbolo>_<magic>.dat` | Estado persistente (no borrar con el EA en marcha) |
| `<Common>/Files/XAUUSD/trades_*.csv`, `report_*.txt` | Diario de operaciones y métricas |
| `<Common>/Files/XAUUSD/champion.model` | Modelo aprobado (solo si lo generas con `challenger.py approve --i-approve`) |

## 7. Compilar y probar en Linux (desarrollo)
```bash
XAUUSD_AUTONOMOUS/Tools/setup_wine_mt5.sh     # una vez: Wine + Xvfb + MT5
XAUUSD_AUTONOMOUS/Tools/run_all_tests.sh      # compila todo y ejecuta todas las pruebas
XAUUSD_AUTONOMOUS/Tools/run_ea_smoke.sh       # EA completo en el terminal con datos sintéticos (sin cuenta)
XAUUSD_AUTONOMOUS/Tools/run_web_e2e.sh        # cliente web MQL5 <-> servidor (requiere la URL local permitida)
```
El terminal bajo Wine no se conecta a ninguna cuenta. MT5 avisa que Wine 9.0 no está soportado oficialmente; la referencia final es tu MetaEditor en Windows.

## 8. Dashboard web (opcional)
Telemetría en el navegador/teléfono y pausa/reanudación/modo seguro remotos (nada más). En el mismo PC de MT5 basta con doble clic en `WebDashboard\iniciar_dashboard.bat` (requiere Python 3.8+) y abrir `http://127.0.0.1:8080`; para verlo desde el celular hace falta un servidor propio con HTTPS. Ver [WebDashboard/README.md](../WebDashboard/README.md). En el EA: añadir la URL en *Opciones → Asesores Expertos → WebRequest* y configurar `InpWebEnabled`, `InpWebUrl`, `InpWebToken`, `InpWebIntervalSec`. Si el servidor no responde, el EA sigue operando igual.

## 9. Seguridad
- Nunca subir al repositorio contraseñas, número de cuenta, tokens ni `.set`/`.ini`/`.env` con datos sensibles (están en `.gitignore`).
- El EA no necesita credenciales: usa la sesión abierta del terminal.
- Quitar el EA del gráfico **no cierra** posiciones; las protecciones (SL/TP) quedan en el servidor.
