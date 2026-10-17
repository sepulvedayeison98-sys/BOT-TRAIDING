# Gestión de riesgo — especificación

> Estado: **implementado en la Fase 6** (`Include/XAUUSD/RiskManager.mqh`, `StateStore.mqh`) y probado con 90 pruebas (`Tests/Validation/Test_Phase6.mq5`). Los límites duros de §1 están aprobados y codificados como constantes.
> Ningún parámetro de este documento puede ser modificado por el LearningEngine.

## 1. Parámetros iniciales y límites duros

| Parámetro | Valor inicial | Límite duro propuesto (el EA no arranca si se supera) |
|---|---|---|
| Riesgo por operación | 1.0 % | ≤ 2.0 % |
| Exposición agregada máxima | 2.0 % | ≤ 5.0 % y ≥ riesgo por operación |
| Posiciones simultáneas (Hedging) | 3 | ≤ 5 |
| Posiciones simultáneas (Netting) | 1 (forzado) | 1 |
| Pérdida diaria máxima | 3.0 % | ≤ 6.0 % y ≥ riesgo por operación |
| R:R mínimo | 1 : 2 | ≥ 1 : 1 |
| Break-even | 1.0 R | > 0 R |
| Inicio de trailing | 1.5 R | ≥ break-even |

Los límites duros son una **propuesta** para tu aprobación. Su objetivo es impedir errores de tipeo (p. ej. escribir `10` en vez de `1.0`).

Prohibido por diseño (no existen parámetros para activarlo): martingala, grids, promediar pérdidas, aumentar riesgo tras pérdida, ampliar SL.
Permitido: **reducir** el riesgo tras rachas de pérdidas (opcional, desactivado por defecto).

## 2. Base de cálculo

- `base_riesgo = min(Balance, Equity)` en el momento de evaluar. Usar el menor es conservador: con flotante negativo, se arriesga menos.
- Todo el riesgo se expresa en **moneda de la cuenta** (`ACCOUNT_CURRENCY`).

## 3. Cálculo de volumen

Para una propuesta con precio de entrada `E` (ask para compra, bid para venta) y `SL`:

1. **Pérdida por 1 lote** con `OrderCalcProfit(tipo, símbolo, 1.0, E, SL, profit)` → `loss_1lot = -profit`.
   - Si la función falla o `loss_1lot ≤ 0` → rechazar (`RISK_CALC_FAILED`).
2. **Verificación cruzada**: `loss_tick = |E − SL| / tick_size × tick_value_loss`. Si difiere de `loss_1lot` más de un 5 % → rechazar y registrar (protege contra especificaciones inconsistentes o conversión de divisa incorrecta).
3. **Costos añadidos al riesgo** por lote:
   - Venta: el SL se ejecuta con el ask → sumar spread esperado en el momento del SL (spread actual × factor configurable).
   - Comisión estimada ida y vuelta (medida de deals reales; inicialmente input).
   - Colchón de slippage (input, en puntos).
4. `riesgo_objetivo = base_riesgo × riesgo_%`.
5. `vol_bruto = riesgo_objetivo / loss_total_1lot`.
6. **Redondeo siempre hacia abajo** al `SYMBOL_VOLUME_STEP`.
7. Si `vol < SYMBOL_VOLUME_MIN` → **rechazar** (`VOLUME_BELOW_MIN`). **Nunca** se redondea hacia arriba al mínimo: eso aumentaría el riesgo por encima del 1 %.
8. Limitar a `SYMBOL_VOLUME_MAX` y a `SYMBOL_VOLUME_LIMIT` si aplica.
9. Recalcular el riesgo real con el volumen final; debe ser ≤ `riesgo_objetivo`.

## 4. Margen

- `OrderCalcMargin(tipo, símbolo, vol, E, margen)`.
- Aprobar solo si `margen_libre − margen ≥ colchón` y el *margin level* resultante ≥ umbral (input, p. ej. 300 %).
- `OrderCheck()` antes de `OrderSend()` como verificación final del servidor (lo hace ExecutionManager).

## 5. Exposición agregada

Riesgo restante de cada posición propia abierta:
`riesgo_pos = max(0, −OrderCalcProfit(tipo, símbolo, vol, precio_apertura, SL_actual))`
- Posición con SL en break-even o en beneficio → riesgo 0.
- Posición **sin SL** → error crítico → `SAFE_MODE`.

`exposición_después = Σ riesgo_pos + riesgo_nuevo` debe ser ≤ 2 % de `base_riesgo`.

**Consecuencia práctica (1 % + 2 %):** como máximo 2 posiciones con riesgo pleno a la vez. Una 3.ª solo es posible cuando alguna ya está protegida en break-even. Esto es intencional.

**Cartera compartida (1.2.0, `InpSharedPortfolio=true`).** Con un gráfico por símbolo (XAUUSD, índices sintéticos) y la misma magic, la suma incluye las posiciones de esa magic en **todos** los símbolos. El riesgo de cada una se calcula con `OrderCalcProfit` sobre su propio símbolo. Si no tiene SL o el cálculo falla, cuenta como `base_riesgo × riesgo_por_operación` (conservador). El máximo de posiciones y el peor caso del día también son de la cartera. Con `false` o con magics distintas, cada gráfico tiene sus propios límites. Ver [SYNTHETIC_INDICES.md](SYNTHETIC_INDICES.md).

## 6. Pérdida diaria

- **Reset**: a la hora configurada en **hora del servidor** (propuesta: 00:00, decisión D4).
- **Base**: `E0 = Equity` en el instante del reset, persistida en `state.json`.
- **Sin snapshot del día** (EA arrancado a mitad del día o fichero perdido): `E0 = Balance_actual − PnL_realizado_hoy` (reconstruido desde los deals del día, neto de comisiones y swaps, excluyendo depósitos/retiros). Es una aproximación: ignora el flotante que existiera en el reset, que no se puede recuperar. Se registra en el log que la base es reconstruida.
- **PnL del día** = `Equity_actual − E0 − depósitos_hoy + retiros_hoy` (depósitos/retiros detectados como deals `DEAL_TYPE_BALANCE`). Incluye realizado + flotante + comisiones + swaps.
- **Alcance** (`InpDailyLossScope`, 1.1.1; decisión del usuario del 2026-10-14): por defecto **solo las operaciones del EA** (su número mágico y símbolo). Entonces `PnL_día = realizado propio desde el reset (beneficio + comisión + swap) + flotante de sus posiciones abiertas`; las operaciones manuales o de otros EA en la misma cuenta **no** consumen el límite. El porcentaje se sigue calculando sobre `E0` (equity de la cuenta al reset). Con `DAILY_SCOPE_ACCOUNT` se usa la fórmula de toda la cuenta de arriba. Si el alcance cambia, un bloqueo guardado del mismo día se reevalúa con el nuevo alcance.
  - Consecuencia: con alcance EA, la cuenta puede perder más del 3 % en un día por operaciones ajenas; el EA solo garantiza que **sus** operaciones no lo superen. Recomendación: no operar a mano ni con otros EA en la misma cuenta.
  - Aproximación: el flotante de una posición propia que viene del día anterior cuenta completo en el día actual.
  - Con cartera compartida (1.2.0) "propio" significa esta magic en todos los símbolos: todos los gráficos ven la misma cifra y se bloquean juntos.
- **Bloqueo**: si `PnL_día ≤ −3 % × E0` → estado `DAILY_LIMIT`.
- **Chequeo previo de peor caso** (recomendado): rechazar una nueva entrada si `pérdida_actual_del_día + exposición_después > 3 % × E0`. Así, aunque todos los SL se ejecuten, el día no supera el límite (salvo gaps/slippage).
- Al alcanzar el límite: bloquear entradas, registrar motivo, **mantener** BE/trailing/invalidación. **No** cerrar posiciones ganadoras automáticamente.

## 7. Stop Loss y Take Profit

### Stop Loss
1. **Estructural**: más allá del nivel de invalidación de la señal (swing/OB/sweep) + colchón `k × ATR(M15)`.
2. **Límites**: distancia ≥ `min_atr × ATR` (evitar SL dentro del ruido) y ≤ `max_atr × ATR`. Si la estructura exige un SL mayor que el máximo → **rechazar** la señal (no se acerca el SL arbitrariamente).
3. Distancia ≥ `SYMBOL_TRADE_STOPS_LEVEL` + spread.

### Take Profit
1. Siguiente zona de liquidez opuesta (swing confirmado, borde de rango, FVG/OB opuesto).
2. Si `R:R < 2` hasta esa zona → **rechazar** (no se estira el TP más allá de un objetivo lógico).

### Gestión posterior (PositionManager)
| Regla | Disparo | Acción |
|---|---|---|
| Break-even | precio ≥ 1.0 R a favor | SL → entrada + costos (spread + comisión) |
| Trailing | precio ≥ 1.5 R | SL siguiendo último swing M5 confirmado o `ATR × m` (configurable), solo en dirección favorable |
| Invalidación | cierre de vela M15 más allá del nivel de invalidación | cerrar posición |

**Invariante:** el nuevo SL nunca puede estar más lejos de la entrada que el SL anterior (para compra: `SL_nuevo ≥ SL_anterior`). Toda modificación que viole esto se descarta y se registra como error.

Antes de modificar: comprobar `SYMBOL_TRADE_FREEZE_LEVEL` (si el precio está dentro del freeze level, no se puede modificar; reintentar en el siguiente tick) y `STOPS_LEVEL`.

## 8. Hedging vs Netting

Detección en `OnInit` con `AccountInfoInteger(ACCOUNT_MARGIN_MODE)`:
- `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING` → posiciones independientes; máx. 3.
- `ACCOUNT_MARGIN_MODE_RETAIL_NETTING` o `EXCHANGE` → máx. 1 posición en XAUUSD; prohibido abrir en la misma dirección (promediaría) y en dirección contraria (reduciría/invertiría la posición fuera del control de riesgo). Señales opuestas solo pueden provocar cierre por invalidación, no inversión.

## 9. Pruebas obligatorias de RiskManager (Fase 6)

- Volumen con tick values de distintas magnitudes y monedas de cuenta (USD y otra).
- Redondeo: casos justo por debajo/encima del step y del mínimo.
- Rechazo cuando el mínimo de lote excede el riesgo.
- Exposición con 0, 1, 2, 3 posiciones, con y sin break-even.
- Pérdida diaria con flotante, depósitos y retiros a mitad del día, reinicio del EA a mitad del día.
- Netting: rechazo de 2.ª posición.
- Inputs fuera de límites duros → `INIT_PARAMETERS_INCORRECT`.

## 10. Notas de implementación (Fase 6)
- `OrderCalcProfit`/`OrderCalcMargin` están detrás de `CTradeCalculator`: en producción `CTerminalCalculator` (funciones reales de MT5); en pruebas, un calculador simulado.
- Verificación cruzada: si `OrderCalcProfit` difiere en más de un 5 % del cálculo por tick value, el rechazo es **crítico** (el EA entra en modo seguro), porque indica especificación o conversión de divisa incoherentes.
- Orden de comprobaciones: inicialización → coherencia de precios → límite diario → R:R → stops level → número de posiciones / Netting → exposición existente (posición sin SL = crítico) → volumen → exposición agregada → peor caso del día → margen.
- `CDailyLossTracker`: el EA llama a `Update(hora_servidor, equity)` en cada temporizador; el bloqueo queda "enganchado" hasta el siguiente reset. El estado se persiste en `StateStore` y solo se restaura si es del mismo día.
- `StateStore`: archivo clave=valor, escritura atómica (`.tmp` + `FileMove`), suma FNV-1a; estado alterado o truncado = corrupto → modo seguro.
