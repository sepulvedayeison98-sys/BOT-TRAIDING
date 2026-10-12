# Changelog

## [0.3.0] - 2026-10-12 — Fase 3: régimen de mercado
### Añadido
- `Include/XAUUSD/RegimeEngine.mqh`: clasificación TREND_UP / TREND_DOWN / RANGE / HIGH_VOLATILITY / NO_TRADE con umbrales configurables y validados al iniciar, motivo legible de cada decisión, distancias a pivotes H1, límites de rango M15 e histéresis (salida inmediata a estados de seguridad, confirmación para el resto).
- `RegimeState` y `EnumRegimeToString` en `Types.mqh`.
- `Tests/Validation/Test_Phase3.mq5`, `Test_RegimeEngine_Custom.mq5`, `SyntheticSymbol.mqh` (helper compartido).
- `Tests/Backtesting/RegimeLogger.mq5` (EA de validación, no opera) y `CreateSyntheticXAU.mq5`.
- `Tools/regime_report.py` (validación estadística, solo librería estándar) y `Tools/tests/test_regime_report.py`.

### Cambiado
- `Test_MarketEngine_Custom.mq5` usa `SyntheticSymbol.mqh`.

### Corregido
- Reporte estadístico: retornos solapados + posición en el rango daban significancia espuria; ahora muestreo no solapado (ver TESTING.md).

### Pruebas
- MQL5: 56/56 (Fase 3), 19/19 (integración), regresión 100/100 y 26/26; todos los `.mq5` con 0 errores y 0 warnings.
- Python: 7/7.

### Pendiente
- Calibrar umbrales con datos reales de Deriv (RegimeLogger en tu tester + reporte), dentro y fuera de muestra.
- Siguen pendientes los entregables de la Fase 2 en tu terminal (SymbolSpecDump, MarketEngineMonitor).

## [0.2.0] - 2026-10-12 — Fase 2: motor de mercado
### Añadido
- `Include/XAUUSD/Types.mqh`: enums y estructuras compartidas (`SwingPoint`, `TFData`, `MarketSnapshot`).
- `Include/XAUUSD/Logger.mqh`: log TSV persistente en UTF-8 con rotación diaria, IDs únicos, registro "solo al cambiar"; si el fichero falla, sigue con `Print()`.
- `Include/XAUUSD/SessionClock.mqh`: reglas DST UE/UK y EE. UU., conversión servidor↔UTC (medida en vivo; offset + regla en el tester), sesiones de Londres/NY en hora local de cada plaza, sesión de trading del bróker.
- `Include/XAUUSD/MarketEngine.mqh`: datos de H1/M15/M5 con velas cerradas, EMA50/200, RSI14, ADX14 (+DI/−DI), ATR14, pivotes confirmados sin repintado, estructura HH/HL–LH/LL, volatilidad relativa, momentum y su cambio, spread actual/medio, validación de datos (sincronización, historial, OHLC, orden temporal, frescura, valores de indicadores, cambio de especificación del símbolo).
- `Tests/Validation/`: `TestFramework.mqh`, `Test_Phase2.mq5`, `Test_MarketEngine_Custom.mq5`, `SymbolSpecDump.mq5`, `MarketEngineMonitor.mq5` (EA de diagnóstico, no opera).
- `Tools/`: `setup_wine_mt5.sh`, `compile.sh`, `run_tests.sh`.

### Decisiones
- Aprobadas D1–D5 y límites duros de riesgo (ver ARCHITECTURE.md §18).
- Logger usa `TimeTradeServer()` en vez de `TimeCurrent()` (este último devuelve la hora del último tick, que puede ser antigua).

### Pruebas
- Compilación: 0 errores, 0 warnings en los 4 `.mq5` (MetaEditor build 6257 bajo Wine).
- Unitarias 100/100; integración 29/29. Detalle en TESTING.md §7.

### Pendiente
- Ejecutar `SymbolSpecDump` y `MarketEngineMonitor` en la cuenta demo Deriv.
- Compilación de confirmación en MetaEditor de Windows.

## [0.1.0] - 2026-10-12 — Fase 1: diseño y diagnóstico
### Añadido
- Estructura de carpetas del proyecto.
- `ARCHITECTURE.md`: diagnóstico del entorno, componentes, flujo de señales, interfaces, persistencia, estados, limitaciones de MQL5, riesgos técnicos, hoja de ruta.
- `RISK_MANAGEMENT.md`: cálculo de volumen, exposición, pérdida diaria, SL/TP, Hedging/Netting.
- `STRATEGIES.md`: reglas objetivas de SMC, Breakout, Reversal, régimen y puntuación.
- `TESTING.md`: plan de pruebas y protocolo de validación estadística.
- `INSTALLATION.md`.

### Pendiente
- Aprobación de la arquitectura y decisiones D1–D5.
- Sin código MQL5. Sin compilación (MetaEditor no disponible en el entorno de desarrollo).
