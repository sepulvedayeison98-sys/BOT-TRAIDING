# Estrategias — especificación objetiva

> Estado: **diseño (Fase 1)**. Todas las reglas usan **velas cerradas** y **pivotes confirmados**. Los valores numéricos son iniciales y deben calibrarse con datos fuera de muestra; no son resultados validados.

## 1. Definiciones base (MarketEngine)

- **Pivote (swing) alto en TF**: vela `i` cuyo `high` es estrictamente mayor que los `high` de las `N` velas a la izquierda y `N` a la derecha (inicial `N = 3` en M5/M15, `N = 2` en H1). Se confirma cuando cierran las `N` velas de la derecha → retraso de `N` velas, intencional para evitar repintado.
- **Estructura alcista**: últimos dos pivotes altos y bajos confirmados ascendentes (HH + HL). Bajista: LH + LL.
- **Momentum**: pendiente normalizada de EMA50 (`(EMA50[1] − EMA50[1+k]) / ATR`) y posición de RSI respecto a 50. Definición exacta se fija en Fase 2.
- **Volatilidad relativa**: `ATR(14)[1] / media(ATR(14), 100)`.
- **Spread medio**: media móvil de spread registrada por el EA (el historial de spread por vela de `MqlRates.spread` se usará cuando exista).

## 2. RegimeEngine (H1 principal, M15 de apoyo)

| Régimen | Condición inicial (todas configurables) |
|---|---|
| `HIGH_VOLATILITY` | `ATR_ratio ≥ 1.8` (se evalúa primero) |
| `TREND_UP` | EMA50 > EMA200, precio > EMA50, ADX ≥ 22, estructura H1 alcista |
| `TREND_DOWN` | simétrico |
| `RANGE` | ADX < 18 y precio oscilando entre extremos confirmados de M15 |
| `NO_TRADE` | datos inválidos, ADX entre 18–22 sin estructura clara, spread anómalo, o condiciones contradictorias |

`HIGH_VOLATILITY` por defecto **no opera** (configurable a "solo con riesgo reducido" — nunca aumentado).

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
