//+------------------------------------------------------------------+
//| Test_RegimeEngine_Custom.mq5                                     |
//| Integración MarketEngine -> RegimeEngine con indicadores reales  |
//| de MT5 sobre símbolos sintéticos:                                |
//| Se reproducen 600 instantes M5 con UpdateAt y se mide la         |
//| proporción de cada clasificación (las fronteras H1 dependen de   |
//| la hora de ejecución, por eso no se usa un único instante):      |
//|  - tendencia alcista con retrocesos  -> mayoría TREND_UP         |
//|  - tendencia bajista (espejo)        -> mayoría TREND_DOWN       |
//|  - oscilación lateral                -> pocas lecturas de        |
//|                                         tendencia                |
//|  - choque de volatilidad al final    -> HIGH_VOLATILITY          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include <XAUUSD/RegimeEngine.mqh>
#include "TestFramework.mqh"
#include "SyntheticSymbol.mqh"

#define SYN_HOURS 900
#define SYN_MINUTES (SYN_HOURS * 60)

//--- tendencia: +1.2/hora con oscilación de 10 h y amplitud 6 (máximos y mínimos crecientes)
double PriceUp(const int i)   { return 2000.0 + 0.02 * i + 6.0 * MathSin(2.0 * M_PI * i / 600.0) + 0.5 * MathSin(i * 1.618033); }
double PriceDown(const int i) { return 3200.0 - 0.02 * i + 6.0 * MathSin(2.0 * M_PI * i / 600.0) + 0.5 * MathSin(i * 1.618033); }
//--- lateral: oscilación de 12 h sin deriva
double PriceFlat(const int i) { return 2400.0 + 10.0 * MathSin(2.0 * M_PI * i / 720.0) + 3.0 * MathSin(2.0 * M_PI * i / 97.0); }
//--- lateral tranquilo y, en las últimas 6 horas, oscilación 12 veces mayor
double PriceShock(const int i)
  {
   double base = 2400.0 + 4.0 * MathSin(2.0 * M_PI * i / 240.0) + 0.5 * MathSin(i * 1.618033);
   if(i > SYN_MINUTES - 360)
      base += 48.0 * MathSin(2.0 * M_PI * (i - (SYN_MINUTES - 360)) / 90.0);
   return base;
  }

#define REPLAY_BARS 600

struct RegimeShares
  {
   int               n;
   double            up;
   double            down;
   double            range;
   double            hv;
   double            none;
  };

//--- crea el símbolo y mide la proporción de clasificaciones instantáneas en REPLAY_BARS
//--- instantes M5; además devuelve la clasificación en el instante actual.
bool RunCase(CTestRunner &t, CLogger &log, CSessionClock &clk, const string name, TSynthPriceFunc f,
             RegimeShares &sh, RegimeState &last)
  {
   ZeroMemory(sh);
   string err = SyntheticSymbolCreate(name, SYN_MINUTES, f, 0.25, 20);
   if(!t.True(err == "", name + ": símbolo creado " + err))
      return false;
   MarketEngineConfig mcfg;
   MarketEngineDefaultConfig(mcfg, name);
   CMarketEngine me;
   if(!t.True(me.Init(mcfg, &log, &clk), name + ": MarketEngine Init"))
      return false;
   RegimeConfig rc;
   RegimeDefaultConfig(rc);
   MarketSnapshot snap;
   datetime cur = (datetime)SeriesInfoInteger(name, PERIOD_M5, SERIES_LASTBAR_DATE);
   bool ok = false;
   for(int i = 0; i < 60 && !ok; i++)
     {
      ok = me.UpdateAt(cur, snap);
      if(!ok)
         Sleep(500);
     }
   t.True(ok, name + ": snapshot válido " + snap.invalid_reason);
   int counts[5] = {0, 0, 0, 0, 0};
   for(int shift = REPLAY_BARS; shift >= 0 && ok; shift--)
     {
      if(!me.UpdateAt(iTime(name, PERIOD_M5, shift), snap))
         continue;
      RegimeState st;
      counts[(int)CRegimeEngine::Classify(snap, rc, st)]++;
      sh.n++;
      if(shift == 0)
         last = st;
     }
   if(sh.n > 0)
     {
      sh.up = (double)counts[REGIME_TREND_UP] / sh.n;
      sh.down = (double)counts[REGIME_TREND_DOWN] / sh.n;
      sh.range = (double)counts[REGIME_RANGE] / sh.n;
      sh.hv = (double)counts[REGIME_HIGH_VOLATILITY] / sh.n;
      sh.none = (double)counts[REGIME_NO_TRADE] / sh.n;
     }
   t.Note(StringFormat("%s: n=%d UP=%.0f%% DOWN=%.0f%% RANGE=%.0f%% HV=%.0f%% NO_TRADE=%.0f%% | actual: %s", name, sh.n,
                       100 * sh.up, 100 * sh.down, 100 * sh.range, 100 * sh.hv, 100 * sh.none, CRegimeEngine::Describe(last)));
   me.Deinit();
   SyntheticSymbolDelete(name);
   return ok && sh.n > REPLAY_BARS / 2;
  }

void OnStart()
  {
   CTestRunner t("Test_RegimeEngine_Custom");
   CLogger log;
   log.Init("TEST_RegimeEngine", LOG_DEBUG, LOG_WARN);
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   CSessionClock clk;
   clk.Init(ccfg, false);
   RegimeShares sh;
   RegimeState st;

   if(RunCase(t, log, clk, "SYN_UP", PriceUp, sh, st))
     {
      t.True(sh.up >= 0.5, StringFormat("serie alcista: TREND_UP en >= 50%% de los instantes (%.0f%%)", 100 * sh.up));
      t.True(sh.down <= 0.02, StringFormat("serie alcista: TREND_DOWN <= 2%% (%.0f%%)", 100 * sh.down));
     }
   if(RunCase(t, log, clk, "SYN_DOWN", PriceDown, sh, st))
     {
      t.True(sh.down >= 0.5, StringFormat("serie bajista: TREND_DOWN en >= 50%% de los instantes (%.0f%%)", 100 * sh.down));
      t.True(sh.up <= 0.02, StringFormat("serie bajista: TREND_UP <= 2%% (%.0f%%)", 100 * sh.up));
     }
   if(RunCase(t, log, clk, "SYN_FLAT", PriceFlat, sh, st))
      t.True(sh.up + sh.down <= 0.25, StringFormat("serie lateral: tendencia en <= 25%% de los instantes (%.0f%%)",
                                                   100 * (sh.up + sh.down)));
   if(RunCase(t, log, clk, "SYN_SHOCK", PriceShock, sh, st))
     {
      t.EqInt(st.raw_regime, REGIME_HIGH_VOLATILITY, "choque de volatilidad al final -> HIGH_VOLATILITY");
      t.True(st.m15_atr_ratio >= 2.2 || st.h1_atr_ratio >= 1.8, "ratio ATR supera el umbral");
     }
   log.Close();
   t.Finish();
  }
