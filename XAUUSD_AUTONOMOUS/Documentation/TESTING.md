# Plan de pruebas y validación

> Estado: **Fases 1–11 completadas; Fase 12 ejecutada en lo posible sin cuenta**. Resultados registrados en §7. Batería completa: `Tools/run_all_tests.sh`.

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

### Fase 5 — 2026-10-12
`Test_Phase5.mq5`: puntuación por componente con valores calculados a mano (SMC 78 → moderada; con BOS y ruptura M5 96 → alta; reversión por agotamiento; breakout), noticias/fin de sesión/spread, selección de la mejor, duplicados, conflicto compra/venta, setup consumido y su caducidad, posición existente (misma zona / mismo setup / lejana), expiración, umbral, señal inválida, configuración → **44 passed, 0 failed**. Regresión Fase 4: 100/100.

### Fase 6 — 2026-10-12
`Test_Phase6.mq5` → **103 passed, 0 failed** (90 + 13 de alcance de la pérdida diaria en 1.1.1: la pérdida manual no cuenta con alcance EA, pérdida/ganancia propias, depósitos, bloqueo enganchado y reset, `Assess` con alcance EA): volumen (0.20 para 1 % con SL de 5 USD; 0.19 con comisión; 0.18 en venta con spread; base = min(balance, equity)), lote mínimo nunca redondeado hacia arriba, volumen máximo, R:R, stops level, verificación cruzada (crítica), fallo de OrderCalcProfit, margen libre y nivel de margen, reducción tras rachas (solo reduce), exposición agregada (1 %+1 % sí, 2 %+1 % no, break-even no cuenta, SL en beneficio = 0), máximo de posiciones, posición sin SL (crítico), Netting, pérdida diaria (peor caso, bloqueo enganchado, reset, depósitos/retiros, reset a las 22:00, restauración solo del mismo día, reconstrucción), límites duros, protección de cuenta real, cambio de especificación, StateStore (ida y vuelta, saneado, prefijos, corrupción, truncado).

La verificación con `OrderCalcProfit` real de XAUUSD en Deriv queda para tu terminal (el EA la hace en cada evaluación y `SymbolSpecDump` la reporta).

### Fase 7 — 2026-10-12
`Test_Phase7.mq5` (servidor simulado `FakeGateway.mqh`) → **74 passed, 0 failed**:
- Ejecución: OrderCheck antes de OrderSend; solicitud correcta (tipo, volumen, SL, TP, magic, comentario, filling); slippage; anti-duplicado con pendiente; recotización → reintento; recotizaciones agotadas (exactamente 3 envíos); **timeout con operación abierta → sin reintento + reconciliación la encuentra**; sin conexión → bloqueo hasta timeout, orden en proceso mantiene el bloqueo; comentario alterado por el bróker; sin dinero; OrderCheck rechaza; spread; desvío de precio; mercado cerrado; trading no permitido; volumen fuera de paso; decisión no aprobada; filling IOC.
- Posiciones: break-even a 1R (entrada + 10 puntos + spread), trailing ATR a 1.6R, el SL nunca se aleja, sin datos válidos no hay trailing, venta en espejo, stops level, freeze level, posición sin SL → SL protector + crítico + huérfana, cierre por invalidación, 3 fallos al modificar → crítico, trailing por pivote M5, persistencia de metadatos, solo posiciones con su magic, cierre total sin tocar otros EA, racha de pérdidas (comisión incluida).

### Fase 8 — 2026-10-12
`Test_Phase8.mq5` → **34 passed, 0 failed**: clasificación (NFP, CPI, PCE, FOMC, tasas, Powell, empleo, otros USD, baja importancia), límites exactos de las ventanas 30/30 y 20/20, próximo evento, fuente no válida / desactualizada / fuera de cobertura → bloqueo, política desactivable (informa sin bloquear), CSV del tester (carga, filtro, cobertura, sin `#range`, sin archivo), calendario no disponible sin conexión → bloqueo. La prueba encontró un bug (eventos no relevantes inyectados bloqueaban) que se corrigió.

### Fase 9 — 2026-10-12
- `Test_Phase9.mq5` → **41 passed, 0 failed**: SHA-256 de MQL5 idéntico al de Python (respuesta conocida), modelo aprobado se carga y aplica, sin modelo → valores por defecto, alterado → rechazado, sin aprobación → rechazado, clave de riesgo o de ejecución → rechazado entero, valor inválido → no se aplica nada, métricas calculadas a mano, filtros, diario CSV (cabecera = la de challenger.py, fila, R, contexto, huérfanas), persistencia del contexto de entrada, reporte.
- `Tools/tests/test_challenger.py` → **16 tests OK** (23 en total con las de regime_report): métricas a mano, Challenger mejor → recomendado, sobreajustado → rechazado, muestra pequeña → rechazado, mejora no significativa → rechazado, lista blanca igual a la del EA, sin claves de riesgo, hash del modelo, clave prohibida, `approve` exige `--i-approve`, fechas de walk-forward, archivos .ini/.set.

### Fase 10 — Dashboard
`Test_Phase10.mq5` → **22 passed, 0 failed**: objetos creados en el gráfico, textos actualizados (estado, régimen, noticias), botón de pausa refleja el estado, comandos, **doble confirmación** de "cerrar todo" y "salir de modo seguro" (armado, confirmación en ≤ 5 s, caducidad), objetos ajenos ignorados, limpieza.

### Fase 11 — EA integrado (`Experts/XAUUSD_Autonomous.mq5`)
- Compilación: **0 errores, 0 warnings**.
- **Prueba de humo** (`Tools/run_ea_smoke.sh`): el EA se carga en el terminal (sin cuenta) operando el símbolo sintético `XAUSYN`; `FeedTicksSmoke` inyecta 3.000 ticks acelerados (8 h simuladas) y cierra el terminal. Resultado: **7/7 verificaciones** — `OnInit` completo, 54 velas M5 procesadas por el pipeline completo (régimen → estrategias → coordinador → gates), 6 cambios de régimen, **0 órdenes** (gate de conexión cerrado, como corresponde), estado persistido con checksum, cierre ordenado (`OnDeinit`), 0 errores críticos. Cada vela deja en el log régimen, motivo, señales, decisión y bloqueos.
- **Fallo seguro observado** (antes de ajustar el entorno de prueba): sin conexión, el EA se negó a arrancar porque el valor de tick era 0 (`SPEC_INVALID`), tanto en EURUSD como en el símbolo sintético.

- **Pruebas de reinicio** (`SMOKE_RESTART=1`, el estado se edita con `Tools/edit_state.py`):
  - estado con `ea.state=PAUSED` y suma recalculada → **10/10**: pausa restaurada, entradas bloqueadas por `PAUSED` en las 54 velas, sin errores críticos (verifica además que la suma FNV-1a de Python y MQL5 coincide);
  - estado alterado sin recalcular la suma → **10/10**: detectado como corrupto, **modo seguro** con entradas bloqueadas, cierre ordenado.
  - Sin cuenta el balance es 0, por lo que la base de pérdida diaria no puede verificarse aquí (el EA la descarta y reconstruye, como corresponde); queda para la demo (§8, prueba 8).

**Hallazgos de la integración:**
- El terminal desconectado no inicializa un EA en el gráfico de un símbolo personalizado ("symbol synchronization timeout"); la prueba usa el parámetro **solo de pruebas** `InpSymbolOverride` (exige `InpAllowAnySymbol=true`).
- La definición de un símbolo personalizado solo se guarda si el terminal se cierra de forma ordenada (`TerminalClose`).
- `SYMBOL_TRADE_TICK_VALUE_LOSS` puede ser 0 cuando no hay conversión de divisa disponible: se usa `SYMBOL_TRADE_TICK_VALUE` con advertencia en el log (el riesgo se verifica además contra `OrderCalcProfit`).
- Mejora de robustez: el temporizador (1 s) también ejecuta la gestión protectora y la detección de vela nueva, para que la protección no dependa de que lleguen ticks al gráfico.

### Índices sintéticos y cartera compartida (1.2.0) — 2026-10-17
- `Test_Instruments.mq5` → **44/44**: familia por nombre (XAUUSD con sufijo, Volatility y `(1s)`, Boom, Crash, Step, Jump, EURUSD no reconocido); resolución del perfil (oro sin cambios, sintético sin sesiones/noticias/rango asiático, Boom/Crash solo con `InpAllowSpikeIndices`, lado del spike, perfil forzado incoherente rechazado salvo `InpAllowAnySymbol`); límites relativos al ATR (cálculo, sin ATR se conservan, mínimo 1 punto, tope sin desbordar); validación; ruta del Champion por símbolo.
- `Test_Phase6.mq5` → **112/112** (+9 de cartera compartida): riesgo en otros símbolos en la exposición, rechazo por exposición y por posiciones de la cartera, peor caso del día con riesgo externo, valores negativos acotados.
- `Test_WebDashboard.mq5` → **33/33** (+5: `UrlEncode`, ruta con instancia). E2E con MT5 real → **39/39**, con la instancia "Volatility 75 (1s) Index": WinINet envía `?i=Volatility%2075%20%281s%29%20Index` sin alterarlo y la firma coincide; telemetría guardada con su instancia y confirmación registrada para ella.
- `WebDashboard/tests/test_server.py` → **29 tests OK** (+4): estado por instancia, comandos dirigidos y para todas con confirmación por instancia, consulta `?i=` cubierta por la firma, migración de una base 1.1.x (los EA 1.1.x siguen recibiendo comandos).
- Prueba de humo del EA con el perfil sintético forzado (`SMOKE_PROFILE=synth`) → **12/12**: perfil aplicado, ninguna vela bloqueada por sesión ni noticias, límites de coste recalculados con el ATR (p. ej. ATR M15 2,24 → spread máx 34, desviación 22, deriva 22, offset BE 4 puntos).
- Interfaz revisada en Chromium con tres instancias (XAUUSD, Volatility 75, Boom 1000): selector, "24/7", noticias "no aplica", destino de comandos y "Aplicado N de M"; oscuro, claro y 390 px sin errores de consola ni desplazamiento horizontal.
- **No probado:** símbolos reales de Deriv, backtest ni demo en sintéticos.

### Rediseño del dashboard (1.1.2)
- `WebDashboard/tests/test_server.py` → **25 tests OK** (nuevo: tipografías servidas localmente con `font/woff2`, sin peticiones a Google).
- E2E cliente MQL5 ↔ servidor → 34/34; EA completo + dashboard (`SMOKE_WEB=1`) → 15/15 con la telemetría ampliada (JSON válido, posiciones como lista).
- Revisión visual en Chromium: 4 pestañas en oscuro y claro, 1400 px y 390 px, estados operando / bloqueado / límite diario / sin reportar: sin errores de consola ni desplazamiento horizontal.

### Alcance de la pérdida diaria (1.1.1)
- `Test_Phase6.mq5` → 103/103 (ver arriba).
- Prueba de humo normal 7/7 y reinicio con `SMOKE_STATE_EDIT=scope` (bloqueo guardado con alcance "toda la cuenta", E0 10000 y equity 0 sin cuenta = −100 %) → **12/12**: el bloqueo se reevalúa, la pérdida diaria con alcance EA es 0,00 % y ninguna vela queda bloqueada por el límite diario.

### Dashboard web (1.1.0)
- `Test_WebDashboard.mq5` → **28 passed, 0 failed**: HMAC-SHA256 con 4 vectores fijos idénticos a Python (incluido RFC 4231 caso 2 y clave > 64 bytes), escape JSON y UTF-8, verificación de comandos (válido, repetido, viejo, alterado, otro token, `CLOSE_ALL` firmado → rechazado, mal formado), validación de configuración (https obligatorio salvo localhost, token ≥ 32, desactivado en el tester), nonces, intervalo y backoff.
- `WebDashboard/tests/test_server.py` → **24 tests OK**.
- **Extremo a extremo** (`Tools/run_web_e2e.sh`, MT5 bajo Wine ↔ servidor real en 127.0.0.1) → **34/34**: telemetría firmada aceptada (texto con comillas y "ñ" intacto), comando `PAUSE` recibido, verificado y confirmado, sin repetición tras confirmar.
- **EA completo + servidor** (`SMOKE_WEB=1 Tools/run_ea_smoke.sh`) → **15/15**: 8 envíos de telemetría con el símbolo correcto, `PAUSE` aplicado y confirmado, el servidor ve `PAUSED`, las velas siguientes quedan bloqueadas por `ESTADO PAUSED`, `web.last_cmd=1` persistido.
- Interfaz revisada en Chromium (claro, oscuro, 390 px): sin errores de consola ni desplazamiento horizontal; tooltip y crosshair del gráfico funcionando.

**Hallazgos:**
- Las claves `WebRequest`/`WebRequestUrl` en texto plano de un `.ini` de arranque **no** autorizan la URL: MT5 guarda la lista cifrada en `Config/common.ini` y solo se configura desde *Opciones* (en el entorno de pruebas se hizo con la interfaz gráfica).
- El cliente WinINet de MT5 reutiliza la conexión: con un servidor HTTP/1.0 la segunda petición fallaba (código 1003). El servidor usa HTTP/1.1 persistente (prueba añadida).
- La serie de equity tenía un límite de 720 filas (≈ 6 h a 30 s, no 3 días): ahora se agrega por intervalos (prueba añadida).

## 8. Lo que falta validar (requiere tu terminal y cuenta demo)

Para los índices sintéticos, la lista de [SYNTHETIC_INDICES.md §4](SYNTHETIC_INDICES.md) (especificación, historial, backtest y demo por símbolo).

| # | Prueba (Fase 12–13) | Cómo | Criterio |
|---|---|---|---|
| 1 | Compilación en tu MetaEditor | F7 en cada `.mq5` | 0 errores |
| 2 | Especificaciones reales | `SymbolSpecDump` | revisar contrato, tick value, lotes, Hedging/Netting, offset |
| 3 | Calendario | `ExportCalendar` en vivo; comprobar 1 evento conocido (p. ej. NFP) en el CSV con su hora | hora correcta en hora del servidor |
| 4 | Régimen | `RegimeLogger` 12+ meses + `regime_report.py`, dentro y fuera de muestra | veredictos de la sección Fase 3 |
| 5 | Backtest del EA | tester, ticks reales, comisión y spread reales, CSV de noticias | ≥ 100 operaciones OOS antes de concluir nada |
| 6 | Walk-forward | `challenger.py folds` + `compare` | criterios de promoción (ARCHITECTURE.md §14) |
| 7 | Spread y slippage | repetir backtest con spread fijo ×1.5 y ×2 y delay aleatorio | el resultado no debe depender de costos optimistas |
| 8 | Reinicio | en demo, quitar y volver a poner el EA con posiciones abiertas | sin duplicados; metadatos y diario recuperados |
| 9 | Desconexión | en demo, cortar la red 2–3 min con una posición abierta | SL/TP siguen en el servidor; el EA no envía duplicados al volver |
| 10 | Límites de riesgo | en demo con `InpDailyLossPct` bajo (p. ej. 1 %) | bloqueo diario, gestión protectora activa |
| 11 | Hedging/Netting | si Deriv ofrece ambos tipos de cuenta demo | Netting: máximo 1 posición, sin promediar |
| 12 | Demo prolongada | varias semanas (distintos regímenes) | comparar ejecución real (slippage, spread, rechazos) con el backtest |
| 13 | Dashboard web (opcional) | desplegar según `WebDashboard/README.md`, permitir la URL en MT5, probar PAUSE/RESUME/SAFE_MODE en demo | estado reflejado en ≤ 1 ciclo; comando en el log del EA y en la auditoría |

Nada de lo anterior está hecho todavía; ningún resultado aquí es una métrica de rendimiento.
