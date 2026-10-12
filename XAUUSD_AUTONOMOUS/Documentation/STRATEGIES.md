# Estrategias — especificación objetiva

> Estado: **diseño (Fase 1)**. Todas las reglas usan **velas cerradas** y **pivotes confirmados**. Los valores numéricos son iniciales y deben calibrarse con datos fuera de muestra; no son resultados validados.

## 1. Definiciones base (MarketEngine)

- **Pivote (swing) alto en TF**: vela `i` cuyo `high` es estrictamente mayor que los `high` de las `N` velas a la izquierda y `N` a la derecha (inicial `N = 3` en M5/M15, `N = 2` en H1). Se confirma cuando cierran las `N` velas de la derecha → retraso de `N` velas, intencional para evitar repintado.
- **Estructura alcista**: últimos dos pivotes altos y bajos confirmados ascendentes (HH + HL). Bajista: LH + LL.
- **Momentum** (implementado en Fase 2): `ema_slope = (EMA50[0] − EMA50[k]) / ATR[0]` con `k = 5` velas cerradas; `ema_slope_prev` es la misma medida desplazada `k` velas. **Cambio de momentum** = cambio de signo entre ambas, ignorando pendientes con |valor| < 0.05 ATR. La posición del RSI respecto a 50 la usarán las estrategias directamente desde `rsi[]`.
- **Volatilidad relativa** (implementado): `atr_ratio = ATR(14)[0] / media(ATR(14)[0..99])`.
- **Spread medio** (implementado): media de `MqlRates.spread` de las últimas 50 velas M5 cerradas (si al menos la mitad lo trae); si el bróker no lo provee, EMA del spread muestreado por tick (requiere ≥ 100 muestras). Si no hay referencia, `spread_avg_points = 0` y los filtros relativos deben tratarlo como "sin referencia".

## 2. RegimeEngine (implementado en Fase 3)

Evaluación en orden; la primera regla que se cumple decide. Todos los umbrales son inputs y son **hipótesis iniciales sin validar**.

| # | Condición | Régimen |
|---|---|---|
| 1 | Snapshot o cualquier TF inválido | `NO_TRADE` |
| 2 | `spread_ratio > 3.0` (si hay referencia de spread) | `NO_TRADE` |
| 3 | `atr_ratio H1 ≥ 1.8` o `atr_ratio M15 ≥ 2.2` | `HIGH_VOLATILITY` |
| 4 | `atr_ratio H1 < 0.5` | `NO_TRADE` (mercado muerto) |
| 5 | `ADX H1 ≥ 22` y **todas**: EMA50 vs EMA200, cierre H1 del lado de la EMA50, +DI/−DI a favor, pendiente EMA50 ≥ 0.05 ATR a favor, estructura H1 HH/HL (o LH/LL) | `TREND_UP` / `TREND_DOWN` |
| 5b | `ADX H1 ≥ 22` sin alineación completa | `NO_TRADE` (el motivo lista cada condición fallida) |
| 6 | `ADX H1 ≤ 18`, `|pendiente| ≤ 0.3`, rango = último pivote alto y bajo M15 confirmados, ancho entre 2 y 12 ATR M15, cierre M5 dentro | `RANGE` |
| 7 | ADX entre 18 y 22 | `NO_TRADE` (zona neutral) |

**Histéresis:** el estado inicial es `NO_TRADE`. Pasar a `NO_TRADE` o `HIGH_VOLATILITY` es inmediato (seguridad). Cualquier otro cambio exige 2 evaluaciones consecutivas (configurable).

**Información adicional para el AdaptiveEngine:** distancia en ATR H1 al pivote alto H1 más reciente por encima del precio y al pivote bajo por debajo (`-1` si no hay), y límites del rango M15.

`HIGH_VOLATILITY` por defecto **no opera** (configurable en fases posteriores a "solo con riesgo reducido", nunca aumentado).

**Hallazgo en pruebas:** en una oscilación lateral sintética el ADX H1 marcó 25.9, por encima del umbral de tendencia. Las reglas de alineación la bloquearon (`NO_TRADE`), pero confirma que **el ADX por sí solo no distingue oscilación de tendencia**; los umbrales deben calibrarse con `Tools/regime_report.py` sobre datos reales.

### Validación estadística del régimen
`Tests/Backtesting/RegimeLogger.mq5` registra régimen y variables en cada vela M5 cerrada; `Tools/regime_report.py` comprueba si cada régimen se comporta como promete:

| Régimen | Hipótesis comprobada | Criterio "CONSISTENTE" |
|---|---|---|
| `TREND_UP` | retorno futuro medio > 0 | t ≥ 2 |
| `TREND_DOWN` | retorno futuro medio < 0 | t ≤ −2 |
| `HIGH_VOLATILITY` | movimiento absoluto mayor | ≥ 1.3 × media global |
| `RANGE` | desde los extremos el precio vuelve al centro | retorno firmado medio > 0, t ≥ 2 |

Retornos medidos en ATR H1, horizontes 12 y 48 velas M5, **muestreados sin solapamiento**, mínimo 30 observaciones. Con caminatas aleatorias la tasa de falsos "consistentes" medida fue ~2–3 % por régimen (60 semillas). Un umbral calibrado debe confirmarse en un periodo distinto.

## 3. Reglas comunes (implementado en Fase 4: `PatternLib.mqh`, `StrategyBase.mqh`)

Todas las detecciones usan velas cerradas y pivotes confirmados. Un evento en la vela `i` solo puede usar pivotes con índice `k ≥ i + n + 1` (confirmados antes del evento).

| Patrón | Regla objetiva |
|---|---|
| Barrido (sweep) | La vela supera un pivote confirmado **aún intacto** por ≥ 0.05 ATR y **cierra de vuelta** del lado previo. |
| BOS / CHoCH / BREAK | Cierre más allá del pivote confirmado más reciente, con la vela anterior sin haberlo cerrado (ruptura fresca). BOS si va a favor de la estructura del TF, CHoCH si va en contra, BREAK si la estructura era mixta o desconocida. |
| FVG | Velas (i, i+1, i+2): alcista si `low[i] > high[i+2]`, tamaño ≥ 0.1 ATR. Se descarta si una vela posterior lo **rellena por completo**. |
| Order Block | Última vela contraria antes del desplazamiento que produjo la ruptura. Se descarta si una vela posterior **cierra** más allá de su extremo. |
| Vela de rechazo | Mecha del lado del rechazo ≥ 60 % del rango y cierre en la mitad favorable. |
| Caja de consolidación | `box_bars` velas con altura ≤ `max_box_atr` ATR. |
| Divergencia RSI | Dos pivotes más recientes del lado indicado: precio más extremo y RSI menos extremo en ≥ 3 puntos; pivote nuevo con ≤ 12 velas de antigüedad. |
| Rango asiático | Máximo/mínimo de 00:00–07:00 UTC de la sesión más reciente (puede estar en curso). |

**Confirmación M5:** vela de rechazo en la última vela M5 cerrada, o ruptura de estructura M5 en las últimas 2 velas.
**Entrada de referencia:** cierre de esa vela M5. La señal expira al cerrar la vela M5 siguiente.
**SL:** invalidación estructural + 0.2 ATR M15; si queda a menos de 0.5 ATR se aleja hasta 0.5 ATR; si queda a más de 4 ATR la señal se descarta.
**TP:** nivel de liquidez opuesto más cercano entre pivotes M15/H1 y los niveles propios de cada estrategia, a ≥ 1 ATR M15 y ≤ 8 ATR H1. Si no hay ninguno, no hay señal. **El R:R mínimo (1:2) lo exige el RiskManager**; las estrategias solo lo calculan.
**Régimen:** ninguna estrategia opera en `NO_TRADE` ni en `HIGH_VOLATILITY`. La compatibilidad de régimen se decide dentro de cada estrategia (un solo lugar).

## 4. StrategySMC (compra; venta = espejo)
1. Régimen `TREND_UP` o `RANGE`.
2. Barrido de un mínimo M15 en las últimas 16 velas.
3. Ruptura alcista M15 por cierre **después** del barrido.
4. Zona de interés en el desplazamiento: FVG sin rellenar (preferente) u Order Block sin invalidar.
5. Descuento: el centro de la zona está por debajo del 50 % del tramo (mecha del barrido → máximo posterior).
6. La última vela M5 toca la zona sin cerrar por debajo, con confirmación M5.
- Invalidación: lo más bajo entre la mecha del barrido y el borde inferior de la zona.
- Niveles extra para el TP: máximo del tramo y máximo asiático.

## 5. StrategyBreakout (compra; venta = espejo)
1. Régimen `TREND_UP` o `RANGE`.
2. Caja M15 de 12 velas con altura ≤ 3 ATR; vela de ruptura que cierra ≥ 0.1 ATR fuera, con cuerpo ≥ 60 %, en las últimas 8 velas M15, sin cierres posteriores de vuelta dentro (falsa ruptura = descarte).
3. Volumen: tick volume ≥ 1.2 × la media de la caja. Se registra como evidencia; es obligatorio solo con `require_volume` (el tick volume es un indicador indirecto).
4. Entrada: **retest** (vela M5 alcista que toca el borde ± 0.2 ATR y cierra fuera) o **continuación** (ruptura M5 si pasaron ≥ 3 velas M15 sin retest).
- Invalidación: mitad de la caja. Nivel extra para el TP: proyección de la altura de la caja.

## 5b. StrategyReversal (compra contra tendencia bajista; venta = espejo)
- Régimen `TREND_DOWN` o `RANGE`.
- **Obligatorio:** CHoCH alcista M15 en las últimas 16 velas, y el cierre M5 sigue por encima del nivel roto.
- ≥ 3 confirmaciones entre: CHoCH, divergencia RSI M15, barrido de un mínimo M15 (anterior o igual al CHoCH), vela de rechazo M15 en el extremo del tramo, extremo a ≥ 2 ATR por debajo de la EMA50 M15.
- Confirmación M5 obligatoria. Sobrecompra/sobreventa sola nunca genera señal.
- Invalidación: extremo del tramo. Nivel extra para el TP: origen del tramo.

### Observaciones de la reproducción sintética (no son métricas de rendimiento)
En 1.500 velas M5 por serie, las estrategias generaron entre 0 y ~25 señales por serie. La frecuencia y los umbrales deben medirse con datos reales en el Strategy Tester.

## 6. AdaptiveEngine — puntuación

| Componente | Puntos | Trend-following (SMC/Breakout) | Reversal |
|---|---|---|---|
| Contexto H1 | 20 | alineación con tendencia H1 | agotamiento H1 (extensión, divergencia H1, zona mayor) |
| Estructura M15 | 20 | BOS/CHoCH a favor | CHoCH contra el movimiento previo |
| Liquidez | 20 | sweep previo + zona en discount/premium correcto | sweep del extremo |
| Confirmación M5 | 20 | BOS/rechazo M5 | BOS/rechazo M5 |
| Momentum y volatilidad | 10 | momentum a favor, ATR_ratio normal | pérdida de momentum |
| Calidad de ejecución | 10 | spread bajo, R:R ≥ 2.5, lejos de noticias y fin de sesión | igual |

El componente H1 se define **por familia de estrategia** (riesgo R5 en ARCHITECTURE.md): con la definición literal "tendencia H1", Reversal quedaría sistemáticamente descartada.

**Umbrales iniciales:** < 65 descartar · 65–79 moderada · ≥ 80 alta. **No son probabilidades.** Inicialmente "moderada" y "alta" usan el **mismo riesgo (1 %)**; diferenciar riesgo por calidad requeriría evidencia estadística y tu aprobación.

**Resolución:**
1. Señales de direcciones opuestas en la misma vela → descartar ambas (`CONFLICT`).
2. Misma dirección, zonas solapadas → una sola oportunidad; gana la de mayor puntuación (`DEDUP`).
3. Ya existe posición propia sobre la misma zona/`invalidation` → descartar.
4. Régimen incompatible con la estrategia (p. ej. Breakout en `RANGE` sin consolidación) → descartar.
5. Envío a RiskManager de **una** propuesta como máximo por vela M5.
