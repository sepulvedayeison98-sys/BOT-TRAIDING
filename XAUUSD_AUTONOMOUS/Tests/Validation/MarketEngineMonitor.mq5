//+------------------------------------------------------------------+
//| MarketEngineMonitor.mq5                                          |
//| EA de DIAGNÓSTICO de la Fase 2. NO OPERA: no contiene ninguna    |
//| llamada de trading. Registra una instantánea de MarketEngine     |
//| en cada vela M5 cerrada para verificar datos reales de XAUUSD    |
//| (demo o Strategy Tester).                                        |
//| Log: MQL5/Files/XAUUSD/logs/MarketEngineMonitor_<fecha>.log      |
//+------------------------------------------------------------------+
#property strict

#include <XAUUSD/Types.mqh>
#include <XAUUSD/Logger.mqh>
#include <XAUUSD/SessionClock.mqh>
#include <XAUUSD/MarketEngine.mqh>

input group "Sesiones (hora local de cada plaza, minutos desde 00:00)"
input int            InpLondonOpenMin   = 480;    // Londres apertura (08:00)
input int            InpLondonCloseMin  = 990;    // Londres cierre (16:30)
input int            InpNewYorkOpenMin  = 480;    // Nueva York apertura (08:00)
input int            InpNewYorkCloseMin = 1020;   // Nueva York cierre (17:00)
input group "Hora del servidor en Strategy Tester"
input int            InpTesterGmtOffsetMin = 0;           // Offset estándar del servidor (minutos)
input ENUM_DST_RULE  InpTesterDstRule      = DST_RULE_NONE; // Regla DST del servidor
input group "Indicadores"
input int            InpEmaFast   = 50;
input int            InpEmaSlow   = 200;
input int            InpRsi       = 14;
input int            InpAdx       = 14;
input int            InpAtr       = 14;
input int            InpBars      = 200;   // Velas cerradas analizadas por TF
input group "Registro"
input ENUM_LOG_LEVEL InpPrintLevel = LOG_INFO;

CLogger        g_log;
CSessionClock  g_clock;
CMarketEngine  g_market;
MarketSnapshot g_snap;

int OnInit()
  {
   g_log.Init("MarketEngineMonitor", LOG_DEBUG, InpPrintLevel);
   SessionClockConfig ccfg;
   SessionClockDefaultConfig(ccfg);
   ccfg.london_open_min = InpLondonOpenMin;
   ccfg.london_close_min = InpLondonCloseMin;
   ccfg.newyork_open_min = InpNewYorkOpenMin;
   ccfg.newyork_close_min = InpNewYorkCloseMin;
   ccfg.tester_std_offset_sec = InpTesterGmtOffsetMin * 60;
   ccfg.tester_dst_rule = InpTesterDstRule;
   if(!g_clock.Init(ccfg, MQLInfoInteger(MQL_TESTER) != 0))
     {
      g_log.Critical("Monitor", "CLOCK_INIT_FAILED", g_clock.LastError());
      return INIT_PARAMETERS_INCORRECT;
     }
   g_log.SetUtcOffset(g_clock.ServerOffsetAt(TimeTradeServer()));

   MarketEngineConfig mcfg;
   MarketEngineDefaultConfig(mcfg, _Symbol);
   mcfg.ema_fast_period = InpEmaFast;
   mcfg.ema_slow_period = InpEmaSlow;
   mcfg.rsi_period = InpRsi;
   mcfg.adx_period = InpAdx;
   mcfg.atr_period = InpAtr;
   mcfg.analysis_bars = InpBars;
   mcfg.min_history_bars = MathMax(mcfg.min_history_bars, InpBars + InpEmaSlow);
   if(!g_market.Init(mcfg, &g_log, &g_clock))
      return INIT_FAILED;

   g_log.Info("Monitor", "START",
              StringFormat("símbolo=%s tester=%s offset_servidor=%d s modo=SOLO_LECTURA",
                           _Symbol, (g_clock.IsTester() ? "sí" : "no"),
                           g_clock.ServerOffsetAt(TimeTradeServer())));
   EventSetTimer(60);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_market.Deinit();
   g_log.Info("Monitor", "STOP", StringFormat("reason=%d", reason));
   g_log.Close();
   Comment("");
  }

void OnTick()
  {
   g_market.SampleTickSpread();
   if(!g_market.IsNewBar(PERIOD_M5))
      return;
   bool ok = g_market.Update(g_snap);
   string d = CMarketEngine::Describe(g_snap);
   if(ok)
      g_log.Info("Monitor", "SNAPSHOT", d);
   else
      g_log.LogOnChange("snapshot.invalid", g_snap.invalid_reason, LOG_WARN, "Monitor", "SNAPSHOT_INVALID", d);
   if(ok)
      g_log.LogOnChange("snapshot.invalid", "", LOG_INFO, "Monitor", "SNAPSHOT_VALID", "datos válidos de nuevo");
   Comment("MarketEngineMonitor (solo lectura)\n", d);
  }

void OnTimer()
  {
   if(!g_clock.Refresh())
      g_log.LogOnChange("clock", g_clock.LastError(), LOG_ERROR, "Monitor", "CLOCK_INVALID", g_clock.LastError());
   else
      g_log.SetUtcOffset(g_clock.ServerOffsetAt(TimeTradeServer()));
  }
