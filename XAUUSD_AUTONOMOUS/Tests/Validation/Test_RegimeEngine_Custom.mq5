//+------------------------------------------------------------------+
//| Test_RegimeEngine_Custom.mq5                                     |
//| Integración MarketEngine -> RegimeEngine con indicadores reales  |
//| de MT5 sobre símbolos sintéticos:                                |
//|  - tendencia alcista con retrocesos  -> TREND_UP                 |
//|  - tendencia bajista (espejo)        -> TREND_DOWN               |
//|  - oscilación lateral                -> no debe ser tendencia    |
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

//--- crea el símbolo, inicializa motores y devuelve la clasificación instantánea
bool RunCase(CTestRunner &t, CLogger &log, CSessionClock &clk, const string name, TSynthPriceFunc f,
             RegimeState &st, MarketSnapshot &snap)
  {
   string err = SyntheticSymbolCreate(name, SYN_MINUTES, f, 0.25, 20);
   if(!t.True(err == "", name + ": símbolo creado " + err))
      return false;
   MarketEngineConfig mcfg;
   MarketEngineDefaultConfig(mcfg, name);
   CMarketEngine me;
   if(!t.True(me.Init(mcfg, &log, &clk), name + ": MarketEngine Init"))
      return false;
   bool ok = false;
   for(int i = 0; i < 60 && !ok; i++)
     {
      ok = me.Update(snap);
      if(!ok)
         Sleep(500);
     }
   t.True(ok, name + ": snapshot válido " + snap.invalid_reason);
   RegimeConfig rc;
   RegimeDefaultConfig(rc);
   CRegimeEngine::Classify(snap, rc, st);
   t.Note(name + ": " + CRegimeEngine::Describe(st));
   me.Deinit();
   SyntheticSymbolDelete(name);
   return ok;
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
   RegimeState st;
   MarketSnapshot s;

   if(RunCase(t, log, clk, "SYN_UP", PriceUp, st, s))
     {
      t.EqInt(st.raw_regime, REGIME_TREND_UP, "serie alcista -> TREND_UP");
      t.True(st.h1_structure == STRUCTURE_BULLISH, "estructura H1 alcista detectada");
     }
   if(RunCase(t, log, clk, "SYN_DOWN", PriceDown, st, s))
     {
      t.EqInt(st.raw_regime, REGIME_TREND_DOWN, "serie bajista -> TREND_DOWN");
      t.True(st.h1_structure == STRUCTURE_BEARISH, "estructura H1 bajista detectada");
     }
   if(RunCase(t, log, clk, "SYN_FLAT", PriceFlat, st, s))
     {
      t.True(st.raw_regime != REGIME_TREND_UP && st.raw_regime != REGIME_TREND_DOWN,
             "serie lateral no se clasifica como tendencia");
     }
   if(RunCase(t, log, clk, "SYN_SHOCK", PriceShock, st, s))
     {
      t.EqInt(st.raw_regime, REGIME_HIGH_VOLATILITY, "choque de volatilidad -> HIGH_VOLATILITY");
      t.True(st.m15_atr_ratio >= 2.2 || st.h1_atr_ratio >= 1.8, "ratio ATR supera el umbral");
     }
   log.Close();
   t.Finish();
  }
