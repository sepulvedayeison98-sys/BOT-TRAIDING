# Changelog

## [1.0.0] - 2026-10-14 — Fases 10–11: panel e integración
### Añadido
- `Experts/XAUUSD_Autonomous.mq5`: EA integrado (pipeline, gates, estados, persistencia, reconciliación, diario, panel, OnTester).
- `Dashboard.mqh` (panel con doble confirmación) y `Test_Phase10.mq5` (22/22).
- `Tests/StressTests/FeedTicksSmoke.mq5` y `Tools/run_ea_smoke.sh` (prueba de humo del EA: 7/7).
- `Documentation/WEB_DASHBOARD.md` (diseño del dashboard web; no implementado).
- `CTradeGateway::PositionAlive`, respaldo de tick value con advertencia, `InpSymbolOverride` (solo pruebas).

### Cambiado
- `CreateSyntheticXAU` puede cerrar el terminal (persistencia del símbolo); el helper sintético define tick value, contrato y lotes.
- `run_tests.sh` limpia los gráficos acumulados en el perfil del terminal.
- INSTALLATION.md, TESTING.md, ARCHITECTURE.md y README actualizados.

## [0.9.0] - 2026-10-12 — Fase 9: aprendizaje controlado
### Añadido
- `LearningEngine.mqh` (Champion): diario de operaciones, métricas, carga verificada del modelo con lista blanca.
- `Tools/challenger.py` (Challenger offline) y `Tools/tests/test_challenger.py`.
- Tipos `TradeRecord`, `PerfStats`. `Test_Phase9.mq5` (41/41).

## [0.8.0] - 2026-10-12 — Fase 8: noticias
### Añadido
- `NewsManager.mqh` (calendario MT5 en vivo, CSV en tester, ventanas por prioridad, política conservadora D3), tipos `NewsEvent`/`NewsState`.
- `Tests/Backtesting/ExportCalendar.mq5`, `Test_Phase8.mq5` (34/34).

## [0.7.0] - 2026-10-12 — Fase 7: ejecución y posiciones
### Añadido
- `TradeGateway.mqh` (interfaz + `CTerminalGateway` real), `ExecutionManager.mqh`, `PositionManager.mqh`.
- Tipos `ExecutionResult`, `PositionInfo`, `PositionMeta`, `PendingRequest`, `ClosedTrade`.
- `Tests/Validation/FakeGateway.mqh` y `Test_Phase7.mq5` (74/74).

## [0.6.0] - 2026-10-12 — Fase 6: gestión de riesgo
### Añadido
- `RiskManager.mqh`: volumen con OrderCalcProfit + verificación cruzada + costos, margen con OrderCalcMargin, exposición agregada, pérdida diaria con peor caso, límites duros, reducción opcional tras pérdidas, protección de cuenta real, `SymbolSpecLoad`/`SymbolSpecChanged`.
- `CDailyLossTracker` (reset configurable, depósitos, bloqueo hasta el reset, restauración/reconstrucción).
- `StateStore.mqh`: persistencia atómica con suma de verificación.
- `Test_Phase6.mq5` (90/90).

## [0.5.0] - 2026-10-12 — Fase 5: coordinador adaptativo
### Añadido
- `AdaptiveEngine.mqh`: puntuación de 6 componentes (contexto H1 específico para reversión), umbrales 65/80, conflictos, deduplicación, setups consumidos, posiciones existentes, propuesta única con explicación.
- Tipos `ScoreBreakdown`, `TradeProposal`, `PositionBrief`, `AdaptiveContext`.
- `Tests/Validation/TestSnapshots.mqh` (constructores compartidos) y `Test_Phase5.mq5` (44/44).

## [0.4.0] - 2026-10-12 — Fase 4: estrategias
### Añadido
- `PatternLib.mqh` (barrido, BOS/CHoCH, FVG, Order Block, caja de consolidación, divergencia RSI, rechazo, rango asiático) y `StrategyBase.mqh` (SL/TP, confirmación M5, invariantes, IDs).
- `StrategySMC.mqh`, `StrategyBreakout.mqh`, `StrategyReversal.mqh`: señales `TradeSignal` con dirección, zona, invalidación, SL, TP, R:R, motivo, evidencia estructurada y clave de setup.
- `MarketEngine.UpdateAt()`: instantánea histórica sin mirar el futuro (mismo código que en vivo).
- `Test_Phase4.mq5`, `Test_Strategies_Replay.mq5`, `Tools/run_all_tests.sh`.

### Cambiado
- MarketEngine copia datos por posición a partir del instante de decisión (apertura de la vela M5).
- `Test_RegimeEngine_Custom` mide proporciones sobre 600 instantes (era frágil con un solo instante).
- `RegimeEngine.Classify()` inicializa todos los campos del estado.

### Pruebas
- MQL5: Fase 4 100/100, reproducción 27/27, regresión completa en verde. Python 7/7.

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
