//+------------------------------------------------------------------+
//| Test_MarketEngine_Custom.mq5                                     |
//| Prueba de integración de CMarketEngine sin bróker: crea un       |
//| símbolo personalizado con historial M1 sintético y verifica      |
//| carga de datos, orientación de series (índice 0 = última vela    |
//| cerrada), indicadores, pivotes y validaciones.                   |
//| El símbolo se elimina al terminar.                               |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>
#include "TestFramework.mqh"

input string InpCustomSymbol = "XAUTEST_SYN";
input int    InpHours        = 900;      // horas de historial sintético

double SynthPrice(const int i)
  {
   double t = (double)i;
   return 2400.0 + 30.0 * MathSin(2.0 * M_PI * t / 4320.0)     // ciclo ~3 días
          + 8.0 * MathSin(2.0 * M_PI * t / 300.0)               // ciclo ~5 h
          + 0.8 * MathSin(t * 1.618033);                        // ruido determinista
  }

bool CreateSymbol(CTestRunner &t, datetime &last_bar_time, double &last_close)
  {
   if(SymbolInfoInteger(InpCustomSymbol, SYMBOL_CUSTOM))
     {
      SymbolSelect(InpCustomSymbol, false);
      CustomSymbolDelete(InpCustomSymbol);
     }
   if(!t.True(CustomSymbolCreate(InpCustomSymbol, "XAUUSD_Tests"), "CustomSymbolCreate"))
      return false;
   CustomSymbolSetInteger(InpCustomSymbol, SYMBOL_DIGITS, 2);
   CustomSymbolSetDouble(InpCustomSymbol, SYMBOL_POINT, 0.01);
   CustomSymbolSetDouble(InpCustomSymbol, SYMBOL_TRADE_TICK_SIZE, 0.01);

   int n = InpHours * 60;
   datetime now = TimeTradeServer();
   datetime end = now - (now % 60);           // minuto actual (barra en formación)
   datetime start = end - (datetime)(n - 1) * 60;
   MqlRates r[];
   ArrayResize(r, n);
   double prev = SynthPrice(0);
   for(int i = 0; i < n; i++)
     {
      double c = SynthPrice(i + 1);
      r[i].time = start + (datetime)i * 60;
      r[i].open = NormalizeDouble(prev, 2);
      r[i].close = NormalizeDouble(c, 2);
      r[i].high = NormalizeDouble(MathMax(prev, c) + 0.30, 2);
      r[i].low = NormalizeDouble(MathMin(prev, c) - 0.30, 2);
      r[i].tick_volume = 50 + (i % 17);
      r[i].real_volume = 0;
      r[i].spread = 20;
      prev = c;
     }
   int upd = CustomRatesUpdate(InpCustomSymbol, r);
   if(!t.EqInt(upd, n, "CustomRatesUpdate cargó todas las velas M1"))
      return false;
   t.True(SymbolSelect(InpCustomSymbol, true), "SymbolSelect símbolo sintético");
   last_bar_time = r[n - 1].time;
   last_close = r[n - 1].close;

   MqlTick tk[1];
   ZeroMemory(tk);
   tk[0].time = last_bar_time + 30;
   tk[0].time_msc = (long)tk[0].time * 1000;
   tk[0].bid = last_close;
   tk[0].ask = NormalizeDouble(last_close + 0.25, 2);
   tk[0].last = 0;
   tk[0].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
   t.True(CustomTicksAdd(InpCustomSymbol, tk) > 0, "CustomTicksAdd tick actual");
   return true;
  }

//--- EMA independiente (semilla = primer cierre, como MODE_EMA de MT5 según su fórmula estándar)
double ReferenceEMA(const string sym, const ENUM_TIMEFRAMES tf, const int period, const int shift)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);   // cronológico
   int total = Bars(sym, tf);
   int got = CopyRates(sym, tf, 0, total, r);
   if(got <= shift + period)
      return 0.0;
   int last = got - 1 - shift;
   double k = 2.0 / (period + 1.0);
   double ema = r[0].close;
   for(int i = 1; i <= last; i++)
      ema = r[i].close * k + ema * (1.0 - k);
   return ema;
  }

void OnStart()
  {
   CTestRunner t("Test_MarketEngine_Custom");
   datetime last_bar_time;
   double last_close;
   if(!CreateSymbol(t, last_bar_time, last_close))
     {
      t.Finish();
      return;
     }

   CLogger log;
   log.Init("TEST_MarketEngine", LOG_DEBUG, LOG_WARN);
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   CSessionClock clk;
   t.True(clk.Init(ccfg, false), "SessionClock Init en vivo: " + clk.LastError());

   //--- símbolo inexistente debe fallar
   MarketEngineConfig bad;
   MarketEngineDefaultConfig(bad, "NO_SUCH_SYMBOL_123");
   CMarketEngine me_bad;
   t.True(!me_bad.Init(bad, &log, &clk), "Init rechaza símbolo inexistente");

   MarketEngineConfig cfg;
   MarketEngineDefaultConfig(cfg, InpCustomSymbol);
   CMarketEngine me;
   if(!t.True(me.Init(cfg, &log, &clk), "MarketEngine Init en símbolo sintético"))
     {
      t.Finish();
      return;
     }

   //--- los indicadores se calculan de forma asíncrona: reintentar hasta 30 s
   MarketSnapshot s;
   bool ok = false;
   for(int i = 0; i < 60 && !ok; i++)
     {
      ok = me.Update(s);
      if(!ok)
         Sleep(500);
     }
   if(!t.True(ok, "Update produce instantánea válida: " + s.invalid_reason))
     {
      me.Deinit();
      t.Finish();
      return;
     }
   t.Note(CMarketEngine::Describe(s));

   //--- orientación: índice 0 = última vela CERRADA
   t.EqTime(s.m5.rates[0].time, iTime(InpCustomSymbol, PERIOD_M5, 1), "M5 rates[0] = vela cerrada shift 1");
   t.EqTime(s.h1.rates[0].time, iTime(InpCustomSymbol, PERIOD_H1, 1), "H1 rates[0] = vela cerrada shift 1");
   t.True(s.m5.rates[0].time > s.m5.rates[1].time, "series ordenadas de reciente a antigua");
   t.EqInt(s.h1.bars, cfg.analysis_bars, "H1 velas cargadas");
   t.EqInt(s.m15.bars, cfg.analysis_bars, "M15 velas cargadas");
   t.EqInt(s.m5.bars, cfg.analysis_bars, "M5 velas cargadas");

   //--- EMA contra cálculo independiente (misma vela, shift 1)
   double ref50 = ReferenceEMA(InpCustomSymbol, PERIOD_M5, 50, 1);
   t.EqDbl(s.m5.ema_fast[0], ref50, 0.01, "EMA50 M5 coincide con referencia independiente");
   double ref200 = ReferenceEMA(InpCustomSymbol, PERIOD_H1, 200, 1);
   t.EqDbl(s.h1.ema_slow[0], ref200, 0.05, "EMA200 H1 coincide con referencia independiente");

   //--- rangos y derivados
   t.True(s.m5.rsi[0] > 0 && s.m5.rsi[0] < 100, "RSI M5 en (0,100)");
   t.True(s.h1.adx[0] >= 0 && s.h1.adx[0] <= 100, "ADX H1 en [0,100]");
   t.True(s.m15.atr[0] > 0, "ATR M15 > 0");
   t.True(s.h1.atr_ratio > 0, "ratio ATR H1 > 0");
   t.True(s.m15.swing_count >= 4, "pivotes M15 detectados en serie oscilante");
   t.True(s.m15.structure != STRUCTURE_UNKNOWN, "estructura M15 clasificada");
   bool confirmed = true;
   for(int i = 0; i < s.m5.swing_count; i++)
      if(s.m5.swings[i].bar_index < cfg.pivot_n_m5)
         confirmed = false;
   t.True(confirmed, "todos los pivotes M5 están confirmados");
   t.True(s.m5.range_high >= s.m5.range_low && s.m5.range_low > 0, "rango M5 coherente");
   t.EqDbl(s.spread_points, 25.0, 0.5, "spread actual en puntos");
   t.EqDbl(s.spread_avg_points, 20.0, 0.01, "spread medio desde MqlRates.spread");

   //--- detección de vela nueva: la primera llamada no cuenta, la segunda sin cambios tampoco
   t.True(!me.IsNewBar(PERIOD_M5), "IsNewBar: primera lectura no es vela nueva");
   t.True(!me.IsNewBar(PERIOD_M5), "IsNewBar: sin cambio no es vela nueva");

   me.Deinit();
   t.True(!me.Update(s), "Update tras Deinit devuelve inválido");
   log.Close();

   SymbolSelect(InpCustomSymbol, false);
   CustomSymbolDelete(InpCustomSymbol);
   t.Finish();
  }
