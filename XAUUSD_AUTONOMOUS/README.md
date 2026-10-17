# XAUUSD Autonomous Trading System

Expert Advisor modular para MetaTrader 5 (Deriv), intradía (H1 contexto, M15 estructura, M5 ejecución). Opera **XAUUSD** (sesiones de Londres y Nueva York) y, desde 1.2.0, **índices sintéticos de Deriv**: Volatility, Step y Jump; Boom y Crash como perfil experimental. Cada instrumento usa un perfil: 24/7, sin filtro de noticias y costes relativos al ATR. Ver [Índices sintéticos](Documentation/SYNTHETIC_INDICES.md).

> **Estado: v1.2.0 — EA integrado y probado con datos sintéticos generados, con dashboard web opcional (varias instancias).** Falta la validación con datos reales de Deriv (backtest, walk-forward y demo), que requiere tu terminal y tu cuenta demo; en los índices sintéticos aún no hay ni backtest. **No se promete rentabilidad.** El trading real está deshabilitado por defecto.

## Cómo decide
1. **MarketEngine**: H1/M15/M5 con velas cerradas; EMA50/200, RSI14, ADX14, ATR14, pivotes confirmados (sin repintado), estructura, volatilidad, momentum, spread; validación de datos.
2. **RegimeEngine**: TREND_UP / TREND_DOWN / RANGE / HIGH_VOLATILITY / NO_TRADE con histéresis.
3. **Estrategias** (señales explicables con zona, invalidación, SL, TP y evidencia): **SMC** (barrido → ruptura → FVG/OB en descuento/premium → confirmación M5), **Breakout** (caja de consolidación → ruptura con cuerpo → retest/continuación), **Reversal** (CHoCH obligatorio + ≥ 3 confirmaciones).
4. **AdaptiveEngine**: puntuación 0–100 (no es probabilidad), conflictos, duplicados, umbrales 65/80.
5. **Gates**: estado, cuenta, conexión, datos, sesión (solo XAUUSD), mercado, noticias (solo XAUUSD), pérdida diaria, régimen, spread, solicitud pendiente.
6. **RiskManager**: 1 % por operación con OrderCalcProfit verificado, exposición ≤ 2 %, ≤ 3 posiciones, pérdida diaria ≤ 3 % (con peor caso), R:R ≥ 2, margen; sin martingala, grids ni promedios. Con varios gráficos y la misma magic, los límites son de toda la cartera.
7. **ExecutionManager**: OrderCheck → OrderSend; sin reintentos con resultado incierto; reconciliación con el servidor.
8. **PositionManager**: break-even 1R, trailing 1.5R, cierre por invalidación, el SL nunca se aleja; Hedging y Netting.
9. **NewsManager**: NFP/CPI/PCE/FOMC/tasas/Fed ±30 min, otros USD ±20 min; si el calendario no es verificable, no se opera.
10. **LearningEngine** (Champion) + **`Tools/challenger.py`** (Challenger offline): diario, métricas, IS/OOS/walk-forward, promoción solo con tu aprobación; nunca toca el riesgo.
11. **Dashboard web** (opcional): telemetría firmada (HMAC) hacia tu servidor y, como máximo, pausar/reanudar/modo seguro desde el navegador.

## Documentación
- [Instalación y uso](Documentation/INSTALLATION.md)
- [Arquitectura](Documentation/ARCHITECTURE.md)
- [Gestión de riesgo](Documentation/RISK_MANAGEMENT.md)
- [Estrategias](Documentation/STRATEGIES.md)
- [Índices sintéticos](Documentation/SYNTHETIC_INDICES.md)
- [Pruebas y validación](Documentation/TESTING.md)
- [Dashboard web](Documentation/WEB_DASHBOARD.md) · [instalación del servidor](WebDashboard/README.md)
- [Changelog](Documentation/CHANGELOG.md)

## Estructura
```
Experts/XAUUSD_Autonomous.mq5      EA principal
Include/XAUUSD/*.mqh               módulos
Tests/Validation/                  pruebas unitarias e integración (scripts MQL5), diagnóstico
Tests/Backtesting/                 RegimeLogger, ExportCalendar, CreateSyntheticXAU
Tests/StressTests/                 FeedTicksSmoke (prueba de humo del EA)
Tools/                             compilación/pruebas bajo Wine, regime_report.py, challenger.py
WebDashboard/                      servidor (Python estándar) e interfaz web del dashboard
Files/                             datos generados (no versionados)
```
