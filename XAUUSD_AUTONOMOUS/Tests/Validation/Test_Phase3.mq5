//+------------------------------------------------------------------+
//| Test_Phase3.mq5                                                  |
//| Pruebas unitarias de RegimeEngine con instantáneas construidas   |
//| a mano (sin bróker ni historial).                                |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/RegimeEngine.mqh>
#include "TestFramework.mqh"

void SetTF(TFData &d, const ENUM_TIMEFRAMES tf, const double close, const double ema_f, const double ema_s,
           const double adx, const double pdi, const double mdi, const double atr, const double atr_ratio,
           const double slope, const ENUM_MARKET_STRUCTURE st)
  {
   d.tf = tf;
   d.valid = true;
   d.invalid_reason = "";
   d.bars = 1;
   ArrayResize(d.rates, 1);
   d.rates[0].time = D'2026.01.14 12:00';
   d.rates[0].open = close;
   d.rates[0].high = close + 1.0;
   d.rates[0].low = close - 1.0;
   d.rates[0].close = close;
   ArrayResize(d.ema_fast, 1);  d.ema_fast[0] = ema_f;
   ArrayResize(d.ema_slow, 1);  d.ema_slow[0] = ema_s;
   ArrayResize(d.rsi, 1);       d.rsi[0] = 50.0;
   ArrayResize(d.adx, 1);       d.adx[0] = adx;
   ArrayResize(d.plus_di, 1);   d.plus_di[0] = pdi;
   ArrayResize(d.minus_di, 1);  d.minus_di[0] = mdi;
   ArrayResize(d.atr, 1);       d.atr[0] = atr;
   d.atr_ratio = atr_ratio;
   d.ema_slope = slope;
   d.ema_slope_prev = slope;
   d.momentum_shift = false;
   d.structure = st;
   d.swing_count = 0;
   ArrayResize(d.swings, 0);
  }

//--- añade un pivote al final (los primeros añadidos son los más recientes)
void AddSwing(TFData &d, const bool is_high, const double price)
  {
   int n = d.swing_count;
   ArrayResize(d.swings, n + 1);
   d.swings[n].is_high = is_high;
   d.swings[n].price = price;
   d.swings[n].bar_index = 10 + n;
   d.swings[n].time = d.rates[0].time - (n + 1) * 900;
   d.swing_count = n + 1;
  }

void BaseSnapshot(MarketSnapshot &s, const double m5_close)
  {
   s.valid = true;
   s.invalid_reason = "";
   s.symbol = "XAUUSD";
   s.server_time = D'2026.01.14 12:05';
   s.spread_points = 20;
   s.spread_avg_points = 20;
   s.spread_ratio = 1.0;
   SetTF(s.m15, PERIOD_M15, m5_close, m5_close, m5_close, 20, 20, 20, 2.0, 1.0, 0.0, STRUCTURE_MIXED);
   SetTF(s.m5, PERIOD_M5, m5_close, m5_close, m5_close, 20, 20, 20, 1.0, 1.0, 0.0, STRUCTURE_MIXED);
  }

void TrendUpSnapshot(MarketSnapshot &s)
  {
   BaseSnapshot(s, 2410.0);
   SetTF(s.h1, PERIOD_H1, 2410.0, 2400.0, 2380.0, 30.0, 30.0, 15.0, 5.0, 1.0, 0.5, STRUCTURE_BULLISH);
   AddSwing(s.h1, true, 2420.0);
   AddSwing(s.h1, false, 2395.0);
  }

void TrendDownSnapshot(MarketSnapshot &s)
  {
   BaseSnapshot(s, 2370.0);
   SetTF(s.h1, PERIOD_H1, 2370.0, 2380.0, 2400.0, 30.0, 12.0, 28.0, 5.0, 1.0, -0.5, STRUCTURE_BEARISH);
  }

void RangeSnapshot(MarketSnapshot &s)
  {
   BaseSnapshot(s, 2400.0);
   SetTF(s.h1, PERIOD_H1, 2400.0, 2400.0, 2399.0, 15.0, 18.0, 17.0, 5.0, 1.0, 0.1, STRUCTURE_MIXED);
   SetTF(s.m15, PERIOD_M15, 2400.0, 2400.0, 2400.0, 15.0, 18.0, 17.0, 3.0, 1.0, 0.0, STRUCTURE_MIXED);
   AddSwing(s.m15, true, 2410.0);    // más reciente
   AddSwing(s.m15, false, 2390.0);
   AddSwing(s.m15, true, 2412.0);
  }

void TestClassify(CTestRunner &t)
  {
   RegimeConfig c;
   RegimeDefaultConfig(c);
   RegimeState st;
   MarketSnapshot s;

   TrendUpSnapshot(s);
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_TREND_UP, "tendencia alcista alineada: " + st.reason);
   t.EqDbl(st.dist_swing_high_atr, 2.0, 1e-9, "distancia a pivote alto H1 = (2420-2410)/5");
   t.EqDbl(st.dist_swing_low_atr, 3.0, 1e-9, "distancia a pivote bajo H1 = (2410-2395)/5");

   TrendDownSnapshot(s);
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_TREND_DOWN, "tendencia bajista alineada: " + st.reason);
   t.EqDbl(st.dist_swing_high_atr, -1.0, 1e-9, "sin pivotes H1 -> distancia -1");

   //--- cada condición de tendencia, rota por separado
   TrendUpSnapshot(s); s.h1.structure = STRUCTURE_MIXED;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "alcista sin estructura -> NO_TRADE");
   t.True(StringFind(st.reason, "estructura") >= 0, "motivo menciona la estructura");
   RegimeConfig c2 = c; c2.require_h1_structure = false;
   t.EqInt(CRegimeEngine::Classify(s, c2, st), REGIME_TREND_UP, "sin exigir estructura -> TREND_UP");
   TrendUpSnapshot(s); s.h1.plus_di[0] = 10.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "+DI <= -DI -> NO_TRADE");
   TrendUpSnapshot(s); s.h1.ema_slope = 0.01;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "pendiente insuficiente -> NO_TRADE");
   TrendUpSnapshot(s); s.h1.rates[0].close = 2395.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "cierre bajo EMA rápida -> NO_TRADE");
   TrendDownSnapshot(s); s.h1.structure = STRUCTURE_BULLISH;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "bajista con estructura alcista -> NO_TRADE");

   //--- límites exactos de ADX
   TrendUpSnapshot(s); s.h1.adx[0] = 22.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_TREND_UP, "ADX = umbral de tendencia (22) -> tendencia");
   TrendUpSnapshot(s); s.h1.adx[0] = 21.9;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "ADX 21.9 (zona neutral) -> NO_TRADE");
   t.True(StringFind(st.reason, "neutral") >= 0, "motivo zona neutral");

   //--- volatilidad
   TrendUpSnapshot(s); s.h1.atr_ratio = 1.8;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_HIGH_VOLATILITY, "atrR H1 = 1.8 -> HIGH_VOLATILITY (prioridad sobre tendencia)");
   TrendUpSnapshot(s); s.m15.atr_ratio = 2.3;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_HIGH_VOLATILITY, "atrR M15 = 2.3 -> HIGH_VOLATILITY");
   TrendUpSnapshot(s); s.h1.atr_ratio = 0.4;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "volatilidad muy baja -> NO_TRADE");

   //--- spread y datos
   TrendUpSnapshot(s); s.spread_ratio = 3.5;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "spread 3.5x -> NO_TRADE");
   TrendUpSnapshot(s); s.spread_ratio = 0.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_TREND_UP, "sin referencia de spread no bloquea régimen");
   TrendUpSnapshot(s); s.valid = false; s.invalid_reason = "prueba";
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "snapshot inválido -> NO_TRADE");
   TrendUpSnapshot(s); s.m15.valid = false;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "M15 inválido -> NO_TRADE");

   //--- rango
   RangeSnapshot(s);
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_RANGE, "rango válido: " + st.reason);
   t.EqDbl(st.range_high, 2410.0, 1e-9, "techo del rango = pivote alto M15 más reciente");
   t.EqDbl(st.range_low, 2390.0, 1e-9, "suelo del rango = pivote bajo M15 más reciente");
   RangeSnapshot(s); s.m5.rates[0].close = 2411.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "precio fuera del rango -> NO_TRADE");
   RangeSnapshot(s); s.m15.atr[0] = 15.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "rango demasiado estrecho en ATR -> NO_TRADE");
   RangeSnapshot(s); s.m15.atr[0] = 1.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "rango demasiado ancho en ATR -> NO_TRADE");
   RangeSnapshot(s); s.h1.ema_slope = 0.5;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "ADX bajo con pendiente fuerte -> NO_TRADE");
   RangeSnapshot(s); s.m15.swing_count = 1;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_NO_TRADE, "sin pivote bajo M15 -> NO_TRADE");
   RangeSnapshot(s); s.h1.adx[0] = 18.0;
   t.EqInt(CRegimeEngine::Classify(s, c, st), REGIME_RANGE, "ADX = umbral de rango (18) -> rango");
  }

void TestHysteresis(CTestRunner &t)
  {
   RegimeConfig c;
   RegimeDefaultConfig(c);
   CRegimeEngine re;
   t.True(re.Init(c, NULL), "RegimeEngine Init");
   RegimeState st;
   MarketSnapshot up, hv, rg;
   TrendUpSnapshot(up);
   TrendUpSnapshot(hv); hv.h1.atr_ratio = 2.0;
   RangeSnapshot(rg);

   t.EqInt(re.Current(), REGIME_NO_TRADE, "régimen inicial NO_TRADE");
   t.EqInt(re.Evaluate(up, st), REGIME_NO_TRADE, "1.ª evaluación alcista: aún NO_TRADE (pendiente de confirmar)");
   t.EqInt(st.raw_regime, REGIME_TREND_UP, "raw = TREND_UP");
   t.EqInt(re.Evaluate(up, st), REGIME_TREND_UP, "2.ª evaluación alcista: TREND_UP confirmado");
   t.EqInt(st.evaluations_in_regime, 1, "contador reiniciado al cambiar");
   t.EqInt(re.Evaluate(up, st), REGIME_TREND_UP, "se mantiene TREND_UP");
   t.EqInt(st.evaluations_in_regime, 2, "contador incrementa");
   t.EqInt(re.Evaluate(rg, st), REGIME_TREND_UP, "1 lectura de rango no cambia el régimen");
   t.EqInt(re.Evaluate(up, st), REGIME_TREND_UP, "vuelve alcista: sigue TREND_UP");
   t.EqInt(re.Evaluate(rg, st), REGIME_TREND_UP, "rango (1) tras interrupción: no confirma");
   t.EqInt(re.Evaluate(rg, st), REGIME_RANGE, "rango (2) consecutivo: RANGE");
   t.EqInt(re.Evaluate(hv, st), REGIME_HIGH_VOLATILITY, "alta volatilidad: cambio inmediato");
   t.EqInt(re.Evaluate(up, st), REGIME_HIGH_VOLATILITY, "salir de alta volatilidad requiere confirmación");
   t.EqInt(re.Evaluate(up, st), REGIME_TREND_UP, "confirmado TREND_UP tras alta volatilidad");
   MarketSnapshot bad;
   TrendUpSnapshot(bad); bad.valid = false; bad.invalid_reason = "sin datos";
   t.EqInt(re.Evaluate(bad, st), REGIME_NO_TRADE, "datos inválidos: NO_TRADE inmediato");

   RegimeConfig c1 = c; c1.confirm_evaluations = 1;
   CRegimeEngine re1;
   re1.Init(c1, NULL);
   t.EqInt(re1.Evaluate(up, st), REGIME_TREND_UP, "confirm_evaluations=1: cambio inmediato");

   CRegimeEngine not_init;
   t.EqInt(not_init.Evaluate(up, st), REGIME_NO_TRADE, "sin Init: NO_TRADE");
  }

void TestConfig(CTestRunner &t)
  {
   RegimeConfig c;
   RegimeDefaultConfig(c);
   string reason;
   t.True(RegimeValidateConfig(c, reason), "config por defecto válida");
   RegimeConfig b = c; b.range_adx_max = 25.0;
   t.True(!RegimeValidateConfig(b, reason), "rechaza umbral de rango >= tendencia");
   b = c; b.high_vol_h1_atr_ratio = 0.9;
   t.True(!RegimeValidateConfig(b, reason), "rechaza alta volatilidad <= 1");
   b = c; b.low_vol_atr_ratio = 1.2;
   t.True(!RegimeValidateConfig(b, reason), "rechaza baja volatilidad >= 1");
   b = c; b.range_max_width_atr = 1.0;
   t.True(!RegimeValidateConfig(b, reason), "rechaza ancho máximo <= mínimo");
   b = c; b.confirm_evaluations = 0;
   t.True(!RegimeValidateConfig(b, reason), "rechaza confirm_evaluations = 0");
   CRegimeEngine re;
   t.True(!re.Init(b, NULL), "Init rechaza config inválida");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase3");
   TestClassify(t);
   TestHysteresis(t);
   TestConfig(t);
   t.Finish();
  }
