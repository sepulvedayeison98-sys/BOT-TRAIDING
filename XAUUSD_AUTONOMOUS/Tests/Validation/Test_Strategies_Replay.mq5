//+------------------------------------------------------------------+
//| Test_Strategies_Replay.mq5                                       |
//| Integración con indicadores reales de MT5 sobre símbolos         |
//| sintéticos:                                                      |
//|  1. Sin mirar el futuro: UpdateAt(D) es idéntico en un símbolo   |
//|     completo y en una copia que termina en D.                    |
//|  2. Update() (vivo) == UpdateAt(apertura M5 actual).             |
//|  3. Reproducción de N velas M5 por Regime + 3 estrategias: toda  |
//|     señal producida cumple sus invariantes.                      |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/RegimeEngine.mqh>
#include <XAUUSD/StrategySMC.mqh>
#include <XAUUSD/StrategyBreakout.mqh>
#include <XAUUSD/StrategyReversal.mqh>
#include "TestFramework.mqh"
#include "SyntheticSymbol.mqh"

input int InpReplayBars = 1500;   // velas M5 reproducidas por serie

#define SYN_DAYS 50
#define SYN_MINUTES (SYN_DAYS * 1440)

double g_prices[];
double PriceAt(const int i) { return g_prices[i]; }

double Gauss(void)
  {
   double u1 = (MathRand() + 1.0) / 32768.0;
   double u2 = (MathRand() + 1.0) / 32768.0;
   return MathSqrt(-2.0 * MathLog(u1)) * MathCos(2.0 * M_PI * u2);
  }

//--- mode 0: alternancia de regímenes; 1: alcista; 2: bajista; 3: lateral
void Generate(const int mode, const int seed)
  {
   ArrayResize(g_prices, SYN_MINUTES + 1);
   MathSrand(seed);
   double p = 2400.0, center = 2400.0;
   int block = 3 * 1440;
   for(int i = 0; i <= SYN_MINUTES; i++)
     {
      double noise = 0.3 * Gauss();
      int phase = (mode == 0) ? (i / block) % 4 : (mode == 1 ? 0 : (mode == 2 ? 2 : 1));
      if(i % block == 0)
         center = p;
      switch(phase)
        {
         case 0: p += 0.008 + noise; break;
         case 1: p += 0.003 * (center - p) + noise; break;
         case 2: p += -0.008 + noise; break;
         default: p += 0.003 * (center - p) + noise;
        }
      g_prices[i] = p;
     }
  }

//--- "" si son idénticos; si no, describe la primera diferencia
string DiffTF(const TFData &a, const TFData &b)
  {
   if(a.bars != b.bars)
      return StringFormat("bars %d vs %d", a.bars, b.bars);
   for(int i = 0; i < a.bars; i++)
     {
      if(a.rates[i].time != b.rates[i].time)
         return StringFormat("time[%d] %s vs %s", i, TimeToString(a.rates[i].time), TimeToString(b.rates[i].time));
      if(a.rates[i].open != b.rates[i].open || a.rates[i].high != b.rates[i].high ||
         a.rates[i].low != b.rates[i].low || a.rates[i].close != b.rates[i].close)
         return StringFormat("OHLC[%d] %s: %.2f/%.2f/%.2f/%.2f vs %.2f/%.2f/%.2f/%.2f", i, TimeToString(a.rates[i].time),
                             a.rates[i].open, a.rates[i].high, a.rates[i].low, a.rates[i].close,
                             b.rates[i].open, b.rates[i].high, b.rates[i].low, b.rates[i].close);
      if(MathAbs(a.ema_fast[i] - b.ema_fast[i]) > 1e-9 || MathAbs(a.ema_slow[i] - b.ema_slow[i]) > 1e-9)
         return StringFormat("EMA[%d] %.6f/%.6f vs %.6f/%.6f", i, a.ema_fast[i], a.ema_slow[i], b.ema_fast[i], b.ema_slow[i]);
      if(MathAbs(a.rsi[i] - b.rsi[i]) > 1e-9 || MathAbs(a.adx[i] - b.adx[i]) > 1e-9 || MathAbs(a.atr[i] - b.atr[i]) > 1e-9)
         return StringFormat("RSI/ADX/ATR[%d] %.6f/%.6f/%.6f vs %.6f/%.6f/%.6f", i, a.rsi[i], a.adx[i], a.atr[i],
                             b.rsi[i], b.adx[i], b.atr[i]);
     }
   if(a.swing_count != b.swing_count || a.structure != b.structure)
      return StringFormat("pivotes %d/%d estructura %d/%d", a.swing_count, b.swing_count, a.structure, b.structure);
   return "";
  }

bool SameTF(const TFData &a, const TFData &b) { return DiffTF(a, b) == ""; }

void TestNoLookahead(CTestRunner &t, CLogger &log, CSessionClock &clk)
  {
   Generate(0, 7);
   string e1 = SyntheticSymbolCreate("SYN_FULL", SYN_MINUTES, PriceAt, 0.25, 20);
   t.True(e1 == "", "símbolo completo: " + e1);
   datetime end = iTime("SYN_FULL", PERIOD_M1, 0);
   // D: instante alineado a M5, a media sesión de un día laborable, >= 2 días antes del final
   datetime D = ((end - 2 * 86400) / 86400) * 86400 + 14 * 3600 + 35 * 60;
   while(CTimeRules::DayOfWeek(D) == 0 || CTimeRules::DayOfWeek(D) == 6)
      D -= 86400;
   int cut = (int)((end - (D - 60)) / 60);                 // la copia termina en la vela M1 de D-60
   string e2 = SyntheticSymbolCreate("SYN_CUT", SYN_MINUTES, PriceAt, 0.25, 20, cut, false);
   t.True(e2 == "", "símbolo cortado: " + e2);
   t.EqTime(iTime("SYN_CUT", PERIOD_M1, 0), D - 60, "la copia termina justo antes de D");

   MarketEngineConfig ca, cb;
   MarketEngineDefaultConfig(ca, "SYN_FULL");
   MarketEngineDefaultConfig(cb, "SYN_CUT");
   CMarketEngine ma, mb;
   t.True(ma.Init(ca, &log, &clk) && mb.Init(cb, &log, &clk), "motores inicializados");
   MarketSnapshot sa, sb;
   bool oka = false, okb = false;
   for(int i = 0; i < 60 && !(oka && okb); i++)
     {
      oka = ma.UpdateAt(D, sa);
      okb = mb.UpdateAt(D, sb);
      if(!(oka && okb))
         Sleep(500);
     }
   t.True(oka, "UpdateAt(D) en símbolo completo: " + sa.invalid_reason);
   t.True(okb, "UpdateAt(D) en copia cortada: " + sb.invalid_reason);
   if(oka && okb)
     {
      t.True(SameTF(sa.h1, sb.h1), "H1 idéntico con y sin futuro: " + DiffTF(sa.h1, sb.h1));
      t.True(SameTF(sa.m15, sb.m15), "M15 idéntico con y sin futuro: " + DiffTF(sa.m15, sb.m15));
      t.True(SameTF(sa.m5, sb.m5), "M5 idéntico con y sin futuro: " + DiffTF(sa.m5, sb.m5));
      t.EqTime(sa.m5.rates[0].time, D - 300, "M5 última cerrada = D - 5 min");
      t.EqTime(sa.m15.rates[0].time, ((D / 900) * 900) - 900, "M15 última cerrada antes de D");
      t.EqTime(sa.h1.rates[0].time, ((D / 3600) * 3600) - 3600, "H1 última cerrada antes de D");
     }
   //--- vivo vs histórico en el instante actual
   MarketSnapshot live, hist;
   bool ok_live = ma.Update(live);
   datetime cur = (datetime)SeriesInfoInteger("SYN_FULL", PERIOD_M5, SERIES_LASTBAR_DATE);
   bool ok_hist = ma.UpdateAt(cur, hist);
   t.True(ok_live && ok_hist, "Update y UpdateAt actuales válidos: " + live.invalid_reason + hist.invalid_reason);
   if(ok_live && ok_hist)
     {
      t.True(SameTF(live.h1, hist.h1) && SameTF(live.m15, hist.m15) && SameTF(live.m5, hist.m5),
             "Update() == UpdateAt(apertura M5 actual)");
      t.EqTime(live.m5.rates[0].time, iTime("SYN_FULL", PERIOD_M5, 1), "vivo: M5 última cerrada = shift 1");
     }
   ma.Deinit();
   mb.Deinit();
   SyntheticSymbolDelete("SYN_FULL");
   SyntheticSymbolDelete("SYN_CUT");
  }

void Replay(CTestRunner &t, CLogger &log, CSessionClock &clk, const string name, const int mode, const int seed)
  {
   Generate(mode, seed);
   string err = SyntheticSymbolCreate(name, SYN_MINUTES, PriceAt, 0.25, 20);
   if(!t.True(err == "", name + ": símbolo " + err))
      return;
   MarketEngineConfig mc;
   MarketEngineDefaultConfig(mc, name);
   CMarketEngine me;
   me.Init(mc, &log, &clk);
   RegimeConfig rc;
   RegimeDefaultConfig(rc);
   CRegimeEngine re;
   re.Init(rc, &log);
   StrategyCommonConfig common;
   StrategyCommonDefaultConfig(common);
   common.pivot_n_m15 = mc.pivot_n_m15;
   common.pivot_n_m5 = mc.pivot_n_m5;
   SMCConfig smc_cfg;        SMCDefaultConfig(smc_cfg);
   BreakoutConfig bo_cfg;    BreakoutDefaultConfig(bo_cfg);
   ReversalConfig rv_cfg;    ReversalDefaultConfig(rv_cfg);
   CStrategySMC smc;         smc.Init(common, smc_cfg, &log);
   CStrategyBreakout bo;     bo.Init(common, bo_cfg, &log);
   CStrategyReversal rv;     rv.Init(common, rv_cfg, &log);
   CStrategyBase *strats[3];
   strats[0] = &smc; strats[1] = &bo; strats[2] = &rv;

   //--- esperar a que los indicadores estén calculados
   MarketSnapshot s;
   datetime cur = (datetime)SeriesInfoInteger(name, PERIOD_M5, SERIES_LASTBAR_DATE);
   for(int i = 0; i < 60 && !me.UpdateAt(cur, s); i++)
      Sleep(500);

   int valid = 0, invalid = 0, total = 0, bad = 0;
   int per[4] = {0, 0, 0, 0};
   int regimes[5] = {0, 0, 0, 0, 0};
   string ids = "|";
   string first_bad = "";
   for(int shift = InpReplayBars; shift >= 0; shift--)
     {
      datetime D = iTime(name, PERIOD_M5, shift);
      if(!me.UpdateAt(D, s))
        { invalid++; continue; }
      valid++;
      RegimeState st;
      re.Evaluate(s, st);
      regimes[(int)st.regime]++;
      for(int k = 0; k < 3; k++)
        {
         TradeSignal out[];
         int n = strats[k].Evaluate(s, st, out);
         for(int j = 0; j < n; j++)
           {
            total++;
            per[(int)out[j].strategy]++;
            string why = "";
            bool ok = CStrategyBase::ValidateSignal(out[j], why);
            if(ok && out[j].entry_price != s.m5.rates[0].close)
              { ok = false; why = "entrada distinta al cierre M5"; }
            if(ok && out[j].created != D)
              { ok = false; why = "created distinto del instante de decisión"; }
            double atr = s.m15.atr[0];
            double dist = MathAbs(out[j].entry_price - out[j].sl);
            if(ok && (dist < common.min_sl_atr * atr - 1e-6 || dist > common.max_sl_atr * atr + 0.011))
              { ok = false; why = StringFormat("distancia SL %.2f fuera de límites ATR", dist); }
            if(ok && (st.regime == REGIME_NO_TRADE || st.regime == REGIME_HIGH_VOLATILITY))
              { ok = false; why = "señal en régimen sin operación"; }
            if(ok && StringFind(ids, "|" + out[j].signal_id + "|") >= 0)
              { ok = false; why = "signal_id repetido"; }
            ids += out[j].signal_id + "|";
            if(!ok)
              {
               bad++;
               if(first_bad == "")
                  first_bad = why + " :: " + CStrategyBase::Describe(out[j]);
              }
           }
        }
     }
   t.True(valid > InpReplayBars * 9 / 10, StringFormat("%s: instantáneas válidas %d / %d", name, valid, valid + invalid));
   t.EqInt(bad, 0, name + ": señales que violan invariantes. " + first_bad);
   t.Note(StringFormat("%s: %d velas, señales=%d (SMC %d, BO %d, RV %d); régimen NO_TRADE=%d UP=%d DOWN=%d RANGE=%d HV=%d",
                       name, valid, total, per[STRAT_SMC], per[STRAT_BREAKOUT], per[STRAT_REVERSAL],
                       regimes[REGIME_NO_TRADE], regimes[REGIME_TREND_UP], regimes[REGIME_TREND_DOWN],
                       regimes[REGIME_RANGE], regimes[REGIME_HIGH_VOLATILITY]));
   me.Deinit();
   SyntheticSymbolDelete(name);
  }

void OnStart()
  {
   CTestRunner t("Test_Strategies_Replay");
   CLogger log;
   log.Init("TEST_Replay", LOG_WARN, LOG_ERROR);
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   CSessionClock clk;
   clk.Init(ccfg, false);
   TestNoLookahead(t, log, clk);
   Replay(t, log, clk, "SYN_MIX", 0, 11);
   Replay(t, log, clk, "SYN_UPT", 1, 12);
   Replay(t, log, clk, "SYN_DNT", 2, 13);
   Replay(t, log, clk, "SYN_RNG", 3, 14);
   log.Close();
   t.Finish();
  }
