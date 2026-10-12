//+------------------------------------------------------------------+
//| Test_Phase5.mq5                                                  |
//| Pruebas del AdaptiveEngine: puntuación por componente (valores   |
//| calculados a mano), umbrales, conflictos, deduplicación,         |
//| setups consumidos, posiciones existentes y expiración.           |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/AdaptiveEngine.mqh>
#include "TestFramework.mqh"
#include "TestSnapshots.mqh"

void BaseSnap(MarketSnapshot &s)
  {
   BuildH1Flat(s.h1, 2400.0, 0);
   double arr[];
   ArrayResize(arr, 40);
   for(int i = 0; i < 10; i++)
     {
      arr[4 * i] = 2400; arr[4 * i + 1] = 2401; arr[4 * i + 2] = 2399; arr[4 * i + 3] = 2400;
     }
   BuildTF(s.m15, PERIOD_M15, arr, 2.0, 2, T_M15_LAST, 2400.0, 0);
   BuildM5(s.m5, 2400.0, 2400.5, 2399.5, 2400.2, 0);
   FinishSnapshot(s);
   s.m5.ema_slope = 0.2;
   s.h1.atr_ratio = 1.0;
   s.h1.rsi[0] = 50.0;
  }

TradeSignal MakeSignal(const ENUM_STRATEGY_ID st, const ENUM_DIRECTION d, const double entry, const string key)
  {
   TradeSignal g;
   ResetEvidence(g.evidence);
   g.strategy = st;
   g.direction = d;
   g.origin_tf = PERIOD_M15;
   g.entry_price = entry;
   bool lng = (d == DIR_LONG);
   g.invalidation = lng ? entry - 4.0 : entry + 4.0;
   g.sl = lng ? entry - 4.5 : entry + 4.5;
   g.tp = lng ? entry + 11.7 : entry - 11.7;   // R:R 2.6
   g.rr = 11.7 / 4.5;
   g.entry_low = entry - 0.5;
   g.entry_high = entry + 0.5;
   g.created = D'2026.01.14 12:15';
   g.expires = D'2026.01.14 12:20';
   g.signal_id = key + "-id";
   g.setup_key = key;
   g.reason = "test";
   g.evidence.sweep = true;
   g.evidence.m15_event = SE_BREAK;
   g.evidence.fvg = true;
   g.evidence.discount_premium_ok = true;
   g.evidence.m5_rejection = true;
   return g;
  }

void TestScore(CTestRunner &t)
  {
   CAdaptiveEngine ae;
   AdaptiveConfig cfg;
   AdaptiveDefaultConfig(cfg);
   t.True(ae.Init(cfg, NULL), "AdaptiveEngine Init");
   MarketSnapshot s;
   BaseSnap(s);
   RegimeState r;
   SetRegime(r, REGIME_TREND_UP);
   AdaptiveContext ctx;
   ctx.news_clear = true;
   ctx.minutes_to_session_end = 120;

   TradeSignal g = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "K1");
   ScoreBreakdown b = ae.Score(g, s, r, ctx);
   // H1 20 + M15 BREAK 12 + liq (sweep 12 + desc 4) + M5 rechazo 10 + mom 5 + vol 5 + ejec (4 + 3 + 3)
   t.EqDbl(b.h1_context, 20, 1e-9, "H1 alineado = 20");
   t.EqDbl(b.m15_structure, 12, 1e-9, "M15 BREAK = 12");
   t.EqDbl(b.liquidity, 16, 1e-9, "liquidez = barrido 12 + descuento 4");
   t.EqDbl(b.m5_confirmation, 10, 1e-9, "M5 solo rechazo = 10");
   t.EqDbl(b.momentum_volatility, 10, 1e-9, "momentum a favor 5 + volatilidad normal 5");
   t.EqDbl(b.execution, 10, 1e-9, "spread 4 + R:R 3 + sin noticias 3");
   t.EqDbl(b.total, 78, 1e-9, "total 78");
   t.EqInt(ae.Quality(b.total), QUALITY_MODERATE, "78 = moderada");
   g.evidence.m5_break = true;
   g.evidence.m15_event = SE_BOS;
   b = ae.Score(g, s, r, ctx);
   t.EqDbl(b.total, 96, 1e-9, "con BOS y ruptura M5: 96");
   t.EqInt(ae.Quality(b.total), QUALITY_HIGH, "96 = alta");
   SetRegime(r, REGIME_RANGE);
   t.EqDbl(ae.Score(g, s, r, ctx).h1_context, 10, 1e-9, "rango = 10 en contexto H1");
   SetRegime(r, REGIME_TREND_DOWN);
   t.EqDbl(ae.Score(g, s, r, ctx).h1_context, 0, 1e-9, "compra contra tendencia (no reversión) = 0");
   ctx.news_clear = false;
   SetRegime(r, REGIME_TREND_UP);
   t.EqDbl(ae.Score(g, s, r, ctx).execution, 7, 1e-9, "noticias cercanas restan 3");
   ctx.news_clear = true;
   ctx.minutes_to_session_end = 10;
   t.EqDbl(ae.Score(g, s, r, ctx).execution, 7, 1e-9, "fin de sesión cercano resta 3");
   ctx.minutes_to_session_end = 120;
   s.spread_ratio = 1.8;
   t.EqDbl(ae.Score(g, s, r, ctx).execution, 8, 1e-9, "spread 1.8x = 2 puntos");
   s.spread_ratio = 1.0;

   //--- reversión: contexto por agotamiento
   TradeSignal rv = MakeSignal(STRAT_REVERSAL, DIR_LONG, 2400.2, "RV1");
   rv.evidence.m15_event = SE_CHOCH;
   rv.evidence.rsi_divergence = true;
   SetRegime(r, REGIME_TREND_DOWN);
   r.dist_swing_low_atr = 0.5;
   s.h1.rsi[0] = 30.0;
   b = ae.Score(rv, s, r, ctx);
   t.EqDbl(b.h1_context, 20, 1e-9, "reversión: tendencia opuesta 10 + RSI H1 extremo 5 + zona H1 5");
   t.EqDbl(b.m15_structure, 20, 1e-9, "reversión: CHoCH = 20");
   t.EqDbl(b.liquidity, 16, 1e-9, "reversión: barrido 12 + divergencia 4");
   t.EqDbl(b.momentum_volatility, 5, 1e-9, "reversión sin cambio de momentum: solo volatilidad 5");
   s.m5.momentum_shift = true;
   t.EqDbl(ae.Score(rv, s, r, ctx).momentum_volatility, 10, 1e-9, "reversión con cambio de momentum: 10");

   //--- breakout
   TradeSignal bo = MakeSignal(STRAT_BREAKOUT, DIR_LONG, 2400.2, "BO1");
   ResetEvidence(bo.evidence);
   bo.evidence.consolidation = true;
   bo.evidence.m15_event = SE_BREAK;
   bo.evidence.retest = true;
   bo.evidence.volume_expansion = true;
   bo.evidence.m5_rejection = true;
   SetRegime(r, REGIME_TREND_UP);
   b = ae.Score(bo, s, r, ctx);
   t.EqDbl(b.m15_structure, 20, 1e-9, "breakout: caja + ruptura = 20");
   t.EqDbl(b.liquidity, 20, 1e-9, "breakout: retest 10 + volumen 10");
  }

void TestDecide(CTestRunner &t)
  {
   CAdaptiveEngine ae;
   AdaptiveConfig cfg;
   AdaptiveDefaultConfig(cfg);
   ae.Init(cfg, NULL);
   MarketSnapshot s;
   BaseSnap(s);
   RegimeState r;
   SetRegime(r, REGIME_TREND_UP);
   AdaptiveContext ctx;
   ctx.news_clear = true;
   ctx.minutes_to_session_end = 120;
   PositionBrief none[];
   TradeSignal sigs[];

   //--- sin señales
   TradeProposal p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && p.decision == "sin señales", "sin señales -> sin propuesta");

   //--- una señal moderada
   ArrayResize(sigs, 1);
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "A");
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(p.valid, "señal de 78 puntos se propone: " + p.decision);
   t.EqInt(p.quality, QUALITY_MODERATE, "calidad moderada");

   //--- dos compras: gana la de mayor puntuación y se anota el duplicado
   ArrayResize(sigs, 2);
   sigs[1] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.4, "B");
   sigs[1].evidence.m5_break = true;
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(p.valid && p.signal.setup_key == "B", "gana la señal de mayor puntuación");
   t.True(StringFind(p.decision, "duplica") >= 0, "se informa la oportunidad duplicada: " + p.decision);

   //--- conflicto compra/venta
   sigs[1] = MakeSignal(STRAT_REVERSAL, DIR_SHORT, 2400.2, "C");
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && StringFind(p.decision, "CONFLICTO") == 0, "compra y venta a la vez -> conflicto");

   //--- setup consumido
   ArrayResize(sigs, 1);
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "A");
   ae.MarkConsumed("A", D'2026.01.14 10:00');
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && StringFind(p.decision, "consumido") >= 0, "setup consumido se descarta");
   t.True(!ae.IsConsumed("A", D'2026.01.15 11:00'), "el bloqueo caduca a las 24 h");

   //--- posición existente en la misma zona
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "D");
   PositionBrief pos[1];
   pos[0].ticket = 1;
   pos[0].direction = DIR_LONG;
   pos[0].open_price = 2400.6;
   pos[0].setup_key = "OTRO";
   p = ae.Decide(sigs, s, r, pos, ctx);
   t.True(!p.valid && StringFind(p.decision, "misma zona") >= 0, "posición en la misma zona -> descarte");
   pos[0].open_price = 2410.0;
   p = ae.Decide(sigs, s, r, pos, ctx);
   t.True(p.valid, "posición lejos -> se permite (el RiskManager decide la exposición)");
   pos[0].setup_key = "D";
   p = ae.Decide(sigs, s, r, pos, ctx);
   t.True(!p.valid && StringFind(p.decision, "este setup") >= 0, "posición del mismo setup -> descarte");

   //--- expirada
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "E");
   sigs[0].expires = D'2026.01.14 12:10';
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && StringFind(p.decision, "expirada") >= 0, "señal expirada -> descarte");

   //--- por debajo del umbral
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "F");
   sigs[0].evidence.sweep = false;
   sigs[0].evidence.discount_premium_ok = false;
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && p.quality == QUALITY_DISCARD, "62 puntos < 65 -> descarte: " + p.decision);
   t.EqDbl(p.score.total, 62, 1e-9, "puntuación registrada aunque se descarte");

   //--- señal inválida
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "G");
   sigs[0].sl = 2401.0;
   p = ae.Decide(sigs, s, r, none, ctx);
   t.True(!p.valid && StringFind(p.decision, "inválida") >= 0, "señal que viola invariantes -> descarte");
  }

void TestConfig(CTestRunner &t)
  {
   AdaptiveConfig c;
   AdaptiveDefaultConfig(c);
   string why;
   t.True(AdaptiveValidateConfig(c, why), "config por defecto válida");
   CAdaptiveEngine ae;
   ae.Init(c, NULL);
   t.True(!ae.SetThresholds(40, 80), "rechaza umbral mínimo < 50");
   t.True(!ae.SetThresholds(70, 60), "rechaza umbral alto < mínimo");
   t.True(ae.SetThresholds(70, 85), "acepta umbrales válidos");
   t.EqDbl(ae.Config().min_score, 70, 1e-9, "umbral actualizado");
   CAdaptiveEngine not_init;
   TradeSignal sigs[];
   PositionBrief none[];
   MarketSnapshot s;
   BaseSnap(s);
   RegimeState r;
   SetRegime(r, REGIME_TREND_UP);
   AdaptiveContext ctx;
   ctx.news_clear = true;
   ctx.minutes_to_session_end = -1;
   ArrayResize(sigs, 1);
   sigs[0] = MakeSignal(STRAT_SMC, DIR_LONG, 2400.2, "H");
   t.True(!not_init.Decide(sigs, s, r, none, ctx).valid, "sin Init no propone");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase5");
   TestScore(t);
   TestDecide(t);
   TestConfig(t);
   t.Finish();
  }
