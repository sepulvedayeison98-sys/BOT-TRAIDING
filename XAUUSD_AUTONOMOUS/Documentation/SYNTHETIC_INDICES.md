# Índices sintéticos (1.2.0)

El mismo EA opera XAUUSD y los índices sintéticos de Deriv. Se coloca **un gráfico por símbolo** y cada gráfico detecta su **perfil de instrumento** por el nombre del símbolo (`InpProfile = Automático`).

> Las estrategias, el régimen y los umbrales se diseñaron y validaron sobre el oro. En sintéticos **no hay backtest ni demo todavía**: es código probado (unitario y de humo), no una estrategia validada. No se promete rentabilidad. Primero backtest y luego demo.

## 1. Perfiles

| | XAUUSD | Sintético continuo | Sintético con spikes |
|---|---|---|---|
| Símbolos (nombre contiene) | `XAUUSD` | `Volatility` (incluye las `(1s)`), `Step`, `Jump` | `Boom`, `Crash` |
| Sesiones | Londres / Nueva York | 24/7, sin filtro | 24/7, sin filtro |
| Noticias USD | sí | no aplica | no aplica |
| Rango asiático (SMC) | sí | no | no |
| Spread, desviación, deriva de entrada, offset de BE | puntos (inputs) | fracción del ATR M15 | fracción del ATR M15 |
| Dirección | ambas | ambas | **solo la del spike**: Boom compra, Crash vende |
| Arranque | automático | automático | exige `InpAllowSpikeIndices=true` |

Un símbolo que no es ninguno de estos no arranca, salvo con `InpAllowAnySymbol=true` (solo pruebas). Forzar un perfil que no corresponde al nombre (por ejemplo el del oro en un Volatility) también lo exige.

### Por qué sin sesiones ni noticias
Deriv genera estos índices con un algoritmo y los ofrece 24/7, sin relación con noticias económicas. Por eso el filtro de Londres/Nueva York y el calendario USD se desactivan. **Comprueba en MT5** (clic derecho en el símbolo > Especificación > Sesiones) que el tuyo cotiza 24/7. El EA sigue respetando las sesiones de trading que declare el bróker (`MERCADO` en los bloqueos).

### Por qué costes relativos al ATR
Un "punto" no vale lo mismo en V75 que en Boom 1000 o en el oro, así que 60 puntos de spread no significan nada fuera del oro. En sintéticos los umbrales se recalculan en cada vela M5 con el ATR M15:

| Input | Por defecto | Uso |
|---|---|---|
| `InpSynthMaxSpreadAtr` | 0.15 | no abre si el spread supera el 15 % del ATR M15 |
| `InpSynthDeviationAtr` | 0.10 | desviación permitida en la orden |
| `InpSynthEntryDriftAtr` | 0.10 | descarta la entrada si el precio se alejó más que eso desde la evaluación |
| `InpSynthBeOffsetAtr` | 0.02 | offset del break-even (además del spread) |

Son **hipótesis**: equivalen aproximadamente a lo que usa el oro con su ATR típico. Hay que calibrarlas con `SymbolSpecDump` y la demo. El panel y el dashboard muestran el spread actual y el máximo vigente. Hasta la primera vela con datos válidos el EA no abre operaciones.

### Por qué Boom/Crash es experimental y solo en la dirección del spike
Boom tiene saltos bruscos al alza y Crash a la baja (según Deriv, en promedio uno cada ~1000/500/300 ticks según el índice; verifícalo en la descripción del símbolo). Si una venta en Boom tiene el SL por encima, un spike puede saltarlo y cerrarla mucho peor que el SL. Eso rompe el 1 % de riesgo por operación, que es la base del sistema. Por eso:
- el perfil no arranca sin `InpAllowSpikeIndices=true`;
- con `InpSpikeSideOnly=true` (por defecto) se descartan las señales contra el spike, que aparecen como `SIGNAL_FILTERED` en el log.

Además, el ATR de estos índices incluye los spikes. Las estrategias (SMC, ruptura, reversión) no se diseñaron para esa dinámica, así que espera muchas menos señales y resultados distintos a los del oro.

## 2. Cartera compartida (varios gráficos)

Con `InpSharedPortfolio=true` (por defecto) y **la misma magic en todos los gráficos** (por defecto 26101201), los límites son de toda la cartera:
- **Exposición** (2 %): suma el riesgo hasta el SL de las posiciones de esta magic en todos los símbolos, cada una con la especificación de su símbolo (`OrderCalcProfit`). Una posición sin SL o cuyo riesgo no se puede calcular cuenta como el riesgo máximo por operación.
- **Posiciones** (3): todas las de esta magic.
- **Pérdida diaria** (3 %, alcance "solo EA"): realizado del día + flotante de todos los símbolos con esta magic.
- **Peor caso del día**: incluye el riesgo abierto en otros símbolos.

Así, tres gráficos (XAUUSD, V75, Boom) no pueden sumar 6 % de exposición ni 9 % de pérdida diaria. Con magics distintas, o con `InpSharedPortfolio=false`, cada gráfico tiene sus propios límites y la cuenta puede perder la suma de todos.

En una cuenta Netting el máximo sigue siendo una posición **por símbolo** (el EA no promedia).

## 3. Dashboard web con varias instancias

Cada gráfico envía su telemetría con su símbolo (activa `InpWebEnabled` en cada uno, con la misma URL y el mismo token).
- Arriba aparece la fila **Instancias**, con estado y conexión de cada gráfico; al pulsar una se ve su información.
- **Control**: elige el destino del comando, solo esa instancia o todas. Con "Todas", cada instancia lo confirma por separado y el historial muestra "Aplicado N de M".
- En sintéticos, *Mercado* muestra "24/7 · sin filtro de sesión" y "Noticias: no aplica"; el ATR va en unidades de precio.

Los EA 1.1.x siguen funcionando con el servidor nuevo y aparecen como una instancia sin símbolo en la ruta.

## 4. Puesta en marcha (demo)

1. **Cuenta.** En Deriv, los sintéticos pueden estar en un tipo de cuenta MT5 distinto del de XAUUSD (Derived/Standard frente a Financial). No estoy seguro de cómo está organizada tu cuenta actual: comprueba en *Observación del mercado > Símbolos* que aparecen "Volatility 75 Index", "Boom 1000 Index", etc. Si no aparecen, necesitas la cuenta demo que los incluya.
2. **Instalar o actualizar.** `git pull` y luego `Tools\instalar_windows.ps1`, como siempre. Es el mismo EA.
3. **Especificación.** Ejecuta `SymbolSpecDump` en el gráfico del sintético y guarda el reporte: dígitos, punto, valor del tick, lote mínimo y paso, stops level, sesiones.
4. **Historial.** Abre el gráfico H1, M15 y M5 del símbolo y desplázate atrás. El EA necesita 700 velas por temporalidad.
5. **Cargar el EA** en el gráfico del sintético con los mismos parámetros. Para Boom/Crash, además, `InpAllowSpikeIndices=true`. Revisa en la pestaña Expertos la línea `PROFILE`:
   ```
   perfil SINTETICO (Volatility): sesiones 24/7, noticias no aplica, costes relativos al ATR M15
   ```
6. **Backtest** en el Strategy Tester con "Cada tick basado en ticks reales" si el historial de ticks está disponible, antes de dejarlo en demo. El criterio de `OnTester` es el mismo.
7. **Champion por símbolo.** XAUUSD sigue usando `XAUUSD/champion.model`. Los demás buscan `XAUUSD/champion_<símbolo>.model`, con espacios y paréntesis cambiados por `_` (por ejemplo `champion_Volatility_75_Index.model`). Sin ese archivo usan los parámetros por defecto. **No copies el modelo del oro a un sintético.**

## 5. Verificación realizada (entorno de desarrollo, sin cuenta Deriv)
- `Test_Instruments.mq5`: 44/44 (detección por nombre, protecciones, lado del spike, límites relativos al ATR, nombres de archivo).
- `Test_Phase6.mq5`: 112/112, con 9 pruebas de cartera compartida (exposición, posiciones y peor caso del día con riesgo en otros símbolos).
- `Test_WebDashboard.mq5`: 33/33. E2E con MT5 real: 39/39, con la instancia "Volatility 75 (1s) Index" en la ruta firmada.
- `WebDashboard/tests`: 29 (instancias, comandos dirigidos, confirmación por instancia, firma de la consulta, migración desde 1.1.x).
- Prueba de humo del EA con el perfil sintético forzado sobre un símbolo personalizado (`SMOKE_PROFILE=synth Tools/run_ea_smoke.sh`).

**No verificado:** símbolos reales de Deriv (especificación, spread y ATR típicos), backtest y demo en sintéticos. Los umbrales en fracción de ATR son hipótesis.
