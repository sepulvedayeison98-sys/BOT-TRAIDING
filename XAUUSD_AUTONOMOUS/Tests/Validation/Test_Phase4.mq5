//+------------------------------------------------------------------+
//| Test_Phase4.mq5                                                  |
//| Pruebas de PatternLib y de las estrategias SMC, Breakout y       |
//| Reversal con escenarios construidos vela a vela. Los valores     |
//| esperados (SL, TP, niveles) se calcularon a mano a partir de las |
//| reglas documentadas. Cada escenario se prueba también en espejo  |
//| (precio reflejado) para verificar la simetría compra/venta.      |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/PatternLib.mqh>
#include <XAUUSD/StrategySMC.mqh>
#include <XAUUSD/StrategyBreakout.mqh>
#include <XAUUSD/StrategyReversal.mqh>
#include "TestFramework.mqh"

#define T_M15_LAST D'2026.01.14 12:00'
#define T_M5_LAST  D'2026.01.14 12:10'

//--- construye un TFData a partir de OHLC cronológicos (aplanados o,h,l,c).
//--- mirror_k > 0 refleja precios: p -> k - p (y RSI -> 100 - RSI).
void BuildTF(TFData &d, const ENUM_TIMEFRAMES tf, const double &ohlc[], const double atr, const int pivot_n,
             const datetime last_time, const double ema, const double mirror_k)
  {
   int n = ArraySize(ohlc) / 4;
   d.tf = tf;
   d.valid = true;
   d.invalid_reason = "";
   d.bars = n;
   ArrayResize(d.rates, n);
   ArrayResize(d.ema_fast, n);
   ArrayResize(d.ema_slow, n);
   ArrayResize(d.rsi, n);
   ArrayResize(d.adx, n);
   ArrayResize(d.plus_di, n);
   ArrayResize(d.minus_di, n);
   ArrayResize(d.atr, n);
   for(int c = 0; c < n; c++)
     {
      int i = n - 1 - c;   // índice serie
      double o = ohlc[4 * c], h = ohlc[4 * c + 1], l = ohlc[4 * c + 2], cl = ohlc[4 * c + 3];
      if(mirror_k > 0)
        {
         double mo = mirror_k - o, mh = mirror_k - l, ml = mirror_k - h, mc = mirror_k - cl;
         o = mo; h = mh; l = ml; cl = mc;
        }
      d.rates[i].time = last_time - (datetime)(i * PeriodSeconds(tf));
      d.rates[i].open = o;
      d.rates[i].high = h;
      d.rates[i].low = l;
      d.rates[i].close = cl;
      d.rates[i].tick_volume = 100;
      d.rates[i].real_volume = 0;
      d.rates[i].spread = 20;
      d.ema_fast[i] = (mirror_k > 0) ? mirror_k - ema : ema;
      d.ema_slow[i] = d.ema_fast[i];
      d.rsi[i] = 50.0;
      d.adx[i] = 25.0;
      d.plus_di[i] = 20.0;
      d.minus_di[i] = 20.0;
      d.atr[i] = atr;
     }
   d.swing_count = CMarketAlgo::FindSwings(d.rates, n, pivot_n, 30, d.swings);
   d.structure = CMarketAlgo::ClassifyStructure(d.swings, d.swing_count);
   d.last_closed_time = d.rates[0].time;
   d.atr_ratio = 1.0;
   d.ema_slope = 0.0;
   d.ema_slope_prev = 0.0;
   d.momentum_shift = false;
   CMarketAlgo::RangeOf(d.rates, n, d.range_high, d.range_low);
  }

//--- M5: 6 velas planas (sin pivotes) + la vela de confirmación
void BuildM5(TFData &d, const double o, const double h, const double l, const double c, const double mirror_k)
  {
   double flat = (o + c) / 2.0;
   double arr[];
   ArrayResize(arr, 28);
   for(int i = 0; i < 6; i++)
     {
      arr[4 * i] = flat; arr[4 * i + 1] = flat + 0.5; arr[4 * i + 2] = flat - 0.5; arr[4 * i + 3] = flat;
     }
   arr[24] = o; arr[25] = h; arr[26] = l; arr[27] = c;
   BuildTF(d, PERIOD_M5, arr, 1.0, 3, T_M5_LAST, flat, mirror_k);
  }

void BuildH1Flat(TFData &d, const double price, const double mirror_k)
  {
   double arr[];
   ArrayResize(arr, 40);
   for(int i = 0; i < 10; i++)
     {
      arr[4 * i] = price; arr[4 * i + 1] = price + 1; arr[4 * i + 2] = price - 1; arr[4 * i + 3] = price;
     }
   BuildTF(d, PERIOD_H1, arr, 5.0, 2, D'2026.01.14 11:00', price, mirror_k);
  }

void FinishSnapshot(MarketSnapshot &s)
  {
   s.valid = true;
   s.invalid_reason = "";
   s.symbol = "TEST";
   s.server_time = D'2026.01.14 12:15:30';
   s.utc_time = s.server_time;
   s.digits = 2;
   s.point = 0.01;
   s.bid = s.m5.rates[0].close;
   s.ask = s.bid + 0.2;
   s.spread_points = 20;
   s.spread_avg_points = 20;
   s.spread_ratio = 1.0;
  }

void SetRegime(RegimeState &r, const ENUM_REGIME reg)
  {
   r.regime = reg;
   r.raw_regime = reg;
   r.reason = "test";
  }

StrategyCommonConfig TestCommon(void)
  {
   StrategyCommonConfig c;
   StrategyCommonDefaultConfig(c);
   c.pivot_n_m15 = 2;
   c.pivot_n_m5 = 3;
   return c;
  }

int FindDir(const TradeSignal &arr[], const ENUM_DIRECTION d)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i].direction == d)
         return i;
   return -1;
  }

//==================================================================
// Escenario SMC (compra). Ver cálculo de valores esperados en los comentarios.
//==================================================================
double SMC_M15[] =
  {
   2410, 2411, 2408, 2409,
   2409, 2410, 2406, 2407,
   2407, 2408, 2404, 2405,
   2405, 2406, 2400, 2401,      // pivote bajo 2400
   2401, 2404, 2401, 2403,
   2403, 2407, 2402, 2406,      // pivote alto 2407
   2406, 2406.5, 2403, 2404,
   2404, 2405, 2402, 2403,
   2403, 2403.5, 2398.8, 2401.5, // barrido de 2400 (mecha 2398.8) - vela bajista = OB
   2401.5, 2405, 2401.2, 2404.8, // desplazamiento
   2405.2, 2409, 2404.6, 2408.5, // cierre > 2407: ruptura. FVG [2403.5, 2404.6]
   2408.5, 2411, 2406, 2407,
   2407, 2407.5, 2405, 2405.5
  };

void BuildSMC(MarketSnapshot &s, const double k, const bool m5_touch)
  {
   BuildTF(s.m15, PERIOD_M15, SMC_M15, 2.5, 2, T_M15_LAST, 2405.0, k);
   if(m5_touch)
      BuildM5(s.m5, 2405.0, 2405.6, 2403.9, 2405.4, k);   // rechazo alcista dentro del FVG
   else
      BuildM5(s.m5, 2405.6, 2406.2, 2405.2, 2406.0, k);   // no toca la zona
   BuildH1Flat(s.h1, 2405.0, k);
   FinishSnapshot(s);
  }

void TestSMC(CTestRunner &t)
  {
   CStrategySMC smc;
   SMCConfig cfg;
   SMCDefaultConfig(cfg);
   t.True(smc.Init(TestCommon(), cfg, NULL), "SMC Init");
   MarketSnapshot s;
   RegimeState r;
   TradeSignal out[];

   //--- piezas individuales
   BuildSMC(s, 0, true);
   SweepInfo sw;
   t.True(CPatterns::FindSweep(s.m15, false, 16, 2, 0.05, sw), "barrido de mínimo detectado");
   t.EqInt(sw.bar, 4, "barrido en índice 4");
   t.EqDbl(sw.level, 2400.0, 1e-9, "nivel barrido 2400");
   t.EqDbl(sw.wick, 2398.8, 1e-9, "mecha del barrido 2398.8");
   BreakInfo br;
   t.True(CPatterns::FindBreak(s.m15, DIR_LONG, 0, 3, 2, br), "ruptura alcista tras el barrido");
   t.EqInt(br.bar, 2, "ruptura en índice 2");
   t.EqDbl(br.level, 2407.0, 1e-9, "nivel roto 2407");
   ZoneInfo z;
   t.True(CPatterns::FindFVG(s.m15, DIR_LONG, 1, 2, 0.1, z), "FVG alcista");
   t.EqDbl(z.bottom, 2403.5, 1e-9, "FVG inferior 2403.5 (el FVG en índice 1 está relleno)");
   t.EqDbl(z.top, 2404.6, 1e-9, "FVG superior 2404.6");
   ZoneInfo ob;
   t.True(CPatterns::FindOrderBlock(s.m15, DIR_LONG, 2, 2, ob), "Order Block alcista");
   t.EqInt(ob.bar, 4, "OB = vela bajista del barrido");

   //--- señal completa
   SetRegime(r, REGIME_TREND_UP);
   ArrayResize(out, 0);
   t.EqInt(smc.Evaluate(s, r, out), 1, "SMC produce 1 señal: " + smc.LastRejection());
   int i = FindDir(out, DIR_LONG);
   if(t.True(i >= 0, "señal de compra"))
     {
      string why;
      t.True(CStrategyBase::ValidateSignal(out[i], why), "invariantes de la señal: " + why);
      t.EqDbl(out[i].entry_price, 2405.4, 1e-9, "entrada = cierre M5");
      t.EqDbl(out[i].invalidation, 2398.8, 1e-9, "invalidación = mecha del barrido");
      t.EqDbl(out[i].sl, 2398.3, 1e-6, "SL = 2398.8 - 0.2 x ATR 2.5");
      t.EqDbl(out[i].tp, 2411.0, 1e-9, "TP = máximo del tramo 2411");
      t.EqDbl(out[i].rr, 5.6 / 7.1, 1e-6, "R:R calculado");
      t.True(out[i].evidence.sweep && out[i].evidence.fvg && out[i].evidence.order_block, "evidencia: barrido + FVG + OB");
      t.True(out[i].evidence.discount_premium_ok, "evidencia: descuento");
      t.True(out[i].evidence.m5_rejection, "evidencia: rechazo M5");
      t.EqInt(out[i].evidence.m15_event, SE_BREAK, "estructura previa desconocida -> BREAK");
      t.True(StringFind(out[i].setup_key, "SMC|LONG|") == 0, "clave de setup");
      t.Note(CStrategyBase::Describe(out[i]));
     }

   //--- espejo: venta con valores reflejados (k = 4800)
   BuildSMC(s, 4800, true);
   SetRegime(r, REGIME_TREND_DOWN);
   ArrayResize(out, 0);
   t.EqInt(smc.Evaluate(s, r, out), 1, "SMC espejo produce 1 señal: " + smc.LastRejection());
   i = FindDir(out, DIR_SHORT);
   if(t.True(i >= 0, "señal de venta en espejo"))
     {
      t.EqDbl(out[i].sl, 4800 - 2398.3, 1e-6, "SL espejo");
      t.EqDbl(out[i].tp, 4800 - 2411.0, 1e-6, "TP espejo");
      t.EqDbl(out[i].entry_price, 4800 - 2405.4, 1e-6, "entrada espejo");
     }

   //--- negativos
   BuildSMC(s, 0, true);
   SetRegime(r, REGIME_TREND_DOWN);
   ArrayResize(out, 0);
   t.EqInt(smc.Evaluate(s, r, out), 0, "SMC sin compra en TREND_DOWN");
   SetRegime(r, REGIME_HIGH_VOLATILITY);
   t.EqInt(smc.Evaluate(s, r, out), 0, "SMC sin señales en HIGH_VOLATILITY");
   SetRegime(r, REGIME_NO_TRADE);
   t.EqInt(smc.Evaluate(s, r, out), 0, "SMC sin señales en NO_TRADE");
   SetRegime(r, REGIME_TREND_UP);
   BuildSMC(s, 0, false);
   t.EqInt(smc.Evaluate(s, r, out), 0, "SMC sin señal si M5 no toca la zona");
   t.True(StringFind(smc.LastRejection(), "zona") >= 0, "motivo menciona la zona: " + smc.LastRejection());
   //--- FVG rellenado: la zona pasa a ser el OB [2398.8, 2403.5] y M5 no lo toca
   BuildSMC(s, 0, true);
   s.m15.rates[0].low = 2403.0;
   ArrayResize(out, 0);
   t.EqInt(smc.Evaluate(s, r, out), 0, "FVG rellenado -> usa OB, M5 fuera del OB -> sin señal");
   t.True(StringFind(smc.LastRejection(), "2398.80") >= 0, "motivo cita la zona del OB: " + smc.LastRejection());
   //--- snapshot inválido
   BuildSMC(s, 0, true);
   s.valid = false;
   t.EqInt(smc.Evaluate(s, r, out), 0, "snapshot inválido -> sin señal");
  }

//==================================================================
// Escenario Breakout (compra). Caja [2398, 2402], ruptura en índice 3.
//==================================================================
double BO_M15[] =
  {
   2400, 2402, 2398.5, 2401,
   2401, 2401.8, 2398, 2399,
   2399, 2401.5, 2398.4, 2401,
   2401, 2402, 2399, 2399.5,
   2399.5, 2401, 2398.2, 2400.5,
   2400.5, 2401.9, 2399.5, 2401.5,
   2401.5, 2406, 2401.2, 2405.6,   // ruptura
   2405.6, 2407, 2404.5, 2406.5,
   2406.5, 2407.5, 2405, 2406,
   2406, 2406.5, 2403.5, 2404
  };

void BuildBO(MarketSnapshot &s, const double k, const bool retest)
  {
   BuildTF(s.m15, PERIOD_M15, BO_M15, 2.0, 2, T_M15_LAST, 2402.0, k);
   s.m15.rates[3].tick_volume = 200;   // volumen de la vela de ruptura
   if(retest)
      BuildM5(s.m5, 2402.6, 2403.8, 2402.3, 2403.6, k);
   else
      BuildM5(s.m5, 2404.2, 2404.8, 2404.0, 2404.5, k);
   BuildH1Flat(s.h1, 2402.0, k);
   FinishSnapshot(s);
  }

void TestBreakout(CTestRunner &t)
  {
   CStrategyBreakout bo;
   BreakoutConfig cfg;
   BreakoutDefaultConfig(cfg);
   cfg.box_bars = 6;
   t.True(bo.Init(TestCommon(), cfg, NULL), "Breakout Init");
   MarketSnapshot s;
   RegimeState r;
   TradeSignal out[];

   BuildBO(s, 0, true);
   BoxInfo box;
   t.True(CPatterns::FindBoxBreakout(s.m15, DIR_LONG, 8, 6, 3.0, 0.1, 0.6, 1.2, box), "caja + ruptura detectadas");
   t.EqInt(box.break_bar, 3, "ruptura en índice 3");
   t.EqDbl(box.top, 2402.0, 1e-9, "techo de la caja");
   t.EqDbl(box.bottom, 2398.0, 1e-9, "suelo de la caja");
   t.True(box.volume_available && box.volume_expansion, "expansión de volumen 200 vs 100");

   SetRegime(r, REGIME_TREND_UP);
   ArrayResize(out, 0);
   t.EqInt(bo.Evaluate(s, r, out), 1, "Breakout produce 1 señal: " + bo.LastRejection());
   int i = FindDir(out, DIR_LONG);
   if(t.True(i >= 0, "señal de compra"))
     {
      string why;
      t.True(CStrategyBase::ValidateSignal(out[i], why), "invariantes: " + why);
      t.EqDbl(out[i].entry_price, 2403.6, 1e-9, "entrada = cierre M5");
      t.EqDbl(out[i].invalidation, 2400.0, 1e-9, "invalidación = mitad de la caja");
      t.EqDbl(out[i].sl, 2399.6, 1e-6, "SL = 2400 - 0.2 x ATR 2");
      t.EqDbl(out[i].tp, 2406.0, 1e-9, "TP = proyección de la caja 2402 + 4");
      t.True(out[i].evidence.retest, "entrada por retest");
      t.True(out[i].evidence.consolidation && out[i].evidence.volume_expansion, "evidencia caja + volumen");
      t.Note(CStrategyBase::Describe(out[i]));
     }
   //--- espejo
   BuildBO(s, 4800, true);
   SetRegime(r, REGIME_TREND_DOWN);
   ArrayResize(out, 0);
   t.EqInt(bo.Evaluate(s, r, out), 1, "Breakout espejo: " + bo.LastRejection());
   i = FindDir(out, DIR_SHORT);
   if(t.True(i >= 0, "señal de venta en espejo"))
     {
      t.EqDbl(out[i].sl, 4800 - 2399.6, 1e-6, "SL espejo");
      t.EqDbl(out[i].tp, 4800 - 2406.0, 1e-6, "TP espejo");
     }
   //--- negativos
   SetRegime(r, REGIME_TREND_UP);
   BuildBO(s, 0, false);
   ArrayResize(out, 0);
   t.EqInt(bo.Evaluate(s, r, out), 0, "sin retest ni ruptura M5 -> sin señal");
   BuildBO(s, 0, true);
   s.m15.rates[0].close = 2401.5;   // falsa ruptura: cierre de vuelta en la caja
   s.m15.rates[0].low = 2401.0;
   t.EqInt(bo.Evaluate(s, r, out), 0, "falsa ruptura -> sin señal");
   BuildBO(s, 0, true);
   BreakoutConfig cv = cfg;
   cv.require_volume = true;
   CStrategyBreakout bov;
   bov.Init(TestCommon(), cv, NULL);
   s.m15.rates[3].tick_volume = 100;
   t.EqInt(bov.Evaluate(s, r, out), 0, "volumen obligatorio sin expansión -> sin señal");
   SetRegime(r, REGIME_TREND_DOWN);
   BuildBO(s, 0, true);
   t.EqInt(bo.Evaluate(s, r, out), 0, "compra en TREND_DOWN -> sin señal");
  }

//==================================================================
// Escenario Reversal (compra contra tendencia bajista).
//==================================================================
double RV_M15[] =
  {
   2438, 2440, 2436, 2437,
   2437, 2438, 2433, 2434,
   2434, 2442, 2434, 2439,      // pivote alto 2442
   2439, 2439, 2432, 2433,
   2433, 2436, 2429, 2430,
   2430, 2433, 2425, 2427,      // pivote bajo 2425
   2427, 2434, 2426.5, 2433,
   2433, 2437, 2430, 2431,      // pivote alto 2437 (LH)
   2431, 2433, 2426, 2427,
   2427, 2430, 2422, 2428,      // pivote bajo 2422
   2428, 2429, 2424, 2425,
   2425, 2431, 2424.5, 2429,    // pivote alto 2431 (LH)
   2429, 2429.5, 2423, 2424,
   2424, 2425, 2415, 2423.5,    // barrido de 2422, mecha 2415, rechazo (pivote bajo LL)
   2423.5, 2427, 2421, 2426.5,
   2426.5, 2433, 2425, 2432.5   // CHoCH: cierre > 2431
  };

void BuildRV(MarketSnapshot &s, const double k, const bool with_div)
  {
   BuildTF(s.m15, PERIOD_M15, RV_M15, 5.0, 2, T_M15_LAST, 2430.0, k);
   if(with_div)
     {
      s.m15.rsi[2] = (k > 0) ? 100 - 35 : 35;   // RSI en el mínimo nuevo (2415)
      s.m15.rsi[6] = (k > 0) ? 100 - 28 : 28;   // RSI en el mínimo previo (2422)
     }
   BuildM5(s.m5, 2432.2, 2433.0, 2430.9, 2432.9, k);
   BuildH1Flat(s.h1, 2430.0, k);
   FinishSnapshot(s);
  }

void TestReversal(CTestRunner &t)
  {
   CStrategyReversal rv;
   ReversalConfig cfg;
   ReversalDefaultConfig(cfg);
   t.True(rv.Init(TestCommon(), cfg, NULL), "Reversal Init");
   MarketSnapshot s;
   RegimeState r;
   TradeSignal out[];

   BuildRV(s, 0, true);
   t.EqInt(s.m15.structure, STRUCTURE_BEARISH, "estructura M15 bajista (LH + LL)");
   BreakInfo ch;
   t.True(CPatterns::FindBreak(s.m15, DIR_LONG, 0, 16, 2, ch), "ruptura alcista");
   t.EqInt(ch.type, SE_CHOCH, "contra estructura bajista = CHoCH");
   t.EqDbl(ch.level, 2431.0, 1e-9, "nivel del CHoCH 2431");
   DivergenceInfo dv;
   t.True(CPatterns::FindRsiDivergence(s.m15, DIR_LONG, 3.0, 12, dv), "divergencia alcista RSI");
   t.True(CPatterns::IsRejection(s.m15.rates[2], DIR_LONG, 0.6), "vela de rechazo en el extremo");

   SetRegime(r, REGIME_TREND_DOWN);
   ArrayResize(out, 0);
   t.EqInt(rv.Evaluate(s, r, out), 1, "Reversal produce 1 señal: " + rv.LastRejection());
   int i = FindDir(out, DIR_LONG);
   if(t.True(i >= 0, "señal de compra"))
     {
      string why;
      t.True(CStrategyBase::ValidateSignal(out[i], why), "invariantes: " + why);
      t.EqInt(out[i].evidence.confirmations, 5, "5/5 confirmaciones");
      t.EqDbl(out[i].invalidation, 2415.0, 1e-9, "invalidación = extremo del tramo");
      t.EqDbl(out[i].sl, 2414.0, 1e-6, "SL = 2415 - 0.2 x ATR 5");
      t.EqDbl(out[i].tp, 2442.0, 1e-9, "TP = pivote alto 2442");
      t.Note(CStrategyBase::Describe(out[i]));
     }
   //--- espejo
   BuildRV(s, 4860, true);
   SetRegime(r, REGIME_TREND_UP);
   ArrayResize(out, 0);
   t.EqInt(rv.Evaluate(s, r, out), 1, "Reversal espejo: " + rv.LastRejection());
   i = FindDir(out, DIR_SHORT);
   if(t.True(i >= 0, "señal de venta en espejo"))
     {
      t.EqDbl(out[i].sl, 4860 - 2414.0, 1e-6, "SL espejo");
      t.EqDbl(out[i].tp, 4860 - 2442.0, 1e-6, "TP espejo");
     }
   //--- sin divergencia: 4/5 sigue siendo suficiente con min 3; con min 5 no
   BuildRV(s, 0, false);
   SetRegime(r, REGIME_TREND_DOWN);
   ArrayResize(out, 0);
   t.EqInt(rv.Evaluate(s, r, out), 1, "sin divergencia: 4 confirmaciones bastan con mínimo 3");
   ReversalConfig c5 = cfg;
   c5.min_confirmations = 5;
   CStrategyReversal rv5;
   rv5.Init(TestCommon(), c5, NULL);
   t.EqInt(rv5.Evaluate(s, r, out), 0, "con mínimo 5 y sin divergencia -> sin señal");
   t.True(StringFind(rv5.LastRejection(), "confirmaciones 4") >= 0, "motivo cuenta confirmaciones: " + rv5.LastRejection());
   //--- CHoCH obligatorio: si la estructura no es bajista la ruptura no es CHoCH
   BuildRV(s, 0, true);
   s.m15.structure = STRUCTURE_MIXED;
   t.EqInt(rv.Evaluate(s, r, out), 0, "sin CHoCH (estructura mixta) -> sin señal");
   //--- régimen
   BuildRV(s, 0, true);
   SetRegime(r, REGIME_TREND_UP);
   t.EqInt(rv.Evaluate(s, r, out), 0, "compra de reversión en TREND_UP -> sin señal");
   //--- precio M5 de vuelta bajo el CHoCH
   BuildRV(s, 0, true);
   SetRegime(r, REGIME_TREND_DOWN);
   s.m5.rates[0].close = 2430.5;
   t.EqInt(rv.Evaluate(s, r, out), 0, "M5 bajo el nivel del CHoCH -> sin señal");
  }

//==================================================================
// Primitivas y configuración
//==================================================================
void TestPrimitives(CTestRunner &t)
  {
   MqlRates r;
   r.open = 10; r.high = 10.5; r.low = 7; r.close = 10.2;
   t.True(CPatterns::IsRejection(r, DIR_LONG, 0.6), "martillo = rechazo alcista");
   t.True(!CPatterns::IsRejection(r, DIR_SHORT, 0.6), "martillo no es rechazo bajista");
   r.high = r.low;
   t.True(!CPatterns::IsRejection(r, DIR_LONG, 0.6), "vela sin rango no es rechazo");

   //--- rango asiático: velas M15 de 06:00 a 08:00 UTC
   double arr[];
   ArrayResize(arr, 9 * 4);
   for(int i = 0; i < 9; i++)
     {
      double p = 100 + i;
      arr[4 * i] = p; arr[4 * i + 1] = p + 1; arr[4 * i + 2] = p - 1; arr[4 * i + 3] = p;
     }
   TFData d;
   BuildTF(d, PERIOD_M15, arr, 1.0, 2, D'2026.01.14 08:00', 100, 0);
   double hi, lo;
   t.True(CPatterns::AsiaRange(d, 0, hi, lo), "rango asiático encontrado");
   // velas 06:00..06:45 (cronológicas 0..3) -> precios 100..103
   t.EqDbl(hi, 104.0, 1e-9, "máximo asiático");
   t.EqDbl(lo, 99.0, 1e-9, "mínimo asiático");
   t.True(CPatterns::AsiaRange(d, 2 * 3600, hi, lo), "con servidor UTC+2 cambia la ventana");
   // servidor 06:00..08:00 = 04:00..06:00 UTC: toda la serie es asiática
   t.EqDbl(hi, 109.0, 1e-9, "máximo asiático con offset +2");

   StrategyCommonConfig c;
   StrategyCommonDefaultConfig(c);
   string why;
   t.True(StrategyCommonValidateConfig(c, why), "config común por defecto válida");
   StrategyCommonConfig b = c; b.max_sl_atr = 0.4;
   t.True(!StrategyCommonValidateConfig(b, why), "rechaza max_sl <= min_sl");
   SMCConfig sc; SMCDefaultConfig(sc); sc.use_fvg = false; sc.use_order_block = false;
   t.True(!SMCValidateConfig(sc, why), "SMC rechaza sin FVG ni OB");
   ReversalConfig rc; ReversalDefaultConfig(rc); rc.min_confirmations = 2;
   t.True(!ReversalValidateConfig(rc, why), "Reversal rechaza menos de 3 confirmaciones");
   BreakoutConfig bc; BreakoutDefaultConfig(bc); bc.min_body_ratio = 1.5;
   t.True(!BreakoutValidateConfig(bc, why), "Breakout rechaza cuerpo >= 1");
   CStrategySMC smc;
   t.True(!smc.Init(b, sc, NULL), "Init rechaza config inválida");
  }

void OnStart()
  {
   CTestRunner t("Test_Phase4");
   TestPrimitives(t);
   TestSMC(t);
   TestBreakout(t);
   TestReversal(t);
   t.Finish();
  }
