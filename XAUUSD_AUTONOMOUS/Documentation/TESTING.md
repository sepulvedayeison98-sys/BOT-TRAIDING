# Plan de pruebas y validación

> Estado: **Fase 4 completada**. Resultados registrados en §7. Batería completa: `Tools/run_all_tests.sh`.

## 1. Niveles de prueba

| Nivel | Herramienta | Qué valida | Fase |
|---|---|---|---|
| Compilación | MetaEditor (o Wine + `metaeditor64.exe /compile`, por verificar) | 0 errores, 0 warnings críticos | Cada fase |
| Unitarias | Scripts MQL5 en `Tests/Validation/*.mq5` con aserciones propias; datos sintéticos en arrays | Lógica pura: redondeo de lote, DST/sesiones, pivotes, FVG/OB/BOS, puntuación, invariantes de SL | 2–7 |
| Integración en tester | Strategy Tester, modo visual y "Every tick based on real ticks" | Flujo completo, gates, logs, reconciliación | 11 |
| Estrés | Símbolo personalizado (`CustomSymbolCreate`, `CustomTicksAdd` — verificar API) con gaps, spread extremo, huecos de datos | Robustez y fallo seguro | 12 |
| Backtest | Strategy Tester con historial Deriv | Métricas de rendimiento | 12 |
| OOS / Walk-forward | Tester con período forward + orquestación externa (Python + `.ini`) | Estabilidad fuera de muestra | 12 |
| Demo | Cuenta demo Deriv | Ejecución real vs backtest | 13 |

## 2. Pruebas por módulo (resumen)

- **MarketEngine**: handles inválidos, `CopyBuffer` con menos datos de los pedidos, historial no sincronizado, vela actual vs cerrada, detección de datos desactualizados (última vela más vieja que 2× el período en sesión abierta).
- **SessionClock**: fechas de cambio DST (UK y EE. UU.) de varios años, semanas en que difieren (marzo/noviembre), offsets de servidor distintos, fin de semana.
- **RegimeEngine**: series sintéticas de tendencia, rango y spike de volatilidad; matriz de confusión contra etiquetado manual de periodos históricos.
- **Estrategias**: casos sintéticos positivos y negativos por patrón; prueba de **no repintado** (señales generadas barra a barra = señales recalculadas al final).
- **RiskManager**: ver RISK_MANAGEMENT.md §9.
- **Execution/Position**: retcodes simulados (requote, sin dinero, mercado cerrado, timeout), reinicio con posiciones abiertas, posición sin SL, freeze level, Hedging y Netting (cuentas demo de cada tipo, si Deriv las ofrece — por verificar).
- **NewsManager**: ventanas antes/después, eventos solapados, calendario no disponible, datos desactualizados.

## 3. Requisitos del backtest

- Modelo: "Every tick based on real ticks" (si Deriv provee ticks suficientes — verificar); comparar con "1 minute OHLC" para medir sensibilidad.
- Spread: real del historial + escenarios con spread fijo aumentado (×1.5, ×2).
- Comisión y slippage configurados explícitamente (desviación en el tester).
- Noticias: desde CSV exportado del calendario. **Backtests sin noticias no son válidos para aprobar un modelo.**
- Delays de ejecución aleatorios del tester activados en una de las corridas.

## 4. Protocolo de validación estadística

1. **Partición temporal** (sin mezclar): In-sample (IS) → Out-of-sample (OOS) reservado, nunca usado para optimizar.
2. **Walk-forward rodante**: ventanas IS/OOS sucesivas; se reporta la concatenación de OOS.
3. **Muestra mínima** (propuesta, a acordar): ≥ 100 operaciones en OOS total y ≥ 30 por estrategia antes de sacar conclusiones por estrategia. Con menos, el resultado se reporta como "no concluyente".
4. **Incertidumbre**: intervalo de confianza bootstrap para expectativa y profit factor; Monte Carlo reordenando operaciones para estimar distribución de drawdown máximo.
5. **Penalización de sobreajuste**: número de parámetros optimizados registrado; preferir mesetas de parámetros estables sobre picos; degradación IS→OOS reportada.
6. **Criterio de aceptación** (propuesta): expectativa OOS > 0 con el límite inferior del IC no muy negativo, PF OOS ≥ 1.2, DD máx. OOS dentro de lo tolerable, sin dependencia de una sola estrategia/sesión/mes. Ningún modelo se acepta solo por una curva positiva.

## 5. Métricas reportadas

Beneficio neto, profit factor, DD máximo (monetario y %), expectativa por operación (en R y en dinero), tasa de acierto, número de operaciones, riesgo efectivo medio, ratio de recuperación, rendimiento por sesión / estrategia / régimen / día de la semana, comisión, swap, slippage medio y máximo, racha máxima de pérdidas, estabilidad IS vs OOS.

## 6. Pruebas de seguridad (Fase 12)

- Reinicio del EA con 0, 1 y 3 posiciones abiertas; con solicitud pendiente incierta.
- Desconexión simulada (en demo: desactivar red) durante gestión de posición.
- Cambio de gráfico/símbolo/TF con el EA cargado.
- Fichero de estado corrupto o borrado.
- Alcanzar límite diario con posiciones abiertas.
- Cuenta real detectada sin autorización → sin entradas.

## 7. Resultados registrados

### Fase 2 — 2026-10-12 (MetaEditor/MT5 build 6257 bajo Wine 9.0, Linux)

| Archivo | Compilación | Ejecución |
|---|---|---|
| `Tests/Validation/Test_Phase2.mq5` (unitarias: reglas de calendario/DST, sesiones, conversión horaria, pivotes, estructura, validación de velas e indicadores, spread, Logger) | 0 errores, 0 warnings | **100 passed, 0 failed** |
| `Tests/Validation/Test_MarketEngine_Custom.mq5` (integración con símbolo sintético: carga de H1/M15/M5, orientación de series, EMA contra cálculo independiente, RSI/ADX/ATR, pivotes confirmados, spread, IsNewBar, Deinit) | 0 errores, 0 warnings | **29 passed, 0 failed** |
| `Tests/Validation/SymbolSpecDump.mq5` | 0 errores, 0 warnings | Pendiente: requiere tu cuenta demo Deriv |
| `Tests/Validation/MarketEngineMonitor.mq5` | 0 errores, 0 warnings | Pendiente: requiere datos reales (demo o tester) |

**Prueba de mutación:** se cambió a propósito la comparación estricta de pivotes (`>=` → `>`); la batería lo detectó (99/100, falla "máximos iguales no generan pivote"). Se restauró el código.

**No cubierto todavía (requiere datos reales de Deriv):** historial no sincronizado, huecos reales de datos, comportamiento en la pausa diaria del oro y fines de semana, offset horario real del servidor, spread real.

### Fase 3 — 2026-10-12 (MetaEditor/MT5 build 6257 bajo Wine 9.0; Python 3.13)

| Archivo | Compilación | Ejecución |
|---|---|---|
| `Tests/Validation/Test_Phase3.mq5` (clasificación por regla y por condición rota, límites exactos de ADX, volatilidad, spread, datos inválidos, rango, histéresis, configuración) | 0 errores, 0 warnings | **56 passed, 0 failed** |
| `Tests/Validation/Test_RegimeEngine_Custom.mq5` (MarketEngine → RegimeEngine con indicadores reales de MT5: series alcista, bajista, lateral y choque de volatilidad) | 0 errores, 0 warnings | **19 passed, 0 failed** |
| `Tools/tests/test_regime_report.py` (detección de comportamiento conocido, caminata aleatoria no confirmada, muestra pequeña, huecos de datos, persistencia, CLI, formato del CSV igual al de RegimeLogger) | — | **7 tests OK** |
| `Tests/Backtesting/RegimeLogger.mq5`, `CreateSyntheticXAU.mq5` | 0 errores, 0 warnings | Tester no ejecutable aquí (ver abajo) |
| Regresión Fase 2 | 0 errores, 0 warnings | 100/100 y 26/26 |

`Test_MarketEngine_Custom` pasa de 29 a 26 aserciones: la creación del símbolo se movió a `SyntheticSymbol.mqh` (4 aserciones pasaron a ser 1).

**Defecto metodológico encontrado y corregido:** la primera versión del reporte correlacionaba la posición en el rango con retornos solapados. La prueba con caminata aleatoria la marcó como "reversión consistente" (regresión espuria: la posición es muy persistente). Ahora se usan retornos no solapados y retorno firmado desde los extremos; falsos positivos medidos en caminatas aleatorias: TREND_UP 2/60, TREND_DOWN 2/60, RANGE 1/60.

**Limitación:** el Strategy Tester de MT5 no arranca sin una cuenta conectada ("tester not started because the account is not specified"), así que el ensayo `RegimeLogger` en tester solo puedes ejecutarlo tú.

### Fase 4 — 2026-10-12

| Archivo | Ejecución |
|---|---|
| `Test_Phase4.mq5`: primitivas (barrido, ruptura, FVG, OB, caja, divergencia, rechazo, rango asiático) y un escenario completo por estrategia construido vela a vela, con SL/TP/niveles calculados a mano; cada escenario también **en espejo** (compra↔venta); casos negativos (régimen, zona no tocada, FVG rellenado → OB, falsa ruptura, volumen obligatorio, confirmaciones insuficientes, sin CHoCH) | **100 passed, 0 failed** |
| `Test_Strategies_Replay.mq5`: (1) **sin mirar el futuro**: `UpdateAt(D)` idéntico (precios e indicadores en H1/M15/M5) en un símbolo completo y en una copia que termina en D; (2) `Update()` en vivo == `UpdateAt(apertura M5 actual)`; (3) reproducción de 4 × 1.500 velas M5 por régimen + 3 estrategias: 0 señales que violen invariantes | **27 passed, 0 failed** |
| `Test_RegimeEngine_Custom.mq5` rehecho como medida estadística sobre 600 instantes (antes dependía de un solo instante y era frágil) | **19 passed, 0 failed** |

Medida de la debilidad del ADX: en la oscilación lateral sintética, la regla clasificó **12 %** de los instantes como tendencia (10 % alcista, 2 % bajista). Las series en tendencia: 100 %.

**Hallazgos de la fase:**
- `CustomTicksAdd` reescribe como vela plana (O=H=L=C) la vela que contiene el tick. Afectaba a la copia "sin futuro" del test; se añadió `add_tick=false` al helper. No afecta a datos del bróker.
- MarketEngine copia por posición (`iBarShift` + `CopyRates`/`CopyBuffer` con el mismo índice) y verifica que la vela esté cerrada en el instante de decisión.
