# Plan de pruebas y validación

> Estado: **diseño (Fase 1)**. Ningún resultado de prueba existe todavía.

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
