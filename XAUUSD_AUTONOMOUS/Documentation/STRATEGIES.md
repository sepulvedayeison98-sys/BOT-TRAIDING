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

## 3. StrategySMC

| Concepto | Regla objetiva |
|---|---|
| Liquidity Sweep | Vela que supera un pivote confirmado (alto o bajo) por ≥ `x × ATR` y **cierra de vuelta** dentro del rango previo. |
| BOS | Cierre de vela más allá del último pivote confirmado **en la dirección** de la estructura. |
| CHoCH | Cierre más allá del último pivote confirmado **contrario** a la estructura vigente. |
| FVG alcista | En velas `i−2, i−1, i`: `low[i] > high[i−2]` y tamaño ≥ `y × ATR`. Bajista simétrico. Se invalida cuando el precio lo rellena por completo (o al 50 %, configurable). |
| Order Block alcista | Última vela bajista antes de un desplazamiento que produce un BOS/CHoCH alcista; zona = [low, high] (o cuerpo, configurable). Válido hasta ser mitigado. |
| Premium / Discount | Respecto al último rango de impulso M15 (pivote bajo → pivote alto): > 50 % premium, < 50 % discount. Compras solo en discount, ventas solo en premium. |
| Zonas de liquidez | Pivotes iguales (dobles techos/suelos dentro de `z × ATR`) y extremos de sesión previa (Asia/Londres). |
| Rechazo estructural | Mecha ≥ 60 % del rango de la vela dentro de una zona OB/FVG, con cierre fuera de ella. |

**Setup (ejemplo compra):** H1 alcista o rango en discount → sweep de liquidez bajo M15 → CHoCH/BOS alcista M15 → retroceso a FVG/OB en discount → confirmación M5 (BOS M5 o rechazo). SL bajo el mínimo del sweep + colchón ATR. TP en la siguiente liquidez opuesta.

## 4. StrategyBreakout

- **Consolidación M15**: ≥ `B` velas con rango total ≤ `c × ATR(M15)` y ADX descendente.
- **Ruptura válida**: cierre fuera del rango ≥ `d × ATR`, cuerpo ≥ 60 % de la vela, spread ≤ umbral; tick volume de la vela ≥ `v ×` media (proxy, ver limitaciones).
- **Entrada**: retest del borde roto con rechazo en M5, o continuación tras BOS M5 si no hay retest en `T` velas (configurable).
- **Falsa ruptura**: si vuelve a cerrar dentro del rango antes de la entrada → señal cancelada (y puede alimentar a SMC/Reversal como sweep).

## 5. StrategyReversal

Requiere **al menos 3** de: divergencia RSI (pivotes confirmados de precio vs RSI), sweep de liquidez, vela de rechazo en zona relevante, CHoCH en M15/M5, extensión ≥ `e × ATR` desde EMA50.
**Obligatorio**: CHoCH de confirmación. Sobrecompra/sobreventa sola nunca genera señal.

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
